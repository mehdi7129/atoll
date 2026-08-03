import XCTest
@testable import AtollCore

/// Le bruit machine hors de la mémoire — filtre à l'entrée, purge de l'existant,
/// et fermeture de la boucle côté recall proactif.
///
/// Défaut mesuré le 2026-08-03 : 134 enveloppes `<task-notification>` indexées
/// comme messages `user`, soit **17 % de tout le corpus `user`** — or `user` ne
/// pèse que 792 messages sur 34 785, ce sont les plus rares et les seuls à
/// porter une intention.
final class MemoryHygieneTests: XCTestCase {

    // MARK: - Le filtre à l'ingestion

    private func line(_ json: String) -> TranscriptLine? {
        TranscriptLineParser.parse(Data(json.utf8))
    }

    /// La forme EXACTE relevée dans les transcripts (CLI 2.1.220).
    func testTaskNotificationYieldsNoFragment() {
        let parsed = line("""
        {"type":"user","uuid":"u1","sessionId":"s","origin":{"kind":"task-notification"},
         "promptSource":"system",
         "message":{"role":"user","content":"<task-notification>\\n<task-id>abc</task-id>\\n</task-notification>"}}
        """)
        XCTAssertTrue(parsed?.fragments.isEmpty ?? false,
                      "une notification de tâche n'a jamais été tapée par personne")
    }

    /// L'ENVELOPPE reste rendue : `SessionDigest` continue d'élargir les bornes
    /// temporelles de la session — c'est le même contrat que `isMeta`.
    func testEnvelopeSurvivesEvenWhenFragmentsAreDropped() {
        let parsed = line("""
        {"type":"user","uuid":"u1","sessionId":"sess-42","cwd":"/tmp/p",
         "origin":{"kind":"task-notification"},
         "message":{"role":"user","content":"<task-notification>x</task-notification>"}}
        """)
        XCTAssertEqual(parsed?.sessionID, "sess-42")
        XCTAssertEqual(parsed?.cwd, "/tmp/p")
    }

    /// Un VRAI message reste indexé, même s'il parle de ces enveloppes — c'est
    /// le cas de la conversation qui a produit ce correctif.
    func testRealPromptMentioningTheEnvelopeIsKept() {
        let parsed = line("""
        {"type":"user","uuid":"u2","sessionId":"s",
         "message":{"role":"user","content":"il faut filtrer les <task-notification> de l'index"}}
        """)
        XCTAssertEqual(parsed?.fragments.count, 1)
        XCTAssertTrue(parsed?.fragments.first?.text.contains("filtrer") ?? false)
    }

    /// `promptSource == "system"` a été ÉCARTÉ comme discriminant : sur 1 513
    /// transcripts, 129 lignes le portent et DEUX sont de vraies instructions.
    func testPromptSourceSystemAloneIsNotEnoughToDrop() {
        let parsed = line("""
        {"type":"user","uuid":"u3","sessionId":"s","promptSource":"system",
         "message":{"role":"user","content":"reprends le travail là où tu t'étais arrêté"}}
        """)
        XCTAssertEqual(parsed?.fragments.count, 1, "une vraie instruction ne doit pas disparaître")
    }

    /// Décodage défensif : une forme inattendue n'exclut RIEN — mieux vaut un
    /// peu de bruit qu'une intention perdue.
    func testUnknownOriginShapesNeverDrop() {
        for origin in ["\"origin\":null", "\"origin\":123", "\"origin\":{\"autre\":\"x\"}",
                       "\"origin\":{\"kind\":\"inconnu\"}", "\"origin\":\"autre\""] {
            let parsed = line("""
            {"type":"user","uuid":"u","sessionId":"s",\(origin),
             "message":{"role":"user","content":"un vrai message de l'utilisateur"}}
            """)
            XCTAssertEqual(parsed?.fragments.count, 1, "origin=\(origin)")
        }
    }

    /// …mais la forme CHAÎNE du discriminant est bien reconnue.
    func testStringOriginIsAlsoRecognised() {
        let parsed = line("""
        {"type":"user","uuid":"u","sessionId":"s","origin":"task-notification",
         "message":{"role":"user","content":"<task-notification>x</task-notification>"}}
        """)
        XCTAssertTrue(parsed?.fragments.isEmpty ?? false)
    }

