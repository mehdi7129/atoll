import XCTest
@testable import AtollCore

final class SkillUsageParserTests: XCTestCase {

    // MARK: - Fixtures

    /// Ligne assistant nominale, calquée sur le format vérifié en vrai :
    /// un bloc tool_use `Skill` au milieu d'un bloc texte.
    private var assistantSkillLine: Data {
        Data("""
        {"type":"assistant","sessionId":"sess-1","timestamp":"2026-07-19T15:07:03.869Z",
         "message":{"content":[
            {"type":"text","text":"Je lance le skill."},
            {"type":"tool_use","id":"toolu_01","name":"Skill",
             "input":{"skill":"atoll-recall","args":"quota"}}
         ]}}
        """.utf8)
    }

    /// Deux invocations du MÊME skill dans une seule ligne, ids distincts,
    /// plus une troisième sans `id` du tout.
    private var multiBlockLine: Data {
        Data("""
        {"type":"assistant","session_id":"sess-2",
         "message":{"content":[
            {"type":"tool_use","id":"toolu_a","name":"Skill","input":{"skill":"commit"}},
            {"type":"thinking","thinking":"réflexion intermédiaire"},
            {"type":"tool_use","id":"toolu_b","name":"Skill","input":{"skill":"commit"}},
            {"type":"tool_use","name":"Skill","input":{"skill":"commit"}}
         ]}}
        """.utf8)
    }

    // MARK: - Chemin nominal

    func testParsesSkillToolUse() throws {
        let invocations = SkillUsageParser.invocations(inLine: assistantSkillLine)

        XCTAssertEqual(invocations.count, 1)
        let invocation = try XCTUnwrap(invocations.first)
        XCTAssertEqual(invocation.toolUseID, "toolu_01")
        XCTAssertEqual(invocation.skill, "atoll-recall")
        XCTAssertEqual(invocation.sessionID, "sess-1")
        // 2026-07-19T15:07:03.869Z, fractions de seconde comprises.
        let expected = try XCTUnwrap(invocation.timestamp)
        XCTAssertEqual(expected.timeIntervalSince1970, 1_784_473_623.869, accuracy: 0.001)
    }

    func testParsesMultipleBlocksInOneLine() {
        let invocations = SkillUsageParser.invocations(inLine: multiBlockLine)

        // Les blocs non-tool_use sont ignorés ; les trois Skill sortent tous,
        // dans l'ordre du transcript — la graphie session_id est acceptée.
        XCTAssertEqual(invocations.map(\.skill), ["commit", "commit", "commit"])
        XCTAssertEqual(invocations.map(\.toolUseID), ["toolu_a", "toolu_b", ""])
        XCTAssertEqual(invocations.map(\.sessionID), ["sess-2", "sess-2", "sess-2"])
        XCTAssertEqual(invocations.map(\.timestamp), [nil, nil, nil])
    }

    // MARK: - Filtrage défensif

    func testIgnoresNonSkillToolUse() {
        // Un tool_use ordinaire (Bash), un Skill sans input.skill, un Skill au
        // skill vide, un skill d'un autre type, un bloc parasite non-objet :
        // aucun ne doit produire d'invocation — et aucun ne doit faire planter.
        let line = Data("""
        {"type":"assistant","message":{"content":[
            {"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"ls"}},
            {"type":"tool_use","id":"toolu_2","name":"Skill","input":{"args":"x"}},
            {"type":"tool_use","id":"toolu_3","name":"Skill","input":{"skill":""}},
            {"type":"tool_use","id":"toolu_4","name":"Skill","input":{"skill":42}},
            {"type":"tool_use","id":"toolu_5","name":"Skill"},
            "bloc parasite",
            {"type":"tool_use","id":"toolu_6","name":"Skill","input":{"skill":"valide"}}
        ]}}
        """.utf8)

        let invocations = SkillUsageParser.invocations(inLine: line)
        XCTAssertEqual(invocations.map(\.skill), ["valide"],
                       "seul le bloc valide survit, les autres s'effacent en silence")
    }

    func testIgnoresUserAndSystemLines() {
        // Même un bloc Skill parfaitement formé ne compte pas hors d'une ligne
        // assistant — les échos côté user/system ne sont pas des invocations.
        let block = """
        {"type":"tool_use","id":"toolu_1","name":"Skill","input":{"skill":"commit"}}
        """
        for type in ["user", "system", "summary", "progress"] {
            let line = Data("""
            {"type":"\(type)","message":{"content":[\(block)]}}
            """.utf8)
            XCTAssertTrue(SkillUsageParser.invocations(inLine: line).isEmpty,
                          "type \(type) : aucune invocation attendue")
        }
        // Sans champ type du tout : rien non plus.
        let untyped = Data("""
        {"message":{"content":[\(block)]}}
        """.utf8)
        XCTAssertTrue(SkillUsageParser.invocations(inLine: untyped).isEmpty)
    }

    func testIgnoresMalformedJSON() {
        let malformed: [Data] = [
            Data("pas du JSON".utf8),
            Data("{tronqué".utf8),
            Data("[1, 2, 3]".utf8),                      // JSON valide mais pas un objet
            Data("\"une chaîne\"".utf8),
            Data(),                                       // ligne vide
            Data("{\"type\":\"assistant\"}".utf8),        // sans message
            Data("{\"type\":\"assistant\",\"message\":{\"content\":\"texte\"}}".utf8), // content non-tableau
            Data("{\"type\":\"assistant\",\"message\":\"plat\"}".utf8),
        ]
        for line in malformed {
            XCTAssertTrue(SkillUsageParser.invocations(inLine: line).isEmpty,
                          "ligne illisible → [] : \(String(decoding: line, as: UTF8.self))")
        }
    }

    // MARK: - Identité

    func testDedupeKeyIsToolUseID() {
        // Deux invocations du même skill dans la même ligne restent DEUX
        // invocations distinctes : l'identité est l'id du bloc tool_use, pas le
        // nom du skill — c'est elle qui portera la dédup en base (uuid PK).
        let invocations = SkillUsageParser.invocations(inLine: multiBlockLine)
        XCTAssertEqual(invocations.count, 3)
        XCTAssertEqual(invocations[0].skill, invocations[1].skill)
        XCTAssertNotEqual(invocations[0].toolUseID, invocations[1].toolUseID)
        // id absent → toolUseID vide : rendu quand même (au stockage de trancher).
        XCTAssertEqual(invocations[2].toolUseID, "")
    }
}
