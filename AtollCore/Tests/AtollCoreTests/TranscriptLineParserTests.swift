import XCTest
@testable import AtollCore

final class TranscriptLineParserTests: XCTestCase {

    private func parse(_ json: String) -> TranscriptLine? {
        TranscriptLineParser.parse(Data(json.utf8))
    }

    // MARK: - Fixtures

    /// Ligne user réelle simplifiée : content est une String directe.
    private var userStringLine: String {
        """
        {"type":"user","uuid":"u-1","sessionId":"s-1","timestamp":"2026-07-19T15:07:03.869Z",\
        "cwd":"/Users/x/proj","gitBranch":"main",\
        "message":{"role":"user","content":"Corrige le bug du quota figé"}}
        """
    }

    /// Ligne user en blocs : un bloc text + un bloc image (à ignorer).
    private var userBlocksLine: String {
        """
        {"type":"user","uuid":"u-2","sessionId":"s-1",\
        "message":{"role":"user","content":[\
        {"type":"text","text":"Regarde la capture"},\
        {"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0KGgo="}}\
        ]}}
        """
    }

    /// Ligne assistant : thinking puis text, dans cet ordre.
    private var assistantThinkingAndTextLine: String {
        """
        {"type":"assistant","uuid":"u-3","sessionId":"s-1",\
        "message":{"role":"assistant","content":[\
        {"type":"thinking","thinking":"Je dois vérifier la géométrie du notch avant."},\
        {"type":"text","text":"Voici le correctif."}\
        ]}}
        """
    }

    /// Ligne assistant tool_use : seule la valeur String de input doit ressortir.
    private var toolUseBashLine: String {
        """
        {"type":"assistant","uuid":"u-5",\
        "message":{"content":[\
        {"type":"tool_use","id":"tu-1","name":"Bash",\
        "input":{"command":"git status","timeout":5000,"run_in_background":false}}\
        ]}}
        """
    }

    // MARK: - user

    func testParseUserStringContent() throws {
        let line = try XCTUnwrap(parse(userStringLine))
        XCTAssertEqual(line.uuid, "u-1")
        XCTAssertEqual(line.sessionID, "s-1")
        XCTAssertEqual(line.cwd, "/Users/x/proj")
        XCTAssertEqual(line.gitBranch, "main")
        XCTAssertNotNil(line.timestamp)
        XCTAssertEqual(line.fragments, [
            TranscriptLine.Fragment(role: .user, text: "Corrige le bug du quota figé"),
        ])
    }

    func testParseUserBlocksTextOnly() throws {
        let line = try XCTUnwrap(parse(userBlocksLine))
        // Le bloc image est ignoré, seul le bloc text devient un fragment.
        XCTAssertEqual(line.fragments, [
            TranscriptLine.Fragment(role: .user, text: "Regarde la capture"),
        ])
    }

    // MARK: - assistant

    func testParseAssistantTextAndThinkingBlocks() throws {
        let line = try XCTUnwrap(parse(assistantThinkingAndTextLine))
        XCTAssertEqual(line.fragments, [
            TranscriptLine.Fragment(role: .thinking, text: "Je dois vérifier la géométrie du notch avant."),
            TranscriptLine.Fragment(role: .assistant, text: "Voici le correctif."),
        ])
    }

    func testThinkingTruncatedAtCap() throws {
        // 4 800 caractères AVEC espaces (pour passer le filtre anti-blob) → cap 4 000.
        let thinking = String(repeating: "abc ", count: 1_200)
        let json = """
        {"type":"assistant","uuid":"u-4",\
        "message":{"content":[{"type":"thinking","thinking":"\(thinking)"}]}}
        """
        let line = try XCTUnwrap(parse(json))
        let fragment = try XCTUnwrap(line.fragments.first)
        XCTAssertEqual(fragment.role, .thinking)
        XCTAssertEqual(fragment.text.count, 4_000)
        XCTAssertTrue(fragment.text.hasPrefix("abc abc "))
    }

    func testParseToolUseBashCommand() throws {
        let line = try XCTUnwrap(parse(toolUseBashLine))
        // Format « nom · valeurs » ; timeout (nombre) et run_in_background (bool)
        // ne sont pas des String → écartés.
        XCTAssertEqual(line.fragments, [
            TranscriptLine.Fragment(role: .tool, text: "Bash · git status"),
        ])
    }

    func testParseToolResultConcatenatedAndTruncated() throws {
        // Deuxième partie de 2 000 caractères avec espaces → concaténation cap 1 500.
        let longPart = String(repeating: "x y ", count: 500)
        let json = """
        {"type":"user","uuid":"u-6",\
        "message":{"content":[\
        {"type":"tool_result","tool_use_id":"tu-1","content":[\
        {"type":"text","text":"première partie"},\
        {"type":"text","text":"\(longPart)"}\
        ]},\
        {"type":"tool_result","tool_use_id":"tu-2","content":"sortie simple"}\
        ]}}
        """
        let line = try XCTUnwrap(parse(json))
        XCTAssertEqual(line.fragments.count, 2)

        let first = try XCTUnwrap(line.fragments.first)
        XCTAssertEqual(first.role, .toolResult)
        XCTAssertEqual(first.text.count, 1_500)
        XCTAssertTrue(first.text.hasPrefix("première partie\n"))

        // content en String directe : même rôle, même traitement.
        XCTAssertEqual(line.fragments.last,
                       TranscriptLine.Fragment(role: .toolResult, text: "sortie simple"))
    }

    // MARK: - Bruit écarté

