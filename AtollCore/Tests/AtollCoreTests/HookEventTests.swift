import XCTest
@testable import AtollCore

final class HookEventTests: XCTestCase {

    func testDecodesFullEnvelope() throws {
        let json = """
        {
          "v": 1,
          "enrich": {
            "pid": 4242,
            "startTime": 1789000000.25,
            "tty": "ttys012",
            "terminalHint": "com.googlecode.iterm2",
            "entrypoint": "cli"
          },
          "payload": {
            "hook_event_name": "PreToolUse",
            "session_id": "abc-123",
            "transcript_path": "/Users/x/.claude/projects/-p/abc-123.jsonl",
            "cwd": "/Users/x/proj",
            "permission_mode": "default",
            "tool_name": "Bash",
            "tool_input": { "command": "git push origin main" }
          }
        }
        """
        let event = try XCTUnwrap(ParsedHookEvent(envelopeData: Data(json.utf8)))
        XCTAssertEqual(event.kind, .preToolUse)
        XCTAssertEqual(event.sessionID, "abc-123")
        XCTAssertEqual(event.toolSummary, "Bash(git push origin main)")
        XCTAssertEqual(event.claudePid, 4242)
        XCTAssertEqual(event.claudeStartTime, 1789000000.25)
        XCTAssertEqual(event.tty, "ttys012")
        XCTAssertEqual(event.terminalHint, "com.googlecode.iterm2")
    }

    func testRejectsUnknownEventAndMissingFields() {
        let unknownKind: [String: Any] = ["payload": ["hook_event_name": "FutureEvent", "session_id": "s"]]
        XCTAssertNil(ParsedHookEvent(envelope: unknownKind))

        let missingSession: [String: Any] = ["payload": ["hook_event_name": "Stop"]]
        XCTAssertNil(ParsedHookEvent(envelope: missingSession))

        XCTAssertNil(ParsedHookEvent(envelopeData: Data("pas du json".utf8)))
        XCTAssertNil(ParsedHookEvent(envelopeData: Data("[1,2,3]".utf8)))
    }

    func testMcpServerName() {
        XCTAssertEqual(ParsedHookEvent.mcpServerName("mcp__github__create_pr"), "github")
        XCTAssertEqual(ParsedHookEvent.mcpServerName("mcp__foo_bar__baz"), "foo_bar")
        XCTAssertEqual(ParsedHookEvent.mcpServerName("mcp__blender__execute_blender_code"), "blender")
        XCTAssertNil(ParsedHookEvent.mcpServerName("Bash"))
        XCTAssertNil(ParsedHookEvent.mcpServerName("mcp__"))
    }

    func testNotificationTypeFallbackToTypeField() throws {
        let payload: [String: Any] = [
            "hook_event_name": "Notification",
            "session_id": "s",
            "type": "permission_prompt",
        ]
        let event = try XCTUnwrap(ParsedHookEvent(envelope: ["payload": payload]))
        XCTAssertEqual(event.notificationType, "permission_prompt")
    }

    func testSummarize() {
        XCTAssertEqual(ParsedHookEvent.summarize(toolName: "Bash", input: ["command": "ls -la"]), "Bash(ls -la)")
        XCTAssertEqual(
            ParsedHookEvent.summarize(toolName: "Edit", input: ["file_path": "/a/b/NotchPanel.swift"]),
            "Edit(NotchPanel.swift)"
        )
        XCTAssertEqual(ParsedHookEvent.summarize(toolName: "Glob", input: ["pattern": "**/*.swift"]), "Glob(**/*.swift)")
        XCTAssertEqual(ParsedHookEvent.summarize(toolName: "Read", input: [:]), "Read")
        XCTAssertNil(ParsedHookEvent.summarize(toolName: nil, input: ["command": "x"]))

        let long = String(repeating: "a", count: 300)
        let summary = ParsedHookEvent.summarize(toolName: "Bash", input: ["command": long])!
        XCTAssertTrue(summary.hasSuffix("…)"))
        XCTAssertLessThan(summary.count, 110)

        let multiline = ParsedHookEvent.summarize(toolName: "Bash", input: ["command": "a\nb"])
        XCTAssertEqual(multiline, "Bash(a b)")
    }
}
