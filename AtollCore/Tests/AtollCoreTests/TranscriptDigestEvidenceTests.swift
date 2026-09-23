import XCTest
@testable import AtollCore

final class TranscriptDigestEvidenceTests: XCTestCase {
    private func line(_ role: TranscriptLine.Role, _ text: String,
                      outcome: TranscriptLine.ToolOutcome? = nil) -> TranscriptLine {
        .init(uuid: nil, sessionID: nil, timestamp: nil, cwd: nil, gitBranch: nil,
              fragments: [.init(role: role, text: text, toolOutcome: outcome)])
    }

    func testLongConclusionAndSummaryKeepTheirFinalCorrectionWithinSameCap() throws {
        for role in [TranscriptLine.Role.assistant, .summary] {
            let original = "HYPOTHÈSE INITIALE\n" + String(repeating: "détail provisoire ", count: 200)
                + "\nCORRECTION VÉRIFIÉE : employer la copie ditto pour codesign."
            let result = TranscriptDigest.make(lines: [line(role, original)])
            let entry = try XCTUnwrap(TranscriptDigest.entries(from: [line(role, original)]).first)
            XCTAssertEqual(entry.text.count, TranscriptDigest.entryCharacterCap)
            XCTAssertTrue(entry.text.hasPrefix("HYPOTHÈSE INITIALE"))
            XCTAssertTrue(entry.text.hasSuffix("CORRECTION VÉRIFIÉE : employer la copie ditto pour codesign."))
            XCTAssertTrue(entry.text.contains("\n[…]\n"))
            XCTAssertEqual(result.fragmentsShortened, 1)
            XCTAssertEqual(result.entriesDropped, 0)
            XCTAssertFalse(result.truncated, "le contrat historique ne vise que les entrées entières")
            XCTAssertTrue(result.text.contains("content=shortened"))
        }
    }

    func testLongToolCommandRemainsContiguousAndIsExplicitlyIncomplete() throws {
        let original = "Bash · tool --config '" + String(repeating: "parameter=value;", count: 200) + "' --verified-end"
        let lines = [line(.tool, original, outcome: .unknown)]
        let entry = try XCTUnwrap(TranscriptDigest.entries(from: lines).first)
        let expected = String(original.prefix(TranscriptDigest.entryCharacterCap - " […]".count)) + " […]"
        XCTAssertEqual(entry.text, expected, "aucun collage tête+fin d'une commande")
        XCTAssertFalse(entry.text.contains("--verified-end"))
        let result = TranscriptDigest.make(lines: lines)
        XCTAssertTrue(result.text.contains("command=incomplete"))
        XCTAssertTrue(result.text.contains("outcome=unknown"))
        XCTAssertEqual(result.fragmentsShortened, 1)
    }

    func testLongSuccessfulCommandIsMarkedIncompleteAndSmallCommandStaysExact() {
        let long = "Bash · " + String(repeating: "x", count: 2500)
        let small = "Bash · printf '%s\\n' 'a b' && swift test --filter ExactTest"
        func successful(_ command: String) -> [TranscriptLine] {
            [line(.tool, command), line(.toolResult, "OK", outcome: .success)]
        }
        let result = TranscriptDigest.make(lines: successful(long))
        XCTAssertTrue(result.text.contains("command=incomplete"))
        XCTAssertEqual(result.fragmentsShortened, 1)
        let short = TranscriptDigest.make(lines: successful(small))
        XCTAssertEqual(short.text, "[tool] " + small)
        XCTAssertEqual(short.fragmentsShortened, 0)
    }

    func testToolResultAndUserAreNeverReassembledFromSeparateParts() throws {
        for role in [TranscriptLine.Role.toolResult, .user] {
            let original = "ERROR PREMIER\n" + String(repeating: "x", count: 2500) + "\nVERDICT FINAL"
            let entry = try XCTUnwrap(TranscriptDigest.entries(from: [line(role, original, outcome: .unknown)]).first)
            XCTAssertEqual(entry.text, String(original.prefix(1996)) + " […]")
            XCTAssertFalse(entry.text.contains("VERDICT FINAL"))
        }
    }

    func testShortenedFragmentsOnlyCountRetainedMatterAfterPruning() {
        let long = String(repeating: "x", count: 2500)
        let lines = [line(.assistant, long), line(.assistant, long), line(.user, "Garder la demande.")]
        let result = TranscriptDigest.make(lines: lines, budget: 100)
        XCTAssertEqual(result.fragmentsShortened, 0)
        XCTAssertEqual(result.entriesDropped, 2)
        XCTAssertEqual(result.entriesKept, 1)
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.text, "[user] Garder la demande.")
    }

    func testReadStopIsIndependentOfFragmentAndEntryLoss() {
        for stopped in [true, false] {
            let result = TranscriptDigest.make(lines: [line(.assistant, "Conclusion complète.")], sourceReadStopped: stopped)
            XCTAssertEqual(result.sourceReadStopped, stopped)
            XCTAssertEqual(result.fragmentsShortened, 0)
            XCTAssertEqual(result.entriesDropped, 0)
            XCTAssertFalse(result.truncated)
        }
        XCTAssertNil(TranscriptDigest.make(lines: []).sourceReadStopped)
    }

    func testEmptyAndZeroBudgetReportNoKeptShorteningAndExactDroppedCount() {
        let empty = TranscriptDigest.make(lines: [], sourceReadStopped: true)
        XCTAssertEqual(empty.fragmentsShortened, 0)
        XCTAssertEqual(empty.entriesDropped, 0)
        XCTAssertEqual(empty.sourceReadStopped, true)
        let result = TranscriptDigest.make(lines: [line(.assistant, String(repeating: "x", count: 3000)),
                                                  line(.thinking, "Sans intérêt")], budget: 0, sourceReadStopped: false)
        XCTAssertEqual(result.entriesDropped, 1)
        XCTAssertEqual(result.fragmentsShortened, 0)
        XCTAssertEqual(result.sourceReadStopped, false)
        XCTAssertTrue(result.truncated)
    }

    func testUnicodeHeadTailRemainsBoundedAndFinalProofIsPreserved() {
        let original = String(repeating: "👨‍👩‍👧‍👦e\u{301}", count: 1600) + "\nFIN VÉRIFIÉE"
        let result = TranscriptDigest.make(lines: [line(.assistant, original)], budget: 2100)
        XCTAssertEqual(result.entriesKept, 1)
        XCTAssertTrue(result.text.hasSuffix("FIN VÉRIFIÉE"))
        XCTAssertLessThanOrEqual(result.characterCount, 2100)
        XCTAssertEqual(result.fragmentsShortened, 1)
    }
}
