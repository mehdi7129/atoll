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
    private(set) var pendingDeliveryCount = 0

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
    @ObservationIgnored private var stateReadError: String?
    private var deliveryStore: RetrospectiveDelivery.Store {
        .init(learningRoot: BridgePaths.learningDirectory)
    }

    /// `forced` = déclenché par un trigger de debug : ce job court-circuite le
    /// gate ET l'interrupteur général (c'est tout son intérêt).
    struct Job {
        let snapshot: SessionStore.Tracked
        let endedAt: Date
        var forced = false
        /// Quel CLI a produit le transcript à analyser. Détermine le parseur du
        /// condensé — un rollout Codex passé au parseur Claude rend zéro entrée,
        /// et le bilan partirait sur un texte vide.
        var transcriptProvider: AgentProvider = .claude
    }

    /// Bilan de fin de session pour une session CODEX.
    ///
    /// POURQUOI CETTE PORTE SÉPARÉE. Le chemin Claude part de
    /// `SessionStore.onSessionEnded` ; or `SessionStore` ne connaît pas les
    /// sessions Codex — elles vivent dans `CodexService`. Sans cette entrée,
    /// fermer Claude Code éteignait toute la boucle d'apprentissage : zéro note,
    /// zéro skill. Mehdi a tranché le 2026-09-09 : « il faut que ce que faisait
    /// Atoll avec Claude Code fonctionne sur Codex, c'est ça qui donne toute la
    /// puissance de l'outil ».
    ///
    /// Le reste du chemin est COMMUN — gate, choix du fournisseur qui paie,
    /// condensé, revalidation Swift, écriture des fichiers par Atoll. Seul le
    /// parseur du transcript change.
    func codexSessionEnded(_ ended: CodexSessions.EndedSession) {
        guard LearningSettings.shared.isEnabled else { return }
        guard let path = ended.transcriptPath, FileManager.default.fileExists(atPath: path) else {
            log.info("session Codex \(ended.sessionID, privacy: .public) : rollout introuvable — pas de bilan")
            return
        }
        // Les faits que `LearningGate` attend, projetés depuis ce que les hooks
        // ont RÉELLEMENT compté. `isSynthetic: false` est exact : ces faits
        // viennent de hooks, pas d'un transcript deviné.
        let snapshot = SessionStore.Tracked(
            id: ended.sessionID, cwd: ended.cwd, transcriptPath: path,
            phase: .ended, isSynthetic: false,
            firstSeenAt: ended.startedAt, lastEventAt: Date())
        var tracked = snapshot
        tracked.model = ended.model
        tracked.userPromptCount = ended.userPromptCount
        lastEndedSnapshot = tracked
        queue.append(Job(snapshot: tracked, endedAt: Date(), transcriptProvider: .codex))
        log.info("session Codex \(ended.sessionID, privacy: .public) terminée — bilan candidat dans \(Int(Self.startDelaySeconds)) s")
        scheduleNext()
    }

    /// Un run est-il engagé ? Pas seulement « un processus tourne » : la
    /// préparation du condensé (jusqu'à ~2 s sur un transcript de 47 Mo) se
    /// fait AVANT le spawn, `process` encore nil. Sans ce drapeau, une session
    /// qui se terminait pendant cette fenêtre déclenchait un SECOND `claude -p`
    /// payant en parallèle (audit du 2026-07-27).
    @ObservationIgnored private var preparing = false
    /// Identité de la préparation courante, invalidée aussi avant le spawn.
    /// `sessionResumed` n'a alors ni job en file ni processus à arrêter : les
    /// gardes de génération après les awaits empêchent un lancement tardif.
    @ObservationIgnored private var runGeneration = UUID()
    @ObservationIgnored private var runLaunched = false
    @ObservationIgnored private var processIdentity: ProcessIdentity?
    @ObservationIgnored private var activeExecution: AnalysisExecution?
    @ObservationIgnored private var activeOrigin: AgentProvider?
    @ObservationIgnored private var activeDestination: AgentProvider?
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
            // Pendant la PRÉPARATION (condensé + inventaire, jusqu'à quelques
            // secondes sur un transcript de 47 Mo), `process` est encore nil :
            // ce `terminate()` ne portait sur rien et le `claude -p` partait
            // ensuite, à ~0,87 $, sur une session qui venait de repartir. Pire,
            // `recordProcessed` la marquait « traitée », donc sa VRAIE fin de
            // session ne serait plus analysée. La génération est revérifiée
            // après chaque await.
            runGeneration = UUID()
            terminateWithEscalation()
        }
    }

    /// Kill-switch (toggle OFF) : effet < 1 s, avec sa PROPRE escalade
    /// SIGTERM → SIGKILL (revue : annuler timeoutTask supprimait le seul
    /// SIGKILL du code — un claude sourd au SIGTERM restait facturé, et
    /// `process` non-nil bloquait toute rétro future jusqu'au redémarrage).
    func disable() {
        runGeneration = UUID()
        queue.removeAll()
        pendingDelay?.cancel()
        pendingDelay = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        terminateWithEscalation()
        phase = .idle
    }

    func terminateActive() {
        runGeneration = UUID()
        terminateWithEscalation()
    }

    func codexConfigurationChanged() {
        queue.removeAll { $0.transcriptProvider == .codex }
        if activeExecution?.provider == .codex || activeOrigin == .codex || activeDestination == .codex { terminateActive() }
    }

    private func terminateWithEscalation() {
        guard let identity = processIdentity else { return }
        ProcessInspector.signal(SIGTERM, to: identity)
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(5))
            ProcessInspector.signal(SIGKILL, to: identity)
        }
    }

    #if DEBUG
    /// Trigger debug : rétrospective sur le PLUS GROS transcript du projet
    /// courant, sans gate. Sert à vérifier le pipeline complet (condensé →
    /// analyse → notes/skills) sur une session réellement riche, sans attendre
    /// qu'une vraie session substantielle se termine. Jamais en release.
    /// `provider` : quel abonnement paie CE run de debug. Le gate est
    /// court-circuité, mais pas le choix du fournisseur — c'est justement ce
    /// qu'on veut pouvoir forcer pour prouver le chemin Codex sans attendre
    /// qu'une vraie session substantielle se termine. Même rôle que `retroBig`
    /// en Phase 12 : c'est LUI qui avait prouvé la boucle d'apprentissage.
    /// Trigger debug : bilan forcé sur le PLUS GROS ROLLOUT CODEX de la machine,
    /// sans passer par le gate. C'est le pendant de `retroBig` — l'outil qui
    /// avait prouvé la boucle d'apprentissage en Phase 12 — et il existe pour la
    /// même raison : sans lui, il faudrait attendre qu'une vraie session Codex
    /// longue se termine pour savoir si la chaîne produit quelque chose.
    func debugRunOnLargestCodexRollout() {
        guard !isBusy, pendingDelay == nil else {
            log.error("debug retro : un run ou une attente est déjà en cours")
            return
        }
        let fm = FileManager.default
        var largest: (url: URL, size: Int)?
        if let walker = fm.enumerator(at: BridgePaths.codexSessionsURL,
                                      includingPropertiesForKeys: [.fileSizeKey],
                                      options: [.skipsHiddenFiles]) {
            for case let file as URL in walker where file.pathExtension == "jsonl" {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if size > (largest?.size ?? 0) { largest = (file, size) }
            }
        }
        guard let largest else {
            log.error("debug retro Codex : aucun rollout trouvé")
            return
        }
        log.info("debug retro CODEX sur \(largest.url.lastPathComponent, privacy: .public) (\(largest.size) octets)")

        // Le `cwd` vient du rollout lui-même : c'est lui qui donne au catalogue
        // d'antériorité les slash commands du PROJET (leçon de la v0.16.5).
        let cwd = (try? String(contentsOf: largest.url, encoding: .utf8))
            .flatMap { $0.split(separator: "\n").first }
            .flatMap { CodexTranscriptParser.parse(Data($0.utf8))?.cwd }

        pendingAttempt = AttemptRecord(
            sessionID: "codex:" + CodexRollout.sessionID(fromFileName: largest.url.lastPathComponent),
            decidedAt: Date(), decision: "run(debug)", outcome: nil,
            transcriptBytes: largest.size,
            quotaFraction: SessionStore.shared.realQuota?.fiveHour.usedFraction,
            quotaAgeSeconds: SessionStore.shared.realQuota
                .map { Date().timeIntervalSince($0.receivedAt) })
        var snapshot = SessionStore.Tracked(
            id: "codex:" + CodexRollout.sessionID(fromFileName: largest.url.lastPathComponent),
            cwd: cwd, transcriptPath: largest.url.path, phase: .ended, isSynthetic: false,
            firstSeenAt: Date().addingTimeInterval(-3_600), lastEventAt: Date())
        snapshot.userPromptCount = 5
        Task { await run(Job(snapshot: snapshot, endedAt: Date(), forced: true,
                             transcriptProvider: .codex)) }
    }

    func debugRunOnLargestTranscript(projectDirectory: String,
                                     provider: AgentProvider = .claude) {
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
        Task { await run(Job(snapshot: snapshot, endedAt: Date(), forced: true),
                         provider: provider) }
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
            while let self, !Task.isCancelled {
                guard let head = self.queue.first else {
                    self.pendingDelay = nil
                    self.phase = .idle
                    return
                }
                if self.phase != .waiting(head.snapshot.id) { self.phase = .waiting(head.snapshot.id) }
                let age = Date().timeIntervalSince(head.endedAt)
                if age < Self.startDelaySeconds {
                    try? await Task.sleep(for: .seconds(Self.startDelaySeconds - age))
                    continue
                }
                if NotesCurationService.shared.phase != .idle || AnalysisBudget.shared.active != nil {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                // Aucun await entre les deux faits vérifiés et le retrait.
                // Pendant l'attente d'un autre job, la tête peut être remplacée
                // par une session qui n'a pas encore ses 15 s de résurrection.
                self.pendingDelay = nil
                guard !self.isBusy else { return }
                self.queue.removeFirst()
                await self.evaluateAndRun(head)
                return
            }
        }
    }

    func evaluateAndRun(_ job: Job) async {
        // Une sortie déjà payée se récupère AVANT les quotas et le choix du
        // modèle. Même un abonnement devenu indisponible ne doit pas la perdre.
        guard recoverBeforeAnalysis(job) else { return }
        // ORDRE IMPÉRATIF : choisir le fournisseur, PUIS lui appliquer le gate
        // avec SON quota. L'inverse évaluerait un plafond de fenêtre sur un
        // compte qu'on ne va pas débiter — et refuserait un run que le second
        // abonnement pouvait payer.
        let execution: AnalysisExecution
        do { execution = try AnalysisExecution.capture(kind: .retrospective) }
        catch {
            lastOutcome = "skip(configuration)"
            journal(AttemptRecord(sessionID: job.snapshot.id, decidedAt: Date(),
                decision: "skip(configuration)", outcome: nil,
                transcriptBytes: job.snapshot.transcriptPath.flatMap {
                    (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? NSNumber)?.intValue
                }, quotaFraction: nil, quotaAgeSeconds: nil, failureReason: error.localizedDescription))
            phase = .idle
            scheduleNext()
            return
        }
        // ⚠️ GARDE-FOU, ET IL EST INDISPENSABLE. Sans fournisseur, le gate voit
        // un quota vide — or « quota inconnu » n'est PAS un refus sec chez lui :
        // il accorde `unknownQuotaMaxPerWindow` run(s) à l'aveugle. Il dirait
        // donc `.run`, et ce run partirait sur le Claude qu'on vient justement
        // de mesurer PLEIN. Le motif est celui de la régression trouvée dans le
        // correctif de la v0.16.6 : la bonne décision prise, puis dépensée
        // quand même faute d'une ligne dans la porte suivante.
        let decision: LearningGate.Decision
        if let refusal = AnalysisBudget.shared.refusalReason(for: execution) {
            // La raison du gate reste FIDÈLE à ce qui bloque : « aucune mesure »
            // et « les deux comptes sont pleins » ne se diagnostiquent pas
            // pareil, et c'est le journal qui devra le dire dans un mois.
            decision = .skip(refusal)
        } else {
            decision = gateDecision(for: job, quota: execution.quota)
        }
        let quota = execution.quota
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
                quotaFraction: quota.usedFraction,
                quotaAgeSeconds: quota.receivedAt.map { Date().timeIntervalSince($0) },
                provider: execution.provider.rawValue,
                providerReason: execution.reason, model: execution.model,
                quotaUnknownReason: execution.quota.unknownReason
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
                quotaFraction: quota.usedFraction,
                quotaAgeSeconds: quota.receivedAt.map { Date().timeIntervalSince($0) },
                provider: execution.provider.rawValue,
                providerReason: execution.reason, model: execution.model,
                quotaUnknownReason: execution.quota.unknownReason
            )
            await run(job, execution: execution)
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

    /// Faits de quota Claude, tels que la statusline les a livrés.
    private func claudeQuotaFacts() -> LearningGate.QuotaFacts {
        LearningGate.QuotaFacts(
            usedFraction: SessionStore.shared.realQuota?.fiveHour.usedFraction,
            receivedAt: SessionStore.shared.rawQuotaReceivedAt,
            resetsAt: SessionStore.shared.realQuota?.fiveHour.resetsAt
        )
    }

    /// Le gate est évalué avec le quota DU FOURNISSEUR retenu : c'est le compte
    /// qui va payer qu'il faut mesurer. `nil` n'arrive pas ici — l'appelant
    /// intercepte ce cas avant, précisément parce que le gate ne refuserait pas
    /// sec un quota inconnu.
    private func gateDecision(for job: Job, quota: LearningGate.QuotaFacts) -> LearningGate.Decision {
        let snapshot = job.snapshot
        let transcriptSize = snapshot.transcriptPath
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int64 }
            .map(Int.init)
        let stillAlive = job.transcriptProvider == .codex
            ? CodexService.shared.contains(snapshot.id)
            : (SessionStore.shared.sessions.first { $0.id == snapshot.id }?.phase.isAlive ?? false)
        let facts = LearningGate.SessionFacts(
            sessionID: snapshot.id,
            durationSeconds: job.endedAt.timeIntervalSince(snapshot.firstSeenAt),
            transcriptSizeBytes: transcriptSize,
            userPromptCount: snapshot.isSynthetic ? nil : snapshot.userPromptCount,
            isCurrentlyAlive: stillAlive
        )
        return LearningGate.decide(session: facts, quota: quota,
                                   config: LearningSettings.shared.gateConfig,
                                   history: loadHistory(), now: Date())
    }

    // MARK: - Run

    private func run(_ job: Job, provider forcedProvider: AgentProvider = .claude,
                     execution supplied: AnalysisExecution? = nil) async {
        guard let transcriptPath = job.snapshot.transcriptPath else {
            phase = .idle
            scheduleNext()
            return
        }
        // Verrou RÉEL, avant tout effet : les deux triggers debug testent
        // `!isBusy` de façon synchrone puis lancent `Task { await run(…) }`.
        // Deux notifications enfilées sur la queue principale passaient donc
        // toutes deux la garde avant que le corps de la première Task ne pose
        // `preparing`. Deux `claude -p` payants partaient, `self.process`
        // écrasait la référence du premier (que le kill-switch ne pouvait plus
        // tuer) et `timeoutTask` perdait son watchdog.
        guard !preparing, process == nil else {
            log.error("run() appelé alors qu'une rétrospective est déjà en vol — ignoré")
            return
        }
        let execution: AnalysisExecution
        let lease: UUID
        let destination: SkillDestination
        do {
            execution = try supplied ?? AnalysisExecution.capture(kind: .retrospective,
                forcedProvider: job.forced ? forcedProvider : nil)
            destination = try SkillDestination.capture(origin: job.transcriptProvider)
            _ = loadState()
            if let stateReadError { throw AnalysisExecution.Failure(stateReadError) }
            try deliveryStore.preflight()
            lease = try AnalysisBudget.shared.begin(execution, kind: .retrospective,
                origin: job.transcriptProvider, destination: destination.provider, force: job.forced)
        } catch {
            if AnalysisBudget.shared.active != nil {
                // Une autre analyse a gagné entre l'évaluation et l'entrée
                // dans run : conserver ce job et réévaluer après son tour.
                queue.insert(job, at: 0)
                pendingAttempt = nil
                phase = .idle
                scheduleNext()
                return
            }
            lastOutcome = error.localizedDescription
            if var attempt = pendingAttempt {
                attempt.outcome = "failed(preparation)"
                journal(attempt, replacingSameID: true)
                pendingAttempt = nil
            }
            phase = .idle
            scheduleNext()
            return
        }
        let provider = execution.provider
        activeExecution = execution
        activeOrigin = job.transcriptProvider
        activeDestination = destination.provider
        defer {
            AnalysisBudget.shared.finish(lease, outcome: lastOutcome ?? "cancelled")
            activeExecution = nil
            activeOrigin = nil
            activeDestination = nil
        }
        // Le budget commun persiste la préparation puis l’intention de spawn.
        phase = .running(job.snapshot.id)
        lastOutcome = nil
        preparing = true
        let generation = UUID()
        runGeneration = generation
        runLaunched = false
        let model = execution.model
        let codexHome = execution.home
        defer { preparing = false }

        // CONDENSÉ (v0.12.0) : Atoll lit le transcript lui-même, hors MainActor,
        // et n'envoie au modèle que la substance. Les transcripts réels font 9 à
        // 47 Mo — en les faisant lire par le modèle sous 1,50 $, il n'en voyait
        // que ~8 %. Ici, il reçoit tout ce qui compte, borné et gratuit.
        // Condensé ET inventaire hors MainActor : l'inventaire parcourt le
        // cache des plugins (~70 ms à chaud, bien plus à froid).
        // Le `cwd` de la session sert à inventorier AUSSI les slash commands que
        // porte son dépôt (`<projet>/.claude/commands`). Sans lui, l'antériorité
        // ignore tout ce qu'un outil comme spec-kit installe dans le projet — et
        // le catalogue le mieux écrit ne sert à rien si son APPEL l'ampute, c'est
        // exactement la panne de `byCoverage` en v0.16.1.
        let sessionDirectory = job.snapshot.cwd.flatMap { path -> URL? in
            path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
        }
        // ⚠️ LE PARSEUR SUIT LE FOURNISSEUR DU TRANSCRIPT. Un rollout Codex
        // passé au parseur Claude rend ZÉRO entrée : le bilan partirait sur un
        // condensé vide et paierait un run pour rien. Même motif que
        // `byCoverage` juste au-dessus — le savoir dans le code, pas dans l'appel.
        let transcriptProvider = job.transcriptProvider
        let prepared = await Task.detached(priority: .utility) {
            Self.digest(ofTranscriptAt: transcriptPath, provider: transcriptProvider)
        }.value
        // L'utilisateur a pu couper l'apprentissage PENDANT la préparation :
        // `disable()` n'avait alors rien à annuler (ni processus, ni délai) et
        // le `claude -p` partait quand même, après l'arrêt explicite.
        // Même fenêtre, autre cause : la session a pu REPARTIR pendant la
        // préparation. `sessionResumed` ne pouvait alors rien annuler (le job
        // était déjà dépilé, `process` encore nil) — c'est ce drapeau qui porte
        // l'annulation. `transcriptBytes: 0` : ne pas marquer la session
        // « traitée » à sa taille de l'instant, sinon sa vraie fin de session
        // deviendrait inéligible jusqu'à +50 Ko de croissance.
        guard runGeneration == generation, !Task.isCancelled else {
            log.info("session ressuscitée pendant la préparation — rien n'est lancé")
            finish(job, outcome: "failed(cancelled)", transcriptBytes: 0)
            return
        }
        guard job.forced || LearningSettings.shared.isEnabled else {
            log.info("apprentissage coupé pendant la préparation — rien n'est lancé")
            finish(job, outcome: "failed(disabled)", transcriptBytes: 0)
            return
        }
        let digest = prepared
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
        pendingAttempt?.digestFragmentsShortened = digest.fragmentsShortened
        pendingAttempt?.digestEntriesDropped = digest.entriesDropped
        pendingAttempt?.digestSourceReadStopped = digest.sourceReadStopped
        AnalysisBudget.shared.updateMetrics(lease, digestFragmentsShortened: digest.fragmentsShortened,
            digestEntriesDropped: digest.entriesDropped, digestSourceReadStopped: digest.sourceReadStopped)
        let materialFingerprint = RetrospectiveDelivery.fingerprint(
            ["retrospective-material-v1", job.transcriptProvider.rawValue,
             job.snapshot.cwd ?? "", job.snapshot.gitBranch ?? "", digest.text].joined(separator: "\n"))
        let destinationScope = RetrospectiveDelivery.scope(for: destination.store.proposedDirectory)
        if !job.forced, loadState().materials.contains(where: {
            $0.sessionID == job.snapshot.id && $0.origin == job.transcriptProvider
                && $0.destinationScope == destinationScope && $0.fingerprint == materialFingerprint
        }) {
            pendingAttempt?.decision = "skip(unchangedMaterial)"
            finish(job, outcome: "skip(unchangedMaterial)",
                   transcriptBytes: pendingAttempt?.transcriptBytes ?? 0)
            return
        }
        // Journalisée MAINTENANT (complétée à la fin) : si l'app se termine
        // pendant le run, la tentative apparaît quand même — l'objectif est
        // « 100 % des fins de session laissent une trace ».
        if let attempt = pendingAttempt { journal(attempt) }

        let catalog: [CatalogEntry]
        do { catalog = try await destination.catalog(project: sessionDirectory) }
        catch {
            guard runGeneration == generation else { finish(job, outcome: "failed(cancelled)", transcriptBytes: 0); return }
            lastOutcome = error.localizedDescription
            finish(job, outcome: "failed(catalog)", transcriptBytes: 0)
            return
        }
        guard runGeneration == generation, !Task.isCancelled else {
            finish(job, outcome: "failed(cancelled)", transcriptBytes: 0)
            return
        }
        let noteHistory = LearningNoteHistory.read(from: BridgePaths.learningNotesDirectory)
        let skillHistory = destination.store.noveltyHistory()
        let userPrompt = RetrospectivePrompt.userPrompt(
            digest: digest.text,
            projectPath: job.snapshot.cwd,
            gitBranch: job.snapshot.gitBranch,
            model: job.snapshot.model,
            existingNoteSlugs: noteHistory.slugs(project: job.snapshot.cwd, query: digest.text),
            existingCapabilities: SkillDestination.summary(catalog)
        ) + "\n" + noteHistory.summary(project: job.snapshot.cwd, query: digest.text)
          + "\n" + skillHistory.summary(query: digest.text)
          + "\nSkill destination: \(destination.provider.label). Produce instructions for that CLI only; never assume tools or commands from the other agent are available."
        AnalysisBudget.shared.updateMetrics(lease, promptCharacters: provider == .codex
            ? CodexExecPlan.fullPrompt(system: RetrospectivePrompt.systemPrompt, user: userPrompt).count
            : RetrospectivePrompt.systemPrompt.count + userPrompt.count)
        // Le SEUL point du fichier où le fournisseur change quelque chose. Tout
        // ce qui précède (condensé, prompt, antériorité) et tout ce qui suit
        // (revalidation, écriture des fichiers) est commun : c'est la propriété
        // qui rend la bascule sûre — Atoll écrit toujours lui-même, après ses
        // propres contrôles, quel que soit le modèle qui a répondu.
        let launch: CodexRun.Launch?
        switch provider {
        case .claude:
            let arguments = RetrospectivePrompt.cliArguments(
                model: model,
                budgetUSD: LearningSettings.budgetUSD
            ) + [userPrompt]
            // Spawn via un shell de LOGIN (sinon le process est muet depuis une
            // app GUI — piège vécu). L'unset APRÈS le sourcing du profil garantit
            // l'auth par souscription. En revanche `claude` n'est PAS résolu par
            // le PATH de ce shell — il est NON INTERACTIF, donc ~/.zshrc n'est
            // jamais lu (exit 127 mesuré le 2026-08-24) : chemin absolu.
            launch = await CodexRun.prepareClaude(arguments: arguments, label: "retro")
        case .codex:
            launch = await CodexRun.prepare(
                schema: RetrospectivePrompt.jsonSchema,
                prompt: CodexExecPlan.fullPrompt(system: RetrospectivePrompt.systemPrompt,
                                                 user: userPrompt),
                label: "retro", home: codexHome, model: model,
                executableOverride: execution.executableOverride)
        }
        guard let launch else {
            let reason = CodexRun.lastFailure ?? "Préparation de l'analyse impossible."
            log.error("spawn rétrospective impossible : \(reason, privacy: .public)")
            // Aucun spawn : AnalysisBudget rendra la réservation sans dépense.
            finish(job, outcome: "failed(\(provider.rawValue)) · \(reason)", transcriptBytes: 0)
            return
        }
        defer { launch.cleanUp() }
        guard runGeneration == generation, !Task.isCancelled else {
            finish(job, outcome: "failed(cancelled)", transcriptBytes: 0)
            return
        }
        guard AnalysisBudget.shared.mayLaunch(lease, context: execution, force: job.forced) else {
            finish(job, outcome: "failed(quota expired)", transcriptBytes: 0)
            return
        }
        let shellCommand = launch.shellCommand

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", shellCommand]
        var environment = ProcessInfo.processInfo.environment
        environment["ATOLL_RETROSPECTIVE"] = "1" // filtré par reconcile()
        process.environment = environment
        process.currentDirectoryURL = launch.workspace
        // NON NÉGOCIABLE sur le chemin Codex : `codex exec` lit stdin même
        // quand le prompt est en argument, et attend EOF — mesuré le
        // 2026-09-06 (« Reading additional input from stdin... »), soit dix
        // minutes de watchdog par run. Voir `CodexExecPlan`.
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try AnalysisBudget.shared.prepareToLaunch(lease)
            processIdentity = try ProcessInspector.launchOwned(process)
        } catch {
            log.error("spawn rétrospective impossible : \(error.localizedDescription)")
            finish(job, outcome: "failed(spawn)", transcriptBytes: 0)
            return
        }
        self.process = process
        runLaunched = true
        AnalysisBudget.shared.launched(lease)
        let identity = processIdentity
        let pid = process.processIdentifier
        SessionStore.shared.registerInternalPid(pid)
        log.info("rétrospective lancée (pid \(pid)) pour \(job.snapshot.id, privacy: .public)")

        timeoutTask?.cancel()   // jamais réaffecter sans annuler (même hygiène qu'à la fin d'un run)
        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(Self.timeoutSeconds))
            guard !Task.isCancelled else { return }
            log.error("rétrospective (pid \(pid)) : timeout \(Int(Self.timeoutSeconds)) s — SIGTERM")
            if let identity { ProcessInspector.signal(SIGTERM, to: identity) }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if let identity { ProcessInspector.signal(SIGKILL, to: identity) }
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
            let data = BoundedProcessOutput.drain(stderr.fileHandleForReading, cap: 2000, tail: true)
            let text = String(decoding: data.suffix(2000), as: UTF8.self)
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        let output = await outputTask
        let errorTail = await errorTask
        AnalysisBudget.shared.recordUsage(lease, stdout: output)

        await Task.detached(priority: .utility) { process.waitUntilExit() }.value
        timeoutTask?.cancel()
        timeoutTask = nil
        SessionStore.shared.unregisterInternalPid(pid)
        self.process = nil
        processIdentity = nil

        guard runGeneration == generation, !Task.isCancelled else {
            finish(job, outcome: "failed(cancelled)", transcriptBytes: 0)
            return
        }

        // Un transcript repris pendant l'appel ne doit pas être marqué traité
        // jusqu'à sa nouvelle taille, que ce modèle n'a pas nécessairement lue.
        let transcriptBytes = pendingAttempt?.transcriptBytes ?? 0

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

        // Codex n'imprime pas son rapport : il l'ÉCRIT dans le fichier demandé
        // par `--output-last-message`. Lire stdout ici ne rendrait que son
        // journal d'événements — c'est la différence de forme la plus
        // importante entre les deux chemins, et la seule qui touche le parse.
        var parsed: Result<RetrospectiveReport, RetrospectiveReport.ParseError>
        if let outputFile = launch.outputFile {
            let data = BoundedProcessOutput.file(at: outputFile, cap: Self.stdoutCapBytes) ?? Data()
            parsed = RetrospectiveReport.parse(codexOutput: data)
        } else {
            // Un .zprofile bavard peut précéder le JSON sur stdout (shell de
            // login) : au premier échec « pas du JSON », on retente depuis la
            // première accolade.
            parsed = RetrospectiveReport.parse(cliOutput: output)
            if case .failure(.notJSON) = parsed,
               let brace = output.firstIndex(of: UInt8(ascii: "{")) {
                parsed = RetrospectiveReport.parse(cliOutput: Data(output[brace...]))
            }
        }
        switch parsed {
        case .failure(let error):
            log.error("rétrospective : sortie inexploitable (\(String(describing: error), privacy: .public))")
            finish(job, outcome: "failed(parse)", transcriptBytes: transcriptBytes)
        case .success(let report):
            pendingAttempt?.costUSD = report.costUSD
            pendingAttempt?.dominantModel = report.modelCosts.first?.model
            // Relecture juste avant l'écriture : une autre session a pu créer
            // ou faire approuver le même savoir pendant la génération.
            let filtered = novelReport(report, project: job.snapshot.cwd, destination: destination)
            var delivery = RetrospectiveDelivery(report: filtered, analysisID: lease,
                sessionID: job.snapshot.id, origin: job.transcriptProvider, destination: destination.provider,
                proposals: destination.store.proposedDirectory, notesDirectory: BridgePaths.learningNotesDirectory,
                project: job.snapshot.cwd, transcriptBytes: transcriptBytes,
                materialFingerprint: materialFingerprint, decidedAt: pendingAttempt?.decidedAt ?? Date())
            do {
                try deliveryStore.save(delivery)
                pendingDeliveryCount = (try? deliveryStore.pending().count) ?? 1
                try deliveryStore.apply(&delivery, notesDirectory: BridgePaths.learningNotesDirectory,
                    proposals: destination.store.proposedDirectory) { [weak self] url, note in self?.noteSink?(url, note) }
                try persistReceipt(delivery)
                try deliveryStore.acknowledge(delivery)
                pendingDeliveryCount = (try? deliveryStore.pending().count) ?? 0
            } catch {
                pendingAttempt?.notesWritten = delivery.notesWritten
                pendingAttempt?.skillsProposed = delivery.skillsProposed
                pendingAttempt?.failureReason = error.localizedDescription
                AnalysisBudget.shared.updateMetrics(lease, notesWritten: delivery.notesWritten,
                                                   skillsProposed: delivery.skillsProposed)
                if delivery.skillsProposed > 0 { onProposalsChanged?() }
                finish(job, outcome: "failed(delivery) · \(error.localizedDescription)", transcriptBytes: transcriptBytes)
                return
            }
            var outcome = report.nothingLearned ? "nothing_learned"
                : "success(\(delivery.notesWritten)n/\(delivery.skillsProposed)s)"
            let duplicates = report.notes.count + report.skills.count - filtered.notes.count - filtered.skills.count
            if duplicates > 0 { outcome += " · \(duplicates) doublon(s) évité(s)" }
            if !report.rejectedSkills.isEmpty {
                outcome += " · \(report.rejectedSkills.count) skill(s) trop long(s), non proposé(s)"
            }
            if let cost = report.costUSD {
                log.info("rétrospective terminée : \(outcome, privacy: .public), coût \(cost) $")
            }
            // Le modèle qui a réellement coûté le plus : `--safe-mode` en
            // convoque un second (sonnet) quel que soit `--model`, et c'est
            // souvent LUI la facture. L'afficher évite de croire que le
            // réglage de modèle est sans effet.
            pendingAttempt?.notesWritten = delivery.notesWritten
            pendingAttempt?.skillsProposed = delivery.skillsProposed
            AnalysisBudget.shared.updateMetrics(lease, notesWritten: delivery.notesWritten,
                                               skillsProposed: delivery.skillsProposed)
            if delivery.skillsProposed > 0 { onProposalsChanged?() }
            finish(job, outcome: outcome, transcriptBytes: transcriptBytes)
        }
    }

    private func novelReport(_ report: RetrospectiveReport, project: String?,
                             destination: SkillDestination) -> RetrospectiveReport {
        var notes = LearningNoteHistory.read(from: BridgePaths.learningNotesDirectory)
        var skills = destination.store.noveltyHistory()
        let newNotes = report.notes.filter { note in
            guard !notes.contains(note, project: project) else { return false }
            notes.record(note, project: project)
            return true
        }
        let newSkills = report.skills.filter { skill in
            guard !skills.contains(skill) else { return false }
            skills.record(skill, status: .proposed)
            return true
        }
        return RetrospectiveReport(sessionSummary: report.sessionSummary,
            nothingLearned: report.nothingLearned, notes: newNotes, skills: newSkills,
            costUSD: report.costUSD, modelCosts: report.modelCosts,
            flags: report.flags, rejectedSkills: report.rejectedSkills)
    }

    /// Aucun modèle ni quota nécessaire pour reprendre une sortie déjà payée.
    /// Les destinations qui ont changé restent en attente, sans redirection.
    func recoverPendingDeliveries() {
        guard LearningSettings.shared.isEnabled, !isBusy,
              NotesCurationService.shared.phase == .idle, AnalysisBudget.shared.active == nil else { return }
        do {
            let pending = try deliveryStore.pending()
            pendingDeliveryCount = pending.count
            var failures: [String] = []
            var recovered = false
            for var delivery in pending {
                do {
                    let destination = try SkillDestination.capture(origin: delivery.origin)
                    guard destination.provider == delivery.destination,
                          RetrospectiveDelivery.scope(for: destination.store.proposedDirectory) == delivery.destinationScope else {
                        failures.append("La destination a changé : résultat conservé.")
                        continue
                    }
                    try deliveryStore.apply(&delivery, notesDirectory: BridgePaths.learningNotesDirectory,
                        proposals: destination.store.proposedDirectory) { [weak self] url, note in self?.noteSink?(url, note) }
                    try persistReceipt(delivery)
                    try deliveryStore.acknowledge(delivery)
                    recovered = true
                } catch {
                    let reason = error.localizedDescription
                    failures.append(reason)
                    // Une reprise partielle peut avoir écrit des artefacts :
                    // les compter sans accuser réception du résultat entier.
                    do { try persistReceipt(delivery, failure: reason) }
                    catch { failures.append(error.localizedDescription) }
                }
                AnalysisBudget.shared.updateMetrics(delivery.analysisID, notesWritten: delivery.notesWritten,
                                                   skillsProposed: delivery.skillsProposed)
                if delivery.skillsProposed > 0 { onProposalsChanged?() }
            }
            pendingDeliveryCount = try deliveryStore.pending().count
            if let first = failures.first { lastOutcome = "failed(delivery) · \(first)" }
            else if recovered { lastOutcome = "Résultat enregistré sans nouvelle analyse." }
        } catch {
            pendingDeliveryCount = max(1, pendingDeliveryCount)
            lastOutcome = "failed(delivery) · \(error.localizedDescription)"
        }
    }

    private func recoverBeforeAnalysis(_ job: Job) -> Bool {
        guard LearningSettings.shared.isEnabled else { return true }
        recoverPendingDeliveries()
        do {
            if try deliveryStore.pending().contains(where: {
                $0.sessionID == job.snapshot.id && $0.origin == job.transcriptProvider
            }) {
                lastOutcome = "Résultat sauvegardé en attente : aucune nouvelle analyse pour cette session."
                phase = .idle
                scheduleNext()
                return false
            }
            return true
        } catch {
            lastOutcome = error.localizedDescription
            phase = .idle
            scheduleNext()
            return false
        }
    }

    private func persistReceipt(_ delivery: RetrospectiveDelivery, failure: String? = nil) throws {
        var state = loadState()
        if let stateReadError { throw AnalysisExecution.Failure(stateReadError) }
        if failure == nil {
            guard delivery.isComplete else { throw AnalysisExecution.Failure("Résultat encore incomplet.") }
            state.processed.removeAll { $0.sessionID == delivery.sessionID }
            state.processed.append(.init(sessionID: delivery.sessionID,
                transcriptBytes: delivery.transcriptBytes, completedAt: Date()))
            state.materials.removeAll { $0.sessionID == delivery.sessionID && $0.origin == delivery.origin
                && $0.destinationScope == delivery.destinationScope }
            state.materials.append(.init(sessionID: delivery.sessionID, origin: delivery.origin,
                destinationScope: delivery.destinationScope, fingerprint: delivery.materialFingerprint))
        }
        let outcome = failure.map { "failed(delivery) · \($0)" }
            ?? "success(\(delivery.notesWritten)n/\(delivery.skillsProposed)s)"
        if let index = state.attempts.firstIndex(where: {
            $0.sessionID == delivery.sessionID && $0.decidedAt == delivery.decidedAt
        }) {
            state.attempts[index].outcome = outcome
            state.attempts[index].notesWritten = delivery.notesWritten
            state.attempts[index].skillsProposed = delivery.skillsProposed
            state.attempts[index].failureReason = failure
        } else {
            state.attempts.append(AttemptRecord(sessionID: delivery.sessionID, decidedAt: delivery.decidedAt,
                decision: "recovered", outcome: outcome, transcriptBytes: delivery.transcriptBytes,
                quotaFraction: nil, quotaAgeSeconds: nil, notesWritten: delivery.notesWritten,
                skillsProposed: delivery.skillsProposed, failureReason: failure))
        }
        guard saveState(state) else { throw AnalysisExecution.Failure("Reçu non enregistré : le résultat reste sauvegardé.") }
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
        var decision: String
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
        var digestFragmentsShortened: Int?
        var digestEntriesDropped: Int?
        var digestSourceReadStopped: Bool?
        /// Abonnement qui a payé ce run (`claude` / `codex`), et pourquoi.
        /// OPTIONNEL À DESSEIN : une entrée écrite avant la bascule n'a pas la
        /// clé, et le `Decodable` synthétisé ne lève pas sur un Optional absent
        /// (contrairement au piège documenté pour `PersistedState`). Absent =
        /// Claude, le seul fournisseur qui existait alors.
        var provider: String?
        /// Raison du choix (`ProviderFailover.Reason`) — sans elle, « ça n'a
        /// pas basculé » est indiagnosticable, exactement le trou que le
        /// journal de la Phase 12 existe pour fermer.
        var providerReason: String?
        /// Le refus de préparation doit rester lisible après relancement.
        var failureReason: String?
        var model: String?
        var quotaUnknownReason: String?
    }

    private struct MaterialReceipt: Codable {
        let sessionID: String
        let origin: AgentProvider
        let destinationScope: String
        let fingerprint: String
    }

    private struct PersistedState: Codable {
        var processed: [LearningGate.History.Processed] = []
        // Lecture des dépenses d’avant analysis-jobs-v2 ; plus aucun nouvel ajout.
        var runTimestamps: [Date] = []
        /// Journal des évaluations (cap 100) — affiché dans les Réglages.
        var attempts: [AttemptRecord] = []
        var materials: [MaterialReceipt] = []

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
            materials = try container.decodeIfPresent([MaterialReceipt].self, forKey: .materials) ?? []
        }
    }

    /// Les évaluations récentes, de la plus récente à la plus ancienne.
    func recentAttempts(limit: Int = 12) -> [AttemptRecord] {
        Array(loadState().attempts.reversed().prefix(limit))
    }

    private func loadState() -> PersistedState {
        stateReadError = nil
        guard FileManager.default.fileExists(atPath: BridgePaths.learningStateURL.path) else { return PersistedState() }
        guard let data = BoundedProcessOutput.file(at: BridgePaths.learningStateURL, cap: 2_097_152),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            stateReadError = "Journal d'apprentissage illisible : aucune nouvelle analyse, fichier préservé."
            return PersistedState()
        }
        return state
    }

    @discardableResult
    private func saveState(_ state: PersistedState) -> Bool {
        guard stateReadError == nil else { return false }
        var capped = state
        capped.processed = Array(capped.processed.suffix(200))
        capped.materials = Array(capped.materials.suffix(200))
        capped.attempts = Array(capped.attempts.suffix(100))
        capped.runTimestamps = capped.runTimestamps.filter { Date().timeIntervalSince($0) < 24 * 3600 }
        do {
            try FileManager.default.createDirectory(at: BridgePaths.learningDirectory,
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(capped)
            try data.write(to: BridgePaths.learningStateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: BridgePaths.learningStateURL.path)
            return true
        } catch {
            log.error("journal d'apprentissage non enregistré : \(error.localizedDescription)")
            return false
        }
    }

    private func loadHistory() -> LearningGate.History {
        let state = loadState()
        // Le plafond est commun aux trois consommateurs dans AnalysisBudget.
        return LearningGate.History(processed: state.processed, runTimestamps: [])
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
    /// `digestByteCap` et `digestLineCap`. Atteindre une borne est signalé :
    /// le condensé ne prétend alors pas représenter toute la session.
    /// `internal` (et non `private`) : la passation vers Codex a besoin du MÊME
    /// condensé. En écrire un second aurait fait diverger deux lectures d'un
    /// format que la règle n° 3 déclare instable.
    nonisolated static func digest(ofTranscriptAt path: String,
                                   budget: Int = TranscriptDigest.defaultCharacterBudget,
                                   provider: AgentProvider = .claude,
                                   byteCap: Int = 64 * 1024 * 1024,
                                   lineCap: Int = 200_000) -> TranscriptDigest.Result? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var splitter = TranscriptLineSplitter(startOffset: 0)
        var lines: [TranscriptLine] = []
        var readBytes = 0
        while readBytes < byteCap, lines.count < lineCap,
              let chunk = try? handle.read(upToCount: min(4 << 20, byteCap - readBytes)), !chunk.isEmpty {
            readBytes += chunk.count
            for raw in splitter.consume(chunk) {
                let parsed = provider == .codex
                    ? CodexTranscriptParser.parse(raw.data)
                    : TranscriptLineParser.parse(raw.data)
                if let parsed { lines.append(parsed) }
                if lines.count >= lineCap { break }
            }
        }
        return TranscriptDigest.make(lines: lines, budget: budget,
            sourceReadStopped: readBytes >= byteCap || lines.count >= lineCap)
    }

}
