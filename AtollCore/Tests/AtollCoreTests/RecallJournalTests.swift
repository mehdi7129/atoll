import XCTest
@testable import AtollCore

/// L'instrument qui doit décider du sort du recall proactif.
///
/// Il sera lu UNE fois, dans un mois, et il faut qu'il soit juste ce jour-là :
/// un journal qu'on découvre faux au moment de l'analyse fait perdre le mois.
final class RecallJournalTests: XCTestCase {

    private let reference = Date(timeIntervalSince1970: 1_786_000_000)

    // MARK: - Le gate dit POURQUOI il refuse

    func testDecisionPorteLaRaisonDuRefus() {
        XCTAssertEqual(ProactiveRecall.decide(prompt: "court"), .promptTooShort)
        XCTAssertEqual(ProactiveRecall.decide(prompt: "/compact maintenant"), .promptIsCommand)
        XCTAssertEqual(ProactiveRecall.decide(prompt: "!ls -la /tmp/quelque/part"), .promptIsCommand)
        XCTAssertEqual(
            ProactiveRecall.decide(prompt: "<task-notification>\n<task-id>abc</task-id>\n</task-notification>"),
            .promptIsMachineEnvelope)
    }

    func testDecisionEligiblePorteLesMotsCles() {
        guard case .eligible(let query, let keywords) =
                ProactiveRecall.decide(prompt: "comment on avait réglé le quota Sparkle déjà") else {
            return XCTFail("ce prompt aurait dû être éligible")
        }
        XCTAssertFalse(query.isEmpty)
        XCTAssertGreaterThanOrEqual(keywords, 2)
    }

    /// `query` et `shouldRecall` doivent rester d'accord avec `decide` : ils en
    /// dérivent, ils ne peuvent plus diverger.
    func testLesTroisPortesRestentCoherentes() {
        for prompt in ["court", "/cmd", "comment on avait réglé le quota Sparkle déjà",
                       "<system-reminder>bla</system-reminder>", "un deux"] {
            let eligible: Bool
            if case .eligible = ProactiveRecall.decide(prompt: prompt) { eligible = true } else { eligible = false }
            XCTAssertEqual(eligible, ProactiveRecall.query(fromPrompt: prompt) != nil, prompt)
            XCTAssertEqual(eligible, ProactiveRecall.shouldRecall(prompt: prompt), prompt)
        }
    }

    // MARK: - Aller-retour d'une entrée

    func testEncodageDecodage() throws {
        let entry = RecallJournal.Entry(
            at: reference, outcome: .injected, session: "1b6e885d", project: "Dynamic_Island",
            keywords: 5, pool: 12, kept: 4, injected: 3, coverage: [3, 2, 1],
            blockChars: 1261, elapsedMs: 68, keys: ["uuid-a", "row:42", "uuid-c"])
        let data = try RecallJournal.encode(entry)
        XCTAssertEqual(data.last, 0x0A, "chaque entrée est une LIGNE : le \\n fait partie du contrat JSONL")
        XCTAssertEqual(RecallJournal.decode(line: data), entry)
    }

    /// Un refus du gate ne porte ni pool ni couverture : ces champs doivent
    /// rester ABSENTS, pas valoir zéro — sinon « la recherche a rendu 0 » et
    /// « la recherche n'a pas eu lieu » deviennent indiscernables, ce qui est
    /// exactement la confusion que ce journal existe pour lever.
    func testUnRefusNePorteAucunChiffreDeRecherche() throws {
        let entry = RecallJournal.Entry(at: reference, outcome: .promptTooShort)
        let decoded = try XCTUnwrap(RecallJournal.decode(line: RecallJournal.encode(entry)))
        XCTAssertNil(decoded.pool)
        XCTAssertNil(decoded.kept)
        XCTAssertNil(decoded.coverage)
    }

    func testUnJournalTolereLesLignesAbimees() throws {
        var data = Data()
        data.append(try RecallJournal.encode(.init(at: reference, outcome: .injected, injected: 2, coverage: [2, 1])))
        data.append(Data("{ceci n'est pas du json\n".utf8))
        data.append(Data("\n".utf8))
        data.append(try RecallJournal.encode(.init(at: reference, outcome: .noHits, pool: 0)))
        // Une ligne tronquée par un crash en pleine écriture : sautée, pas fatale.
        data.append(Data("{\"at\":\"2026-08-09T".utf8))

        let entries = RecallJournal.entries(in: data)
        XCTAssertEqual(entries.count, 2, "les lignes illisibles sont sautées, le reste survit")
        XCTAssertEqual(entries.map(\.outcome), [.injected, .noHits])
    }

    // MARK: - Le résumé

