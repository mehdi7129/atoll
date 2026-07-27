import Foundation
import Observation
import OSLog
import AtollCore

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "retro")

/// Rétrospectives de fin de session : un `claude -p` STRICTEMENT read-only
/// analyse le transcript et rend un JSON structuré ; ATOLL écrit les fichiers
/// (le modèle n'a aucun outil d'écriture — sandbox par construction).
///
/// File FIFO, un seul run à la fois. Chaque étape est fail-open : un échec de
/// spawn/parse est loggé, la session marquée `failed`, zéro retry (le quota
/// prime), zéro impact sur le CLI de l'utilisateur.
@MainActor
@Observable
final class RetrospectiveRunner {
    static let shared = RetrospectiveRunner()

    enum Phase: Equatable { case idle, waiting(String), running(String) }
    private(set) var phase: Phase = .idle
    private(set) var lastOutcome: String?

    /// Branchement vers l'index mémoire 7a : chaque note écrite est indexée.
    @ObservationIgnored var noteSink: ((URL, RetrospectiveReport.Note) -> Void)?
    /// Prévient la 7c qu'au moins un skill vient d'être proposé (rafraîchit la file).
    @ObservationIgnored var onProposalsChanged: (() -> Void)?

    @ObservationIgnored private var queue: [Job] = []
    @ObservationIgnored private var pendingDelay: Task<Void, Never>?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var lastEndedSnapshot: SessionStore.Tracked?
    /// Entrée de journal du run en cours, complétée par `finish`.
    @ObservationIgnored private var pendingAttempt: AttemptRecord?

    /// `forced` = déclenché par un trigger de debug : ce job court-circuite le
    /// gate ET l'interrupteur général (c'est tout son intérêt).
    struct Job {
        let snapshot: SessionStore.Tracked
        let endedAt: Date
        var forced = false
    }

    /// Un run est-il engagé ? Pas seulement « un processus tourne » : la
    /// préparation du condensé (jusqu'à ~2 s sur un transcript de 47 Mo) se
    /// fait AVANT le spawn, `process` encore nil. Sans ce drapeau, une session
    /// qui se terminait pendant cette fenêtre déclenchait un SECOND `claude -p`
    /// payant en parallèle (audit du 2026-07-27).
    @ObservationIgnored private var preparing = false
    private var isBusy: Bool { process != nil || preparing }

    private static let startDelaySeconds: TimeInterval = 15 // fenêtre résurrection 8 s + dernière statusline
    private static let timeoutSeconds: TimeInterval = 600
    // `nonisolated` : lue dans un Task.detached (contexte nonisolated) plus bas.
    nonisolated private static let stdoutCapBytes = 4 * 1024 * 1024

    // MARK: - Entrées (branchées par l'AppDelegate)

    func sessionEnded(_ snapshot: SessionStore.Tracked, reason: SessionStore.SessionEndReason) {
        lastEndedSnapshot = snapshot
        guard LearningSettings.shared.isEnabled else { return } // zéro travail si OFF
        // Les sessions synthétiques (hookless) n'ont qu'un transcript DEVINÉ
        // (newestTranscript, encodage lossy) : rétrospective sur le mauvais
        // fichier possible (revue) → on s'abstient, hooks requis.
        guard !snapshot.isSynthetic else {
            log.info("session \(snapshot.id, privacy: .public) synthétique — pas de rétrospective (transcript non fiable)")
            return
        }
        queue.append(Job(snapshot: snapshot, endedAt: Date()))
        log.info("session \(snapshot.id, privacy: .public) terminée (\(reason.rawValue, privacy: .public)) — rétrospective candidate dans \(Int(Self.startDelaySeconds)) s")
        scheduleNext()
    }

