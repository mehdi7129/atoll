import Foundation
import Observation
import AtollCore

@MainActor
@Observable
final class CodexService {
    static let shared = CodexService()
    static let quotaEnabledKey = "codexQuotaEnabled"
    static var executableKey: String { CodexExecutable.overrideKey }

    private(set) var sessions: [AgentSession] = []
    private(set) var quota: CodexQuota?
    private(set) var status = "lecture désactivée dans Réglages → Codex"
    private(set) var isLoading = false
    @ObservationIgnored private var observed = CodexSessions()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.observed.prune()
                // Un helper mort ne doit pas laisser sa carte à l'écran.
                CodexInteractionCenter.shared.dropCardsOfDeadHelpers()
                self.adoptRunningSessions()
                self.sessions = self.observed.sessions()
            }
        }
        // AU DÉMARRAGE, tout de suite : c'est précisément le trou que ce scan
        // comble — une session Codex ouverte pendant qu'Atoll redémarrait
        // restait invisible jusqu'au prochain prompt de l'utilisateur.
        adoptRunningSessions()
        sessions = observed.sessions()
        syncQuotaSettings()
    }

    /// Scan hors du fil principal : `proc_listpids` puis une lecture d'en-tête
    /// par rollout. Les hooks restent l'autorité — `adopt` n'écrase rien.
    private func adoptRunningSessions() {
        let known = Set(observed.sessions().map(\.id))
        Task.detached(priority: .utility) {
            let found = CodexSessionScanner.scan(known: known)
            guard !found.isEmpty else { return }
            await MainActor.run {
                self.observed.adopt(found)
                self.sessions = self.observed.sessions()
            }
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
        // `applyEvent` rend les faits de la session quand elle vient de se
        // terminer : c'est le pendant Codex de `SessionStore.onSessionEnded`, et
        // sans lui la boucle d'apprentissage n'existe pas pour Codex.
        let applied = observed.applyEvent(event)
        sessions = observed.sessions()
        // Un événement rejeté n'est pas un événement : il ne sonne pas non plus.
        // Sonner sur le `Stop` retardataire d'un tour déjà clos ferait tinter
        // une fin de tâche qui a déjà eu lieu.
        guard applied.accepted else { return applied }
        playSound(for: event)
        // Une session qui se termine emporte ses cartes : le helper est mort
        // avec elle, répondre sur ces descripteurs n'atteindrait personne.
        if event.kind == .sessionEnd {
            CodexInteractionCenter.shared.cancelAll(forSession: event.sessionID)
        }
        // Un TOUR interrompu ou terminé emporte les siennes : plus personne
        // n'attend la réponse à une demande de ce tour. `SessionEnd` avait son
        // nettoyage, pas l'interruption — une carte y survivait jusqu'au reaper
        // ou aux 600 s d'expiration.
        switch applied.closure {
        case .none: break
        case .named(let turn):
            CodexInteractionCenter.shared.cancelAll(forSession: event.sessionID, turn: turn)
        case .unnamed:
            // Clôture sans tour identifiable : on ne peut retirer que les cartes
            // qui n'en portent pas non plus. Retirer les autres reviendrait à
            // tuer les demandes d'un tour qu'on n'a pas prouvé clos.
            CodexInteractionCenter.shared.cancelUnattributedCards(forSession: event.sessionID)
        }
        if let ended = applied.ended { RetrospectiveRunner.shared.codexSessionEnded(ended) }
        return applied
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
        case .permissionRequest: SoundCenter.shared.play(.decisionNeeded)
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
    }

    func syncQuotaSettings() {
        pollTask?.cancel()
        generation = UUID()
        let current = generation
        quota = nil // no cross-account/executable cache
        isLoading = false
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
        let worker = Task.detached(priority: .utility) {
            CodexAccountClient.read(executable: executable, cancelled: { Task<Never, Never>.isCancelled })
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

