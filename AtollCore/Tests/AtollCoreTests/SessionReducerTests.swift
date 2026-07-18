import XCTest
@testable import AtollCore

final class SessionReducerTests: XCTestCase {

    private func event(
        _ kind: ParsedHookEvent.Kind,
        tool: String? = nil,
        toolInput: [String: Any]? = nil,
        notificationType: String? = nil,
        reason: String? = nil
    ) -> ParsedHookEvent {
        var payload: [String: Any] = [
            "hook_event_name": kind.rawValue,
            "session_id": "s-1",
            "transcript_path": "/tmp/t.jsonl",
            "cwd": "/Users/x/proj",
        ]
        if let tool { payload["tool_name"] = tool }
        if let toolInput { payload["tool_input"] = toolInput }
        if let notificationType { payload["notification_type"] = notificationType }
        if let reason { payload["reason"] = reason }
        return ParsedHookEvent(envelope: ["v": 1, "payload": payload])!
    }

    func testHappyPathLifecycle() {
        var phase = SessionPhase.starting
        phase = SessionReducer.reduce(phase, event(.sessionStart))
        XCTAssertEqual(phase, .waitingInput)
        phase = SessionReducer.reduce(phase, event(.userPromptSubmit))
        XCTAssertEqual(phase, .busy)
        phase = SessionReducer.reduce(phase, event(.preToolUse, tool: "Bash", toolInput: ["command": "ls"]))
        XCTAssertEqual(phase, .toolRunning(tool: "Bash(ls)"))
        phase = SessionReducer.reduce(phase, event(.postToolUse, tool: "Bash"))
        XCTAssertEqual(phase, .busy)
        phase = SessionReducer.reduce(phase, event(.stop))
        XCTAssertEqual(phase, .waitingInput)
        phase = SessionReducer.reduce(phase, event(.sessionEnd, reason: "other"))
        XCTAssertEqual(phase, .ended)
    }

    func testPermissionFlowViaNotification() {
        var phase = SessionPhase.busy
        phase = SessionReducer.reduce(phase, event(.notification, tool: "Edit", notificationType: "permission_prompt"))
        XCTAssertEqual(phase, .waitingPermission(tool: "Edit"))
        // L'utilisateur répond dans le terminal → l'outil s'exécute.
        phase = SessionReducer.reduce(phase, event(.postToolUse, tool: "Edit"))
        XCTAssertEqual(phase, .busy)
    }

    func testPermissionDeniedReturnsToBusy() {
        let phase = SessionReducer.reduce(.waitingPermission(tool: "Bash(rm x)"), event(.permissionDenied, tool: "Bash"))
        XCTAssertEqual(phase, .busy)
    }

    func testUnknownNotificationTypeKeepsPhase() {
        let phase = SessionReducer.reduce(.busy, event(.notification, notificationType: "auth_success"))
        XCTAssertEqual(phase, .busy)
    }

    func testCompactCycle() {
        var phase = SessionReducer.reduce(.busy, event(.preCompact))
        XCTAssertEqual(phase, .compacting)
        phase = SessionReducer.reduce(phase, event(.postCompact))
        XCTAssertEqual(phase, .busy)
    }

    func testEndedIsTerminal() {
        for kind in ParsedHookEvent.Kind.allCases {
            XCTAssertEqual(SessionReducer.reduce(.ended, event(kind)), .ended,
                           "\(kind) ne doit pas ressusciter une session terminée")
        }
    }

    func testSubagentEventsKeepBusy() {
        XCTAssertEqual(SessionReducer.reduce(.busy, event(.subagentStart)), .busy)
        XCTAssertEqual(SessionReducer.reduce(.toolRunning(tool: "Task"), event(.subagentStop)), .busy)
    }

    func testLateCompletionEventsDoNotStrandWaitingInput() {
        // Un PostToolUse tardif (outil asynchrone) après Stop ne doit pas
        // remettre un spinner sans porte de sortie.
        XCTAssertEqual(SessionReducer.reduce(.waitingInput, event(.postToolUse, tool: "Bash")), .waitingInput)
        XCTAssertEqual(SessionReducer.reduce(.waitingInput, event(.subagentStop)), .waitingInput)
        XCTAssertEqual(SessionReducer.reduce(.waitingInput, event(.permissionDenied)), .waitingInput)
    }

    func testUIStatusProjection() {
        XCTAssertEqual(SessionPhase.toolRunning(tool: "Bash(ls)").uiStatus, .working(tool: "Bash(ls)"))
        XCTAssertEqual(SessionPhase.waitingPermission(tool: nil).uiStatus, .awaitingPermission(tool: "permission"))
        XCTAssertEqual(SessionPhase.waitingInput.uiStatus, .awaitingInput)
        XCTAssertEqual(SessionPhase.ended.uiStatus, .done)
        XCTAssertFalse(SessionPhase.ended.isAlive)
    }
}
