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
    /// Cet événement autorise-t-il à QUITTER une attente de décision ?
    ///
    /// Hors attente de décision, toujours oui — cette garde ne change rien au
    /// reste de la machine.
    ///
    /// LE DISCRIMINANT EST LE NOM D'OUTIL, pas le résumé. `toolSummary` inclut
    /// les ARGUMENTS (`Bash(git push)`) : comparer des résumés faisait échouer
    /// TOUTE sortie légitime — deux appels du même outil n'ont jamais le même
    /// résumé — et la session serait restée en alerte pour toujours. C'est le
    /// même discriminant que `InteractionCenter.cancelForSession(_:tool:)`,
    /// cette fois pour de bon : la carte et la phase se ferment ensemble.
    ///
    /// Pourquoi cette garde existe : les hooks d'outil d'un SOUS-AGENT portent
    /// le `session_id` du PARENT. Sans elle, un sous-agent faisait passer
    /// `.waitingPermission` à `.busy` — et comme `needsAttention` ne regarde que
    /// la permission, l'îlot cessait d'alerter pendant qu'un helper restait
    /// bloqué. `permissionDenied` fait exception : il PROUVE la décision.
    ///
    /// ON NE BLOQUE QUE SUR PREUVE POSITIVE — deux noms d'outil présents et
    /// DIFFÉRENTS. Un événement sans nom exploitable laisse passer.
    ///
    /// C'est l'inverse du défaut de la carte (`cancelForSession(_:tool:)`, qui
    /// n'annule rien sans nom), et l'asymétrie est VOULUE parce que les deux
    /// erreurs ne coûtent pas la même chose : refermer une carte à tort perd une
    /// décision que l'utilisateur n'a jamais prise, alors que retenir une alerte
    /// à tort ne fait que du bruit. La documentation de terrain
    /// (`docs/research/research-claude-integration.md` l. 15) range `tool_name`
    /// parmi les champs de `PreToolUse`/`PermissionRequest` et n'attribue à
    /// `PostToolUse` que `tool_response` : si un `PostToolUse` réel arrivait sans
    /// nom d'outil, bloquer par défaut aurait retenu l'alerte jusqu'au `Stop`
    /// suivant — une régression visible, sur une hypothèse non mesurée. La
    /// défense contre le SOUS-AGENT, elle, ne dépend pas de ce choix : ses
    /// événements portent bien un nom d'outil, et il est différent.
    private static func mayLeavePermissionWait(_ phase: SessionPhase, _ event: ParsedHookEvent) -> Bool {
        guard case .waitingPermission(let pending) = phase else { return true }
        switch event.kind {
        case .permissionDenied:
            // La demande a été tranchée : ça sort, quel que soit l'outil.
            return true
        case .subagentStart, .subagentStop:
            // Ils ne portent pas de nom d'outil — mais ils NOMMENT leur nature :
            // un sous-agent ne dit rien de ce que la session PARENTE attend.
            // C'est une preuve positive, pas une ambiguïté.
            return false
        default:
            guard let pending, !pending.isEmpty,
                  let finished = event.toolName, !finished.isEmpty
            else { return true }
            return ParsedHookEvent.toolName(ofSummary: pending) == finished
        }
    }

    public static func reduce(_ phase: SessionPhase, _ event: ParsedHookEvent) -> SessionPhase {
        // ended est terminal : une nouvelle session (nouveau session_id) crée un nouvel état.
        guard phase != .ended else { return .ended }

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
            guard mayLeavePermissionWait(phase, event) else { return phase }
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
            guard mayLeavePermissionWait(phase, event) else { return phase }
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
