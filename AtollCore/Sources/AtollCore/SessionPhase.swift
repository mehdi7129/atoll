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

        // Les hooks d'outil, même homonymes, peuvent appartenir à un autre
        // appel ou à un sous-agent. Sans corrélation native de la demande,
        // conserver l'attente jusqu'à une preuve sur la session entière.
        if case .waitingPermission = phase {
            switch event.kind {
            case .sessionStart, .userPromptSubmit, .permissionRequest,
                 .stop, .stopFailure, .sessionEnd:
                break
            case .notification:
                guard ["permission_prompt", "idle_prompt"].contains(event.notificationType ?? "") else { return phase }
            default:
                return phase
            }
        }

        switch event.kind {
        case .sessionStart:
            return .waitingInput
        case .userPromptSubmit:
            return .busy
        case .preToolUse:
            // Gardé comme les événements de complétion : `preToolUse` est
            // l'événement de sous-agent le PLUS fréquent, et il arrive AVANT
            // `postToolUse`. Le protéger seulement là-bas laissait la faille
            // grande ouverte — « appliqué à une partie seulement de ses
            // points », dans le correctif même qui prétendait fermer ce motif.
            return .toolRunning(tool: event.toolSummary ?? event.toolName)
        case .permissionRequest:
            return .waitingPermission(tool: event.toolSummary ?? event.toolName)
        case .postToolUse, .postToolUseFailure, .permissionDenied, .subagentStart, .subagentStop:
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
