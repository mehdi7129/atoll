import XCTest
@testable import AtollCore

final class MemoryIndexTests: XCTestCase {

    private var directory: URL!
    private var databaseURL: URL!
    private var index: MemoryIndex!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("index.db")
        index = try MemoryIndex(url: databaseURL, mode: .readWrite)
    }

    override func tearDownWithError() throws {
        index?.close()
        index = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Fixtures

    /// Un fragment indexable et son identité — la matière première des lots.
    private struct Entry {
        var uuid: String
        var text: String
        var role: TranscriptLine.Role = .user
        var timestamp: Date?
        var cwd: String?
    }

    /// Chemin JSONL par défaut : un seul fichier suffit à la plupart des tests.
    private var defaultPath: String { "/transcripts/session-1.jsonl" }

    /// Ouvre (ou ré-ouvre) le fichier puis ingère le lot — le chemin nominal
    /// exact de l'appelant réel : openFile → ingest(newOffset).
    @discardableResult
    private func ingest(_ entries: [Entry],
                        sessionID: String = "session-1",
                        path: String? = nil,
                        inode: UInt64 = 100,
                        size: Int64 = 1_000,
                        newOffset: Int64 = 1_000) throws -> MemoryIndex.FileState {
        let filePath = path ?? defaultPath
        let state = try index.openFile(path: filePath, inode: inode, size: size)
        let lines = entries.map { entry in
            (line: TranscriptLine(uuid: entry.uuid,
                                  sessionID: sessionID,
                                  timestamp: entry.timestamp,
                                  cwd: entry.cwd,
                                  gitBranch: nil,
                                  fragments: [.init(role: entry.role, text: entry.text)]),
             syntheticUUID: entry.uuid)
        }
        try index.ingest(lines: lines, fileState: state, sessionID: sessionID,
                         projectDir: "-transcripts", newOffset: newOffset)
        return state
    }

    // MARK: - Schéma

    func testCreateSchemaSetsUserVersion() throws {
        // v2 = arrivée de la table skill_usage (une base v1 est reconstruite).
        XCTAssertEqual(MemoryIndex.schemaVersion, 2)
        XCTAssertEqual(try index.storedSchemaVersion(), MemoryIndex.schemaVersion)

        // Ré-ouverture d'une base à jour : version reconnue, rien n'est recréé
        // (les données survivent).
        try ingest([Entry(uuid: "u1", text: "persistance vérifiée")])
        index.close()
        index = try MemoryIndex(url: databaseURL, mode: .readWrite)
        XCTAssertEqual(try index.storedSchemaVersion(), MemoryIndex.schemaVersion)
        XCTAssertEqual(try index.stats().messageCount, 1)
    }

    // MARK: - Recherche

    func testIngestThenSearchReturnsSnippetWithMarkers() throws {
        try ingest([Entry(uuid: "u1",
                          text: "la géométrie du notch insète ses flancs",
                          cwd: "/Users/x/proj")])

        let hits = try index.search(rawQuery: "notch", limit: 10, projectPrefix: nil)
        XCTAssertEqual(hits.count, 1)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertTrue(hit.snippet.contains("«notch»"),
                      "marqueurs « » attendus dans : \(hit.snippet)")
        XCTAssertEqual(hit.sessionID, "session-1")
        XCTAssertEqual(hit.projectPath, "/Users/x/proj")
        XCTAssertEqual(hit.projectDir, "-transcripts")
        XCTAssertEqual(hit.role, "user")
    }

    func testSearchIsAccentAndCaseInsensitive() throws {
        try ingest([Entry(uuid: "u1", text: "La MÉMOIRE des sessions est précieuse")])

        // « memoire » (sans accent, minuscules) doit trouver « MÉMOIRE » :
        // unicode61 replie la casse, remove_diacritics 2 replie les accents.
        let hits = try index.search(rawQuery: "memoire", limit: 10, projectPrefix: nil)
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].snippet.contains("«MÉMOIRE»"))
    }

    func testSearchOrdersByBM25Relevance() throws {
        try ingest([
            Entry(uuid: "dense", text: "quota quota quota", role: .assistant),
            Entry(uuid: "sparse",
                  text: "le quota est mentionné une seule fois au milieu de beaucoup "
                      + "d'autres mots sans rapport avec le sujet qui nous occupe"),
        ])

        let hits = try index.search(rawQuery: "quota", limit: 10, projectPrefix: nil)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].role, "assistant",
                       "le message dense en occurrences doit sortir premier")
        XCTAssertLessThan(hits[0].rank, hits[1].rank,
                          "bm25 : plus négatif = plus pertinent")
    }

    func testSearchProjectPrefixFilter() throws {
        try ingest([Entry(uuid: "a", text: "peuplier majestueux", cwd: "/Users/x/alpha")],
                   sessionID: "session-a", path: "/transcripts/a.jsonl", inode: 1)
        try ingest([Entry(uuid: "b", text: "peuplier discret", cwd: "/Users/y/beta")],
                   sessionID: "session-b", path: "/transcripts/b.jsonl", inode: 2)

        let all = try index.search(rawQuery: "peuplier", limit: 10, projectPrefix: nil)
        XCTAssertEqual(all.count, 2)

        let filtered = try index.search(rawQuery: "peuplier", limit: 10,
                                        projectPrefix: "/Users/x")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, "session-a")
    }

    func testSearchProjectPrefixEscapesLikeWildcards() throws {
        // Vécu en revue : sans ESCAPE, le `_` du préfixe est un joker LIKE et
        // /tmp/Dynamic_Island matchait aussi /tmp/DynamicXIsland.
        try ingest([Entry(uuid: "a", text: "cormoran attentif", cwd: "/tmp/Dynamic_Island")],
                   sessionID: "session-a", path: "/transcripts/wa.jsonl", inode: 11)
        try ingest([Entry(uuid: "b", text: "cormoran distrait", cwd: "/tmp/DynamicXIsland")],
                   sessionID: "session-b", path: "/transcripts/wb.jsonl", inode: 12)

        let filtered = try index.search(rawQuery: "cormoran", limit: 10,
                                        projectPrefix: "/tmp/Dynamic_Island")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].sessionID, "session-a")

        XCTAssertEqual(MemoryIndex.escapedLikePrefix("a_b%c\\d"), "a\\_b\\%c\\\\d")
    }

    func testPrefixStarQuerySupported() throws {
        try ingest([Entry(uuid: "u1", text: "la géométrie de l'îlot est testée")])

        XCTAssertEqual(try index.search(rawQuery: "géom*", limit: 10, projectPrefix: nil).count, 1)
        // remove_diacritics 2 : le préfixe sans accent matche aussi.
        XCTAssertEqual(try index.search(rawQuery: "geom*", limit: 10, projectPrefix: nil).count, 1)
        // Sans étoile, pas de préfixe implicite : le terme exact seulement.
        XCTAssertTrue(try index.search(rawQuery: "géom", limit: 10, projectPrefix: nil).isEmpty)
    }

    func testSanitizedMatchQueryNeutralizesOperators() throws {
        XCTAssertEqual(MemoryIndex.sanitizedMatchQuery("foo AND bar"),
                       "\"foo\" \"AND\" \"bar\"")
        XCTAssertEqual(MemoryIndex.sanitizedMatchQuery("NOT (a) OR b"),
                       "\"NOT\" \"(a)\" \"OR\" \"b\"")
        XCTAssertEqual(MemoryIndex.sanitizedMatchQuery("col:x ^debut -exclu"),
                       "\"col:x\" \"^debut\" \"-exclu\"")
        // L'étoile finale est la SEULE syntaxe préservée (requête par préfixe).
        XCTAssertEqual(MemoryIndex.sanitizedMatchQuery("géom*"), "\"géom\"*")
        XCTAssertEqual(MemoryIndex.sanitizedMatchQuery("géom**"), "\"géom\"*")
        // Guillemets internes doublés (échappement FTS5).
        XCTAssertEqual(MemoryIndex.sanitizedMatchQuery("a\"b"), "\"a\"\"b\"")
        // Vide et étoiles nues → rien.
        XCTAssertEqual(MemoryIndex.sanitizedMatchQuery(""), "")
        XCTAssertEqual(MemoryIndex.sanitizedMatchQuery("   "), "")
        XCTAssertEqual(MemoryIndex.sanitizedMatchQuery("***"), "")

        // Et surtout : aucune requête brute, si hostile soit-elle, ne doit
        // faire échouer le MATCH une fois sanitizée.
        try ingest([Entry(uuid: "u1", text: "contenu quelconque")])
        for hostile in ["AND", "OR NOT", "NEAR(a b)", "\"", "((", "-", "^", "col:", "a - b"] {
            XCTAssertNoThrow(
                try index.search(rawQuery: hostile, limit: 5, projectPrefix: nil),
                "requête hostile rejetée : \(hostile)"
            )
        }
    }

    // MARK: - Idempotence et fichiers

    func testIngestIsIdempotent() throws {
        let entries = [Entry(uuid: "u1", text: "un contenu unique et stable"),
                       Entry(uuid: "u2", text: "un second message")]
        try ingest(entries)
        let before = try index.stats()
        // Rejeu du même lot (crash simulé avant l'avancée d'offset côté appelant).
        try ingest(entries)
        let after = try index.stats()

        XCTAssertEqual(before.messageCount, 2)
        XCTAssertEqual(after.messageCount, before.messageCount)
        XCTAssertEqual(after.sessionCount, 1)
        // Pas de doublon côté FTS non plus : le trigger AFTER INSERT ne se
        // déclenche pas sur une ligne ignorée par INSERT OR IGNORE.
        XCTAssertEqual(try index.search(rawQuery: "unique", limit: 10, projectPrefix: nil).count, 1)
    }

    func testOpenFileDetectsTruncationAndPurges() throws {
        let state = try ingest([Entry(uuid: "u1", text: "avant troncature")],
                               newOffset: 800)
        XCTAssertEqual(state.offset, 0, "premier passage : lecture depuis 0")

        // Le fichier revient PLUS COURT que l'offset déjà lu : contenu réécrit.
        let reopened = try index.openFile(path: defaultPath, inode: 100, size: 500)
        XCTAssertEqual(reopened.fileID, state.fileID)
        XCTAssertEqual(reopened.offset, 0)
        XCTAssertEqual(try index.stats().messageCount, 0)
        XCTAssertTrue(try index.search(rawQuery: "troncature", limit: 10, projectPrefix: nil).isEmpty,
                      "la purge doit aussi désindexer (trigger messages_ad)")
    }

    func testOpenFileDetectsInodeChange() throws {
        let state = try ingest([Entry(uuid: "u1", text: "avant rotation")],
                               newOffset: 800)

        // Même inode, taille cohérente : l'offset stocké est rendu tel quel.
        let unchanged = try index.openFile(path: defaultPath, inode: 100, size: 900)
        XCTAssertEqual(unchanged.offset, 800)

        // inode différent = nouveau fichier au même chemin (rotation) :
        // purge des messages et relecture complète depuis 0.
        let rotated = try index.openFile(path: defaultPath, inode: 101, size: 2_000)
        XCTAssertEqual(rotated.fileID, state.fileID)
        XCTAssertEqual(rotated.offset, 0)
        XCTAssertEqual(try index.stats().messageCount, 0)
        XCTAssertTrue(try index.search(rawQuery: "rotation", limit: 10, projectPrefix: nil).isEmpty)
    }

    // MARK: - Modes et stats

    func testReadOnlyModeNeverCreatesDatabase() throws {
        let missing = directory.appendingPathComponent("absente.db")
        XCTAssertThrowsError(try MemoryIndex(url: missing, mode: .readOnly))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path),
                       "readOnly ne doit JAMAIS créer de fichier")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path + "-wal"))

        // Sur une base existante, readOnly lit… et ne peut pas écrire.
        try ingest([Entry(uuid: "u1", text: "visible en lecture seule")])
        let reader = try MemoryIndex(url: databaseURL, mode: .readOnly)
        defer { reader.close() }
        XCTAssertEqual(try reader.search(rawQuery: "visible", limit: 5, projectPrefix: nil).count, 1)
        XCTAssertThrowsError(try reader.markMissing(path: defaultPath))
    }

    func testStatsCounts() throws {
        try ingest([Entry(uuid: "u1", text: "premier message"),
                    Entry(uuid: "u2", text: "second message")],
                   sessionID: "session-a", path: "/transcripts/a.jsonl", inode: 1)
        try ingest([Entry(uuid: "u3", text: "troisième message")],
                   sessionID: "session-b", path: "/transcripts/b.jsonl", inode: 2)

        let stats = try index.stats()
        XCTAssertEqual(stats.sessionCount, 2)
        XCTAssertEqual(stats.messageCount, 3)
        XCTAssertGreaterThan(stats.databaseBytes, 0)
    }

    func testSessionUpsertKeepsEarliestFirstAndLatestLastTimestamp() throws {
        try ingest([Entry(uuid: "u1", text: "milieu",
                          timestamp: Date(timeIntervalSince1970: 2_000))],
                   newOffset: 100)
        // Second lot : un timestamp plus ancien ET un plus récent — les bornes
        // doivent s'élargir dans les deux sens, jamais rétrécir.
        try ingest([Entry(uuid: "u2", text: "plus tôt",
                          timestamp: Date(timeIntervalSince1970: 1_000)),
                    Entry(uuid: "u3", text: "plus tard",
                          timestamp: Date(timeIntervalSince1970: 3_000))],
                   newOffset: 300)

        let bounds = try XCTUnwrap(try index.sessionTimeBounds(sessionID: "session-1"))
        XCTAssertEqual(bounds.first, 1_000)
        XCTAssertEqual(bounds.last, 3_000)
    }

    // MARK: - Usage des skills

    func testRecordAndQuerySkillUsage() throws {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)
        try index.recordSkillUsage([
            SkillInvocation(toolUseID: "toolu_1", skill: "atoll-recall",
                            sessionID: "s1", timestamp: early),
            SkillInvocation(toolUseID: "toolu_2", skill: "atoll-recall",
                            sessionID: "s2", timestamp: late),
            // Doublon d'uuid (rejeu du même bloc) : INSERT OR IGNORE le neutralise.
            SkillInvocation(toolUseID: "toolu_1", skill: "atoll-recall",
                            sessionID: "s1", timestamp: early),
        ])

        let stats = try index.skillUsage()
        XCTAssertEqual(stats.count, 1)
        let stat = try XCTUnwrap(stats.first)
        XCTAssertEqual(stat.skill, "atoll-recall")
        XCTAssertEqual(stat.count, 2, "le doublon d'uuid ne compte qu'une fois")
        XCTAssertEqual(stat.lastUsed, late, "lastUsed = MAX(ts)")

        // Rejeu du lot COMPLET (crash simulé côté appelant) : rien ne bouge.
        try index.recordSkillUsage([
            SkillInvocation(toolUseID: "toolu_2", skill: "atoll-recall",
                            sessionID: "s2", timestamp: late),
        ])
        XCTAssertEqual(try index.skillUsage().first?.count, 2)
    }

    func testSkillUsagePrefixFilter() throws {
        try index.recordSkillUsage([
            SkillInvocation(toolUseID: "a", skill: "atoll-recall", sessionID: nil, timestamp: nil),
            SkillInvocation(toolUseID: "b", skill: "atoll-notch", sessionID: nil, timestamp: nil),
            SkillInvocation(toolUseID: "c", skill: "commit", sessionID: nil, timestamp: nil),
        ])

        let all = try index.skillUsage()
        XCTAssertEqual(all.count, 3)

        let filtered = try index.skillUsage(prefix: "atoll-")
        XCTAssertEqual(filtered.map(\.skill).sorted(), ["atoll-notch", "atoll-recall"])
        // Sans timestamp, la ligne compte mais ne date pas : lastUsed nil.
        XCTAssertEqual(filtered.first?.lastUsed, nil)

        // Jokers LIKE neutralisés (escapedLikePrefix) : « atoll_ » est le
        // littéral underscore, pas « atoll + n'importe quel caractère ».
        XCTAssertTrue(try index.skillUsage(prefix: "atoll_").isEmpty)
    }
}
