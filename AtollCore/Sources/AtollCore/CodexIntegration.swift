import Foundation

public enum AgentProvider: String, Sendable {
    case claude, codex
    public var label: String { self == .claude ? "Claude" : "Codex" }
}

/// Separate wire contract: never send Codex events through Claude's permissions,
/// transcript parser, fleet reconciliation or proactive memory injection.
public struct CodexHookEvent: Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case sessionStart = "SessionStart", sessionEnd = "SessionEnd"
        case userPromptSubmit = "UserPromptSubmit", preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse", permissionRequest = "PermissionRequest"
        case stop = "Stop", interrupt = "Interrupt"
        case preCompact = "PreCompact", postCompact = "PostCompact"
    }
    public let kind: Kind
    public let sessionID: String
    public let turnID: String?
    public let cwd: String?
    public let model: String?
    public let prompt: String?
    public let tool: String?

    public init?(envelope: [String: Any]) {
        guard envelope["provider"] as? String == "codex",
              let payload = envelope["payload"] as? [String: Any],
              let name = payload["hook_event_name"] as? String,
              let kind = Kind(rawValue: name),
              let id = payload["session_id"] as? String, !id.isEmpty,
              (payload["agent_id"] as? String).map({ $0.isEmpty }) ?? true
        else { return nil }
        self.kind = kind
        sessionID = "codex:" + id
        turnID = payload["turn_id"] as? String
        cwd = payload["cwd"] as? String
        model = payload["model"] as? String
        prompt = (payload["prompt"] as? String).map { String($0.prefix(200)) }
        tool = ParsedHookEvent.summarize(toolName: payload["tool_name"] as? String,
                                         input: payload["tool_input"] as? [String: Any])
    }
}

/// Hook-only observation, not a claimed inventory of every Codex desktop/CLI thread.
public struct CodexSessions: Sendable {
    private struct Entry: Sendable {
        var session: AgentSession
        var turnID: String?
        var lastEvent: Date
    }
    private var entries: [String: Entry] = [:]
    public init() {}

    public mutating func apply(_ event: CodexHookEvent, now: Date = Date()) {
        if event.kind == .sessionEnd { entries.removeValue(forKey: event.sessionID); return }
        var entry = entries[event.sessionID] ?? Entry(session: AgentSession(
            id: event.sessionID,
            projectName: event.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex",
            status: .awaitingInput, startedAt: now, cwd: event.cwd, provider: .codex
        ), lastEvent: now)
        // A late event from the previous turn must not finish the new turn.
        if event.kind != .userPromptSubmit, let turn = event.turnID,
           let current = entry.turnID, turn != current { return }
        if event.kind == .userPromptSubmit || entry.turnID == nil { entry.turnID = event.turnID }
        if let cwd = event.cwd {
            entry.session.cwd = cwd
            entry.session.projectName = URL(fileURLWithPath: cwd).lastPathComponent
        }
        if let model = event.model { entry.session.model = model }
        entry.lastEvent = now
        entry.session.stateConfirmedByHook = true
        switch event.kind {
        case .sessionStart, .stop, .interrupt: entry.session.status = .awaitingInput
        case .userPromptSubmit:
            entry.session.status = .working(tool: nil)
            entry.session.subtitle = event.prompt
        case .preToolUse: entry.session.status = .working(tool: event.tool)
        case .postToolUse, .postCompact: entry.session.status = .working(tool: nil)
        case .preCompact: entry.session.status = .working(tool: "compactage")
        case .permissionRequest:
            entry.session.status = .awaitingPermission(tool: event.tool ?? "Codex")
        case .sessionEnd: break
        }
        entries[event.sessionID] = entry
    }

    public func sessions(now: Date = Date()) -> [AgentSession] {
        entries.values.compactMap { entry -> AgentSession? in
            let age = now.timeIntervalSince(entry.lastEvent)
            guard age < 86_400 else { return nil } // crashed/abandoned clients
            var session = entry.session
            // Codex has no PermissionDenied hook. Silence isn't proof of an
            // outstanding approval, nor proof that a long-running tool finished.
            if age > (session.needsAttention ? 120 : 900) {
                session.status = .awaitingInput
                session.stateConfirmedByHook = false
            }
            return session
        }.sorted {
            if $0.needsAttention != $1.needsAttention { return $0.needsAttention }
            return $0.startedAt > $1.startedAt
        }
    }

    public mutating func prune(now: Date = Date()) {
        entries = entries.filter { now.timeIntervalSince($0.value.lastEvent) < 86_400 }
    }
}

/// Installed synchronously (short, fail-open) so main-thread lifecycle events
/// retain their order. No output, no decision, no transcript reads.
public enum CodexHookSettingsEditor {
    public static let command = "\"$HOME/.atoll/bin/atoll-codex-bridge\""
    public enum EditError: Error { case invalidSettings }

    public static func edit(_ data: Data?, install: Bool) throws -> Data {
        var root: [String: Any] = [:]
        if let data {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw EditError.invalidSettings }
            root = decoded
        }
        if let hooks = root["hooks"], !(hooks is [String: Any]) { throw EditError.invalidSettings }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for kind in CodexHookEvent.Kind.allCases {
            if let value = hooks[kind.rawValue], !(value is [[String: Any]]) {
                throw EditError.invalidSettings
            }
            var groups = hooks[kind.rawValue] as? [[String: Any]] ?? []
            groups = try groups.compactMap { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    throw EditError.invalidSettings
                }
                let kept = handlers.filter { $0["command"] as? String != command }
                if kept.count == handlers.count { return group }
                guard !kept.isEmpty else { return nil }
                var copy = group
                copy["hooks"] = kept
                return copy
            }
            if install {
                groups.append(["hooks": [["type": "command", "command": command, "timeout": 3]]])
            }
            if groups.isEmpty { hooks.removeValue(forKey: kind.rawValue) }
            else { hooks[kind.rawValue] = groups }
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    public static func isInstalled(_ data: Data?) -> Bool {
        guard let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return CodexHookEvent.Kind.allCases.allSatisfy { kind in
            (hooks[kind.rawValue] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains {
                    $0["command"] as? String == command
                }
            }
        }
    }
}
