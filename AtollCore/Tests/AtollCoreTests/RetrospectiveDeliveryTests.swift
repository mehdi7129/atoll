import Foundation
import XCTest
@testable import AtollCore

final class RetrospectiveDeliveryTests: XCTestCase {
    private var root: URL!
    private var store: RetrospectiveDelivery.Store { .init(learningRoot: root) }
    private var notes: URL { root.appendingPathComponent("notes") }
    private var proposals: URL { root.appendingPathComponent("proposed") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("atoll-delivery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func result() -> RetrospectiveDelivery {
        let report = RetrospectiveReport(sessionSummary: "Savoir vérifié", nothingLearned: false,
            notes: [.init(slug: "verified-note", category: "pitfall", content: "Le drapeau --verified est requis.", confidence: "high")],
            skills: [.init(slug: "verified-skill", title: "Procédure vérifiée", description: "Appliquer la procédure vérifiée.",
                           skillMD: "Exécuter verify --verified.", rationale: "Preuve dans la session.", confidence: "high")],
            costUSD: nil, flags: ["verified-skill": ["pipe-to-shell"]])
        return .init(report: report, analysisID: UUID(), sessionID: "fixture", origin: .claude,
                     destination: .claude, proposals: proposals, notesDirectory: notes, project: "/fixture",
                     transcriptBytes: 120_000, materialFingerprint: "fixture-digest", decidedAt: Date())
    }

    func testDeliveryIsDurableAndCompletedArtifactsAreNotRecreated() throws {
        var value = result()
        try store.preflight()
        try store.save(value)
        var indexed = 0
        try store.apply(&value, notesDirectory: notes, proposals: proposals) { _, note in
            XCTAssertEqual(note.slug, "verified-note")
            indexed += 1
        }
        XCTAssertEqual(value.notesWritten, 1)
        XCTAssertEqual(value.skillsProposed, 1)
        XCTAssertEqual(indexed, 1)
        let skillDirectory = proposals.appendingPathComponent(value.skills[0].dirname)
        let meta = try Data(contentsOf: skillDirectory.appendingPathComponent("meta.json"))
        XCTAssertTrue(String(decoding: meta, as: UTF8.self).contains("pipe-to-shell"))
        // Une revue ou un rangement peut avoir déplacé les artefacts avant que
        // le journal de session ait fini d'enregistrer son reçu.
        try FileManager.default.moveItem(at: notes, to: root.appendingPathComponent("notes-archived"))
        try FileManager.default.moveItem(at: proposals, to: root.appendingPathComponent("proposals-reviewed"))
        value = try XCTUnwrap(store.pending().first)
        try store.apply(&value, notesDirectory: notes, proposals: proposals) { _, _ in indexed += 1 }
        XCTAssertEqual(indexed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: notes.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: proposals.path))
        try store.acknowledge(value)
        XCTAssertTrue(try store.pending().isEmpty)
    }

