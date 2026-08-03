import XCTest
@testable import AtollCore

/// La recherche élargie : ce qui rend la mémoire d'Atoll utilisable, et le
/// garde-fou qui empêche qu'elle devienne bavarde.
///
/// Défaut mesuré le 2026-08-03 : l'index contenait 8 135 messages contenant
/// « drone » et rendait **zéro** résultat pour « drone Houdini trajectoire »,
/// parce que le mode `.all` exige que les trois mots tiennent dans le MÊME
/// fragment (404 caractères en moyenne).
final class MemoryRelaxedSearchTests: XCTestCase {

    // MARK: - Découpe de la requête

    func testQueryTermsSplitsOnWhitespace() {
        XCTAssertEqual(MemoryIndex.queryTerms("drone Houdini trajectoire"),
                       ["drone", "Houdini", "trajectoire"])
    }

    func testQueryTermsStripsPrefixStars() {
        XCTAssertEqual(MemoryIndex.queryTerms("géom* trajecto**"), ["géom", "trajecto"])
    }

    func testQueryTermsIgnoresEmptyTokens() {
        XCTAssertEqual(MemoryIndex.queryTerms("   drone \n\t  *  "), ["drone"])
    }

    // MARK: - Couverture

    private func hit(_ snippet: String, rank: Double = -1) -> MemoryIndex.Hit {
        MemoryIndex.Hit(sessionID: "s", projectPath: nil, projectDir: "d", title: nil,
                        role: "user", timestamp: nil, snippet: snippet, rank: rank, dedupKey: "")
    }

    func testCoverageCountsDistinctTerms() {
        let terms = ["drone", "houdini", "trajectoire"]
        XCTAssertEqual(MemoryRanking.coverage(of: hit("les «drone»s en «houdini»"), terms: terms), 2)
        XCTAssertEqual(MemoryRanking.coverage(of: hit("rien à voir"), terms: terms), 0)
    }

    /// L'index est en `unicode61 remove_diacritics 2` : la couverture doit lire
    /// comme lui, sinon « trajectoire » ne compterait pas pour « TRAJECTOIRE »
    /// ni « géométrie » pour « geometrie ».
    func testCoverageIgnoresCaseAndDiacritics() {
        XCTAssertEqual(MemoryRanking.coverage(of: hit("La «TRAJECTOIRE» est «Géométrique»"),
                                              terms: ["trajectoire", "geometrique"]), 2)
    }

    /// LE point du tri : un extrait qui couvre deux mots sur trois doit passer
    /// devant un extrait qui n'en couvre qu'un — mesuré avant correction, le
    /// second occupait la 5ᵉ place sur 8.
    func testByCoveragePutsTheMostCoveringFirst() {
        let terms = ["drone", "houdini", "trajectoire"]
        let un = hit("un «drone»")
        let deux = hit("le «drone» sous «houdini»")
        let trois = hit("«drone» «houdini» «trajectoire»")
        let sorted = MemoryRanking.byCoverage([un, deux, trois], terms: terms)
        XCTAssertEqual(sorted.map(\.snippet), [trois.snippet, deux.snippet, un.snippet])
    }

    /// À couverture ÉGALE, l'ordre d'entrée est préservé — c'est lui qui porte
    /// le classement bm25 + récence, il ne doit pas être détruit.
    func testByCoverageIsStableAtEqualCoverage() {
        let terms = ["drone"]
        let a = hit("premier «drone»"), b = hit("second «drone»"), c = hit("tiers «drone»")
        XCTAssertEqual(MemoryRanking.byCoverage([a, b, c], terms: terms).map(\.snippet),
                       [a.snippet, b.snippet, c.snippet])
    }

    func testByCoverageIsANoOpWithoutTerms() {
        let a = hit("x"), b = hit("y")
        XCTAssertEqual(MemoryRanking.byCoverage([a, b], terms: []).map(\.snippet), ["x", "y"])
    }

    // MARK: - Le repli, sur une vraie base

    private var directory: URL!
    private var index: MemoryIndex!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryRelaxed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        index = try MemoryIndex(url: directory.appendingPathComponent("index.db"), mode: .readWrite)
    }

    override func tearDownWithError() throws {
        index?.close()
        index = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// Même chemin nominal que l'appelant réel : openFile → ingest(newOffset).
    private func ingest(_ texts: [String]) throws {
        let state = try index.openFile(path: "/transcripts/s.jsonl", inode: 1, size: 1_000)
        let lines = texts.enumerated().map { offset, text in
            (line: TranscriptLine(uuid: "u\(offset)",
                                  sessionID: "sess",
                                  timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset)),
                                  cwd: "/tmp/projet",
                                  gitBranch: nil,
                                  fragments: [.init(role: .user, text: text)]),
             syntheticUUID: "u\(offset)")
        }
        try index.ingest(lines: lines, fileState: state, sessionID: "sess",
                         projectDir: "-projet", newOffset: 1_000)
    }

    /// Le cas de Mehdi, reproduit : trois mots répartis sur trois messages.
    /// En strict, rien. Élargi, on trouve — et on le DIT.
    func testRelaxesOnlyWhenStrictFindsNothing() throws {
        try ingest([
            "le drone décolle à la seconde 12",
            "Houdini exporte les points",
            "la trajectoire est lissée",
        ])

        let relaxed = try index.searchRelaxing(rawQuery: "drone Houdini trajectoire",
                                               limit: 8, projectPrefix: nil)
        XCTAssertTrue(relaxed.relaxed, "l'élargissement doit être annoncé")
        XCTAssertFalse(relaxed.hits.isEmpty, "8 135 messages « drone » et zéro résultat : le défaut")
    }

    /// …et la recherche PRÉCISE qui marche ne doit surtout pas être diluée.
    func testStrictHitsAreNeverRelaxed() throws {
        try ingest([
            "la notarisation de l'appcast a réussi",
            "appcast tout seul",
            "notarisation toute seule",
        ])

        let result = try index.searchRelaxing(rawQuery: "notarisation appcast",
                                              limit: 8, projectPrefix: nil)
        XCTAssertFalse(result.relaxed, "le strict a répondu : aucun élargissement")
        XCTAssertEqual(result.hits.count, 1, "seul le message contenant LES DEUX mots")
    }

    /// Rien d'un côté, rien de l'autre : ne pas annoncer un élargissement qui
    /// n'a rien donné — le bandeau serait un mensonge de plus.
    func testEmptyResultIsNeverFlaggedAsRelaxed() throws {
        try ingest(["un texte sans rapport"])

        let result = try index.searchRelaxing(rawQuery: "bluetooth intermittent",
                                              limit: 8, projectPrefix: nil)
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertFalse(result.relaxed)
    }

    /// Le repli est sur ZÉRO, jamais sur « peu de résultats » : un seul résultat
    /// strict suffit à interdire l'élargissement.
    func testASingleStrictHitBlocksRelaxation() throws {
        try ingest([
            "alpha bêta ensemble",
            "alpha tout seul", "alpha encore", "bêta tout seul", "bêta encore",
        ])

        let result = try index.searchRelaxing(rawQuery: "alpha bêta", limit: 8, projectPrefix: nil)
        XCTAssertFalse(result.relaxed)
        XCTAssertEqual(result.hits.count, 1)
    }
}
