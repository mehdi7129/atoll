import XCTest
@testable import AtollCore

final class TranscriptHistoryTests: XCTestCase {

    private func window(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    private func parse(_ lines: [String], maxTurns: Int = 12, dropFirst: Bool = false) -> [TranscriptHistory.HistoryTurn] {
        TranscriptHistory.parse(window: window(lines), dropFirstLine: dropFirst, maxTurns: maxTurns)
    }

    // Formes réelles v2.1.214 (anonymisées).
    private let realUser = #"{"type":"user","sessionId":"s","timestamp":"2026-07-19T10:00:00Z","message":{"role":"user","content":"Corrige le bug des quotas"}}"#
    private let realAssistantText = #"{"type":"assistant","message":{"id":"msg_1","role":"assistant","content":[{"type":"text","text":"Je regarde le wrapper statusline."}]}}"#

    func testExtractsRealExchange() {
        let turns = parse([realUser, realAssistantText])
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].role, .user)
        XCTAssertEqual(turns[0].text, "Corrige le bug des quotas")
        XCTAssertEqual(turns[1].role, .assistant)
        XCTAssertEqual(turns[1].text, "Je regarde le wrapper statusline.")
    }

    func testGroupsAssistantLinesSharingMessageID() {
        // Une réponse = plusieurs lignes JSONL (un bloc par ligne), même message.id.
        let thinking = #"{"type":"assistant","message":{"id":"msg_2","content":[{"type":"thinking","thinking":"hmm"}]}}"#
        let part1 = #"{"type":"assistant","message":{"id":"msg_2","content":[{"type":"text","text":"Première partie."}]}}"#
        let toolUse = #"{"type":"assistant","message":{"id":"msg_2","content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#
        let part2 = #"{"type":"assistant","message":{"id":"msg_2","content":[{"type":"text","text":"Seconde partie."}]}}"#
        let turns = parse([realUser, thinking, part1, toolUse, part2])
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[1].text, "Première partie.\nSeconde partie.")
    }

    func testSeparateMessageIDsMakeSeparateTurns() {
        let a1 = #"{"type":"assistant","message":{"id":"msg_a","content":[{"type":"text","text":"Réponse A"}]}}"#
        let a2 = #"{"type":"assistant","message":{"id":"msg_b","content":[{"type":"text","text":"Réponse B"}]}}"#
        let turns = parse([a1, a2])
        XCTAssertEqual(turns.map(\.text), ["Réponse A", "Réponse B"])
    }

    func testFiltersNonHumanUserLines() {
        let toolResult = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
        let commandWrapper = #"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#
        let reminder = #"{"type":"user","message":{"content":"<system-reminder>rappel</system-reminder>"}}"#
        let interrupted = #"{"type":"user","message":{"content":"[Request interrupted by user]"}}"#
        let meta = #"{"type":"user","isMeta":true,"message":{"content":"caveat interne"}}"#
        let turns = parse([toolResult, commandWrapper, reminder, interrupted, meta, realUser])
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "Corrige le bug des quotas")
    }

    func testUserContentAsBlockListWithText() {
        // Rare mais possible : contenu utilisateur en liste avec bloc text (image collée…).
        let blocks = #"{"type":"user","message":{"content":[{"type":"text","text":"Regarde cette capture"},{"type":"image","source":{}}]}}"#
        let turns = parse([blocks])
        XCTAssertEqual(turns.map(\.text), ["Regarde cette capture"])
    }

    func testIgnoresSidechainsUnknownTypesAndGarbage() {
        let sidechain = #"{"type":"assistant","isSidechain":true,"message":{"id":"m","content":[{"type":"text","text":"sous-agent"}]}}"#
        let unknown = #"{"type":"queue-operation","payload":{}}"#
        let aiTitle = #"{"type":"ai-title","aiTitle":"Titre"}"#
        let garbage = "pas du json du tout"
        let turns = parse([sidechain, unknown, aiTitle, garbage, realUser])
        XCTAssertEqual(turns.count, 1)
    }

    func testKeepsOnlyLastTurnsInOrder() {
        var lines: [String] = []
        for index in 1...20 {
            lines.append(#"{"type":"user","message":{"content":"question \#(index)"}}"#)
        }
        let turns = parse(lines, maxTurns: 5)
        XCTAssertEqual(turns.count, 5)
        XCTAssertEqual(turns.first?.text, "question 16")
        XCTAssertEqual(turns.last?.text, "question 20")
    }

    func testDropsPartialFirstLineWhenWindowStartsMidFile() {
        // La fenêtre commence au milieu d'une ligne géante : le fragment doit sauter.
        let partial = #"ext","text":"fragment de ligne coupée"}]}}"#
        let turns = parse([partial, realUser], dropFirst: true)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "Corrige le bug des quotas")
    }

    func testTruncatesHugeMessages() {
        let huge = String(repeating: "a", count: 5_000)
        let line = #"{"type":"user","message":{"content":"\#(huge)"}}"#
        let turns = parse([line])
        XCTAssertEqual(turns[0].text.count, TranscriptHistory.maxCharactersPerTurn + 1) // + « … »
        XCTAssertTrue(turns[0].text.hasSuffix("…"))
    }

    func testLoadMissingFileReturnsEmpty() {
        XCTAssertEqual(TranscriptHistory.load(path: "/nulle/part/x.jsonl"), [])
    }

    func testLoadRealWindowFromDisk() throws {
        // Aller-retour disque avec une fin de fichier réaliste.
        let dir = FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("atoll-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try window([realUser, realAssistantText]).write(to: file)
        let turns = TranscriptHistory.load(path: file.path, maxTurns: 12)
        XCTAssertEqual(turns.count, 2)
    }
}
