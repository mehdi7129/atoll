import Foundation
import Observation
import OSLog
import AtollCore

@MainActor
@Observable
final class CodexService {
    static let shared = CodexService()
    static let quotaEnabledKey = "codexQuotaEnabled"
    /// Marqueur d'environnement des `codex exec` lancés par Atoll lui-même.
    /// Même valeur que côté helper (`CodexBridge.internalRunMarker`) et que le
    /// chemin Claude : c'est `RetrospectiveRunner` qui le pose.
    static let internalRunMarker = "ATOLL_RETROSPECTIVE"
    static var executableKey: String { CodexExecutable.overrideKey }

    private(set) var sessions: [AgentSession] = []
    private(set) var quota: CodexQuota?
    private(set) var status = "lecture désactivée dans Réglages → Codex"
    private(set) var isLoading = false
    @ObservationIgnored private var observed = CodexSessions()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var scanGeneration = UUID()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanTicket = UUID()
    private(set) var lastEventAt: Date?
    var serverRunning = false {
        didSet { SessionStore.shared.scheduleSnapshot() }
    }
    @ObservationIgnored private var records: [CodexSessionRecord] = []
    @ObservationIgnored private var metadataTask: Task<Void, Never>?
    @ObservationIgnored private var metadataTicket = UUID()
    @ObservationIgnored private var metadataSignatures: [String: String] = [:]