    func testSkipsIsMetaUserLine() throws {
        let json = """
        {"type":"user","isMeta":true,"uuid":"u-7","sessionId":"s-7","cwd":"/tmp/p",\
        "message":{"content":"Caveat: the messages below were generated by the user"}}
        """
        let line = try XCTUnwrap(parse(json), "l'enveloppe d'une ligne isMeta reste utile")
        XCTAssertTrue(line.fragments.isEmpty)
        XCTAssertEqual(line.uuid, "u-7")
        XCTAssertEqual(line.cwd, "/tmp/p")
    }

    func testSkipsNonConversationalTypes() {
        // Types réels observés dans les transcripts, tous sans valeur mémorielle.
        let types = ["system", "last-prompt", "attachment", "mode", "permission-mode",
                     "file-history-snapshot", "file-history-delta", "queue-operation", "progress"]
        for type in types {
            XCTAssertNil(parse("""
            {"type":"\(type)","uuid":"u-8","sessionId":"s-8","content":"peu importe"}
            """), "type \(type) doit être écarté")
        }
    }

    func testUnknownTypeReturnsNil() {
        XCTAssertNil(parse(#"{"type":"telepathy","uuid":"u-9"}"#), "type inconnu")
        XCTAssertNil(parse(#"{"uuid":"u-9","message":{"content":"salut"}}"#), "type absent")
        XCTAssertNil(parse(#"{"type":42,"uuid":"u-9"}"#), "type non-String")
    }

    func testInvalidJSONReturnsNil() {
        XCTAssertNil(parse("pas du json"))
        XCTAssertNil(parse(#"{"type":"user","tronqué"#))
        XCTAssertNil(parse("[1,2,3]"), "un tableau n'est pas une ligne")
        XCTAssertNil(TranscriptLineParser.parse(Data()))
    }

    func testSessionIdSnakeCaseFallback() throws {
        let snakeOnly = try XCTUnwrap(parse("""
        {"type":"summary","summary":"Résumé","session_id":"snake-1"}
        """))
        XCTAssertEqual(snakeOnly.sessionID, "snake-1")

        // Les deux graphies présentes → camelCase prioritaire.
        let both = try XCTUnwrap(parse("""
        {"type":"summary","summary":"Résumé","sessionId":"camel-1","session_id":"snake-1"}
        """))
        XCTAssertEqual(both.sessionID, "camel-1")
    }

    func testSkipsBase64LikeString() throws {
        // 320 caractères sans aucune espace → heuristique anti-blob.
        let blob = String(repeating: "QUJD", count: 80)
        let line = try XCTUnwrap(parse("""
        {"type":"user","uuid":"u-10","message":{"content":"\(blob)"}}
        """))
        XCTAssertTrue(line.fragments.isEmpty, "un blob sans espace > 256 car. est écarté")

        // Une URL sans espace mais courte (≤ 256) reste indexable.
        let url = try XCTUnwrap(parse("""
        {"type":"user","uuid":"u-11","message":{"content":"https://github.com/mehdi7129/atoll"}}
        """))
        XCTAssertEqual(url.fragments.first?.text, "https://github.com/mehdi7129/atoll")
    }

    func testSkipsCommandNoise() throws {
        // Échos des slash-commands : String directe et bloc text, même filtre.
        let direct = try XCTUnwrap(parse("""
        {"type":"user","uuid":"u-12",\
        "message":{"content":"<command-name>/clear</command-name>"}}
        """))
        XCTAssertTrue(direct.fragments.isEmpty)

        let block = try XCTUnwrap(parse("""
        {"type":"user","uuid":"u-13",\
        "message":{"content":[{"type":"text","text":"<local-command-stdout>ok</local-command-stdout>"}]}}
        """))
        XCTAssertTrue(block.fragments.isEmpty)
    }

    // MARK: - summary / ai-title

    func testSummaryAndAiTitleFragments() throws {
        let summary = try XCTUnwrap(parse("""
        {"type":"summary","summary":"Refonte du quota par modèle","leafUuid":"u-14"}
        """))
        XCTAssertEqual(summary.fragments, [
            TranscriptLine.Fragment(role: .summary, text: "Refonte du quota par modèle"),
        ])

        let aiTitle = try XCTUnwrap(parse("""
        {"type":"ai-title","aiTitle":"Quota figé corrigé","sessionId":"s-14"}
        """))
        XCTAssertEqual(aiTitle.fragments, [
            TranscriptLine.Fragment(role: .title, text: "Quota figé corrigé"),
        ])

        // Graphie de repli « title », acceptée défensivement.
        let plainTitle = try XCTUnwrap(parse("""
        {"type":"ai-title","title":"Titre de secours"}
        """))
        XCTAssertEqual(plainTitle.fragments, [
            TranscriptLine.Fragment(role: .title, text: "Titre de secours"),
        ])

        // Champ attendu absent → enveloppe conservée, fragments vide (pas nil).
        let empty = try XCTUnwrap(parse(#"{"type":"summary","leafUuid":"u-15"}"#))
        XCTAssertTrue(empty.fragments.isEmpty)
    }

    // MARK: - Timestamps

    func testTimestampFractionalAndPlainISO8601() throws {
        let fractional = try XCTUnwrap(parse("""
        {"type":"summary","summary":"a b","timestamp":"2026-07-19T15:07:03.869Z"}
        """))
        let plain = try XCTUnwrap(parse("""
        {"type":"summary","summary":"a b","timestamp":"2026-07-19T15:07:03Z"}
        """))
        let withMillis = try XCTUnwrap(fractional.timestamp)
        let seconds = try XCTUnwrap(plain.timestamp)
        XCTAssertEqual(withMillis.timeIntervalSince(seconds), 0.869, accuracy: 0.001)

        // Horodatage illisible → nil, la ligne survit (parsing défensif).
        let garbage = try XCTUnwrap(parse("""
        {"type":"summary","summary":"a b","timestamp":"hier soir"}
        """))
        XCTAssertNil(garbage.timestamp)
    }
}
