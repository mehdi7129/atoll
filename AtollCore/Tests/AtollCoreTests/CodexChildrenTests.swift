import XCTest
@testable import AtollCore

final class CodexChildrenTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func event(_ kind: String, child: String? = nil, turn: String = "t1", tool: String? = nil) throws -> CodexHookEvent {
        var payload: [String: Any] = ["session_id": "parent", "hook_event_name": kind, "turn_id": child == nil ? turn : "child-" + turn,
            "cwd": child == nil ? "/parent" : "/child", "model": child == nil ? "parent-model" : "child-model",
            "transcript_path": child == nil ? "/parent.jsonl" : "/child.jsonl"]
        payload["agent_id"] = child
        payload["tool_name"] = tool
        payload["tool_input"] = ["command": "fixture"]
        return try XCTUnwrap(CodexHookEvent(envelope: ["provider": "codex", "payload": payload,
            "enrich": ["sessionPid": Int32(4242), "sessionStartTime": 1_799_999_900.0] as [String: Any]]))
    }

    func testChildrenNeverOverwriteOrEndParentAndAreDeduplicated() throws {
        var sessions = CodexSessions()
        sessions.apply(try event("UserPromptSubmit"), now: now)
        sessions.apply(try event("PreToolUse", tool: "Read"), now: now)
        let parent = try XCTUnwrap(sessions.sessions(now: now).first)
        for kind in ["SubagentStart", "SubagentStart", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop"] {
            sessions.apply(try event(kind, child: "child", tool: "Bash"), now: now)
            let current = try XCTUnwrap(sessions.sessions(now: now).first)
            XCTAssertEqual(current.status, parent.status)
            XCTAssertEqual(current.model, parent.model)
            XCTAssertEqual(current.cwd, "/parent")
            XCTAssertEqual(current.subagentCount, 1)
            XCTAssertEqual(sessions.transcriptPath(for: "codex:parent"), "/parent.jsonl")
        }
        let ended = sessions.applyEvent(try event("SessionEnd", child: "child"), now: now)
        XCTAssertNil(ended.ended)
        XCTAssertEqual(ended.childClosed, "child")
        XCTAssertEqual(ended.childClosedTurn, "child-t1")
        XCTAssertEqual(sessions.sessions(now: now).first?.subagentCount, 0)
        XCTAssertTrue(sessions.applyEvent(try event("SubagentStart", child: "child"), now: now).cardIsStale)
        XCTAssertNil(CodexSessionRecord(event: try event("PermissionRequest", child: "child"), home: URL(fileURLWithPath: "/fixture")))
    }

    func testChildStopAfterParentTurnClosesOnlyChildAndLateStartCannotReviveIt() throws {
        var sessions = CodexSessions()
        sessions.apply(try event("UserPromptSubmit"), now: now)
        sessions.apply(try event("SubagentStart", child: "a"), now: now)
        sessions.apply(try event("SubagentStart", child: "b"), now: now)
        sessions.apply(try event("Stop"), now: now)
        let result = sessions.applyEvent(try event("SubagentStop", child: "a"), now: now)
        XCTAssertEqual(result.closure, .none)
        XCTAssertEqual(result.childClosed, "a")
        XCTAssertEqual(sessions.sessions(now: now).first?.subagentCount, 1)
        sessions.apply(try event("UserPromptSubmit", turn: "t2"), now: now)
        XCTAssertEqual(sessions.applyEvent(try event("PermissionRequest", child: "a", turn: "t2"), now: now).turn, .unknown)
        XCTAssertEqual(sessions.sessions(now: now).first?.subagentCount, 1)
    }

    func testUnattributedChildDoesNotCreateParentAndCannotReopenEndedParent() throws {
        var sessions = CodexSessions()
        XCTAssertEqual(sessions.applyEvent(try event("SubagentStart", child: "a"), now: now).turn, .unknown)
        XCTAssertTrue(sessions.sessions(now: now).isEmpty)
        sessions.apply(try event("SessionStart"), now: now)
        sessions.apply(try event("SessionEnd"), now: now)
        XCTAssertTrue(sessions.applyEvent(try event("SessionStart", child: "a"), now: now).cardIsStale)
        XCTAssertTrue(sessions.sessions(now: now).isEmpty)
    }

    func testNativeCapturedChildUsesIndependentTurnAndParentTranscript() throws {
        let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/audit-support/2026-09-10")
        func capture(_ name: String) throws -> CodexHookEvent {
            var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureRoot.appendingPathComponent(name))) as? [String: Any])
            let enrich = payload.removeValue(forKey: "_atoll_test_enrich") ?? [:]
            return try XCTUnwrap(CodexHookEvent(envelope: ["provider": "codex", "payload": payload, "enrich": enrich]))
        }
        var sessions = CodexSessions()
        let parent = try capture("event-10-UserPromptSubmit.json")
        sessions.apply(parent, now: now)
        let child = try capture("event-13-SubagentStart.json")
        XCTAssertNotEqual(child.turnID, parent.turnID)
        XCTAssertTrue(sessions.applyEvent(child, now: now).accepted)
        XCTAssertEqual(sessions.sessions(now: now).first?.subagentCount, 1)
        XCTAssertTrue(sessions.applyEvent(try capture("event-16-PermissionRequest.json"), now: now).accepted)
        let stopped = sessions.applyEvent(try capture("event-19-SubagentStop.json"), now: now)
        XCTAssertEqual(stopped.childClosed, child.agentID)
        XCTAssertEqual(stopped.childClosedTurn, child.turnID)
        XCTAssertEqual(sessions.sessions(now: now).first?.subagentCount, 0)
        XCTAssertEqual(sessions.transcriptPath(for: parent.sessionID), parent.transcriptPath)
        XCTAssertTrue(sessions.sessions(now: now).first?.isActive == true)
    }

    func testAnonymousChildStopHasNoAuthorityAndExplicitNewTurnCanReopenChild() throws {
        var sessions = CodexSessions()
        sessions.apply(try event("UserPromptSubmit"), now: now)
        sessions.apply(try event("SubagentStart", child: "a"), now: now)
        let anonymous = try XCTUnwrap(CodexHookEvent(envelope: ["provider": "codex", "payload": [
            "hook_event_name": "SubagentStop", "session_id": "parent", "agent_id": "a", "turn_id": "child-t1"]]))
        XCTAssertEqual(sessions.applyEvent(anonymous, now: now).turn, .unknown)
        XCTAssertEqual(sessions.sessions(now: now).first?.subagentCount, 1)
        sessions.apply(try event("SubagentStop", child: "a"), now: now)
        let resumed = try XCTUnwrap(CodexHookEvent(envelope: ["provider": "codex", "payload": [
            "hook_event_name": "SubagentStart", "session_id": "parent", "agent_id": "a", "turn_id": "child-t2"],
            "enrich": ["sessionPid": Int32(4242), "sessionStartTime": 1_799_999_900.0, "observedAt": now.timeIntervalSince1970 + 1] as [String: Any]]))
        XCTAssertTrue(sessions.applyEvent(resumed, now: now.addingTimeInterval(1)).accepted)
        XCTAssertEqual(sessions.sessions(now: now).first?.subagentCount, 1)
        XCTAssertTrue(sessions.applyEvent(try event("SubagentStop", child: "a"), now: now).cardIsStale)
        XCTAssertEqual(sessions.sessions(now: now).first?.subagentCount, 1)
    }
}