    func testResumeCompteCeQuiDecide() throws {
        let entries: [RecallJournal.Entry] = [
            .init(at: reference, outcome: .injected, injected: 3, coverage: [3, 1, 1],
                  blockChars: 900, elapsedMs: 60),
            .init(at: reference.addingTimeInterval(60), outcome: .injected, injected: 1,
                  coverage: [1], blockChars: 300, elapsedMs: 80),
            .init(at: reference.addingTimeInterval(120), outcome: .promptTooShort, elapsedMs: 1),
            .init(at: reference.addingTimeInterval(180), outcome: .noHits, pool: 0, elapsedMs: 40),
        ]
        let summary = RecallJournal.summarize(entries)

        XCTAssertEqual(summary.total, 4)
        XCTAssertEqual(summary.byOutcome[.injected], 2)
        // Le refus du gate n'a PAS interrogé la base : c'est la distinction qui
        // sépare « gate trop strict » de « mémoire sans réponse ».
        XCTAssertEqual(summary.searched, 3)
        XCTAssertEqual(summary.injectedSnippets, 4)
        XCTAssertEqual(summary.coverageHistogram[1], 3)
        XCTAssertEqual(summary.coverageHistogram[3], 1)
        XCTAssertEqual(summary.totalBlockChars, 1200)
        XCTAssertEqual(summary.injectionRate, 0.5)
        // 3 extraits sur 4 n'appariaient qu'un seul mot du prompt.
        XCTAssertEqual(summary.thinMatchRate, 0.75)
        XCTAssertEqual(summary.maxElapsedMs, 80)
        XCTAssertEqual(summary.firstAt, reference)
        XCTAssertEqual(summary.lastAt, reference.addingTimeInterval(180))
    }

    /// Médiane et non moyenne : une seule ouverture de base à froid (mesurée à
    /// 431 ms) déplacerait la moyenne et ferait croire à une lenteur permanente.
    func testLatenceMediane() {
        let entries = [10, 12, 11, 431, 13].map {
            RecallJournal.Entry(at: reference, outcome: .injected, elapsedMs: $0)
        }
        let summary = RecallJournal.summarize(entries)
        XCTAssertEqual(summary.medianElapsedMs, 12)
        XCTAssertEqual(summary.maxElapsedMs, 431)
    }

    /// LE piège vu en mesurant pour de vrai : les refus du gate coûtent 0 ms et
    /// sont MAJORITAIRES. Les inclure écrasait la médiane à 0, et la ligne de
    /// latence disparaissait du rapport — l'information qu'on veut justement
    /// lire dans un mois se serait tue toute seule.
    func testLaLatenceIgnoreLesRefusInstantanesDuGate() {
        let entries: [RecallJournal.Entry] = [
            .init(at: reference, outcome: .promptTooShort, elapsedMs: 0),
            .init(at: reference, outcome: .promptIsCommand, elapsedMs: 0),
            .init(at: reference, outcome: .promptIsMachineEnvelope, elapsedMs: 0),
            .init(at: reference, outcome: .injected, elapsedMs: 62),
            .init(at: reference, outcome: .noHits, elapsedMs: 2),
        ]
        let summary = RecallJournal.summarize(entries)
        XCTAssertEqual(summary.medianElapsedMs, 62, "médiane des passages ayant CHERCHÉ")
        XCTAssertEqual(summary.maxElapsedMs, 62)
        XCTAssertTrue(RecallJournal.report(summary).contains("latence"),
                      "la ligne de latence doit apparaître même quand les refus dominent")
    }

    func testJournalVideNeDivisePasParZero() {
        let summary = RecallJournal.summarize([])
        XCTAssertEqual(summary.injectionRate, 0)
        XCTAssertEqual(summary.thinMatchRate, 0)
        XCTAssertFalse(RecallJournal.report(summary).isEmpty)
    }

    func testOutcomeSearchedSepareLeGateDeLaBase() {
        for outcome in [RecallJournal.Outcome.promptTooShort, .promptIsCommand,
                        .promptIsMachineEnvelope, .tooFewKeywords] {
            XCTAssertFalse(outcome.searched, outcome.rawValue)
        }
        for outcome in [RecallJournal.Outcome.injected, .noHits, .noneAboveFloor,
                        .emptyBlock, .indexUnavailable, .searchFailed] {
            XCTAssertTrue(outcome.searched, outcome.rawValue)
        }
    }

    /// Le rapport est lu par un humain, une fois, dans un mois : il doit porter
    /// les chiffres qui décident, pas seulement un total.
    func testLeRapportPorteLesChiffresQuiDecident() {
        let summary = RecallJournal.summarize([
            .init(at: reference, outcome: .injected, injected: 2, coverage: [1, 1], blockChars: 500, elapsedMs: 70),
            .init(at: reference.addingTimeInterval(60), outcome: .noHits, pool: 0, elapsedMs: 30),
        ])
        let report = RecallJournal.report(summary)
        XCTAssertTrue(report.contains("injected"))
        XCTAssertTrue(report.contains("noHits"))
        XCTAssertTrue(report.contains("ms"), "la latence ajoutée au prompt doit figurer")
        XCTAssertTrue(report.contains("SERVI"), "le rapport doit dire ce qu'il ne mesure PAS")
    }
}
