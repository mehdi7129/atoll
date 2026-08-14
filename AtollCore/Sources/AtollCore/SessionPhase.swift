import Foundation

/// Phase d'une session Claude Code, pilotée par les événements de hooks.
public enum SessionPhase: Equatable, Sendable {
    case starting
    case busy
    case toolRunning(tool: String?)
    case waitingPermission(tool: String?)
    case waitingInput
    case compacting
    /// Terminal : aucune transition n'en sort.
    case ended

    /// Projection vers le statut d'affichage de l'îlot.
    public var uiStatus: AgentSession.Status {
        switch self {
        case .starting, .busy:
            return .working(tool: nil)
        case .toolRunning(let tool):
            return .working(tool: tool)
        case .waitingPermission(let tool):
            return .awaitingPermission(tool: tool ?? "permission")
        case .waitingInput:
            return .awaitingInput
        case .compacting:
            return .working(tool: "compact…")
        case .ended:
            return .done
        }
    }

    public var isAlive: Bool { self != .ended }
}

/// Machine à états pure : (phase, événement) → phase.
/// Mapping validé sur vibe-notch (docs/research/research-followup-session-liveness.md).
public enum SessionReducer {
    public static func reduce(_ phase: SessionPhase, _ event: ParsedHookEvent) -> SessionPhase {
        // ended est terminal : une nouvelle session (nouveau session_id) crée un nouvel état.
        guard phase != .ended else { return .ended }

        switch event.kind {
        case .sessionStart:
            return .waitingInput
        case .userPromptSubmit:
            return .busy
        case .preToolUse:
            return .toolRunning(tool: event.toolSummary ?? event.toolName)
        case .permissionRequest:
            return .waitingPermission(tool: event.toolSummary ?? event.toolName)
        case .postToolUse, .postToolUseFailure, .permissionDenied, .subagentStart, .subagentStop:
            // UNE ATTENTE DE DÉCISION NE SE QUITTE PAS SUR N'IMPORTE QUOI.
            //
            // La v0.16.1 a protégé la CARTE d'être effacée par un sous-agent —
            // les hooks d'outil d'un sous-agent portent le `session_id` du
            // PARENT — mais le correctif n'a pas été appliqué à la PHASE. La
            // carte restait donc affichée pendant que la phase repassait en
            // `.busy`, et comme `needsAttention` ne regarde QUE la permission,
            // l'îlot cessait d'alerter alors qu'un helper était toujours bloqué.
            // Le motif « appliqué à une partie seulement de ses points ».
            //
            // Même discriminant que `InteractionCenter.cancelForSession(_:tool:)` :
            // on ne quitte l'attente que pour le MÊME outil, et l'ambiguïté (un
            // nom manquant d'un côté ou de l'autre) ne quitte rien.
            // `permissionDenied` fait exception — il PROUVE que la demande a été
            // tranchée, quel que soit l'outil rapporté.
            if case .waitingPermission(let pending) = phase, event.kind != .permissionDenied {
                let finished = event.toolSummary ?? event.toolName
                guard let finished, !finished.isEmpty,
                      let pending, !pending.isEmpty,
                      finished == pending
                else { return phase }
            }
            // Un événement de complétion tardif (outil asynchrone terminé après
            // Stop) ne doit pas ré-afficher un spinner sans porte de sortie.
            return phase == .waitingInput ? .waitingInput : .busy
        case .notification:
            switch event.notificationType {
            case "permission_prompt":
                return .waitingPermission(tool: event.toolSummary ?? event.toolName)
            case "idle_prompt":
                return .waitingInput
            default:
                // Types inconnus (auth_success, elicitation…) : sans effet sur la phase.
                return phase
            }
        case .stop, .stopFailure:
            return .waitingInput
        case .preCompact:
            return .compacting
        case .postCompact:
            return .busy
        case .sessionEnd:
            return .ended
        }
    }
}