    func testBlockedWritesKeepOutputAndResumeWithoutDuplicates() throws {
        var value = result()
        try store.save(value)
        try Data("obstacle".utf8).write(to: notes)
        try Data("obstacle".utf8).write(to: proposals)
        XCTAssertThrowsError(try store.apply(&value, notesDirectory: notes, proposals: proposals) { _, _ in XCTFail("note non écrite") })
        XCTAssertEqual(value.notesWritten, 0)
        XCTAssertEqual(value.skillsProposed, 0)
        XCTAssertFalse(try XCTUnwrap(store.pending().first).isComplete)
        XCTAssertThrowsError(try store.acknowledge(value))
        try FileManager.default.removeItem(at: notes)
        try FileManager.default.removeItem(at: proposals)
        value = try XCTUnwrap(store.pending().first)
        var indexed = 0
        try store.apply(&value, notesDirectory: notes, proposals: proposals) { _, _ in indexed += 1 }
        try store.apply(&value, notesDirectory: notes, proposals: proposals) { _, _ in indexed += 1 }
        XCTAssertEqual(indexed, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: notes.path).count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: proposals.path).count, 1)
    }

    func testPartialResultPreservesForeignFileAndProgress() throws {
        var value = result()
        try store.save(value)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let conflict = notes.appendingPathComponent(value.notes[0].filename)
        try Data("contenu humain".utf8).write(to: conflict)
        XCTAssertThrowsError(try store.apply(&value, notesDirectory: notes, proposals: proposals) { _, _ in XCTFail("note conflictuelle") })
        XCTAssertEqual(value.notesWritten, 0)
        XCTAssertEqual(value.skillsProposed, 1)
        XCTAssertEqual(try String(contentsOf: conflict, encoding: .utf8), "contenu humain")
        let persisted = try XCTUnwrap(store.pending().first)
        XCTAssertTrue(persisted.skills[0].completed)
        XCTAssertFalse(persisted.notes[0].completed)
    }

    func testScopeChangeCannotRedirectResult() throws {
        var value = result()
        try store.save(value)
        let other = root.appendingPathComponent("other-proposed")
        XCTAssertThrowsError(try store.apply(&value, notesDirectory: notes, proposals: other) { _, _ in XCTFail("destination changée") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
        XCTAssertFalse(value.isComplete)
    }

    func testCheckpointFailureDoesNotWriteArtifacts() throws {
        try Data("obstacle".utf8).write(to: store.directory)
        XCTAssertThrowsError(try store.save(result()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: notes.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: proposals.path))
    }

    func testInvalidCheckpointAndSymlinkAreRejected() throws {
        let value = result()
        try store.save(value)
        let url = store.directory.appendingPathComponent(value.id.uuidString + ".json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var items = try XCTUnwrap(json["notes"] as? [[String: Any]])
        items[0]["filename"] = "../outside.md"
        json["notes"] = items
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertThrowsError(try store.pending())
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: root.appendingPathComponent("outside"))
        XCTAssertThrowsError(try store.save(value))
    }

    func testPendingOutputsAreBoundedWithoutDiscardingThem() throws {
        for _ in 0..<16 { try store.save(result()) }
        XCTAssertThrowsError(try store.preflight())
        XCTAssertEqual(try store.pending().count, 16)
    }

    @discardableResult
    private func archiveNote(_ value: RetrospectiveDelivery) throws -> URL {
        let archive = root.appendingPathComponent("archive/notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: notes.appendingPathComponent(value.notes[0].filename),
                                        to: archive.appendingPathComponent(value.notes[0].filename))
        return archive
    }

    private func restoreInterruptedCheckpoint(_ value: RetrospectiveDelivery) throws -> RetrospectiveDelivery {
        var interrupted = value
        for i in interrupted.notes.indices { interrupted.notes[i].completed = false }
        for i in interrupted.skills.indices { interrupted.skills[i].completed = false }
        // État écrit avant l'installation, resté ancien après le crash : la
        // progression completed=true n'a pas atteint le disque.
        try store.save(interrupted)
        return try XCTUnwrap(store.pending().first { $0.id == value.id })
    }

    func testInterruptedCheckpointRecognizesRejectedSkillAndCuratedNote() throws {
        var value = result()
        try store.save(value)
        try store.apply(&value, notesDirectory: notes, proposals: proposals) { _, _ in }
        let skills = LearnedSkillStore(learningRoot: root, skillsRoot: root.appendingPathComponent("installed"))
        try skills.reject(XCTUnwrap(skills.discoverProposals().first))
        let archive = try archiveNote(value)
        value = try restoreInterruptedCheckpoint(value)
        try store.apply(&value, notesDirectory: notes, proposals: proposals) { _, _ in XCTFail("note déjà rangée") }
        XCTAssertTrue(value.isComplete)
        XCTAssertEqual(value.notesWritten, 1)
        XCTAssertEqual(value.skillsProposed, 1)
        XCTAssertTrue(skills.discoverProposals().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: proposals.appendingPathComponent(value.skills[0].dirname).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: notes.appendingPathComponent(value.notes[0].filename).path))
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent(value.notes[0].filename)), value.notes[0].contents)
    }

    func testInterruptedCheckpointRecognizesApprovedSkillIncludingHumanEdit() throws {
        var value = result()
        value.notes = []
        try store.save(value)
        try store.apply(&value, notesDirectory: notes, proposals: proposals) { _, _ in }
        let skills = LearnedSkillStore(learningRoot: root, skillsRoot: root.appendingPathComponent("installed"))
        let edited = proposals.appendingPathComponent(value.skills[0].dirname).appendingPathComponent("SKILL.md")
        try Data("# Correction humaine avant validation\n".utf8).write(to: edited)
        let installed = try skills.approve(XCTUnwrap(skills.discoverProposals().first))
        value = try restoreInterruptedCheckpoint(value)
        try store.apply(&value, notesDirectory: notes, proposals: proposals) { _, _ in }
        XCTAssertTrue(value.isComplete)
        XCTAssertEqual(skills.installedSkills().map(\.slug), [installed.slug])
        XCTAssertTrue(skills.discoverProposals().isEmpty)
        let archives = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("archive/approved"), includingPropertiesForKeys: nil)
        let meta = try Data(contentsOf: XCTUnwrap(archives.first).appendingPathComponent("meta.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: meta) as? [String: Any])
        XCTAssertEqual(json["delivery_id"] as? String, value.id.uuidString)
        XCTAssertEqual(json["delivery_artifact"] as? String, value.skills[0].dirname)
        XCTAssertEqual(json["flags"] as? [String], ["pipe-to-shell"])
    }

    func testMissingProofAfterArchivePurgeStaysPendingWithoutRecreation() throws {
        var value = result()
        try store.save(value)
        try store.apply(&value, notesDirectory: notes, proposals: proposals) { _, _ in }
        let skills = LearnedSkillStore(learningRoot: root, skillsRoot: root.appendingPathComponent("installed"))
        try skills.reject(XCTUnwrap(skills.discoverProposals().first))
        try archiveNote(value)
        // Simule la rétention de curation ou le ménage manuel des archives.
        try FileManager.default.removeItem(at: root.appendingPathComponent("archive"))
        value = try restoreInterruptedCheckpoint(value)
        XCTAssertThrowsError(try store.apply(&value, notesDirectory: notes, proposals: proposals) { _, _ in XCTFail("preuve absente") })
        XCTAssertEqual(value.notesWritten, 0)
        XCTAssertEqual(value.skillsProposed, 0)
        XCTAssertFalse(try XCTUnwrap(store.pending().first).isComplete)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: notes.path).isEmpty)
        XCTAssertTrue(skills.discoverProposals().isEmpty)
    }

    func testAnotherDeliveryWithIdenticalContentsDoesNotCountAsOurProof() throws {
        var first = result()
        var other = result()
        // Même matière, dates et noms : seule la provenance doit départager.
        XCTAssertEqual(first.skills[0].markdown, other.skills[0].markdown)
        XCTAssertNotEqual(first.notes[0].contents, other.notes[0].contents)
        try store.save(other)
        try store.apply(&other, notesDirectory: notes, proposals: proposals) { _, _ in }
        let skills = LearnedSkillStore(learningRoot: root, skillsRoot: root.appendingPathComponent("installed"))
        try skills.reject(XCTUnwrap(skills.discoverProposals().first))
        try archiveNote(other)
        try store.acknowledge(other)
        first.notes[0].started = true
        first.skills[0].started = true
        try store.save(first)
        XCTAssertThrowsError(try store.apply(&first, notesDirectory: notes, proposals: proposals) { _, _ in XCTFail("autre livraison") })
        XCTAssertEqual(first.notesWritten, 0)
        XCTAssertEqual(first.skillsProposed, 0)
        XCTAssertTrue(skills.discoverProposals().isEmpty)
    }

    func testInterruptedSkillFilePairCanFinishMetadataWithoutDuplicatingMarkdown() throws {
        var value = result()
        value.notes = []
        value.skills[0].started = true
        let dir = proposals.appendingPathComponent(value.skills[0].dirname)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try value.skills[0].markdown.write(to: dir.appendingPathComponent("SKILL.md"))
        try store.save(value)
        try store.apply(&value, notesDirectory: notes, proposals: proposals) { _, _ in }
        XCTAssertTrue(value.isComplete)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("SKILL.md")), value.skills[0].markdown)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("meta.json")), value.skills[0].metadata)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: proposals.path).count, 1)
    }

    func testLegacyCheckpointWithoutWriteIntentDoesNotInventMissingArtifacts() throws {
        var value = result()
        value.notes[0].started = nil
        value.skills[0].started = nil
        try store.save(value)
        value = try XCTUnwrap(store.pending().first)
        XCTAssertNil(value.notes[0].started)
        XCTAssertThrowsError(try store.apply(&value, notesDirectory: notes, proposals: proposals) { _, _ in XCTFail("provenance ancienne ambiguë") })
        XCTAssertFalse(value.isComplete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: notes.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: proposals.path))
    }
}
