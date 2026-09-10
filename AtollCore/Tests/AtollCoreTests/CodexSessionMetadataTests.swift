import XCTest
@testable import AtollCore

final class CodexSessionMetadataTests: XCTestCase {
    private func read(_ suffix: [[String: Any]], id: String = "parent") throws -> CodexSessionMetadata? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let lines: [[String: Any]] = [["type": "session_meta", "payload": ["id": "parent", "git": ["branch": "main"]]]] + suffix
        var data = Data()
        for line in lines { data.append(try JSONSerialization.data(withJSONObject: line)); data.append(10) }
        try data.write(to: url)
        return CodexSessionMetadata.read(at: url, sessionID: id)
    }
    private func token(_ used: Double, window: Double) -> [String: Any] {
        ["type": "event_msg", "timestamp": "2026-09-10T00:00:00.000Z", "payload": [
            "type": "token_count", "info": ["last_token_usage": ["total_tokens": used],
                "total_token_usage": ["total_tokens": 1_000_000], "model_context_window": window]]]
    }

    func testNativeMetadataIgnoresMachineInstructionsAndCumulativeTokens() throws {
        func user(_ text: String) -> [String: Any] { ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]]] }
        let value = try XCTUnwrap(read([user("<environment_context>\nMachine\n</environment_context>"),
            user("Vérifie ce changement"), ["type": "turn_context", "payload": ["model": "fixture-model"]], token(25, window: 100)]))
        XCTAssertEqual(value.firstHumanPrompt, "Vérifie ce changement")
        XCTAssertEqual(value.branchAtStart, "main")
        XCTAssertEqual(value.model, "fixture-model")
        XCTAssertEqual(value.contextFraction, 0.25)
        XCTAssertNotNil(value.contextAt)
        XCTAssertNil(try read([token(25, window: 100)], id: "child"))
    }

    func testUnknownOrCompactedContextDoesNotKeepAnOldMeasurement() throws {
        XCTAssertNil(try read([token(25, window: 100), ["type": "compacted", "payload": ["message": ""]]])?.contextFraction)
        XCTAssertNil(try read([token(25, window: 100), token(110, window: 100)])?.contextFraction)
        XCTAssertNil(try read([token(25, window: 100), ["type": "event_msg", "payload": ["type": "token_count", "info": NSNull()]]])?.contextFraction)
        XCTAssertEqual(try read([token(0, window: 100)])?.contextFraction, 0)
    }

    func testMetadataCannotCreateOrReviveSessionAndCannotAffectNewProcess() throws {
        var sessions = CodexSessions()
        let metadata = try XCTUnwrap(read([token(25, window: 100)]))
        let old = try XCTUnwrap(ProcessIdentity(pid: 4242, startedAt: 100))
        sessions.enrich(metadata, sessionID: "codex:parent", process: old)
        XCTAssertTrue(sessions.sessions().isEmpty)
        func hook(_ kind: String, start: Double) throws -> CodexHookEvent {
            try XCTUnwrap(CodexHookEvent(envelope: ["provider": "codex", "payload": ["session_id": "parent", "hook_event_name": kind],
                "enrich": ["sessionPid": Int32(4242), "sessionStartTime": start] as [String: Any]]))
        }
        sessions.apply(try hook("SessionStart", start: 100))
        sessions.apply(try hook("SessionStart", start: 200))
        sessions.enrich(metadata, sessionID: "codex:parent", process: old)
        XCTAssertNil(sessions.sessions().first?.contextUsedFraction)
        sessions.apply(try hook("SessionEnd", start: 200))
        sessions.enrich(metadata, sessionID: "codex:parent", process: try XCTUnwrap(ProcessIdentity(pid: 4242, startedAt: 200)))
        XCTAssertTrue(sessions.sessions().isEmpty)
    }

    func testJSONBooleansAreNotTokenMeasurements() throws {
        for (used, window): (Any, Any) in [(true, 100), (1, true), (false, 100), ("1", 100)] {
            let malformed: [String: Any] = ["type": "event_msg", "payload": ["type": "token_count", "info": [
                "last_token_usage": ["total_tokens": used], "model_context_window": window]]]
            let value = try XCTUnwrap(read([token(25, window: 100), malformed]))
            XCTAssertNil(value.contextFraction)
            XCTAssertNil(value.contextAt)
        }
    }
}
