import XCTest
@testable import AtollCore

final class CodexIntegrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func envelope(_ kind: String, extra: [String: Any] = [:]) -> [String: Any] {
        var payload: [String: Any] = ["hook_event_name": kind, "session_id": "same-id", "cwd": "/tmp/project"]
        payload.merge(extra) { _, new in new }
        return ["provider": "codex", "payload": payload]
    }

    func testProviderIsolationAndLegacyCompatibility() throws {
        let wire = envelope("PermissionRequest")
        XCTAssertNil(ParsedHookEvent(envelope: wire))
        XCTAssertEqual(CodexHookEvent(envelope: wire)?.sessionID, "codex:same-id")
        var legacy = wire
        legacy.removeValue(forKey: "provider")
        XCTAssertNotNil(ParsedHookEvent(envelope: legacy))
        XCTAssertNil(CodexHookEvent(envelope: legacy))
        legacy["provider"] = "future-provider"
        XCTAssertNil(ParsedHookEvent(envelope: legacy))
        XCTAssertNil(CodexHookEvent(envelope: legacy))
        legacy["provider"] = NSNull()
        XCTAssertNil(ParsedHookEvent(envelope: legacy))
        XCTAssertEqual(AgentSession(projectName: "legacy", status: .done).provider, .claude)
    }

    func testRejectsInvalidAndSubagentPayloads() {
        XCTAssertNil(CodexHookEvent(envelope: [:]))
        XCTAssertNil(CodexHookEvent(envelope: envelope("FutureEvent")))
        XCTAssertNil(CodexHookEvent(envelope: envelope("Stop", extra: ["agent_id": "child"])))
        XCTAssertNil(CodexHookEvent(envelope: envelope("SessionStart", extra: ["session_id": ""])))
        XCTAssertNotNil(CodexHookEvent(envelope: envelope("SessionStart", extra: ["transcript_path": NSNull()])))
    }

    func testMainLifecycleAndNativePermissionObservation() throws {
        var sessions = CodexSessions()
        func apply(_ kind: String, extra: [String: Any] = [:]) throws {
            sessions.apply(try XCTUnwrap(CodexHookEvent(envelope: envelope(kind, extra: extra))), now: now)
        }
        try apply("SessionStart", extra: ["model": "gpt-6"])
        XCTAssertEqual(sessions.sessions(now: now).first?.provider, .codex)
        XCTAssertEqual(sessions.sessions(now: now).first?.model, "gpt-6")
        try apply("UserPromptSubmit", extra: ["prompt": "bonjour", "turn_id": "t1"])
        XCTAssertTrue(try XCTUnwrap(sessions.sessions(now: now).first).isActive)
        try apply("PermissionRequest", extra: ["tool_name": "Bash", "tool_input": ["command": "git push"]])
        XCTAssertEqual(sessions.sessions(now: now).first?.status, .awaitingPermission(tool: "Bash(git push)"))
        try apply("PostToolUse")
        XCTAssertTrue(try XCTUnwrap(sessions.sessions(now: now).first).isActive)
        try apply("Stop")
        XCTAssertEqual(sessions.sessions(now: now).first?.status, .awaitingInput)
        try apply("SessionEnd")
        XCTAssertTrue(sessions.sessions(now: now).isEmpty)
    }

    func testInterruptAndOldTurnStop() throws {
        var sessions = CodexSessions()
        for (kind, turn) in [("UserPromptSubmit", "old"), ("UserPromptSubmit", "new"), ("Stop", "old")] {
            sessions.apply(try XCTUnwrap(CodexHookEvent(envelope: envelope(kind, extra: ["turn_id": turn]))), now: now)
        }
        XCTAssertTrue(try XCTUnwrap(sessions.sessions(now: now).first).isActive)
        sessions.apply(try XCTUnwrap(CodexHookEvent(envelope: envelope("Interrupt", extra: ["turn_id": "new"]))), now: now)
        XCTAssertEqual(sessions.sessions(now: now).first?.status, .awaitingInput)
    }

    func testSilenceNeverLeavesPermanentAttention() throws {
        var sessions = CodexSessions()
        sessions.apply(try XCTUnwrap(CodexHookEvent(envelope: envelope("PermissionRequest"))), now: now)
        let stale = try XCTUnwrap(sessions.sessions(now: now.addingTimeInterval(121)).first)
        XCTAssertFalse(stale.needsAttention)
        XCTAssertFalse(stale.stateConfirmedByHook)
        sessions.prune(now: now.addingTimeInterval(86_401))
        XCTAssertTrue(sessions.sessions(now: now.addingTimeInterval(86_401)).isEmpty)
    }

    func testLongActivityBecomesUnknownNotConfirmedIdle() throws {
        var sessions = CodexSessions()
        sessions.apply(try XCTUnwrap(CodexHookEvent(envelope: envelope("PreToolUse"))), now: now)
        XCTAssertTrue(try XCTUnwrap(sessions.sessions(now: now.addingTimeInterval(899)).first).isActive)
        XCTAssertFalse(try XCTUnwrap(sessions.sessions(now: now.addingTimeInterval(901)).first).stateConfirmedByHook)
    }

    func testHooksInstallIdempotentAndUninstallPreservesForeignHandlers() throws {
        let original = Data(#"{"description":"mine","other":true,"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"my-script"}]}],"FutureEvent":[{"custom":true}]}}"#.utf8)
        let installed = try CodexHookSettingsEditor.edit(original, install: true)
        XCTAssertTrue(CodexHookSettingsEditor.isInstalled(installed))
        XCTAssertEqual(installed, try CodexHookSettingsEditor.edit(installed, install: true))
        let removed = try CodexHookSettingsEditor.edit(installed, install: false)
        XCTAssertFalse(CodexHookSettingsEditor.isInstalled(removed))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: original) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: removed) as? NSDictionary)
    }

    func testHookEditorNeverOverwritesMalformedConfig() {
        for raw in ["not json", "[]", #"{"hooks":[]}"#, #"{"hooks":{"Stop":42}}"#,
                    #"{"hooks":{"Stop":[{"hooks":"oops"}]}}"#] {
            XCTAssertThrowsError(try CodexHookSettingsEditor.edit(Data(raw.utf8), install: true))
        }
    }

    func testManagedHandlerRemovedWithoutRemovingItsNeighbours() throws {
        let root: [String: Any] = ["hooks": ["Stop": [["matcher": "*", "hooks": [
            ["command": CodexHookSettingsEditor.command], ["command": "echo atoll-codex-bridge"]
        ]]]]]
        let data = try JSONSerialization.data(withJSONObject: root)
        let removed = try CodexHookSettingsEditor.edit(data, install: false)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: removed) as? [String: Any])
        let hooks = try XCTUnwrap(decoded["hooks"] as? [String: [[String: Any]]])
        let group = try XCTUnwrap(hooks["Stop"]?.first)
        XCTAssertEqual((group["hooks"] as? [[String: String]])?.first?["command"], "echo atoll-codex-bridge")
    }

    func testInstalledHooksAreBoundedObservationOnly() throws {
        let data = try CodexHookSettingsEditor.edit(nil, install: true)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(hooks.count, CodexHookEvent.Kind.allCases.count)
        for groups in hooks.values {
            let handler = try XCTUnwrap((groups.first?["hooks"] as? [[String: Any]])?.first)
            XCTAssertEqual(handler["timeout"] as? Int, 3)
            XCTAssertNil(handler["async"])
        }
    }
}
