import Foundation
import Observation
import OSLog
import AtollCore

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "interactions")

/// Registre des demandes interactives en attente (permissions, plans, questions)
/// et façade des décisions vers le BridgeServer.
///
/// Course avec le terminal (documentée, issue #12176) : le prompt TUI s'affiche
/// pendant que le hook bloque — premier répondu gagne. Quand un événement de
/// résolution arrive (PostToolUse, PermissionDenied, Stop, SessionEnd), la carte
/// est annulée et la connexion fermée en silence.
@MainActor
@Observable
final class InteractionCenter {
    static let shared = InteractionCenter()

    enum Kind: Equatable {
        /// Permission d'outil classique (Bash, Edit…).
        case permission
        /// Validation de plan (ExitPlanMode) — markdown du plan.
        case plan(String)
        /// Questions (AskUserQuestion) — passthrough du tool_input requis.
        case questions([ParsedHookEvent.AskQuestion], toolInputData: Data)
    }

    struct Pending: Identifiable, Equatable {
        let id: String
        let sessionID: String
        let projectName: String
        let kind: Kind
        let toolName: String?
        let toolSummary: String?
        let receivedAt: Date

        static func == (lhs: Pending, rhs: Pending) -> Bool { lhs.id == rhs.id }
    }

    private(set) var pending: [Pending] = []
    /// Compteur des permissions approuvées automatiquement (mode auto-accept).
    private(set) var autoAcceptedCount = 0
    private(set) var lastAutoAccepted: String?
    @ObservationIgnored weak var server: BridgeServer?

    var current: Pending? { pending.first }

    /// Clé unique du niveau d'autonomie (Manuel / Auto / Rockstar).
    static let autonomyKey = "autonomyLevel"
    // Anciennes clés — conservées uniquement pour la migration ponctuelle.
    static let autoAcceptKey = "autoAcceptEnabled"
    static let rockstarKey = "rockstarEnabled"

    /// Niveau d'autonomie courant. Les règles deny et les hooks bloquants de
    /// l'utilisateur s'exécutent dans Claude Code AVANT que la demande n'atteigne
    /// Atoll — un hook ne peut pas les outrepasser (vérifié : même
    /// `setMode bypassPermissions` via updatedPermissions est ignoré par le CLI).
    /// C'est pourquoi Rockstar suspend les règles deny À LA SOURCE (parking via
    /// HookInstaller.syncDenyParking) ; les hooks bloquants de l'utilisateur,
    /// eux, restent toujours actifs (ce sont des éléments de son workflow).
    var autonomyLevel: AutonomyLevel {
        AutonomyLevel(rawValue: UserDefaults.standard.string(forKey: Self.autonomyKey) ?? "") ?? .manual
    }

