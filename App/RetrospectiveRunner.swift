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

    struct Job { let snapshot: SessionStore.Tracked; let endedAt: Date }

    private static let startDelaySeconds: TimeInterval = 15 // fenêtre résurrection 8 s + dernière statusline
    private static let timeoutSeconds: TimeInterval = 600
    private static let stdoutCapBytes = 4 * 1024 * 1024

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
    /// Trigger debug : rétrospective sur la dernière session terminée, SANS
    /// gate (mais avec le verrou un-à-la-fois ET sans course avec un délai
    /// en attente). Jamais en release.
    func debugRunOnLastEnded() {
        guard let snapshot = lastEndedSnapshot else {
            log.error("debug retro : aucune session terminée connue")
            return
        }
        guard process == nil, pendingDelay == nil else {
            log.error("debug retro : un run ou une attente est déjà en cours")
            return
        }
        Task { await run(Job(snapshot: snapshot, endedAt: Date())) }
    }
    #endif

    // MARK: - File

    private func scheduleNext() {
        guard process == nil, pendingDelay == nil, let job = queue.first else { return }
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
            self.pendingDelay = nil
            // Un run est déjà en vol (trigger debug) : on laisse finish()
            // rappeler scheduleNext — jamais deux rétrospectives en parallèle.
            guard self.process == nil else { return }
            guard let job = self.queue.first else { self.phase = .idle; return }
            self.queue.removeFirst()
            await self.evaluateAndRun(job)
        }
    }

    private func evaluateAndRun(_ job: Job) async {
        let decision = gateDecision(for: job)
        switch decision {
        case .skip(let reason):
            log.info("rétrospective sautée pour \(job.snapshot.id, privacy: .public) : \(reason.rawValue, privacy: .public)")
            lastOutcome = "skip(\(reason.rawValue))"
            phase = .idle
            scheduleNext()
        case .run:
            await run(job)
        }
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
            receivedAt: SessionStore.shared.quotaReceivedAt,
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

        let userPrompt = RetrospectivePrompt.userPrompt(
            transcriptPath: transcriptPath,
            projectPath: job.snapshot.cwd,
            gitBranch: job.snapshot.gitBranch,
            model: job.snapshot.model,
            existingNoteSlugs: existingNoteSlugs()
        )
        let arguments = RetrospectivePrompt.cliArguments(
            model: LearningSettings.shared.model,
            budgetUSD: LearningSettings.budgetUSD
        ) + [userPrompt]

        // Spawn via un shell de LOGIN (sinon le process est muet depuis une app
        // GUI — piège vécu) ; `claude` est résolu par le PATH du shell.
        // L'unset APRÈS le sourcing du profil garantit l'auth par souscription.
        let shellCommand = "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; exec claude "
            + arguments.map(Self.shellQuote).joined(separator: " ")

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
        let output: Data = await Task.detached(priority: .utility) {
            var collected = Data()
            let handle = stdout.fileHandleForReading
            while let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty {
                collected.append(chunk)
                if collected.count > Self.stdoutCapBytes { break } // borné
            }
            return collected
        }.value
        let errorTail: String = await Task.detached(priority: .utility) {
            let data = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            let text = String(decoding: data.suffix(2000), as: UTF8.self)
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value

        process.waitUntilExit()
        timeoutTask?.cancel()
        timeoutTask = nil
        SessionStore.shared.unregisterInternalPid(pid)
        self.process = nil

        let transcriptBytes = (try? FileManager.default
            .attributesOfItem(atPath: transcriptPath)[.size] as? Int64).map(Int.init) ?? 0

        guard process.terminationStatus == 0 else {
            log.error("rétrospective (pid \(pid)) : exit \(process.terminationStatus) — \(errorTail, privacy: .public)")
            finish(job, outcome: "failed(exit)", transcriptBytes: transcriptBytes)
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
        recordProcessed(sessionID: job.snapshot.id, transcriptBytes: transcriptBytes)
        lastOutcome = outcome
        phase = .idle
        scheduleNext()
    }

    // MARK: - État persistant (dédup + plafond)

    private struct PersistedState: Codable {
        var processed: [LearningGate.History.Processed] = []
        var runTimestamps: [Date] = []
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

    private func recordProcessed(sessionID: String, transcriptBytes: Int) {
        var state = loadState()
        state.processed.removeAll { $0.sessionID == sessionID }
        state.processed.append(.init(sessionID: sessionID,
                                     transcriptBytes: transcriptBytes,
                                     completedAt: Date()))
        saveState(state)
    }

    private func existingNoteSlugs() -> [String] {
        let files = (try? FileManager.default
            .contentsOfDirectory(atPath: BridgePaths.learningNotesDirectory.path)) ?? []
        // "2026-07-20-mon-slug.md" → "mon-slug" (préfixe date AAAA-MM-JJ- retiré).
        return files.compactMap { name in
            guard name.hasSuffix(".md") else { return nil }
            let stem = String(name.dropLast(3))
            guard stem.count > 11, stem.prefix(11).allSatisfy({ $0.isNumber || $0 == "-" })
            else { return stem }
            return String(stem.dropFirst(11))
        }
    }

    private static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
