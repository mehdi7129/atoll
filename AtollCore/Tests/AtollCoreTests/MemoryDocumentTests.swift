import XCTest
import SQLite3
@testable import AtollCore

final class MemoryDocumentTests: XCTestCase {
    private var directory: URL!
    private var database: URL!
    private var index: MemoryIndex!
    private let path = "/fixtures/memory.md"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = directory.appendingPathComponent("index.db")
        index = try MemoryIndex(url: database, mode: .readWrite)
    }

    override func tearDownWithError() throws {
        index?.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func replace(_ text: String?, inode: UInt64 = 42, size: Int64 = 100,
                         cwd: String? = "/project") throws {
        let line = text.map {
            TranscriptLine(uuid: "memory", sessionID: nil, timestamp: Date(), cwd: cwd,
                           gitBranch: nil, fragments: [.init(role: .memory, text: $0)])
        }
        try index.replaceDocument(path: path, inode: inode, size: size, line: line,
                                  sessionID: "memory-fixture", projectDir: "project")
    }

    private func hits(_ query: String, prefix: String? = nil) throws -> [MemoryIndex.Hit] {
        try index.search(rawQuery: query, limit: 20, projectPrefix: prefix)
    }

    private func sql(_ statement: String) throws {
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        let result = sqlite3_exec(connection, statement, nil, nil, nil)
        XCTAssertEqual(result, SQLITE_OK, String(cString: sqlite3_errmsg(connection)))
    }

    func testDocumentReplacesEqualSizeGrowthShrinkAndRotation() throws {
        try replace("ancienttoken")
        for (text, inode, size) in [("equaltoken", UInt64(42), Int64(100)),
                                    ("growthtoken", 42, 200), ("shrinktoken", 42, 50),
                                    ("rotatedtoken", 99, 150)] {
            try replace(text, inode: inode, size: size)
            XCTAssertEqual(try hits(text).count, 1)
            XCTAssertEqual(try index.stats().messageCount, 1)
        }
        for token in ["ancienttoken", "equaltoken", "growthtoken", "shrinktoken"] {
            XCTAssertTrue(try hits(token).isEmpty)
        }
    }

    func testUnchangedDocumentPreservesIdentityAcrossConnectionAndTimestamp() throws {
        try replace("stabletoken")
        let original = try XCTUnwrap(hits("stabletoken").first)
        index.close()
        index = try MemoryIndex(url: database, mode: .readWrite)
        try sql("CREATE TRIGGER reject_delete BEFORE DELETE ON messages BEGIN SELECT RAISE(ABORT, 'no rewrite'); END")
        try replace("stabletoken")
        XCTAssertEqual(try hits("stabletoken").first, original)
    }

    func testEmptyDocumentRemovesFragmentsAndSessionButKeepsTrackedFile() throws {
        try replace("oldtoken")
        try replace(nil, size: 0)
        XCTAssertTrue(try hits("oldtoken").isEmpty)
        XCTAssertEqual(try index.stats().sessionCount, 0)
        XCTAssertEqual(try index.trackedPaths(prefix: "/fixtures/"), [path])
        XCTAssertEqual(try index.openFile(path: path, inode: 42, size: 0).offset, 0)
        try replace("newtoken", size: 120)
        XCTAssertEqual(try hits("newtoken").count, 1)
    }

    func testFailedReplacementRollsBackContentInodeAndOffset() throws {
        try replace("preservedtoken")
        let before = try index.openFile(path: path, inode: 42, size: 100)
        try sql("CREATE TRIGGER reject_insert BEFORE INSERT ON messages BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        XCTAssertThrowsError(try replace("rejectedtoken", inode: 99, size: 200))
        XCTAssertEqual(try hits("preservedtoken").count, 1, "transaction lost original content")
        XCTAssertTrue(try hits("rejectedtoken").isEmpty)
        XCTAssertEqual(try index.openFile(path: path, inode: 42, size: 100), before)
        try sql("DROP TRIGGER reject_insert")
        try replace("acceptedtoken", inode: 99, size: 200)
        XCTAssertTrue(try hits("preservedtoken").isEmpty)
        XCTAssertEqual(try hits("acceptedtoken").count, 1)
    }

    func testFailedEmptyReplacementPreservesContent() throws {
        try replace("preservedtoken")
        try sql("CREATE TRIGGER reject_update BEFORE UPDATE OF offset ON files BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        XCTAssertThrowsError(try replace(nil, size: 0))
        XCTAssertEqual(try hits("preservedtoken").count, 1)
    }

    func testUnchangedDocumentAcquiresDiscoveredProjectAndPreservesItDuringAbsence() throws {
        try replace("projecttoken", cwd: nil)
        XCTAssertTrue(try hits("projecttoken", prefix: "/project").isEmpty)
        try replace("projecttoken")
        XCTAssertEqual(try hits("projecttoken", prefix: "/project").count, 1)
        try replace("projecttoken", cwd: nil)
        XCTAssertEqual(try hits("projecttoken", prefix: "/project").count, 1)
    }
}
