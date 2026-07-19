import XCTest
@testable import AtollCore

final class StreamEventTests: XCTestCase {

    func testInitEvent() {
        let line = #"{"type":"system","subtype":"init","session_id":"abc","model":"claude-fable-5","tools":[]}"#
        XCTAssertEqual(StreamEvent(line: line), .initialized(sessionID: "abc", model: "claude-fable-5"))
    }

    func testTextDelta() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Bon"}},"session_id":"x"}"#
        XCTAssertEqual(StreamEvent(line: line), .textDelta("Bon"))
    }

    func testThinkingDelta() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hmm"}}}"#
        XCTAssertEqual(StreamEvent(line: line), .thinkingDelta("hmm"))
    }

    func testAssistantFullText() {
        let line = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Bonjour"},{"type":"tool_use","name":"Bash"}]}}"#
        XCTAssertEqual(StreamEvent(line: line), .assistantText("Bonjour"))
    }

    func testResultSuccess() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"result":"Terminé","total_cost_usd":0.02,"session_id":"x"}"#
        XCTAssertEqual(StreamEvent(line: line), .result(text: "Terminé", costUSD: 0.02, isError: false))
    }

    func testResultError() {
        let line = #"{"type":"result","subtype":"error_max_turns","is_error":true,"session_id":"x"}"#
        XCTAssertEqual(StreamEvent(line: line), .result(text: nil, costUSD: nil, isError: true))
    }

    func testRateLimit() {
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning"}}"#
        XCTAssertEqual(StreamEvent(line: line), .rateLimit(status: "allowed_warning"))
    }

    func testOtherAndGarbage() {
        XCTAssertEqual(StreamEvent(line: #"{"type":"system","subtype":"status"}"#), .other(type: "system/status"))
        XCTAssertNil(StreamEvent(line: "pas du json"))
        XCTAssertNil(StreamEvent(line: #"{"no_type":1}"#))
    }

    // MARK: - Protocole d'entrée

    func testUserMessageIsNDJSON() throws {
        let data = ChatProtocol.userMessage("salut")
        XCTAssertEqual(data.last, 0x0A, "doit finir par un saut de ligne")
        let object = try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "user")
        let message = object?["message"] as? [String: Any]
        XCTAssertEqual(message?["content"] as? String, "salut")
        XCTAssertEqual(message?["role"] as? String, "user")
    }

    func testArgumentsNewVsResume() {
        let new = ChatProtocol.arguments(sessionID: "s-1", resume: nil)
        XCTAssertTrue(new.contains("--session-id"))
        XCTAssertTrue(new.contains("s-1"))
        XCTAssertTrue(new.contains("--input-format"))
        XCTAssertFalse(new.contains("--resume"))

        let resumed = ChatProtocol.arguments(sessionID: "s-1", resume: "old-session")
        XCTAssertTrue(resumed.contains("--resume"))
        XCTAssertTrue(resumed.contains("old-session"))
        XCTAssertFalse(resumed.contains("--session-id"))
    }
}
