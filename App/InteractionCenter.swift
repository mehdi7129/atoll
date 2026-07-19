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
    @ObservationIgnored weak var server: BridgeServer?

    var current: Pending? { pending.first }

    // MARK: - Enregistrement

    func register(event: ParsedHookEvent, requestID: String) {
        let kind: Kind
        if let plan = event.planText, event.toolName == "ExitPlanMode" {
            kind = .plan(plan)
        } else if let questions = event.questions, let inputData = event.toolInputData,
                  event.toolName == "AskUserQuestion" {
            kind = .questions(questions, toolInputData: inputData)
        } else {
            kind = .permission
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
