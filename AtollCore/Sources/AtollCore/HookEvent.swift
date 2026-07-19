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
        case permissionRequest = "PermissionRequest"
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

    /// Une question du tool AskUserQuestion.
    public struct AskQuestion: Equatable, Sendable {
        public struct Option: Equatable, Sendable {
            public let label: String
            public let description: String?
        }

        public let question: String
        public let header: String?
        public let multiSelect: Bool
        public let options: [Option]
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
    // Spécifique PermissionRequest — conservé en Data (re-sérialisé) pour rester
    // Equatable/Sendable tout en permettant le passthrough exact vers la décision.
    public let toolInputData: Data?
    public let suggestionsData: Data?
    /// Markdown du plan si l'outil est ExitPlanMode.
    public let planText: String?
    /// Questions décodées si l'outil est AskUserQuestion.
    public let questions: [AskQuestion]?
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

        let toolInput = payload["tool_input"] as? [String: Any]
        if kind == .permissionRequest {
            toolInputData = toolInput.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            suggestionsData = (payload["permission_suggestions"] as? [Any])
                .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            planText = toolInput?["plan"] as? String
            questions = Self.parseQuestions(toolInput)
        } else {
            toolInputData = nil
            suggestionsData = nil
            planText = nil
            questions = nil
        }

        let enrich = envelope["enrich"] as? [String: Any] ?? [:]
        claudePid = (enrich["pid"] as? NSNumber)?.int32Value
        claudeStartTime = (enrich["startTime"] as? NSNumber)?.doubleValue
        tty = enrich["tty"] as? String
        terminalHint = enrich["terminalHint"] as? String
        entrypoint = enrich["entrypoint"] as? String
    }

    private static func parseQuestions(_ toolInput: [String: Any]?) -> [AskQuestion]? {
        guard let raw = toolInput?["questions"] as? [[String: Any]], !raw.isEmpty else { return nil }
        let parsed = raw.compactMap { entry -> AskQuestion? in
            guard let question = entry["question"] as? String else { return nil }
            let options = (entry["options"] as? [[String: Any]] ?? []).compactMap { option -> AskQuestion.Option? in
                guard let label = option["label"] as? String else { return nil }
                return AskQuestion.Option(label: label, description: option["description"] as? String)
            }
            return AskQuestion(
                question: question,
                header: entry["header"] as? String,
                multiSelect: entry["multiSelect"] as? Bool ?? false,
                options: options
            )
        }
        return parsed.isEmpty ? nil : parsed
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
