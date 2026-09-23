import XCTest
@testable import AtollCore

final class CurationCheckpointTests: XCTestCase {
    private let notes = [(name: "a.md", content: "Format en mètres, jamais en centimètres."),
                         (name: "b.md", content: "Vérifier les identifiants à chaque export.")]
    private let date = Date(timeIntervalSince1970: 1_750_000_000)

    private func fixture() throws -> (CurationCheckpoint, NotesCurationOutput, NotesCurationPlanner.Plan) {
        let output = NotesCurationOutput(notes: [.init(title: "Export", content:
            "Exporter les positions en mètres et vérifier les identifiants à chaque export.",
            sources: ["a.md", "b.md"])], contradictions: [.init(summary: "Deux conventions à vérifier", files: ["a.md", "b.md"])])
        let plan = try NotesCurationPlanner.plan(existing: notes, output: output, now: date).get()
        return (try CurationCheckpoint(previous: notes, output: output, plan: plan,
            createdAt: date, leaseID: UUID()), output, plan)
    }

    private func store() throws -> CurationCheckpointStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return CurationCheckpointStore(directory: root.appendingPathComponent("pending"))
    }

    func testColdRoundTripKeepsPaidResultDateAndProvenance() throws {
        let (receipt, output, plan) = try fixture()
        let store = try store()
        XCTAssertNil(try store.load())
        try store.save(receipt)
        let loaded = try XCTUnwrap(CurationCheckpointStore(directory: store.directory).load())
        XCTAssertEqual(loaded.id, receipt.id)
        XCTAssertEqual(loaded.leaseID, receipt.leaseID)
        XCTAssertEqual(loaded.sourceNames, ["a.md", "b.md"])
        XCTAssertEqual(loaded.createdAt, date)
        XCTAssertEqual(loaded.output, output)
        let replanned = try NotesCurationPlanner.plan(existing: notes, output: XCTUnwrap(loaded.output), now: loaded.createdAt).get()
        XCTAssertEqual(replanned, plan)
        XCTAssertEqual(loaded.match(notes: notes.reversed()), .source)
        XCTAssertEqual(loaded.match(notes: plan.newNotes.map { ($0.fileName, $0.content) }), .target)
    }

    func testChangedAddedRemovedOrRenamedNoteCannotUseOldResult() throws {
        let (receipt, _, _) = try fixture()
        XCTAssertEqual(receipt.match(notes: [notes[0]]), .changed)
        XCTAssertEqual(receipt.match(notes: notes + [("c.md", "Préférence nouvelle")]), .changed)
        XCTAssertEqual(receipt.match(notes: [("a.md", notes[0].content + " modifié"), notes[1]]), .changed)
        XCTAssertEqual(receipt.match(notes: [("renamed.md", notes[0].content), notes[1]]), .changed)
    }

    func testPrivateStoreAndRemovalDoesNotDeleteAnotherCheckpoint() throws {
        let store = try store()
        let (receipt, _, _) = try fixture()
        try store.save(receipt)
        let fm = FileManager.default
        XCTAssertEqual(try fm.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int, 0o700)
        let file = store.directory.appendingPathComponent("result.json")
        XCTAssertEqual(try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertThrowsError(try store.remove(ifID: UUID()))
        XCTAssertEqual(try store.load()?.id, receipt.id)
        try store.remove(ifID: receipt.id)
        XCTAssertNil(try store.load())
    }

    func testCorruptUnsupportedAndOversizedFilesAreNotAnAbsentResult() throws {
        let store = try store()
        let (receipt, _, _) = try fixture()
        try store.save(receipt)
        let file = store.directory.appendingPathComponent("result.json")
        let valid = try Data(contentsOf: file)
        try Data("{".utf8).write(to: file)
        XCTAssertThrowsError(try store.load())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        json["version"] = 2
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        XCTAssertThrowsError(try store.load())
        json["version"] = 1
        json["sourceNames"] = ["../outside.md"]
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        XCTAssertThrowsError(try store.load())
        json["sourceNames"] = ["a.md", "b.md"]
        json["payload"] = Data(#"{"notes":[],"contradictions":[]}"#.utf8).base64EncodedString()
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        XCTAssertThrowsError(try store.load())
        try Data(repeating: 32, count: CurationCheckpointStore.byteLimit + 1).write(to: file)
        XCTAssertThrowsError(try store.load())
    }

    func testUnreadableParentAndWriteFailureAreNotSuccessfulOperations() throws {
        let store = try store()
        let (receipt, _, _) = try fixture()
        try FileManager.default.createDirectory(at: store.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("obstacle".utf8).write(to: store.directory)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(receipt))
        XCTAssertEqual(try String(contentsOf: store.directory), "obstacle")
    }
}