    func sessionResumed(_ sessionID: String) {
        // Reprise pendant l'attente → le job est annulé ; pendant le run → SIGTERM.
        let before = queue.count
        queue.removeAll { $0.snapshot.id == sessionID }
        if queue.count != before {
            log.info("session \(sessionID, privacy: .public) ressuscitée — job annulé")
        }
        if case .running(let running) = phase, running == sessionID {
            log.info("session \(sessionID, privacy: .public) ressuscitée pendant sa rétrospective — arrêt")
            process?.terminate()
        }
    }

    /// Kill-switch (toggle OFF) : effet < 1 s, avec sa PROPRE escalade
    /// SIGTERM → SIGKILL (revue : annuler timeoutTask supprimait le seul
    /// SIGKILL du code — un claude sourd au SIGTERM restait facturé, et
    /// `process` non-nil bloquait toute rétro future jusqu'au redémarrage).
    func disable() {
        queue.removeAll()
        pendingDelay?.cancel()
        pendingDelay = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        terminateWithEscalation()
        phase = .idle
    }

    func terminateActive() {
        terminateWithEscalation()
    }

    private func terminateWithEscalation() {
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(5))
            // kill(pid, 0) == 0 ⟺ le pid vit encore — on n'envoie SIGKILL
            // qu'à un processus toujours présent (fenêtre de recyclage minime).
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    #if DEBUG
    /// Trigger debug : rétrospective sur le PLUS GROS transcript du projet
    /// courant, sans gate. Sert à vérifier le pipeline complet (condensé →
    /// analyse → notes/skills) sur une session réellement riche, sans attendre
    /// qu'une vraie session substantielle se termine. Jamais en release.
    func debugRunOnLargestTranscript(projectDirectory: String) {
        guard !isBusy, pendingDelay == nil else {
            log.error("debug retro : un run ou une attente est déjà en cours")
            return
        }
        let root = BridgePaths.claudeProjectsURL.appendingPathComponent(projectDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let largest = files
            .filter { $0.pathExtension == "jsonl" }
            .max { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let r = (try? rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return l < r
            }
        guard let largest else {
            log.error("debug retro : aucun transcript dans \(root.path, privacy: .public)")
            return
        }
        let size = (try? largest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        log.info("debug retro sur \(largest.lastPathComponent, privacy: .public) (\(size) octets)")
        // Le chemin debug journalise lui aussi : c'est souvent celui qu'on
        // regarde en premier quand on doute du pipeline.
        pendingAttempt = AttemptRecord(
            sessionID: largest.deletingPathExtension().lastPathComponent,
            decidedAt: Date(),
            decision: "run(debug)",
            outcome: nil,
            transcriptBytes: size,
            quotaFraction: SessionStore.shared.realQuota?.fiveHour.usedFraction,
            quotaAgeSeconds: SessionStore.shared.realQuota
                .map { Date().timeIntervalSince($0.receivedAt) }
        )
        let snapshot = SessionStore.Tracked(
            id: largest.deletingPathExtension().lastPathComponent,
            cwd: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/Dynamic_Island").path,
            transcriptPath: largest.path,
            phase: .ended,
            isSynthetic: false,
            firstSeenAt: Date().addingTimeInterval(-3_600),
            lastEventAt: Date()
        )
        Task { await run(Job(snapshot: snapshot, endedAt: Date(), forced: true)) }
    }

    /// Trigger debug : rétrospective sur la dernière session terminée, SANS
    /// gate (mais avec le verrou un-à-la-fois ET sans course avec un délai
    /// en attente). Jamais en release.
    func debugRunOnLastEnded() {
        guard let snapshot = lastEndedSnapshot else {
            log.error("debug retro : aucune session terminée connue")
            return
        }
        guard !isBusy, pendingDelay == nil else {
            log.error("debug retro : un run ou une attente est déjà en cours")
            return
        }
        Task { await run(Job(snapshot: snapshot, endedAt: Date(), forced: true)) }
    }
    #endif

    // MARK: - File

    private func scheduleNext() {
        guard !isBusy, pendingDelay == nil, let job = queue.first else { return }
        phase = .waiting(job.snapshot.id)
        pendingDelay = Task { [weak self] in
            // Le délai appartient au JOB réellement dépilé, pas à la tête au
            // moment de l'armement (revue : un job B arrivé pendant l'attente
            // de A annulé aurait sauté sa fenêtre de résurrection). On dort
            // jusqu'à ce que le job de tête ait VRAIMENT ses 15 s d'âge.
            while let head = self?.queue.first {
                let age = Date().timeIntervalSince(head.endedAt)
                if age >= Self.startDelaySeconds { break }
                try? await Task.sleep(for: .seconds(Self.startDelaySeconds - age))
                guard let self, !Task.isCancelled else { return }
                _ = self // le while relit queue.first : le job a pu changer
            }
            guard let self, !Task.isCancelled else { return }
            // Une curation tourne (elle aussi paie un `claude -p`, jusqu'à
            // 1,50 $ et 10 min) : on ATTEND plutôt que de sauter — sauter
            // grillerait la session. La curation a un timeout dur, l'attente ne
            // peut donc pas être éternelle. La garde était écrite dans l'autre
            // sens seulement : la curation vérifiait la rétrospective, jamais
            // l'inverse (audit du 2026-07-27).
            while NotesCurationService.shared.phase != .idle {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
            }
            self.pendingDelay = nil
            // Un run est déjà en vol (trigger debug) : on laisse finish()
            // rappeler scheduleNext — jamais deux rétrospectives en parallèle.
            guard !self.isBusy else { return }
            guard let job = self.queue.first else { self.phase = .idle; return }
            self.queue.removeFirst()
            await self.evaluateAndRun(job)
        }
    }

    private func evaluateAndRun(_ job: Job) async {
        let decision = gateDecision(for: job)
        let quota = SessionStore.shared.realQuota
        let transcriptBytes = job.snapshot.transcriptPath
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int64 }
            .map(Int.init)

        switch decision {
        case .skip(let reason):
            log.info("rétrospective sautée pour \(job.snapshot.id, privacy: .public) : \(reason.rawValue, privacy: .public)")
            lastOutcome = "skip(\(reason.rawValue))"
            journal(AttemptRecord(
                sessionID: job.snapshot.id,
                decidedAt: Date(),
                decision: "skip(\(reason.rawValue))",
                outcome: nil,
                transcriptBytes: transcriptBytes,
                quotaFraction: quota?.fiveHour.usedFraction,
                quotaAgeSeconds: quota.map { Date().timeIntervalSince($0.receivedAt) }
            ))
            phase = .idle
            scheduleNext()
        case .run:
            pendingAttempt = AttemptRecord(
                sessionID: job.snapshot.id,
                decidedAt: Date(),
                decision: "run",
                outcome: nil,
                transcriptBytes: transcriptBytes,
                quotaFraction: quota?.fiveHour.usedFraction,
                quotaAgeSeconds: quota.map { Date().timeIntervalSince($0.receivedAt) }
            )
            await run(job)
        }
    }

    /// Ajoute une entrée au journal (cap 100, les plus anciennes tombent).
    private func journal(_ record: AttemptRecord, replacingSameID: Bool = false) {
        var state = loadState()
        if replacingSameID { state.attempts.removeAll { $0.id == record.id } }
        state.attempts.append(record)
        state.attempts = Array(state.attempts.suffix(100))
        saveState(state)
    }

    private func gateDecision(for job: Job) -> LearningGate.Decision {
        let snapshot = job.snapshot
        let transcriptSize = snapshot.transcriptPath
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int64 }
            .map(Int.init)
        let stillAlive = SessionStore.shared.sessions
            .first { $0.id == snapshot.id }?.phase.isAlive ?? false
        let facts = LearningGate.SessionFacts(
            sessionID: snapshot.id,
            durationSeconds: job.endedAt.timeIntervalSince(snapshot.firstSeenAt),
            transcriptSizeBytes: transcriptSize,
            userPromptCount: snapshot.isSynthetic ? nil : snapshot.userPromptCount,
            isCurrentlyAlive: stillAlive
        )
        let quota = LearningGate.QuotaFacts(
            usedFraction: SessionStore.shared.realQuota?.fiveHour.usedFraction,
            receivedAt: SessionStore.shared.rawQuotaReceivedAt,
            resetsAt: SessionStore.shared.realQuota?.fiveHour.resetsAt
        )
        return LearningGate.decide(session: facts, quota: quota,
                                   config: LearningSettings.shared.gateConfig,
                                   history: loadHistory(), now: Date())
    }

    // MARK: - Run

    private func run(_ job: Job) async {
        guard let transcriptPath = job.snapshot.transcriptPath else {
            phase = .idle
            scheduleNext()
            return
        }
        // La TENTATIVE compte pour le plafond (persistée AVANT le spawn) :
        // un claude en panne ne peut pas boucler.
        recordAttempt()
        phase = .running(job.snapshot.id)
        // Verrou posé AVANT le seul await : pendant la préparation du condensé,
        // `process` est encore nil et le runner paraissait libre.
        preparing = true
        defer { preparing = false }

        // CONDENSÉ (v0.12.0) : Atoll lit le transcript lui-même, hors MainActor,
        // et n'envoie au modèle que la substance. Les transcripts réels font 9 à
        // 47 Mo — en les faisant lire par le modèle sous 1,50 $, il n'en voyait
        // que ~8 %. Ici, il reçoit tout ce qui compte, borné et gratuit.
        // Condensé ET inventaire hors MainActor : l'inventaire parcourt le
        // cache des plugins (~70 ms à chaud, bien plus à froid).
        let prepared = await Task.detached(priority: .utility) {
            (digest: Self.digest(ofTranscriptAt: transcriptPath),
             capabilities: SkillCatalog().summaryForPrompt())
        }.value
        // L'utilisateur a pu couper l'apprentissage PENDANT la préparation :
        // `disable()` n'avait alors rien à annuler (ni processus, ni délai) et
        // le `claude -p` partait quand même, après l'arrêt explicite.
        guard job.forced || LearningSettings.shared.isEnabled else {
            log.info("apprentissage coupé pendant la préparation — rien n'est lancé")
            finish(job, outcome: "failed(disabled)", transcriptBytes: 0)
            return
        }
        let digest = prepared.digest
        guard let digest, !digest.text.isEmpty else {
            log.error("condensé vide pour \(transcriptPath, privacy: .public) — rien à analyser")
            finish(job, outcome: "failed(digest)", transcriptBytes: 0)
            return
        }
        log.info("condensé : \(digest.entriesKept) entrées, \(digest.characterCount) caractères (tronqué : \(digest.truncated))")
        // Chiffres du condensé au journal : c'est ce qui permet de voir, depuis
        // les Réglages, que le modèle n'a reçu qu'une partie de la session.
        pendingAttempt?.digestEntries = digest.entriesKept
        pendingAttempt?.digestCharacters = digest.characterCount
        pendingAttempt?.digestTruncated = digest.truncated
        // Journalisée MAINTENANT (complétée à la fin) : si l'app se termine
        // pendant le run, la tentative apparaît quand même — l'objectif est
        // « 100 % des fins de session laissent une trace ».
        if let attempt = pendingAttempt { journal(attempt) }

        let userPrompt = RetrospectivePrompt.userPrompt(
            digest: digest.text,
            projectPath: job.snapshot.cwd,
            gitBranch: job.snapshot.gitBranch,
            model: job.snapshot.model,
            existingNoteSlugs: existingNoteSlugs(),
            existingCapabilities: prepared.capabilities
        )
        let arguments = RetrospectivePrompt.cliArguments(
            model: LearningSettings.shared.model,
            budgetUSD: LearningSettings.budgetUSD
        ) + [userPrompt]

        // Spawn via un shell de LOGIN (sinon le process est muet depuis une app
        // GUI — piège vécu) ; `claude` est résolu par le PATH du shell.
        // L'unset APRÈS le sourcing du profil garantit l'auth par souscription.
        let shellCommand = "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; exec claude "
            + arguments.map(FleetLaunch.shellQuote).joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", shellCommand]
        var environment = ProcessInfo.processInfo.environment
        environment["ATOLL_RETROSPECTIVE"] = "1" // filtré par reconcile()
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: transcriptPath)
            .deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            log.error("spawn rétrospective impossible : \(error.localizedDescription)")
            finish(job, outcome: "failed(spawn)", transcriptBytes: 0)
            return
        }
        self.process = process
        let pid = process.processIdentifier
        SessionStore.shared.registerInternalPid(pid)
        log.info("rétrospective lancée (pid \(pid)) pour \(job.snapshot.id, privacy: .public)")

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.timeoutSeconds))
            guard !Task.isCancelled else { return }
            log.error("rétrospective (pid \(pid)) : timeout \(Int(Self.timeoutSeconds)) s — SIGTERM")
            self?.process?.terminate()
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            kill(pid, SIGKILL)
        }

        // Lectures BLOQUANTES sur des tâches détachées (readabilityHandler est
        // inopérant en LSUIElement — piège vécu) ; livraison au MainActor.
        // Les DEUX pipes sont drainés EN PARALLÈLE (revue) : en série, un
        // stderr saturé (~64 Ko) bloque `claude` dans son `write`, stdout ne
        // se ferme jamais et il faut attendre le timeout. Au-delà du cap on
        // continue de lire en jetant : on ne cesse jamais de vider le tuyau.
        async let outputTask: Data = Task.detached(priority: .utility) {
            var collected = Data()
            var overflowed = false
            let handle = stdout.fileHandleForReading
            while let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty {
                if overflowed { continue }
                collected.append(chunk)
                if collected.count > Self.stdoutCapBytes { overflowed = true } // borné
            }
            return collected
        }.value
        async let errorTask: String = Task.detached(priority: .utility) {
            let data = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            let text = String(decoding: data.suffix(2000), as: UTF8.self)
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        let output = await outputTask
        let errorTail = await errorTask

        await Task.detached(priority: .utility) { process.waitUntilExit() }.value
        timeoutTask?.cancel()
        timeoutTask = nil
        SessionStore.shared.unregisterInternalPid(pid)
        self.process = nil

        let transcriptBytes = (try? FileManager.default
            .attributesOfItem(atPath: transcriptPath)[.size] as? Int64).map(Int.init) ?? 0

        guard process.terminationStatus == 0 else {
            log.error("rétrospective (pid \(pid)) : exit \(process.terminationStatus) — \(errorTail, privacy: .public)")
            // Le code de sortie va AU JOURNAL : c'est lui qui distingue un
            // arrêt d'Atoll (143 = SIGTERM, ex. session reprise) d'un refus du
            // modèle. Sans lui, le journal — dont c'est la raison d'être —
            // n'affichait qu'« failed(exit) », muet sur la cause (vu en vrai).
            finish(job, outcome: "failed(exit \(process.terminationStatus))",
                   transcriptBytes: transcriptBytes)
            return
        }

        // Un .zprofile bavard peut précéder le JSON sur stdout (shell de login) :
        // au premier échec « pas du JSON », on retente depuis la première accolade.
        var parsed = RetrospectiveReport.parse(cliOutput: output)
        if case .failure(.notJSON) = parsed,
           let brace = output.firstIndex(of: UInt8(ascii: "{")) {
            parsed = RetrospectiveReport.parse(cliOutput: Data(output[brace...]))
        }
        switch parsed {
        case .failure(let error):
            log.error("rétrospective : sortie inexploitable (\(String(describing: error), privacy: .public))")
            finish(job, outcome: "failed(parse)", transcriptBytes: transcriptBytes)
        case .success(let report):
            apply(report, for: job)
            let outcome = report.nothingLearned ? "nothing_learned"
                : "success(\(report.notes.count)n/\(report.skills.count)s)"
            if let cost = report.costUSD {
                log.info("rétrospective terminée : \(outcome, privacy: .public), coût \(cost) $")
            }
            pendingAttempt?.costUSD = report.costUSD
            // Le modèle qui a réellement coûté le plus : `--safe-mode` en
            // convoque un second (sonnet) quel que soit `--model`, et c'est
            // souvent LUI la facture. L'afficher évite de croire que le
            // réglage de modèle est sans effet.
            pendingAttempt?.dominantModel = report.modelCosts.first?.model
            pendingAttempt?.notesWritten = report.notes.count
            pendingAttempt?.skillsProposed = report.skills.count
            finish(job, outcome: outcome, transcriptBytes: transcriptBytes)
        }
    }

    /// TOUTES les écritures se font ici, côté Atoll, dans des répertoires
    /// bornés — jamais par le modèle, jamais sous ~/.claude.
    private func apply(_ report: RetrospectiveReport, for job: Job) {
        let fm = FileManager.default
        let now = Date()

        var existing = (try? fm.contentsOfDirectory(atPath: BridgePaths.learningNotesDirectory.path))
            .map(Set.init) ?? []
        for note in report.notes {
            let rendered = LearningNoteFile.render(note: note, sessionID: job.snapshot.id,
                                                   project: job.snapshot.cwd, date: now)
            let filename = LearningNoteFile.deduplicatedFilename(rendered.filename, existing: existing)
            let url = BridgePaths.learningNotesDirectory.appendingPathComponent(filename)
            do {
                try rendered.contents.write(to: url, atomically: true, encoding: .utf8)
                existing.insert(filename)
                noteSink?(url, note)
            } catch {
                log.error("écriture note \(filename, privacy: .public) : \(error.localizedDescription)")
            }
        }

        for skill in report.skills {
            // QUARANTAINE : proposed/<slug>/ — jamais actif sans revue (7c).
            let dir = BridgePaths.learningProposedDirectory
                .appendingPathComponent(skill.slug, isDirectory: true)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try LearningSkillProposalFile.renderSkillMD(skill)
                    .write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
                try LearningSkillProposalFile.renderMeta(
                    skill, sessionID: job.snapshot.id, project: job.snapshot.cwd,
                    date: now, flags: report.flags[skill.slug] ?? []
                ).write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
                log.info("skill proposé en quarantaine : \(skill.slug, privacy: .public)")
            } catch {
                log.error("écriture skill \(skill.slug, privacy: .public) : \(error.localizedDescription)")
            }
        }
        if !report.skills.isEmpty { onProposalsChanged?() }
    }

    private func finish(_ job: Job, outcome: String, transcriptBytes: Int) {
        // Le run est TERMINÉ : on relâche le verrou de préparation ICI, avant le
        // `scheduleNext()` de la fin de cette fonction. Le `defer` de `run()` ne
        // joue qu'au retour de `run`, donc APRÈS — et l'enchaînement de la file
        // mourait : un second job attendait la fin d'une TROISIÈME session, ou
        // n'était jamais analysé (revue des corrections, 2026-07-27). Le `defer`
        // reste, en filet pour les chemins qui ne passent pas par `finish`.
        preparing = false
        // Un ÉCHEC ne marque plus la session « traitée » (v0.12.0) : jusque-là
        // un run avorté (spawn KO, exit ≠ 0, sortie illisible) grillait la
        // session pour toujours — il fallait +50 Ko de transcript pour qu'elle
        // redevienne éligible. Un échec laisse donc une seconde chance, et le
        // plafond par fenêtre reste le garde-fou anti-boucle.
        let failed = outcome.hasPrefix("failed(")
        if !failed {
            recordProcessed(sessionID: job.snapshot.id, transcriptBytes: transcriptBytes)
        }
        // Échec AVANT toute dépense (condensé vide, spawn impossible) : la
        // tentative est retirée du plafond de la fenêtre. Sinon une seule
        // session cassée neutralisait la rétrospective pendant 5 h pour toutes
        // les autres — d'autant plus grave que le mode « quota inconnu »
        // n'accorde qu'UN créneau (revue).
        if ["failed(digest)", "failed(spawn)", "failed(disabled)"].contains(outcome) {
            refundAttempt()
        }
        if var attempt = pendingAttempt {
            attempt.outcome = outcome
            // L'entrée a pu être journalisée au départ : on la remplace au lieu
            // de la dupliquer (même sessionID + même `decidedAt` = même id).
            journal(attempt, replacingSameID: true)
            pendingAttempt = nil
        }
        lastOutcome = outcome
        phase = .idle
        scheduleNext()
    }

    // MARK: - État persistant (dédup + plafond)

    /// Une évaluation de fin de session, telle qu'elle s'est réellement passée.
    ///
    /// AJOUTÉ EN v0.12.0 après un diagnostic à l'aveugle : jusque-là, l'issue
    /// d'une rétrospective ne vivait QUE dans `lastOutcome`, en mémoire. Quand
    /// Mehdi a constaté « Atoll ne crée jamais de skills », il a fallu croiser
    /// des tailles de fichiers et des horodatages pour deviner que le gate
    /// refusait sur « quota inconnu » — l'information n'existait nulle part.
    /// Désormais CHAQUE décision laisse une trace, y compris les refus.
    struct AttemptRecord: Codable, Identifiable, Equatable {
        var id: String { "\(sessionID)-\(decidedAt.timeIntervalSince1970)" }
        let sessionID: String
        let decidedAt: Date
        /// `run` ou `skip(<raison>)` — la rawValue du gate, telle quelle.
        let decision: String
        /// Issue du run : `success(2n/1s)`, `nothing_learned`, `failed(parse)`…
        /// nil pour un skip (il n'y a pas eu de run).
        var outcome: String?
        let transcriptBytes: Int?
        /// Quota au moment de la DÉCISION — le paramètre le plus souvent fautif.
        let quotaFraction: Double?
        let quotaAgeSeconds: Double?
        var costUSD: Double?
        var notesWritten: Int?
        var skillsProposed: Int?
        /// Modèle le plus facturé du run (voir `RetrospectiveReport.modelCosts`).
        var dominantModel: String?
        /// Ce que le modèle a réellement reçu (condensé) — répond à « pourquoi
        /// n'a-t-il rien trouvé ? » sans relire les logs.
        var digestEntries: Int?
        var digestCharacters: Int?
        var digestTruncated: Bool?
    }

    private struct PersistedState: Codable {
        var processed: [LearningGate.History.Processed] = []
        var runTimestamps: [Date] = []
        /// Journal des évaluations (cap 100) — affiché dans les Réglages.
        var attempts: [AttemptRecord] = []

        init() {}

        /// Décodage TOLÉRANT AUX CHAMPS ABSENTS — écrit à la main exprès.
        ///
        /// PIÈGE VÉCU (revue) : la synthèse `Decodable` de Swift n'utilise PAS
        /// les valeurs par défaut d'une propriété pour une clé absente, elle
        /// lève `keyNotFound`. Un `retrospectives.json` d'une version
        /// précédente (sans `attempts`) faisait donc échouer tout le décodage,
        /// le `try?` de `loadState` rendait un état VIDE, et la première
        /// écriture effaçait définitivement `processed` (sessions déjà
        /// analysées → ré-analysées, notes en double) ET `runTimestamps` (le
        /// plafond de la fenêtre 5 h repartait de zéro, juste après qu'on ait
        /// assoupli le quota). C'est arrivé en vrai sur cette machine.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            processed = try container.decodeIfPresent(
                [LearningGate.History.Processed].self, forKey: .processed) ?? []
            runTimestamps = try container.decodeIfPresent([Date].self, forKey: .runTimestamps) ?? []
            attempts = try container.decodeIfPresent([AttemptRecord].self, forKey: .attempts) ?? []
        }
    }

    /// Les évaluations récentes, de la plus récente à la plus ancienne.
    func recentAttempts(limit: Int = 12) -> [AttemptRecord] {
        Array(loadState().attempts.reversed().prefix(limit))
    }

    private func loadState() -> PersistedState {
        guard let data = try? Data(contentsOf: BridgePaths.learningStateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return PersistedState() }
        return state
    }

    private func saveState(_ state: PersistedState) {
        var capped = state
        capped.processed = Array(capped.processed.suffix(200))
        capped.runTimestamps = capped.runTimestamps.filter {
            Date().timeIntervalSince($0) < 24 * 3600
        }
        // ~/.atoll/learning supprimé en cours de route → sans cette recréation,
        // plafond et dédup seraient silencieusement désactivés (revue).
        try? FileManager.default.createDirectory(at: BridgePaths.learningDirectory,
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(capped) {
            try? data.write(to: BridgePaths.learningStateURL, options: .atomic)
        }
    }

    private func loadHistory() -> LearningGate.History {
        let state = loadState()
        return LearningGate.History(processed: state.processed,
                                    runTimestamps: state.runTimestamps)
    }

    private func recordAttempt() {
        var state = loadState()
        state.runTimestamps.append(Date())
        saveState(state)
    }

    /// Retire la dernière tentative du plafond : elle n'a rien coûté.
    private func refundAttempt() {
        var state = loadState()
        if !state.runTimestamps.isEmpty { state.runTimestamps.removeLast() }
        saveState(state)
    }

    private func recordProcessed(sessionID: String, transcriptBytes: Int) {
        var state = loadState()
        state.processed.removeAll { $0.sessionID == sessionID }
        state.processed.append(.init(sessionID: sessionID,
                                     transcriptBytes: transcriptBytes,
                                     completedAt: Date()))
        saveState(state)
    }

    /// Lit un transcript JSONL et en tire le condensé analysable.
    ///
    /// `nonisolated` : appelée depuis une tâche détachée — lire et parser 47 Mo
    /// n'a rien à faire sur le MainActor. Bornes : on cesse de lire au-delà de
    /// `digestByteCap` (au-delà, c'est une session-fleuve dont le début suffit
    /// à caractériser les procédures) et au-delà de `digestLineCap` lignes.
    nonisolated private static func digest(ofTranscriptAt path: String) -> TranscriptDigest.Result? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var splitter = TranscriptLineSplitter(startOffset: 0)
        var lines: [TranscriptLine] = []
        var readBytes = 0
        while readBytes < digestByteCap, lines.count < digestLineCap,
              let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            readBytes += chunk.count
            for raw in splitter.consume(chunk) {
                if let parsed = TranscriptLineParser.parse(raw.data) { lines.append(parsed) }
                if lines.count >= digestLineCap { break }
            }
        }
        return TranscriptDigest.make(lines: lines)
    }

    nonisolated private static let digestByteCap = 64 * 1024 * 1024
    nonisolated private static let digestLineCap = 200_000

    private func existingNoteSlugs() -> [String] {
        let files = (try? FileManager.default
            .contentsOfDirectory(atPath: BridgePaths.learningNotesDirectory.path)) ?? []
        // "2026-07-20-mon-slug.md" → "mon-slug". On DÉLÈGUE au calcul déjà
        // corrigé de l'indexeur : le motif large « 11 caractères de chiffres et
        // de tirets » amputait les notes produites par la curation
        // (`01-2026-07-20-bilan.md` → « 20-bilan »), et la liste d'antériorité
        // envoyée au modèle ne désignait alors plus rien.
        return files.compactMap { name in
            guard name.hasSuffix(".md") else { return nil }
            return MemoryIndexer.noteSlug(for: URL(fileURLWithPath: name))
        }
    }
}