    // MARK: - La purge de l'existant

    private var directory: URL!
    private var index: MemoryIndex!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryHygiene-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        index = try MemoryIndex(url: directory.appendingPathComponent("index.db"), mode: .readWrite)
    }

    override func tearDownWithError() throws {
        index?.close()
        index = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func ingest(_ texts: [String]) throws {
        let state = try index.openFile(path: "/transcripts/s.jsonl", inode: 1, size: 1_000)
        let lines = texts.enumerated().map { offset, text in
            (line: TranscriptLine(uuid: "u\(offset)", sessionID: "sess",
                                  timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                                  cwd: "/tmp/projet", gitBranch: nil,
                                  fragments: [.init(role: .user, text: text)]),
             syntheticUUID: "u\(offset)")
        }
        try index.ingest(lines: lines, fileState: state, sessionID: "sess",
                         projectDir: "-projet", newOffset: 1_000)
    }

    func testHygieneRemovesAlreadyIndexedNotifications() throws {
        try ingest([
            "<task-notification>\n<task-id>abc</task-id>\n</task-notification>",
            "voici un vrai message que je veux garder",
            "<task-notification>autre</task-notification>",
        ])
        XCTAssertEqual(try index.runHygieneIfNeeded(), 2)
        let rest = try index.searchRelaxing(rawQuery: "task notification message",
                                            limit: 10, projectPrefix: nil)
        XCTAssertEqual(rest.hits.count, 1)
        XCTAssertTrue(rest.hits[0].snippet.contains("vrai"))
    }

    /// LE PIÈGE À NE PAS COMMETTRE : déclencher la purge par `user_version`
    /// ferait passer `migrateIfNeeded` par `recreateFromScratch`, qui supprime
    /// la base — et 548 messages appartiennent à des transcripts DISPARUS du
    /// disque, donc irrécupérables. Le compteur vit dans `application_id`.
    func testHygieneNeverTouchesTheSchemaVersion() throws {
        try ingest(["<task-notification>x</task-notification>", "un vrai message"])
        _ = try index.runHygieneIfNeeded()
        XCTAssertEqual(try index.storedSchemaVersion(), MemoryIndex.schemaVersion)
        XCTAssertEqual(try index.storedHygieneVersion(), MemoryIndex.hygieneVersion)
    }

    func testHygieneRunsOnlyOnce() throws {
        try ingest(["<task-notification>x</task-notification>", "un vrai message"])
        XCTAssertEqual(try index.runHygieneIfNeeded(), 1)
        XCTAssertEqual(try index.runHygieneIfNeeded(), 0, "second passage : rien à faire")
    }

    /// Ancrage au DÉBUT : un message qui cite l'enveloppe au milieu d'une phrase
    /// est une vraie prose et doit survivre à la purge.
    func testHygieneSparesProseThatMentionsTheEnvelope() throws {
        try ingest(["il faut filtrer les <task-notification> qui polluent l'index"])
        XCTAssertEqual(try index.runHygieneIfNeeded(), 0)
    }

    // MARK: - La boucle refermée

    func testProactiveRecallIgnoresMachineEnvelopes() {
        let notification = """
        <task-notification>
        <task-id>wimnlwuwy</task-id>
        <tool-use-id>toolu_01MkJwhvG9BzMrxRNdBq1Nkk</tool-use-id>
        </task-notification>
        """
        XCTAssertFalse(ProactiveRecall.shouldRecall(prompt: notification))
        XCTAssertNil(ProactiveRecall.query(fromPrompt: notification))
        XCTAssertFalse(ProactiveRecall.shouldRecall(
            prompt: "<system-reminder>fais attention à ceci</system-reminder>"))
    }

    /// …et un vrai prompt qui PARLE de ces balises garde son recall.
    func testProactiveRecallStillWorksWhenTheUserMentionsThem() {
        XCTAssertTrue(ProactiveRecall.shouldRecall(
            prompt: "comment filtrer les <task-notification> dans l'index mémoire d'Atoll ?"))
    }
}
