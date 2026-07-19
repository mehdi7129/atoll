import XCTest
@testable import AtollCore

final class TranscriptHistoryTests: XCTestCase {

    private func window(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    private func parse(_ lines: [String], maxExchanges: Int = 8, dropFirst: Bool = false) -> [TranscriptHistory.HistoryTurn] {
        TranscriptHistory.parse(window: window(lines), dropFirstLine: dropFirst, maxExchanges: maxExchanges)
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
        let thinking = #"{"type":"assistant","message":{"id":"msg_2","content":[{"type":"thinking","thinking":"hmm"}]}}"#
        let part1 = #"{"type":"assistant","message":{"id":"msg_2","content":[{"type":"text","text":"Première partie."}]}}"#
        let toolUse = #"{"type":"assistant","message":{"id":"msg_2","content":[{"type":"tool_use","name":"Bash","input":{}}]}}"#
        let part2 = #"{"type":"assistant","message":{"id":"msg_2","content":[{"type":"text","text":"Seconde partie."}]}}"#
        let turns = parse([realUser, thinking, part1, toolUse, part2])
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[1].text, "Première partie.\nSeconde partie.")
    }

    func testGroupsNonConsecutiveAssistantLines() {
        // tool_use parallèle : lignes assistant du même id entrelacées avec des
        // tool_result user → doivent rester UN seul tour assistant.
        let part1 = #"{"type":"assistant","message":{"id":"msg_x","content":[{"type":"text","text":"J'appelle deux outils."}]}}"#
        let toolResult = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
        let part2 = #"{"type":"assistant","message":{"id":"msg_x","content":[{"type":"text","text":"Voici le résultat."}]}}"#
        let turns = parse([realUser, part1, toolResult, part2])
        XCTAssertEqual(turns.count, 2, "le tool_result ne doit pas scinder la réponse")
        XCTAssertEqual(turns[1].text, "J'appelle deux outils.\nVoici le résultat.")
    }

    func testSeparateMessageIDsMakeSeparateTurns() {
        let a1 = #"{"type":"assistant","message":{"id":"msg_a","content":[{"type":"text","text":"Réponse A"}]}}"#
        let a2 = #"{"type":"assistant","message":{"id":"msg_b","content":[{"type":"text","text":"Réponse B"}]}}"#
        let turns = parse([a1, a2])
        XCTAssertEqual(turns.map(\.text), ["Réponse A", "Réponse B"])
    }

    func testAssistantWithoutIDNeverMerged() {
        let a1 = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Bloc 1"}]}}"#
        let a2 = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Bloc 2"}]}}"#
        let turns = parse([a1, a2])
        XCTAssertEqual(turns.map(\.text), ["Bloc 1", "Bloc 2"])
    }

    func testFiltersNonHumanUserLines() {
        let toolResult = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
        let commandWrapper = #"{"type":"user","message":{"content":"<command-name>/clear</command-name>"}}"#
        let reminder = #"{"type":"user","message":{"content":"<system-reminder>rappel</system-reminder>"}}"#
        let meta = #"{"type":"user","isMeta":true,"message":{"content":"caveat interne"}}"#
        let turns = parse([toolResult, commandWrapper, reminder, meta, realUser])
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "Corrige le bug des quotas")
    }

    func testFiltersInterruptionsAndNotificationsInBlockForm() {
        // Formes RÉELLES : les interruptions et task-notifications sont des
        // listes de blocs text (constat de revue — la branche liste ne les
        // filtrait pas).
        let interrupted = #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
        let interruptedString = #"{"type":"user","message":{"content":"[Request interrupted by user]"}}"#
        let taskNotif = #"{"type":"user","message":{"content":[{"type":"text","text":"<task-notification>\n<task-id>abc</task-id>"}]}}"#
        let turns = parse([interrupted, interruptedString, taskNotif, realUser])
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "Corrige le bug des quotas")
    }

    func testExcludesCompactSummaryAndTranscriptOnly() {
        // Résumé de compactage : isCompactSummary + isVisibleInTranscriptOnly,
        // string géante — ne DOIT PAS apparaître comme un tour user.
        let summary = #"{"type":"user","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"content":"This session is being continued from a previous conversation…"}}"#
        let turns = parse([summary, realUser])
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "Corrige le bug des quotas")
    }

    func testKeepsGenuinePromptQuotingInterruptString() {
        // hasPrefix, pas contains : un vrai prompt qui CITE la chaîne est gardé.
        let genuine = #"{"type":"user","message":{"content":"Regarde ce log : [Request interrupted by user] — pourquoi ?"}}"#
        let turns = parse([genuine])
        XCTAssertEqual(turns.count, 1)
        XCTAssertTrue(turns[0].text.hasPrefix("Regarde ce log"))
    }

    func testUserContentAsBlockListWithText() {
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

    func testKeepsOnlyLastExchangesInOrder() {
        var lines: [String] = []
        for index in 1...20 {
            lines.append(#"{"type":"user","message":{"content":"question \#(index)"}}"#)
            lines.append(#"{"type":"assistant","message":{"id":"m\#(index)","content":[{"type":"text","text":"réponse \#(index)"}]}}"#)
        }
        let turns = parse(lines, maxExchanges: 3)
        // 3 échanges = 3 user + 3 assistant, les derniers, dans l'ordre.
        XCTAssertEqual(turns.count, 6)
        XCTAssertEqual(turns.first?.text, "question 18")
        XCTAssertEqual(turns.last?.text, "réponse 20")
        XCTAssertEqual(turns.filter { $0.role == .user }.count, 3)
    }

    func testDropsPartialFirstLineWhenWindowStartsMidFile() {
        let partial = #"ext","text":"fragment de ligne coupée"}]}}"#
        let turns = parse([partial, realUser], dropFirst: true)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].text, "Corrige le bug des quotas")
    }

    func testTruncatesHugeMessages() {
        let huge = String(repeating: "a", count: 5_000)
        let line = #"{"type":"user","message":{"content":"\#(huge)"}}"#
        let turns = parse([line])
        XCTAssertEqual(turns[0].text.count, TranscriptHistory.maxCharactersPerTurn + 1)
        XCTAssertTrue(turns[0].text.hasSuffix("…"))
    }

    func testLoadMissingFileReturnsEmpty() {
        XCTAssertEqual(TranscriptHistory.load(path: "/nulle/part/x.jsonl"), [])
    }

    func testLoadWidensWindowUntilEnoughExchanges() throws {
        // Prompts noyés sous d'énormes tool_results : la fenêtre initiale (2 Mo)
        // ne capte presque rien, mais load() l'élargit jusqu'à obtenir des
        // échanges réels.
        let dir = FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("atoll-hist-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        var lines: [String] = []
        let filler = String(repeating: "x", count: 300_000) // ~300 Ko par tool_result
        for index in 1...12 {
            lines.append(#"{"type":"user","message":{"content":"prompt \#(index)"}}"#)
            lines.append(#"{"type":"assistant","message":{"id":"a\#(index)","content":[{"type":"text","text":"ok \#(index)"}]}}"#)
            lines.append(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","content":"\#(filler)"}]}}"#)
        }
        try window(lines).write(to: file)
        let turns = TranscriptHistory.load(path: file.path, minExchanges: 6, maxExchanges: 8)
        let userTurns = turns.filter { $0.role == .user }.count
        XCTAssertGreaterThanOrEqual(userTurns, 6, "la fenêtre doit s'élargir pour capter les prompts")
    }
}
