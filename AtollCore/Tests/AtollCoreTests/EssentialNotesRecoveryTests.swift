import XCTest
@testable import AtollCore

final class EssentialNotesRecoveryTests: XCTestCase {
    private let fm = FileManager.default
    private let previous = [(name: "a.md", content: "Les positions utilisent des mètres."),
                            (name: "b.md", content: "Vérifier les identifiants après export.")]

    private func fixture() throws -> (URL, CurationCheckpoint, [String: Data]) {
        let root = fm.temporaryDirectory.appendingPathComponent("atoll-essential-notes-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let output = NotesCurationOutput(notes: [
            .init(title: "Unités", content: "Exporter les positions en mètres.", sources: ["a.md"]),
            .init(title: "Identifiants", content: "Vérifier les identifiants à chaque export.", sources: ["b.md"])
        ], contradictions: [])
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let plan = try NotesCurationPlanner.plan(existing: previous, output: output, now: date).get()
        let receipt = try CurationCheckpoint(previous: previous, output: output, plan: plan, createdAt: date, leaseID: UUID())
        try CurationCheckpointStore(directory: root.appendingPathComponent("curation-pending")).save(receipt)
        for note in previous {
            try write(Data(note.content.utf8), root.appendingPathComponent("archive/notes-20250101/" + note.name))
        }
        let target = Dictionary(uniqueKeysWithValues: plan.newNotes.map { ($0.fileName, Data($0.content.utf8)) })
        for (name, bytes) in target { try write(bytes, root.appendingPathComponent(".notes-staging-fixture/" + name)) }
        try write(Data(receipt.id.uuidString.utf8), root.appendingPathComponent(".notes-staging-fixture/.swap-started"))
        try fm.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        return (root, receipt, target)
    }
    private func write(_ data: Data, _ path: URL) throws {
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path)
    }
    private func noteFiles(_ root: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: fm.contentsOfDirectory(at: root.appendingPathComponent("notes"), includingPropertiesForKeys: nil)
            .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }

    func testMigrationRestoresInterruptedSwapLocallyWithoutPurgingPaidEvidence() throws {
        let (learning, receipt, target) = try fixture()
        let moved = try XCTUnwrap(target.keys.sorted().first)
        try fm.moveItem(at: learning.appendingPathComponent(".notes-staging-fixture/" + moved),
                        to: learning.appendingPathComponent("notes/" + moved))
        let migratedLearning = learning.appendingPathComponent(".atoll/learning")
        try fm.createDirectory(at: migratedLearning, withIntermediateDirectories: true)
        for name in ["curation-pending", "archive", ".notes-staging-fixture", "notes"] {
            try fm.moveItem(at: learning.appendingPathComponent(name), to: migratedLearning.appendingPathComponent(name))
        }
        _ = try EssentialMigrationStore(home: learning, codexHome: learning.appendingPathComponent("codex")).run()
        XCTAssertEqual(try noteFiles(migratedLearning), Dictionary(uniqueKeysWithValues: previous.map { ($0.name, Data($0.content.utf8)) }),
                       "EM-notes-migration-recovers")
        XCTAssertEqual(try CurationCheckpointStore(directory: migratedLearning.appendingPathComponent("curation-pending")).load()?.id,
                       receipt.id, "EM-notes-migration-keeps-checkpoint")
    }

    func testRecoveryRestoresSourceAndKeepsCheckpointAndStagingOnRepeatedRuns() throws {
        let (root, receipt, target) = try fixture()
        let moved = try XCTUnwrap(target.keys.sorted().first)
        try fm.moveItem(at: root.appendingPathComponent(".notes-staging-fixture/" + moved), to: root.appendingPathComponent("notes/" + moved))
        try EssentialNotesRecovery.recover(learningRoot: root)
        let expected = Dictionary(uniqueKeysWithValues: previous.map { ($0.name, Data($0.content.utf8)) })
        XCTAssertEqual(try noteFiles(root), expected, "EM-notes-source-restored")
        XCTAssertEqual(try CurationCheckpointStore(directory: root.appendingPathComponent("curation-pending")).load()?.id, receipt.id,
                       "EM-notes-paid-result-kept")
        for (name, bytes) in target {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".notes-staging-fixture/" + name)), bytes, "EM-notes-staging-kept")
        }
        try EssentialNotesRecovery.recover(learningRoot: root)
        XCTAssertEqual(try noteFiles(root), expected, "EM-notes-retry-idempotent")
    }

    func testAlreadyCompletedSwapIsNotRolledBack() throws {
        let (root, receipt, target) = try fixture()
        for name in target.keys {
            try fm.moveItem(at: root.appendingPathComponent(".notes-staging-fixture/" + name), to: root.appendingPathComponent("notes/" + name))
        }
        try EssentialNotesRecovery.recover(learningRoot: root)
        XCTAssertEqual(try noteFiles(root), target, "EM-notes-committed-target-kept")
        XCTAssertEqual(try CurationCheckpointStore(directory: root.appendingPathComponent("curation-pending")).load()?.id, receipt.id)
    }

    func testUserEditedNoteMakesSwapAmbiguousWithoutOverwritingAnything() throws {
        let (root, _, target) = try fixture()
        let personal = Data("Modification personnelle après le crash.".utf8)
        try write(personal, root.appendingPathComponent("notes/a.md"))
        let before = try noteFiles(root)
        XCTAssertThrowsError(try EssentialNotesRecovery.recover(learningRoot: root), "EM-notes-ambiguous-refused")
        XCTAssertEqual(try noteFiles(root), before)
        for (name, bytes) in target { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".notes-staging-fixture/" + name)), bytes) }
    }

    func testCorruptPaidCheckpointIsNotDiscarded() throws {
        let (root, _, _) = try fixture()
        let file = root.appendingPathComponent("curation-pending/result.json")
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try EssentialNotesRecovery.recover(learningRoot: root))
        XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent(".notes-staging-fixture").path))
    }
}
