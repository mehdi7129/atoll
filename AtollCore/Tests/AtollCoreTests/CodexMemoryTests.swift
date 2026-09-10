import XCTest
import SQLite3
@testable import AtollCore

final class CodexMemoryTests: XCTestCase {
    private let envelope = "# AGENTS.md instructions for /fixture\n\n<INSTRUCTIONS>\nMachineNebuleuse\n</INSTRUCTIONS>\n<environment_context>\nMachineGalaxie\n</environment_context>"

    private let clientEnvelopes = [
        "<task-notification>\n<task-id>fixture</task-id>\n<summary>MachineNebuleuse</summary>\n</task-notification>",
        "<command-name>/fixture</command-name>\n<command-message>MachineNebuleuse</command-message>\n<command-args></command-args>",
        "<local-command-stdout>MachineNebuleuse\nune sortie\n</local-command-stdout>",
        "<realtime_delegation>\n<source>MachineNebuleuse</source>\n<input>automatique</input>\n</realtime_delegation>",
    ]

    func testClientEnvelopesPreserveHumanSuffixAndQuotes() {
        for envelope in clientEnvelopes {
            let parts = CodexTranscriptParser.classifiedUserText(envelope + "\nHumainSaturne")
            XCTAssertEqual(parts.map(\.role), [.instruction, .user], envelope)
            XCTAssertEqual(parts.last?.text, "HumainSaturne")
            for quote in ["Explique ce message :\n" + envelope, "```xml\n" + envelope + "\n```", "> " + envelope] {
                XCTAssertEqual(CodexTranscriptParser.classifiedUserText(quote).map(\.role), [.user])
            }
        }
        for incomplete in ["<command-name>/fixture</command-name>", "<local-command-stdout>Que signifie ceci ?",
                           "<task-notification>\nExplique-moi ceci", "<realtime_delegation>\nMa question"] {
            XCTAssertEqual(CodexTranscriptParser.classifiedUserText(incomplete).map(\.role), [.user])
        }
        let inline = "<local-command-stdout>Une sortie</local-command-stdout>\nHumain"
        XCTAssertEqual(CodexTranscriptParser.classifiedUserText(inline).map(\.role), [.instruction, .user])
    }

