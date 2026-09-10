import XCTest
@testable import AtollCore

final class CodexMemoryTests: XCTestCase {
    private let envelope = "# AGENTS.md instructions for /fixture\n\n<INSTRUCTIONS>\nMachineNebuleuse\n</INSTRUCTIONS>\n<environment_context>\nMachineGalaxie\n</environment_context>"

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
