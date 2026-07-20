import XCTest
@testable import AtollCore

/// Le découpeur de lignes est LE point où une erreur d'offset perd ou duplique
/// des messages en silence — chaque frontière est couverte.
final class TranscriptLineSplitterTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testSingleCompleteLine() {
        var splitter = TranscriptLineSplitter(startOffset: 0)
        let lines = splitter.consume(data("abc\n"))
        XCTAssertEqual(lines, [.init(data: data("abc"), startOffset: 0)])
        XCTAssertEqual(splitter.consumedOffset, 4)
    }

    func testLineSplitAcrossChunks() {
        var splitter = TranscriptLineSplitter(startOffset: 100)
        XCTAssertTrue(splitter.consume(data("hel")).isEmpty)
        XCTAssertEqual(splitter.consumedOffset, 100) // rien de complet : pas d'avance
        let lines = splitter.consume(data("lo\nwor"))
        XCTAssertEqual(lines, [.init(data: data("hello"), startOffset: 100)])
        XCTAssertEqual(splitter.consumedOffset, 106)
        let rest = splitter.consume(data("ld\n"))
        XCTAssertEqual(rest, [.init(data: data("world"), startOffset: 106)])
        XCTAssertEqual(splitter.consumedOffset, 112)
    }

    func testTrailingPartialLineNeverCounted() {
        var splitter = TranscriptLineSplitter(startOffset: 0)
        let lines = splitter.consume(data("a\npartielle-sans-newline"))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(splitter.consumedOffset, 2) // la queue ne compte JAMAIS
    }

    func testMultipleLinesInOneChunk() {
        var splitter = TranscriptLineSplitter(startOffset: 10)
        let lines = splitter.consume(data("aa\nbb\ncc\n"))
        XCTAssertEqual(lines.map(\.startOffset), [10, 13, 16])
        XCTAssertEqual(splitter.consumedOffset, 19)
    }

    func testEmptyLinesAreSkippedButOffsetAdvances() {
        var splitter = TranscriptLineSplitter(startOffset: 0)
        let lines = splitter.consume(data("\n\nxy\n"))
        XCTAssertEqual(lines, [.init(data: data("xy"), startOffset: 2)])
        XCTAssertEqual(splitter.consumedOffset, 5)
    }

    func testPathologicalGiantLineAbandonedButOffsetAdvances() {
        var splitter = TranscriptLineSplitter(startOffset: 0)
        let giant = Data(repeating: 0x41, count: TranscriptLineSplitter.maxCarryBytes + 1)
        XCTAssertTrue(splitter.consume(giant).isEmpty)
        // La « ligne » est abandonnée mais le flux n'est pas bloqué.
        XCTAssertEqual(splitter.consumedOffset, Int64(giant.count))
        let after = splitter.consume(data("ok\n"))
        XCTAssertEqual(after, [.init(data: data("ok"), startOffset: Int64(giant.count))])
    }

    func testOffsetsStableAcrossRuns() {
        // Même contenu, découpé différemment → mêmes lignes, mêmes offsets
        // (le syntheticUUID "line-<offset>" doit être identique au re-scan).
        let content = "première ligne\nseconde\ntroisième un peu plus longue\n"
        var one = TranscriptLineSplitter(startOffset: 0)
        let all = one.consume(data(content))
        var two = TranscriptLineSplitter(startOffset: 0)
        var chunked: [TranscriptLineSplitter.Line] = []
        for byte in data(content) {
            chunked.append(contentsOf: two.consume(Data([byte])))
        }
        XCTAssertEqual(all, chunked)
        XCTAssertEqual(one.consumedOffset, two.consumedOffset)
    }
}
