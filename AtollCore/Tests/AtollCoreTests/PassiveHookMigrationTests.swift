import XCTest
@testable import AtollCore

final class PassiveHookMigrationTests: XCTestCase {
    private let claudeCommand = "\"$HOME/.atoll/bin/atoll-bridge\""

    private func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    func testClaudeMigrationKeepsRemovedEventsMixedGroupsAndPersonalFields() throws {
        let foreign: [String: Any] = ["command": "echo personal", "async": false, "timeout": 100]
        let original = try encode([
            "permissions": ["deny": ["Bash(example)"]],
            "statusLine": ["command": "my-statusline", "refreshInterval": 17],
            "hooks": [
                "PermissionRequest": [["matcher": "Bash", "customGroup": 42, "hooks": [
                    ["command": claudeCommand, "timeout": 86_400, "async": false,
                     "statusMessage": "Waiting for approval in Atoll", "customField": "keep"], foreign]]],
                "UserPromptSubmit": [["hooks": [["command": claudeCommand, "timeout": 5]]]],
                "FutureEvent": [["hooks": [foreign]]]
            ]
        ])
        let data = try HookSettingsEditor.migratePassive(original)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(Set(hooks.keys), Set(["PermissionRequest", "UserPromptSubmit", "FutureEvent"]), "removed-event-reinstalled")
        let group = try XCTUnwrap(hooks["PermissionRequest"]?.first)
        XCTAssertEqual(group["matcher"] as? String, "Bash")
        XCTAssertEqual(group["customGroup"] as? Int, 42)
        let handlers = try XCTUnwrap(group["hooks"] as? [[String: Any]])
        XCTAssertEqual(handlers[0]["async"] as? Bool, true, "claude-permission-blocking")
        XCTAssertEqual(handlers[0]["timeout"] as? Int, 3)
        XCTAssertNil(handlers[0]["statusMessage"])
        XCTAssertEqual(handlers[0]["customField"] as? String, "keep")
        XCTAssertEqual(handlers[1] as NSDictionary, foreign as NSDictionary)
        XCTAssertEqual(root["permissions"] as? NSDictionary, ["deny": ["Bash(example)"]] as NSDictionary)
        XCTAssertEqual(root["statusLine"] as? NSDictionary, ["command": "my-statusline", "refreshInterval": 17] as NSDictionary)
        XCTAssertEqual(try HookSettingsEditor.migratePassive(data), data)
        XCTAssertTrue(HookSettingsEditor.hasManagedHooks(in: data))
        XCTAssertFalse(HookSettingsEditor.isInstalled(in: data))
        XCTAssertFalse(HookSettingsEditor.installedProactiveRecall(in: data))
    }

    func testClaudeNoHooksAndInvalidStructuresNeverBecomeAnInstall() throws {
        let untouched = Data("{ \"hooks\" : {\"Other\":42}, \"mine\":true }".utf8)
        XCTAssertEqual(try HookSettingsEditor.migratePassive(untouched), untouched)
        for malformed in ["", "broken", "{\"hooks\":[]}", "{\"hooks\":{\"PermissionRequest\":[{\"hooks\":42}]}}"] {
            XCTAssertThrowsError(try HookSettingsEditor.migratePassive(Data(malformed.utf8)))
        }
    }

    func testCodexWithoutManagedHooksIsByteUnchanged() throws {
        for source in ["{ \"mine\":true }", "{ \"hooks\":{ \"Stop\":[{\"hooks\":[{\"command\":\"foreign\"}]}]} }"] {
            let original = Data(source.utf8)
            XCTAssertEqual(try CodexHookSettingsEditor.migratePassive(original), original)
        }
    }

    func testClaudeNumericAsyncIsNormalizedWithoutLosingOtherFields() throws {
        let original = try encode(["hooks": ["PermissionRequest": [["hooks": [[
            "command": claudeCommand, "async": 1, "timeout": 3, "custom": true
        ]]]]]])
        let data = try HookSettingsEditor.migratePassive(original)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"async\" : true"))
        XCTAssertNotEqual(original, data)
    }

    func testCustomTimeoutAndMessageSurvivePassiveContractChangeForBothProviders() throws {
        for command in [claudeCommand, CodexHookSettingsEditor.command] {
            let original = try encode(["hooks": ["PermissionRequest": [["hooks": [[
                "command": command, "async": false, "timeout": 999, "statusMessage": "Mon message", "enabled": false
            ]]]]]])
            let data = try command == claudeCommand ? HookSettingsEditor.migratePassive(original) : CodexHookSettingsEditor.migratePassive(original)
            let expected = try encode(["hooks": ["PermissionRequest": [["hooks": [[
                "command": command, "async": true, "timeout": 999, "statusMessage": "Mon message", "enabled": false
            ]]]]]])
            XCTAssertTrue(CodexHookSettingsEditor.sameJSON(data, expected), "customization-lost")
        }
    }

    func testCodexPassiveWaitSurvivesUncorrelatedToolsUntilNativeProgress() throws {
        func event(_ kind: String, tool: String? = nil, turn: String = "t1") throws -> CodexHookEvent {
            var payload: [String: Any] = ["hook_event_name": kind, "session_id": "passive", "turn_id": turn]
            payload["tool_name"] = tool
            return try XCTUnwrap(CodexHookEvent(envelope: ["provider": "codex", "payload": payload]))
        }
        var sessions = CodexSessions()
        sessions.applyEvent(try event("UserPromptSubmit"))
        sessions.applyEvent(try event("PermissionRequest", tool: "Bash"))
        for kind in ["PreToolUse", "PostToolUse", "PreCompact", "PostCompact"] {
            for tool: String? in [nil, "Read", "Bash"] {
                sessions.applyEvent(try event(kind, tool: tool))
                XCTAssertEqual(sessions.sessions().first?.status, .awaitingPermission(tool: "Bash"), "codex-passive-wait")
            }
        }
        sessions.applyEvent(try event("Stop"))
        XCTAssertEqual(sessions.sessions().first?.status, .awaitingInput)
        sessions.applyEvent(try event("PermissionRequest", tool: "Bash"))
        XCTAssertEqual(sessions.sessions().first?.status, .awaitingInput, "late-permission-reopened-closed-turn")
        sessions.applyEvent(try event("UserPromptSubmit", turn: "t2"))
        XCTAssertEqual(sessions.sessions().first?.status, .working(tool: nil))
    }
}