    func testClientEnvelopeMigrationReclassifiesAllFourFamiliesAndKeepsOriginalBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try MemoryIndex(url: root.appendingPathComponent("memory.sqlite"), mode: .readWrite)
        defer { index.close() }
        for (number, envelope) in clientEnvelopes.enumerated() {
            let path = "/purged/\(number).jsonl"
            let state = try index.openFile(path: path, inode: 1, size: 100)
            let line = TranscriptLine(uuid: path, sessionID: "codex:old", timestamp: Date(), cwd: "/fixture", gitBranch: nil,
                fragments: [.init(role: .user, text: envelope + "\nHumainSaturne")])
            try index.ingest(lines: [(line, path)], fileState: state, sessionID: "codex:old", projectDir: "fixture", newOffset: 100)
            try index.markMissing(path: path)
        }
        XCTAssertEqual(try index.runCodexHygieneIfNeeded(), 4)
        XCTAssertEqual(try index.runCodexHygieneIfNeeded(), 0)
        XCTAssertTrue(try index.search(rawQuery: "MachineNebuleuse", limit: 10, projectPrefix: nil).isEmpty)
        XCTAssertEqual(try index.search(rawQuery: "HumainSaturne", limit: 10, projectPrefix: nil).count, 4)
        let backupURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("memory-before-codex-hygiene-") && $0.pathExtension == "sqlite" })
        let backup = try MemoryIndex(url: backupURL, mode: .readOnly)
        defer { backup.close() }
        XCTAssertEqual(try backup.search(rawQuery: "MachineNebuleuse", limit: 10, projectPrefix: nil).count, 4)
    }

    func testIncompleteSnapshotIsRemovedAndExistingDestinationNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("snapshot.sqlite")
        enum Failure: Error { case simulatedDiskFailure }
        XCTAssertThrowsError(try MemoryIndex.writeCodexHygieneSnapshot(to: target) { destination in
            XCTAssertEqual(sqlite3_exec(destination, "CREATE TABLE partial(data); INSERT INTO partial VALUES(zeroblob(1048576));", nil, nil, nil), SQLITE_OK)
            XCTAssertGreaterThan(try Data(contentsOf: target).count, 1_000_000)
            for suffix in ["-wal", "-shm", "-journal"] { try Data("partiel".utf8).write(to: URL(fileURLWithPath: target.path + suffix)) }
            throw Failure.simulatedDiskFailure
        })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [], "sauvegarde partielle abandonnée")
        let original = Data("ne pas remplacer".utf8)
        try original.write(to: target)
        XCTAssertThrowsError(try MemoryIndex.writeCodexHygieneSnapshot(to: target) { _ in XCTFail("fichier étranger ouvert") })
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testStructuralEnvelopesPreserveHumanSuffixAndOrdinaryQuotes() {
        let parts = CodexTranscriptParser.classifiedUserText(envelope + "\n\nHumainSaturne")
        XCTAssertEqual(parts.map(\.role), [.instruction, .instruction, .user])
        XCTAssertEqual(parts.last?.text, "HumainSaturne")
        for text in ["Explique AGENTS.md", "Je cite : " + envelope, "# AGENTS.md instructions for /fixture\nVoici ma question"] {
            XCTAssertEqual(CodexTranscriptParser.classifiedUserText(text).map(\.role), [.user])
        }
    }

    func testQuotedClosingTagDoesNotEndInstructions() {
        let text = "# AGENTS.md instructions for /fixture\n\n<INSTRUCTIONS>\nCitation inline `</INSTRUCTIONS>`\n```xml\n</INSTRUCTIONS>\n```\nToujours automatique\n</INSTRUCTIONS>\nHumain"
        let parts = CodexTranscriptParser.classifiedUserText(text)
        XCTAssertEqual(parts.map(\.role), [.instruction, .user])
        XCTAssertEqual(parts.last?.text, "Humain")
        XCTAssertEqual(CodexTranscriptParser.classifiedUserText("<environment_context> Que signifie cette balise ?").first?.role, .user)
    }

    func testEncryptedCompactionIsNotAHumanPromptOrClearSummary() throws {
        let encrypted: [String: Any] = ["type": "compacted", "payload": [
            "message": "", "replacement_history": [["type": "compaction", "encrypted_content": "fixture-ciphertext"],
                ["type": "message", "role": "user", "content": [["type": "input_text", "text": "déjà indexé"]]]]]]
        XCTAssertNil(CodexTranscriptParser.parse(try JSONSerialization.data(withJSONObject: encrypted)))
    }

    func testMigrationKeepsPurgedHistoryBacksUpAndOnlyReclassifiesCodex() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let index = try MemoryIndex(url: root.appendingPathComponent("memory.sqlite"), mode: .readWrite)
        defer { index.close() }
        func ingest(_ text: String, session: String, path: String) throws {
            let state = try index.openFile(path: path, inode: 1, size: 100)
            let line = TranscriptLine(uuid: path, sessionID: session, timestamp: Date(), cwd: "/fixture", gitBranch: nil,
                                      fragments: [.init(role: .user, text: text)])
            try index.ingest(lines: [(line, path)], fileState: state, sessionID: session, projectDir: "fixture", newOffset: 100)
            try index.markMissing(path: path)
        }
        try ingest(envelope + "\nHumainSaturne", session: "codex:old", path: "/purged/codex.jsonl")
        try ingest("SouvenirJupiter", session: "codex:old", path: "/purged/other.jsonl")
        try ingest(envelope, session: "claude", path: "/purged/claude.jsonl")
        XCTAssertEqual(try index.runCodexHygieneIfNeeded(), 1)
        XCTAssertEqual(try index.runCodexHygieneIfNeeded(), 0)
        XCTAssertEqual(try index.search(rawQuery: "MachineNebuleuse", limit: 10, projectPrefix: nil).map(\.sessionID), ["claude"])
        XCTAssertEqual(try index.search(rawQuery: "HumainSaturne", limit: 10, projectPrefix: nil).count, 1)
        XCTAssertEqual(try index.search(rawQuery: "SouvenirJupiter", limit: 10, projectPrefix: nil).count, 1)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("memory-before-codex-hygiene-") && $0.pathExtension == "sqlite" }
        XCTAssertEqual(backups.count, 1)
        let backup = try MemoryIndex(url: XCTUnwrap(backups.first), mode: .readOnly)
        defer { backup.close() }
        XCTAssertEqual(try backup.search(rawQuery: "MachineNebuleuse", limit: 10, projectPrefix: nil).count, 2)
        try ingest(envelope, session: "codex:later", path: "/purged/older-app.jsonl")
        XCTAssertEqual(try index.runCodexHygieneIfNeeded(), 1, "une ancienne app peut avoir réindexé une enveloppe")
    }

    func testBackupCleanupCannotMatchForeignFiles() {
        let base = "memory-before-codex-hygiene-\(UUID().uuidString).sqlite"
        for suffix in ["", "-wal", "-shm", "-journal"] {
            XCTAssertTrue(MemoryIndex.isCodexHygieneBackupFileName(base + suffix))
        }
        for name in ["memory.db", "memory-before-codex-hygiene-my-backup.sqlite", base + ".bak", "../" + base] {
            XCTAssertFalse(MemoryIndex.isCodexHygieneBackupFileName(name))
        }
    }

    func testUnavailableIndexNeverCountsAsSearchLatency() throws {
        XCTAssertFalse(RecallJournal.Outcome.indexUnavailable.searched)
        let summary = RecallJournal.summarize([
            .init(at: Date(), outcome: .indexUnavailable, elapsedMs: 10_000),
            .init(at: Date(), outcome: .noHits, elapsedMs: 7)])
        XCTAssertEqual(summary.searched, 1)
        XCTAssertEqual(summary.medianElapsedMs, 7)
    }
}
