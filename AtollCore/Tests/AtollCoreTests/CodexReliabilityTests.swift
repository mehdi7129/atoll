import XCTest
@testable import AtollCore

final class CodexReliabilityTests: XCTestCase {
    private func event(_ kind: String, turn: String? = nil) -> CodexHookEvent {
        var payload: [String: Any] = ["hook_event_name": kind, "session_id": "session",
                                      "cwd": "/project", "tool_name": "Bash"]
        payload["turn_id"] = turn
        return CodexHookEvent(envelope: ["provider": "codex", "payload": payload])!
    }

    func testSessionEndKeepsAnonymousActivityUnknownWithoutResurrectingState() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1"))
        XCTAssertNotNil(sessions.apply(event("SessionEnd")))
        for kind in ["SessionStart", "PreToolUse", "PostToolUse", "PermissionRequest", "UserPromptSubmit", "Stop"] {
            XCTAssertEqual(sessions.applyEvent(event(kind, turn: "t1")).turn, .unknown, kind)
            XCTAssertTrue(sessions.sessions().isEmpty, kind)
        }
        XCTAssertNil(sessions.apply(event("SessionEnd")), "une seule fin doit déclencher le bilan")
    }

    func testAnonymousEventDatedBeforeClosureIsCertainlyStale() {
        var sessions = CodexSessions()
        let now = Date(timeIntervalSince1970: 1_000)
        sessions.apply(event("SessionStart"), now: now)
        sessions.apply(event("SessionEnd"), now: now)
        for stamp in [999.0, 1001.0] {
            let anonymous = CodexHookEvent(envelope: ["provider": "codex", "payload": [
                "hook_event_name": "PermissionRequest", "session_id": "session"],
                "enrich": ["observedAt": stamp]])!
            XCTAssertEqual(sessions.applyEvent(anonymous, now: now).turn, stamp < 1000 ? .closed : .unknown)
        }
    }

    func testAnonymousClosureExpiresWithoutResurrectingASessionByItself() {
        var sessions = CodexSessions()
        let now = Date(timeIntervalSince1970: 1_000)
        sessions.apply(event("SessionStart"), now: now)
        sessions.apply(event("SessionEnd"), now: now)
        sessions.prune(now: now.addingTimeInterval(3_601))
        XCTAssertFalse(sessions.contains("codex:session"))
        XCTAssertTrue(sessions.applyEvent(event("SessionStart"), now: now.addingTimeInterval(3_602)).accepted)
    }

    func testLateScanCannotResurrectAnEndedSession() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1"))
        sessions.apply(event("SessionEnd"))
        sessions.adopt([.init(sessionID: "codex:session", cwd: "/project",
                              transcriptPath: "/old/rollout.jsonl", startedAt: Date())])
        XCTAssertTrue(sessions.sessions().isEmpty)
    }

    func testAnonymousStopRemembersTheKnownTurn() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1"))
        sessions.apply(event("Stop"))
        XCTAssertTrue(sessions.applyEvent(event("UserPromptSubmit", turn: "t1")).cardIsStale)
        XCTAssertEqual(sessions.sessions().first?.status, .awaitingInput)
        XCTAssertTrue(sessions.applyEvent(event("UserPromptSubmit", turn: "t2")).accepted)
    }

    func testRepeatedPromptOfAnOpenTurnIsNotCountedTwice() throws {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1"))
        sessions.apply(event("UserPromptSubmit", turn: "t1"))
        XCTAssertEqual(try XCTUnwrap(sessions.apply(event("SessionEnd"))).userPromptCount, 1)
    }

    func testCodexTextDoesNotInventToolSuccessOrFailure() throws {
        for output in ["let error = nil", #"{"exit_code":1,"output":""}"#, "done"] {
            let payload: [String: Any] = ["type": "function_call_output", "call_id": "c", "output": output]
            let data = try JSONSerialization.data(withJSONObject: ["type": "response_item", "payload": payload])
            let line = try XCTUnwrap(CodexTranscriptParser.parse(data))
            let digest = TranscriptDigest.make(lines: [line])
            XCTAssertTrue(digest.text.contains("outcome=unknown"), digest.text)
            XCTAssertFalse(digest.text.contains("outcome=failure"))
            XCTAssertFalse(digest.text.contains("outcome=success"))
        }
    }

    private func identified(_ kind: String, pid: Int32 = 42, start: Double = 100,
                             capturedAt: Double = 200, turn: String? = nil) -> CodexHookEvent {
        var payload: [String: Any] = ["hook_event_name": kind, "session_id": "session",
                                      "cwd": "/project", "transcript_path": "/old/date/rollout.jsonl"]
        payload["turn_id"] = turn
        return CodexHookEvent(envelope: ["provider": "codex", "payload": payload, "enrich": [
            "sessionPid": pid, "sessionStartTime": start, "observedAt": capturedAt]])!
    }

    func testResumeUsesANewIncarnationAndRejectsOldSessionEnd() {
        var sessions = CodexSessions()
        sessions.apply(identified("SessionStart"))
        sessions.apply(identified("SessionEnd"))
        XCTAssertTrue(sessions.applyEvent(identified("SessionStart", start: 300, capturedAt: 301)).accepted)
        XCTAssertTrue(sessions.applyEvent(identified("SessionEnd")).cardIsStale)
        XCTAssertEqual(sessions.process(for: "codex:session"), ProcessIdentity(pid: 42, startedAt: 300))
        XCTAssertEqual(sessions.sessions().count, 1)
        XCTAssertFalse(sessions.applyEvent(event("SessionEnd")).accepted)
        XCTAssertEqual(sessions.sessions().count, 1, "un ancien helper sans parent ne peut fermer la reprise")
        XCTAssertNotNil(sessions.apply(identified("SessionEnd", start: 300)))
        XCTAssertNil(sessions.apply(identified("SessionEnd", start: 300)))
    }

    func testPermissionOfANewIncarnationBeforeItsStartRemainsUnknown() {
        for ended in [true, false] {
            var sessions = CodexSessions()
            sessions.apply(identified("SessionStart"))
            if ended { sessions.apply(identified("SessionEnd")) }
            let early = sessions.applyEvent(identified("PermissionRequest", start: 300, capturedAt: 301))
            XCTAssertFalse(early.accepted)
            XCTAssertFalse(early.cardIsStale)
            sessions.apply(identified("SessionStart", start: 300, capturedAt: 301))
            XCTAssertTrue(sessions.applyEvent(identified("PermissionRequest", start: 300, capturedAt: 302)).accepted)
            XCTAssertTrue(sessions.applyEvent(identified("PermissionRequest")).cardIsStale)
        }
    }

    func testAnonymousStopCapturedBeforeNewPromptClosesNothing() {
        var sessions = CodexSessions()
        sessions.apply(identified("UserPromptSubmit", capturedAt: 201, turn: "new"))
        let late = sessions.applyEvent(identified("Stop", capturedAt: 200))
        XCTAssertFalse(late.accepted)
        XCTAssertEqual(late.closure, .none)
        XCTAssertEqual(sessions.sessions().first?.status, .working(tool: nil))
    }

    func testProcessDeathAndRecycledPIDEndExactlyOnce() {
        for alive in [true, false] {
            var sessions = CodexSessions()
            sessions.apply(identified("UserPromptSubmit", turn: "t"))
            let ended = sessions.reconcile { _ in .init(isAlive: alive, startTime: 300) }
            XCTAssertEqual(ended.map(\.sessionID), ["codex:session"])
            XCTAssertTrue(sessions.reconcile { _ in .init(isAlive: false, startTime: nil) }.isEmpty)
            XCTAssertTrue(sessions.applyEvent(identified("PreToolUse", turn: "t")).cardIsStale)
        }
    }

    func testAnUnavailableProcessProbeDoesNotEndALiveSession() {
        var sessions = CodexSessions()
        sessions.apply(identified("SessionStart"))
        XCTAssertTrue(sessions.reconcile { _ in .init(isAlive: true, startTime: nil) }.isEmpty)
        XCTAssertTrue(sessions.contains("codex:session"))
    }

    func testAFirstPermissionDoesNotConsumeThePromptCount() throws {
        var sessions = CodexSessions()
        sessions.apply(event("PermissionRequest", turn: "t1"))
        sessions.apply(event("UserPromptSubmit", turn: "t1"))
        XCTAssertEqual(try XCTUnwrap(sessions.apply(event("SessionEnd"))).userPromptCount, 1)
    }

    func testOldRolloutRestoredOnlyForSameLiveProcessAndHome() throws {
        let home = URL(fileURLWithPath: "/codex-home")
        let record = try XCTUnwrap(CodexSessionRecord(event: identified("SessionStart"), home: home))
        XCTAssertNotNil(record.discovered(home: home) { _ in .init(isAlive: true, startTime: 100) })
        XCTAssertNil(record.discovered(home: home) { _ in .init(isAlive: true, startTime: 101) })
        XCTAssertNil(record.discovered(home: home) { _ in .init(isAlive: false, startTime: nil) })
        XCTAssertNil(record.discovered(home: URL(fileURLWithPath: "/other")) { _ in .init(isAlive: true, startTime: 100) })
        var sessions = CodexSessions()
        sessions.adopt([try XCTUnwrap(record.discovered(home: home) { _ in .init(isAlive: true, startTime: 100) })])
        XCTAssertEqual(sessions.process(for: "codex:session"), record.process)
    }

    func testInvalidProcessIdentityCannotAuthorizeASignal() throws {
        XCTAssertNil(ProcessIdentity(pid: 0, startedAt: 100))
        XCTAssertThrowsError(try JSONDecoder().decode(ProcessIdentity.self, from: Data(#"{"pid":-1,"startedAt":100}"#.utf8)))
        let identity = try XCTUnwrap(ProcessIdentity(pid: 42, startedAt: 100))
        XCTAssertFalse(identity.matches(pid: 42, startedAt: nil))
        XCTAssertFalse(identity.matches(pid: 42, startedAt: 100.001))
        XCTAssertTrue(identity.matches(pid: 42, startedAt: 100))
    }

    func testOnlyInteractiveCodexCommandsCanBeSessionAncestors() {
        for args in [["codex"], ["codex", "resume", "s"], ["codex", "--model", "gpt-6", "prompt"]] {
            XCTAssertTrue(CodexProcessKind.isInteractive(arguments: args))
        }
        for args in [[], ["codex", "exec", "prompt"], ["codex", "-m", "gpt-6", "app-server"],
                     ["codex", "agents"], ["codex", "--unknown-option"]] {
            XCTAssertFalse(CodexProcessKind.isInteractive(arguments: args))
        }
    }
}