    func start() {
        records = CodexSessionRegistry.load(from: CodexSessionScanner.registryURL)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let ended = self.observed.reconcile { pid in
                    .init(isAlive: ProcessInspector.isAlive(pid), startTime: ProcessInspector.startTime(of: pid))
                }
                for session in ended {
                    self.scanGeneration = UUID()
                    self.records.removeAll { $0.sessionID == session.sessionID }
                    CodexInteractionCenter.shared.cancelAll(forSession: session.sessionID, process: session.process)
                    RetrospectiveRunner.shared.codexSessionEnded(session)
                }
                if !ended.isEmpty { self.saveRecords() }
                self.observed.prune()
                // Un helper mort ne doit pas laisser sa carte à l'écran.
                CodexInteractionCenter.shared.dropCardsOfDeadHelpers()
                self.adoptRunningSessions()
                self.sessions = self.observed.sessions()
                self.refreshMetadata()
                SessionStore.shared.scheduleSnapshot()
            }
        }
        // AU DÉMARRAGE, tout de suite : c'est précisément le trou que ce scan
        // comble — une session Codex ouverte pendant qu'Atoll redémarrait
        // restait invisible jusqu'au prochain prompt de l'utilisateur.
        adoptRunningSessions()
        sessions = observed.sessions()
        syncQuotaSettings()
    }

    /// Relit hors du fil principal le registre d'identités confirmé par les hooks.
    /// Les hooks restent l'autorité — `adopt` n'écrase rien.
    private func adoptRunningSessions() {
        guard scanTask == nil else { return }
        let known = Set(observed.sessions().map(\.id))
        let current = scanGeneration
        let home = CodexPaths.homeURL
        let ticket = UUID()
        scanTicket = ticket
        scanTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                CodexSessionScanner.scan(known: known, home: home)
            }.value
            guard let self else { return }
            guard ticket == self.scanTicket else { return }
            self.scanTask = nil
            guard !Task.isCancelled, current == self.scanGeneration else { return }
            self.observed.adopt(found)
            self.sessions = self.observed.sessions()
            self.refreshMetadata()
        }
    }

    func contains(_ sessionID: String) -> Bool {
        observed.contains(sessionID) || CodexInteractionCenter.shared.pending.contains { $0.sessionID == sessionID }
    }

    func accepts(_ event: CodexHookEvent) -> Bool {
        let accepted = CodexPaths.configurationError == nil
            && (event.home.map { $0 == CodexPaths.homeURL } ?? (CodexPaths.configuredHome == nil))
        if !accepted {
            Logger(subsystem: "dev.mehdiguiard.atoll", category: "codex-service")
                .info("Événement Codex ignoré : dossier du hook différent du dossier sélectionné ou configuration invalide.")
        }
        return accepted
    }

    func changeHome(to path: String?) throws {
        try CodexPaths.selectHome(path)
        stop()
        for card in CodexInteractionCenter.shared.pending { CodexInteractionCenter.shared.handBack(card.id) }
        RetrospectiveRunner.shared.codexConfigurationChanged()
        NotesCurationService.shared.cancelIfCodex()
        PluginInventory.shared.cancelIfCodex()
        observed = CodexSessions()
        sessions = []
        lastEventAt = nil
        CodexExecutable.invalidateCache()
        SkillReviewCenter.shared.reconcileAndScan()
        start()
    }

    private func saveRecords() {
        try? CodexSessionRegistry.save(records, to: CodexSessionScanner.registryURL)
    }

    private func refreshMetadata() {
        guard metadataTask == nil else { return }
        let records = records, signatures = metadataSignatures, ticket = UUID()
        metadataTicket = ticket
        metadataTask = Task { [weak self] in
            let values = await Task.detached(priority: .utility) {
                records.compactMap { record -> (CodexSessionRecord, String, CodexSessionMetadata)? in
                    let url = URL(fileURLWithPath: record.transcriptPath)
                    guard let info = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
                    let signature = "\(record.process.pid):\(record.process.startedAt):\(info.fileSize ?? 0):\(info.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                    guard signatures[record.sessionID] != signature,
                          let metadata = CodexSessionMetadata.read(at: url, sessionID: record.sessionID) else { return nil }
                    return (record, signature, metadata)
                }
            }.value
            guard let self, self.metadataTicket == ticket, !Task.isCancelled else { return }
            self.metadataTask = nil
            for (record, signature, metadata) in values {
                self.observed.enrich(metadata, sessionID: record.sessionID, process: record.process)
                self.metadataSignatures[record.sessionID] = signature
            }
            self.metadataSignatures = self.metadataSignatures.filter { id, _ in self.records.contains { $0.sessionID == id } }
            self.sessions = self.observed.sessions()
            SessionStore.shared.scheduleSnapshot()
        }
    }

    /// Ancre terminal d'une session Codex — pendant de
    /// `SessionStore.terminalAnchor(for:)`. Sans elle, le jump-back reste mort
    /// pour Codex alors que son mécanisme est agnostique au fournisseur.
    func anchor(for sessionID: String) -> TerminalAnchor? {
        observed.anchor(for: sessionID)
    }

    /// Rollout d'une session Codex, pour la passation et le bilan.
    func transcriptPath(for sessionID: String) -> String? {
        observed.transcriptPath(for: sessionID)
    }

    /// Rend le verdict de la projection à l'appelant, qui en a besoin pour
    /// décider du sort de la CARTE : un tour certainement clos la tue, un tour
    /// seulement inconnu la laisse vivre.
    @discardableResult
    func apply(_ event: CodexHookEvent) -> CodexSessions.Applied {
        defer { SessionStore.shared.scheduleSnapshot() }
        scanGeneration = UUID()
        // `applyEvent` rend les faits de la session quand elle vient de se
        // terminer : c'est le pendant Codex de `SessionStore.onSessionEnded`, et
        // sans lui la boucle d'apprentissage n'existe pas pour Codex.
        let applied = observed.applyEvent(event)
        sessions = observed.sessions()
        if !applied.cardIsStale, event.kind == .permissionRequest {
            RetrospectiveRunner.shared.sessionResumed(event.sessionID)
        }
        // Un événement rejeté n'est pas un événement : il ne sonne pas non plus.
        // Sonner sur le `Stop` retardataire d'un tour déjà clos ferait tinter
        // une fin de tâche qui a déjà eu lieu.
        guard applied.accepted else { return applied }
        lastEventAt = Date()
        if event.agentID != nil {
            if let child = applied.childClosed {
                CodexInteractionCenter.shared.cancelAll(forAgent: child, inSession: event.sessionID,
                    turn: applied.childClosedTurn,
                    process: event.process ?? observed.process(for: event.sessionID))
            }
            return applied
        }
        if event.kind == .sessionStart || event.kind == .userPromptSubmit {
            RetrospectiveRunner.shared.sessionResumed(event.sessionID)
        }
        if event.kind == .sessionEnd {
            records.removeAll { $0.sessionID == event.sessionID }
            saveRecords()
        } else if let record = CodexSessionRecord(event: event, home: CodexPaths.homeURL,
                                                  previousAnchor: observed.anchor(for: event.sessionID)),
                  !records.contains(record) {
            records.removeAll { $0.sessionID == event.sessionID }
            records.append(record)
            records = Array(records.suffix(256))
            saveRecords()
        }
        playSound(for: event)
        // Une session qui se termine emporte ses cartes : le helper est mort
        // avec elle, répondre sur ces descripteurs n'atteindrait personne.
        if event.kind == .sessionEnd {
            CodexInteractionCenter.shared.cancelAll(forSession: event.sessionID,
                                                    process: applied.ended?.process ?? event.process)
        }
        // Un TOUR interrompu ou terminé emporte les siennes : plus personne
        // n'attend la réponse à une demande de ce tour. `SessionEnd` avait son
        // nettoyage, pas l'interruption — une carte y survivait jusqu'au reaper
        // ou aux 600 s d'expiration.
        switch applied.closure {
        case .none: break
        case .named(let turn):
            CodexInteractionCenter.shared.cancelAll(forSession: event.sessionID, turn: turn,
                                                    process: event.process ?? observed.process(for: event.sessionID))
        case .unnamed:
            // Clôture sans tour identifiable : on ne peut retirer que les cartes
            // qui n'en portent pas non plus. Retirer les autres reviendrait à
            // tuer les demandes d'un tour qu'on n'a pas prouvé clos.
            CodexInteractionCenter.shared.cancelUnattributedCards(forSession: event.sessionID,
                                                                  process: event.process ?? observed.process(for: event.sessionID))
        }
        if let ended = applied.ended { RetrospectiveRunner.shared.codexSessionEnded(ended) }
        if event.kind == .sessionStart || event.kind == .stop || event.kind == .postCompact { refreshMetadata() }
        return applied
    }

    func diagnosticSessions() -> [[String: Any]] {
        sessions.map { session in
            var row: [String: Any] = ["id": session.id, "provider": "codex",
                "phase": String(describing: session.status),
                "source": session.stateConfirmedByHook ? "hook" : "registry-or-stale-hook",
                "stateConfirmedByHook": session.stateConfirmedByHook,
                "observedChildCount": session.subagentCount,
                "childCountMeasured": session.subagentCountIsKnown]
            if let date = observed.lastObservedAt(for: session.id) { row["lastObservedAt"] = ISO8601DateFormatter().string(from: date) }
            if let identity = observed.process(for: session.id) { row["pid"] = identity.pid; row["processStartedAt"] = identity.startedAt }
            row["cwd"] = session.cwd
            row["model"] = session.model
            row["branchAtStart"] = session.gitBranch
            row["contextFraction"] = session.contextUsedFraction
            row["contextUsedTokens"] = session.contextTokenUsage?.usedTokens
            row["contextWindowTokens"] = session.contextTokenUsage?.windowTokens
            row["contextMeasuredAt"] = session.contextMeasuredAt.map { ISO8601DateFormatter().string(from: $0) }
            return row
        }
    }

    /// Les DEUX sons d'Atoll valent pour Codex comme pour Claude.
    ///
    /// Demande explicite de Mehdi le 2026-09-09 (« pour la partie son, je veux
    /// qu'on ait du son, c'est hyper important »), et le besoin est identique :
    /// il a mis ces sons pour être APPELÉ plutôt que surveiller un écran. Que
    /// la carte d'autorisation s'affiche dans Codex plutôt que dans l'îlot ne
    /// change rien à ce besoin — l'îlot dit d'ailleurs où la traiter.
    ///
    /// Table VOLONTAIREMENT étroite, comme celle du helper : `permissionRequest`
    /// → décision attendue, `stop` → tour terminé, et RIEN d'autre. Sonner sur
    /// `preToolUse` ou `sessionStart` ferait tinter chaque outil.
    private func playSound(for event: CodexHookEvent) {
        switch event.kind {
        case .stop: SoundCenter.shared.play(.taskCompleted)
        default: break
        }
    }

    func seedPreviewQuota() {
        guard CodexPreview.enabled else { return }
        quota = CodexQuota(result: ["rateLimits": ["limitId": "codex", "primary": [
            "usedPercent": 18, "windowDurationMins": 300, "resetsAt": Date().addingTimeInterval(7200).timeIntervalSince1970
        ], "secondary": ["usedPercent": 43, "windowDurationMins": 10080,
                          "resetsAt": Date().addingTimeInterval(172800).timeIntervalSince1970]]])
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pollTask?.cancel()
        generation = UUID()
        scanTask?.cancel()
        scanTask = nil
        scanTicket = UUID()
        scanGeneration = UUID()
        metadataTicket = UUID()
        metadataTask?.cancel()
        metadataTask = nil
        metadataSignatures = [:]
    }

    func syncQuotaSettings() {
        pollTask?.cancel()
        generation = UUID()
        let current = generation
        quota = nil // no cross-account/executable cache
        isLoading = false
        if let error = CodexPaths.configurationError { status = error; return }
        guard UserDefaults.standard.bool(forKey: Self.quotaEnabledKey) else {
            status = "lecture désactivée dans Réglages → Codex"
            return
        }
        status = "lecture du quota…"
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetch(generation: current)
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    private func fetch(generation current: UUID) async {
        guard let executable = resolveExecutable() else {
            status = "codex introuvable — indique son chemin dans les réglages"
            return
        }
        isLoading = true
        let home = CodexPaths.homeURL
        let worker = Task.detached(priority: .utility) {
            CodexAccountClient.read(executable: executable, home: home, cancelled: { Task<Never, Never>.isCancelled })
        }
        let outcome = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled, generation == current else { return }
        isLoading = false
        switch outcome {
        case .available(let value):
            quota = value
            status = "à jour · lecture toutes les 2 min"
        case .unavailable(let message):
            quota = nil // errors and account changes never appear as fresh 0%
            status = message
        }
    }

    /// UNE seule résolution pour toute l'app — celle de `CodexExecutable`. Deux
    /// copies auraient divergé, et la version précédente de ce fichier en
    /// portait déjà une seconde (leçon `byCoverage`, v0.16.1).
    private func resolveExecutable() -> URL? { CodexExecutable.resolveCheap() }
}
