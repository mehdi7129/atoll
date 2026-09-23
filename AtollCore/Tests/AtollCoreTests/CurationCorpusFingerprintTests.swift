import XCTest
@testable import AtollCore

final class CurationCorpusFingerprintTests: XCTestCase {
    func testStableAcrossDirectoryEnumerationOrderAndSerialization() throws {
        let corpus = [(name: "b.md", content: "Deuxième note."), (name: "a.md", content: "Première note.")]
        let fingerprint = CurationCorpusFingerprint(notes: corpus)
        XCTAssertEqual(fingerprint, CurationCorpusFingerprint(notes: Array(corpus.reversed())))
        XCTAssertEqual(fingerprint.version, 1)
        XCTAssertEqual(fingerprint.sha256.count, 64)
        XCTAssertEqual(try JSONDecoder().decode(CurationCorpusFingerprint.self,
            from: JSONEncoder().encode(fingerprint)), fingerprint)
    }

    func testChangeAdditionRemovalAndRenameAreDifferent() {
        let reference = CurationCorpusFingerprint(notes: [("a.md", "Même connaissance.")])
        for corpus in [[("a.md", "Connaissance corrigée.")], [("b.md", "Même connaissance.")],
                       [("a.md", "Même connaissance."), ("b.md", "Nouvelle connaissance.")], []] {
            XCTAssertNotEqual(reference, CurationCorpusFingerprint(notes: corpus))
        }
    }

    func testLengthFramingPreservesNoteBoundaries() {
        XCTAssertNotEqual(CurationCorpusFingerprint(notes: [("ab", "c")]),
                          CurationCorpusFingerprint(notes: [("a", "bc")]))
        XCTAssertNotEqual(CurationCorpusFingerprint(notes: [("a", "b"), ("c", "d")]),
                          CurationCorpusFingerprint(notes: [("a", "bcd")]))
    }

    func testPolicyVersionIsPartOfStoredIdentity() throws {
        let current = CurationCorpusFingerprint(notes: [("a.md", "Fait vérifié.")])
        let previous = try JSONDecoder().decode(CurationCorpusFingerprint.self,
            from: Data("{\"version\":0,\"sha256\":\"\(current.sha256)\"}".utf8))
        XCTAssertNotEqual(current, previous)
    }
}