    /// Migration unique des deux anciens booléens vers le réglage à 3 niveaux.
    /// Rockstar l'emporte s'il était activé, sinon auto, sinon manuel.
    static func migrateAutonomyIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: autonomyKey) == nil else { return }
        let level: AutonomyLevel
        if defaults.bool(forKey: rockstarKey) { level = .rockstar }
        else if defaults.bool(forKey: autoAcceptKey) { level = .auto }
        else { level = .manual }
        defaults.set(level.rawValue, forKey: autonomyKey)
        defaults.removeObject(forKey: rockstarKey)
        defaults.removeObject(forKey: autoAcceptKey)
    }

    // MARK: - Enregistrement

    func register(event: ParsedHookEvent, requestID: String) {
        // Classement par CONTENU, pas par nom d'outil strict : une question mal
        // classée en permission enverrait un allow sans réponses (le CLI
        // avancerait sans réponse). Priorité aux questions puis au plan.
        let kind: Kind
        if let questions = event.questions, let inputData = event.toolInputData {
            kind = .questions(questions, toolInputData: inputData)
        } else if let plan = event.planText {
            kind = .plan(plan)
        } else {
            kind = .permission
        }

        // Auto-approbation selon le niveau d'autonomie (un seul réglage, exclusif).
        switch autonomyLevel {
        case .rockstar:
            // Approuve TOUT : permissions (même destructrices), plans, questions.
            // Les règles deny de l'utilisateur sont déjà suspendues par le
            // parking ; ses hooks bloquants restent actifs (workflow).
            if let decision = rockstarDecision(for: kind) {
                autoApprove(requestID, decision: decision, event: event,
                            label: event.toolSummary ?? event.toolName ?? kindLabel(kind),
                            tag: "rockstar")
                return
            }
        case .auto:
            // Permissions SÛRES uniquement (allowlist) — jamais destructif, plans
            // ni questions (le classement plus haut les exclut du cas .permission).
            if case .permission = kind,
               AutoAcceptPolicy.isSafeToAutoAccept(toolName: event.toolName, toolInputData: event.toolInputData) {
                autoApprove(requestID, decision: PermissionDecision.allow(), event: event,
                            label: event.toolSummary ?? event.toolName ?? "outil", tag: "auto")
                return
            }
        case .manual:
            break
        }

        let project = event.cwd.map { ($0 as NSString).lastPathComponent } ?? "claude"
        pending.append(Pending(
            id: requestID,
            sessionID: event.sessionID,
            projectName: project,
            kind: kind,
            toolName: event.toolName,
            toolSummary: event.toolSummary,
            receivedAt: Date()
        ))
    }

    /// À l'activation de Rockstar : résout immédiatement les cartes DÉJÀ en
    /// attente (l'utilisateur vient précisément de dire « décidez sans moi »).
    /// Sans cela, une carte antérieure au changement resterait bloquée.
    func resolvePendingAsRockstar() {
        guard autonomyLevel == .rockstar, !pending.isEmpty else { return }
        let waiting = pending
        pending.removeAll()
        for request in waiting {
            if let decision = rockstarDecision(for: request.kind) {
                server?.reply(request.id, decision: decision)
                autoAcceptedCount += 1
                lastAutoAccepted = request.toolSummary ?? request.toolName ?? kindLabel(request.kind)
                SessionStore.shared.markAutoApproved(request.sessionID)
                log.info("rockstar (carte en attente): \(self.lastAutoAccepted ?? "?", privacy: .public)")
            } else {
                // Décision impossible (tool_input illisible) : rendre la main.
                server?.cancelPending(request.id)
            }
        }
    }

    /// Approuve automatiquement : envoie la décision, compte, ré-avance la phase.
    private func autoApprove(_ requestID: String, decision: Data, event: ParsedHookEvent,
                             label: String, tag: String) {
        server?.reply(requestID, decision: decision)
        autoAcceptedCount += 1
        lastAutoAccepted = label
        SessionStore.shared.markAutoApproved(event.sessionID)
        log.info("\(tag, privacy: .public): \(label, privacy: .public)")
    }

    /// Décision d'approbation automatique pour le mode rockstar, selon le type.
    /// nil = impossible de décider (ex. questions dont le tool_input est illisible) →
    /// on rend alors la main au terminal plutôt que d'envoyer du JSON malformé.
    private func rockstarDecision(for kind: Kind) -> Data? {
        switch kind {
        case .permission:
            return PermissionDecision.allow()
        case .plan:
            // acceptEdits : après le plan, les éditions ne redemandent plus rien
            // (seul setMode qu'un hook puisse réellement poser — bypassPermissions
            // est ignoré par le CLI, vérifié 2.1.215).
            return PermissionDecision.approvePlan(acceptEdits: true)
        case .questions(let questions, let toolInputData):
            return PermissionDecision.answerQuestions(
                toolInputData: toolInputData,
                answers: PermissionDecision.defaultAnswers(for: questions)
            )
        }
    }

    private func kindLabel(_ kind: Kind) -> String {
        switch kind {
        case .permission: return "permission"
        case .plan: return "plan"
        case .questions: return "question"
        }
    }

    // MARK: - Décisions

    func allow(_ id: String) {
        resolve(id) { _ in PermissionDecision.allow() }
    }

    func deny(_ id: String, message: String = "Refusé depuis Atoll.") {
        resolve(id) { _ in PermissionDecision.deny(message: message) }
    }

    func approvePlan(_ id: String, acceptEdits: Bool) {
        resolve(id) { _ in PermissionDecision.approvePlan(acceptEdits: acceptEdits) }
    }

    func rejectPlan(_ id: String, feedback: String) {
        let message = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        resolve(id) { _ in
            PermissionDecision.rejectPlan(feedback: message.isEmpty ? "Plan refusé depuis Atoll." : message)
        }
    }

    func answerQuestions(_ id: String, answers: [String: String]) {
        resolve(id) { request in
            guard case .questions(_, let toolInputData) = request.kind else { return nil }
            return PermissionDecision.answerQuestions(toolInputData: toolInputData, answers: answers)
        }
    }

    /// Rendre explicitement la main au prompt du terminal.
    func handBackToTerminal(_ id: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: index)
        server?.cancelPending(request.id)
    }

    /// Course perdue / session terminée : annule les cartes de la session.
    func cancelForSession(_ sessionID: String) {
        let toCancel = pending.filter { $0.sessionID == sessionID }
        guard !toCancel.isEmpty else { return }
        pending.removeAll { $0.sessionID == sessionID }
        for request in toCancel {
            server?.cancelPending(request.id)
            log.info("carte annulée (résolue ailleurs): \(request.id, privacy: .public)")
        }
    }

    private func resolve(_ id: String, _ build: (Pending) -> Data?) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: index)
        if let decision = build(request) {
            server?.reply(request.id, decision: decision)
        } else {
            // Décision impossible à construire : on rend la main plutôt que
            // d'envoyer du JSON malformé au CLI.
            server?.cancelPending(request.id)
        }
    }
}
