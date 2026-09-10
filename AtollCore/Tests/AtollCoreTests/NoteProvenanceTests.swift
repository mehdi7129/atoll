import XCTest
@testable import AtollCore

final class NoteProvenanceTests: XCTestCase {
    func testCurationKeepsAllSessionsThroughSuccessiveConsolidations() throws {
        let originals = [(name: "a.md", content: "---\nsource_session: codex:one\n---\nUn savoir"),
                         (name: "b.md", content: "---\nsource_session: claude-two\n---\nAutre savoir")]
        let output = NotesCurationOutput(notes: [.init(title: "Condensé", content: "Un savoir et un autre savoir réunis", sources: ["a.md", "b.md"])], contradictions: [])
        let plan = try NotesCurationPlanner.plan(existing: originals, output: output, now: Date()).get()
        let first = try XCTUnwrap(plan.newNotes.first)
        let current = [(name: first.fileName, content: first.content)]
        XCTAssertEqual(NoteProvenance.sessions(for: [first.fileName], existing: current), ["claude-two", "codex:one"])
        XCTAssertTrue(first.content.contains(InstalledSkillsManifest.sha256(originals[0].content)))
    }

    func testHistoricalSourceCanBeResolvedInArchiveButAmbiguityIsNotGuessed() {
        let original = (name: "a.md", content: "---\nsource_session: codex:old\n---\nSavoir")
        let legacy = [(name: "curated.md", content: "---\nsources:\n  - a.md\n---\nSavoir")]
        XCTAssertEqual(NoteProvenance.sessions(for: ["curated.md"], existing: legacy, archives: [original]), ["codex:old"])
        let collision = (name: "a.md", content: "---\nsource_session: unrelated\n---\nAutre")
        XCTAssertEqual(NoteProvenance.sessions(for: ["curated.md"], existing: legacy, archives: [original, collision]), [])
        let references = NoteProvenance.references(for: ["a.md"], existing: [original])
        let known = [(name: "curated.md", content: "---\nsource_notes: \(references)\n---\nSavoir")]
        XCTAssertEqual(NoteProvenance.sessions(for: ["curated.md"], existing: known, archives: [original, collision]), ["codex:old"])
    }

    func testCyclicHistoricalReferencesTerminate() {
        let notes = [(name: "a.md", content: "---\nsources:\n  - b.md\n---\nA"),
                     (name: "b.md", content: "---\nsources:\n  - a.md\n---\nB")]
        XCTAssertEqual(NoteProvenance.sessions(for: ["a.md"], existing: notes, archives: notes), [])
    }

    func testCorruptHashReferenceDoesNotFallBackToNameOnly() {
        let legacy = [(name: "curated.md", content: "---\nsource_notes: broken\nsources:\n  - a.md\n---\nSavoir")]
        let archive = [(name: "a.md", content: "---\nsource_session: codex:old\n---\nSavoir")]
        XCTAssertEqual(NoteProvenance.sessions(for: ["curated.md"], existing: legacy, archives: archive), [])
    }

    func testCurationRefusesMissingAndUnknownSources() {
        let originals = [(name: "a.md", content: "---\nsource_session: codex:old\n---\nSavoir")]
        for sources in [[], ["unknown.md"]] {
            let output = NotesCurationOutput(notes: [.init(title: "Note", content: "Savoir conservé", sources: sources)], contradictions: [])
            XCTAssertEqual(NotesCurationPlanner.plan(existing: originals, output: output, now: Date()), .failure(.untraceableSources))
        }
    }
}
