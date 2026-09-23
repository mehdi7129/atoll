import XCTest
@testable import AtollCore

final class AnalysisUsageTests: XCTestCase {
    private func parse(_ text: String, _ provider: AgentProvider = .codex) -> AnalysisUsage {
        AnalysisUsage.parse(stdout: Data(text.utf8), provider: provider)
    }

    /// Forme publiée dans la documentation du mode non interactif OpenAI,
    /// consultée le 22 septembre 2026 ; --json vérifié avec le CLI 0.155.1.
    /// https://developers.openai.com/codex/noninteractive
    func testCodexNativeSnapshotPreservesCacheAndReasoningWithoutAddingThem() {
        let usage = parse(#"{"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"output_tokens":122,"reasoning_output_tokens":0}}"#)
        XCTAssertEqual(usage.availability, .reported)
        XCTAssertEqual(usage.source, .codexTurnCompleted)
        XCTAssertEqual(usage.inputTokens, 24763)
        XCTAssertEqual(usage.cachedInputTokens, 24448)
        XCTAssertEqual(usage.outputTokens, 122)
        XCTAssertEqual(usage.reasoningOutputTokens, 0)
        XCTAssertNil(usage.cacheCreationInputTokens)
        XCTAssertNil(usage.limitation)
    }

    func testLatestSnapshotReplacesEarlierCountsAndIgnoresOtherTotals() {
        let usage = parse("""
        {"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":70,"output_tokens":10}}
        {"type":"item.completed","usage":{"input_tokens":999,"output_tokens":999}}
        {"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":888}}}}
        {"type":"turn.completed","usage":{"input_tokens":250,"cached_input_tokens":180,"output_tokens":30}}
        """)
        XCTAssertEqual(usage.inputTokens, 250)
        XCTAssertEqual(usage.outputTokens, 30)
        XCTAssertEqual(usage.cachedInputTokens, 180)
        XCTAssertEqual(usage.availability, .reported)
    }

    func testCodexFailureAndCancellationWithoutUsageStayUnknown() {
        for text in ["", #"{"type":"turn.failed","error":{"message":"interrupted"}}"#,
                     #"{"type":"error","message":"rate limit"}"#,
                     #"{"type":"turn.started"}"#] {
            XCTAssertEqual(parse(text), .unknown)
        }
    }

    func testNewIncompleteTurnDoesNotClaimPreviousUsageCoversTheWholeRun() {
        let first = #"{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":70,"output_tokens":10}}"#
        for event in ["turn.started", "turn.failed", "error"] {
            let usage = parse(first + "\n{\"type\":\"\(event)\"}")
            XCTAssertEqual(usage.inputTokens, 100)
            XCTAssertEqual(usage.availability, .partial)
            XCTAssertEqual(usage.limitation, .unfinishedTurn)
        }
    }

    func testClaudeEnvelopeKeepsNativeCountsDistinctFromModelAndCacheBreakdowns() {
        let usage = parse("""
        shell de login bavard
        {"type":"result","subtype":"success",
         "usage":{"input_tokens":30,"output_tokens":18,"cache_read_input_tokens":80,
                  "cache_creation_input_tokens":40,"cache_creation":{"ephemeral_5m_input_tokens":40}},
         "modelUsage":{"model":{"inputTokens":30,"outputTokens":18,"cacheReadInputTokens":80}},
         "structured_output":{"notes":[],"skills":[]}}
        """, .claude)
        XCTAssertEqual(usage.availability, .reported)
        XCTAssertEqual(usage.source, .claudeResult)
        XCTAssertEqual(usage.inputTokens, 30)
        XCTAssertEqual(usage.outputTokens, 18)
        XCTAssertEqual(usage.cachedInputTokens, 80)
        XCTAssertEqual(usage.cacheCreationInputTokens, 40)
        XCTAssertNil(usage.reasoningOutputTokens)
    }

    func testClaudeErrorEnvelopeStillReportsSpentTokens() {
        let usage = parse(#"{"type":"result","subtype":"error_max_budget_usd","is_error":true,"usage":{"input_tokens":10,"output_tokens":4,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}"#, .claude)
        XCTAssertEqual(usage.availability, .reported)
        XCTAssertEqual(usage.inputTokens, 10)
        XCTAssertEqual(usage.outputTokens, 4)
    }

    func testClaudeJSONLUsesOnlyTheLatestResultNotMessagesOrRepeatedResults() {
        let usage = parse("""
        {"type":"assistant","message":{"usage":{"input_tokens":999,"output_tokens":999}}}
        {"type":"result","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}
        {"type":"result","usage":{"input_tokens":20,"output_tokens":8,"cache_read_input_tokens":2,"cache_creation_input_tokens":1}}
        """, .claude)
        XCTAssertEqual(usage.inputTokens, 20)
        XCTAssertEqual(usage.outputTokens, 8)
        XCTAssertEqual(usage.availability, .reported)
    }

    func testAbsentCountersAreNotZeroAndOldEnvelopeIsAccepted() {
        let usage = parse(#"{"structured_output":{"notes":[]},"usage":{"input_tokens":20,"output_tokens":8}}"#, .claude)
        XCTAssertEqual(usage.inputTokens, 20)
        XCTAssertEqual(usage.availability, .partial)
        XCTAssertEqual(usage.limitation, .missingFields)
        XCTAssertNil(usage.cachedInputTokens)
        XCTAssertNil(usage.cacheCreationInputTokens)
        XCTAssertEqual(parse(#"{"structured_output":{},"total_cost_usd":0.12}"#, .claude), .unknown)
    }

    func testMeasuredZerosRemainDifferentFromUnknown() {
        let usage = parse(#"{"type":"turn.completed","usage":{"input_tokens":0,"cached_input_tokens":0,"output_tokens":0}}"#)
        XCTAssertEqual(usage.availability, .reported)
        XCTAssertEqual(usage.inputTokens, 0)
        XCTAssertEqual(usage.outputTokens, 0)
        XCTAssertEqual(usage.cachedInputTokens, 0)
        XCTAssertNotEqual(usage, .unknown)
    }

    func testInvalidCountersNeverCoerceToUsableMeasurements() {
        for value in ["true", "false", "null", "-1", "1.2", "\"12\"", "9223372036854775808", "1e200"] {
            let usage = parse("{\"type\":\"turn.completed\",\"usage\":{\"input_tokens\":\(value),\"output_tokens\":2}}")
            XCTAssertNil(usage.inputTokens, value)
            XCTAssertEqual(usage.outputTokens, 2)
            XCTAssertEqual(usage.availability, .partial)
        }
    }

    func testNoUsageIsInferredFromUnexpectedVersionOrNestedModelText() {
        for text in ["not JSON", #"{"type":"turn.completed","usage":{"total_tokens":1234}}"#,
                     #"{"input_tokens":1234,"output_tokens":7}"#,
                     #"{"type":"item.completed","item":{"text":"private","usage":{"input_tokens":1234}}}"#,
                     #"{"type":"turn.completed","usage":null}"#] {
            XCTAssertEqual(parse(text), .unknown)
        }
    }

    func testTruncatedOutputCannotClaimCompleteUsageEvenWithAnEarlierSnapshot() {
        let text = #"{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":3,"output_tokens":2}}"#
        let usage = AnalysisUsage.parse(stdout: Data(text.utf8), provider: .codex, cap: text.utf8.count - 1)
        XCTAssertEqual(usage.availability, .unknown)
        XCTAssertEqual(usage.limitation, .truncatedOutput)
        XCTAssertNil(usage.inputTokens)
    }

    func testInterruptedJSONAfterSnapshotOnlyRetainsPartialUsage() {
        let text = #"{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":3,"output_tokens":2}}"#
        let usage = parse(text + "\n  {\"type\":\"turn.completed\",\"usage\":")
        XCTAssertEqual(usage.availability, .partial)
        XCTAssertEqual(usage.limitation, .truncatedOutput)
        XCTAssertEqual(usage.inputTokens, 10)
    }

    func testMetricsSerializationContainsNoPromptTranscriptSessionOrCost() throws {
        let usage = parse(#"{"type":"result","session_id":"PRIVATE_SESSION","result":"PRIVATE_TEXT","total_cost_usd":42,"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}"#, .claude)
        let data = try JSONEncoder().encode(usage)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("PRIVATE"))
        XCTAssertFalse(json.contains("cost"))
        XCTAssertEqual(try JSONDecoder().decode(AnalysisUsage.self, from: data), usage)
    }

    func testCodexPlanEnablesJSONLEventsWithoutRemovingStructuredFileOutput() {
        let arguments = CodexExecPlan.arguments(schemaPath: "/tmp/schema", outputPath: "/tmp/report", instructionsPath: "/tmp/instructions", workingDirectory: nil)
        XCTAssertTrue(arguments.contains("--json"))
        XCTAssertTrue(arguments.contains("--output-last-message"))
        XCTAssertTrue(arguments.contains("/tmp/report"))
    }
}
