import Foundation

/// Événement de hook Claude Code, décodé défensivement depuis l'enveloppe envoyée
/// par `atoll-bridge` sur le socket :
///
/// ```json
/// {
///   "v": 1,
///   "enrich": { "pid": 123, "startTime": 1234.5, "tty": "ttys012",
///               "terminalHint": "iTerm.app", "entrypoint": "cli" },
///   "payload": { …JSON reçu par le hook sur stdin… }
/// }
/// ```
///
/// Tout champ absent ou d'un type inattendu devient nil — le format des payloads
/// évolue entre versions du CLI et ne doit jamais nous faire planter.
public struct ParsedHookEvent: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse"
        case postToolUseFailure = "PostToolUseFailure"
        case permissionDenied = "PermissionDenied"
        case notification = "Notification"
        case stop = "Stop"
        case stopFailure = "StopFailure"
        case subagentStart = "SubagentStart"
        case subagentStop = "SubagentStop"
        case preCompact = "PreCompact"
        case postCompact = "PostCompact"
        case sessionEnd = "SessionEnd"
    }

    public let kind: Kind
    public let sessionID: String
    public let transcriptPath: String?
    public let cwd: String?
    public let toolName: String?
    public let toolSummary: String?
    public let notificationType: String?
    public let promptText: String?
    public let sessionEndReason: String?
    // Enrichissements du helper.
    public let claudePid: Int32?
    public let claudeStartTime: Double?
    public let tty: String?
    public let terminalHint: String?
    public let entrypoint: String?

    public init?(envelopeData: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: envelopeData),
              let envelope = object as? [String: Any] else { return nil }
        self.init(envelope: envelope)
    }

    public init?(envelope: [String: Any]) {
        guard let payload = envelope["payload"] as? [String: Any],
              let eventName = payload["hook_event_name"] as? String,
              let kind = Kind(rawValue: eventName),
              let sessionID = payload["session_id"] as? String,
              !sessionID.isEmpty
        else { return nil }

        self.kind = kind
        self.sessionID = sessionID
        transcriptPath = payload["transcript_path"] as? String
        cwd = payload["cwd"] as? String
        toolName = payload["tool_name"] as? String
        toolSummary = Self.summarize(
            toolName: payload["tool_name"] as? String,
            input: payload["tool_input"] as? [String: Any]
        )
        // Les docs et les payloads réels divergent : "notification_type" ou "type".
        notificationType = (payload["notification_type"] as? String) ?? (payload["type"] as? String)
        promptText = payload["prompt"] as? String
        sessionEndReason = payload["reason"] as? String

        let enrich = envelope["enrich"] as? [String: Any] ?? [:]
        claudePid = (enrich["pid"] as? NSNumber)?.int32Value
        claudeStartTime = (enrich["startTime"] as? NSNumber)?.doubleValue
        tty = enrich["tty"] as? String
        terminalHint = enrich["terminalHint"] as? String
        entrypoint = enrich["entrypoint"] as? String
    }

    /// Résumé lisible d'un appel d'outil pour l'affichage : `Bash(git push)`, `Edit(Foo.swift)`…
    public static func summarize(toolName: String?, input: [String: Any]?, maxLength: Int = 90) -> String? {
        guard let toolName else { return nil }
        var detail: String?
        if let input {
            if let command = input["command"] as? String {
                detail = command
            } else if let path = input["file_path"] as? String {
                detail = (path as NSString).lastPathComponent
            } else if let pattern = input["pattern"] as? String {
                detail = pattern
            } else if let description = input["description"] as? String {
                detail = description
            }
        }
        guard var detail, !detail.isEmpty else { return toolName }
        detail = detail.replacingOccurrences(of: "\n", with: " ")
        if detail.count > maxLength {
            detail = String(detail.prefix(maxLength)) + "…"
        }
        return "\(toolName)(\(detail))"
    }
}
