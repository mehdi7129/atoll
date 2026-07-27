import XCTest
@testable import AtollCore

final class SessionGroupingTests: XCTestCase {

    private func session(_ name: String, _ status: AgentSession.Status) -> AgentSession {
        AgentSession(id: name, projectName: name, status: status)
    }

    /// LE point de cette vue : ce qui te bloque passe devant ce qui ronronne.
    func testOrdersMostUrgentFirst() {
        let groups = SessionGrouping.byState([
            session("d", .done),
            session("w", .working(tool: nil)),
            session("i", .awaitingInput),
            session("p", .awaitingPermission(tool: "Bash")),
        ])
        XCTAssertEqual(groups.map(\.bucket),
                       [.awaitingDecision, .awaitingInput, .working, .done])
    }

    /// Un en-tête vide mangerait une ligne de l'îlot pour ne rien dire.
    func testOmitsEmptyBuckets() {
        let groups = SessionGrouping.byState([session("w", .working(tool: "Read"))])
        XCTAssertEqual(groups.map(\.bucket), [.working])
    }

    func testKeepsIncomingOrderInsideABucket() {
        let groups = SessionGrouping.byState([
            session("premier", .working(tool: nil)),
            session("second", .working(tool: nil)),
        ])
        XCTAssertEqual(groups[0].sessions.map(\.projectName), ["premier", "second"])
    }

    func testEmptyInputYieldsNoGroups() {
        XCTAssertTrue(SessionGrouping.byState([]).isEmpty)
    }

    func testEveryStatusHasABucket() {
        let statuses: [AgentSession.Status] = [
            .working(tool: nil), .working(tool: "Bash"),
            .awaitingPermission(tool: "Edit"), .awaitingInput, .done,
        ]
        for status in statuses {
            // Ne doit ni planter ni retomber sur un fourre-tout : chaque état a
            // sa place, sinon une session deviendrait invisible dans cette vue.
            let groups = SessionGrouping.byState([session("x", status)])
            XCTAssertEqual(groups.count, 1)
        }
    }

    func testAllSessionsSurviveGrouping() {
        let sessions = (0..<10).map { index in
            session("s\(index)", index % 2 == 0 ? .working(tool: nil) : .awaitingInput)
        }
        let regrouped = SessionGrouping.byState(sessions).flatMap(\.sessions)
        XCTAssertEqual(Set(regrouped.map(\.id)), Set(sessions.map(\.id)))
        XCTAssertEqual(regrouped.count, sessions.count)
    }

    // MARK: - Bornage (hauteur fixe du panneau)

    /// Ce qui saute quand ça ne tient pas, c'est ce qui DORT — jamais ce qui
    /// attend une décision.
    func testLimitDropsLeastUrgentFirst() {
        let bounded = SessionGrouping.byState([
            session("p", .awaitingPermission(tool: "Bash")),
            session("w1", .working(tool: nil)),
            session("w2", .working(tool: nil)),
            session("d", .done),
        ], limit: 2)
        XCTAssertEqual(bounded.groups.flatMap(\.sessions).map(\.projectName), ["p", "w1"])
        XCTAssertEqual(bounded.hiddenCount, 2)
    }

    /// Un groupe entièrement coupé ne doit pas laisser un en-tête tout seul.
    func testLimitDropsEmptiedGroupHeaders() {
        let bounded = SessionGrouping.byState([
            session("p", .awaitingPermission(tool: "Bash")),
            session("w", .working(tool: nil)),
        ], limit: 1)
        XCTAssertEqual(bounded.groups.map(\.bucket), [.awaitingDecision])
    }

    func testLimitAboveCountHidesNothing() {
        let bounded = SessionGrouping.byState([session("w", .working(tool: nil))], limit: 10)
        XCTAssertEqual(bounded.hiddenCount, 0)
        XCTAssertEqual(bounded.groups.flatMap(\.sessions).count, 1)
    }

    func testZeroLimitHidesEverything() {
        let bounded = SessionGrouping.byState([session("w", .working(tool: nil))], limit: 0)
        XCTAssertTrue(bounded.groups.isEmpty)
        XCTAssertEqual(bounded.hiddenCount, 1)
    }

    func testHiddenCountIsExactAcrossManyGroups() {
        let sessions = (0..<12).map { index -> AgentSession in
            switch index % 3 {
            case 0: return session("p\(index)", .awaitingPermission(tool: "Bash"))
            case 1: return session("w\(index)", .working(tool: nil))
            default: return session("i\(index)", .awaitingInput)
            }
        }
        for limit in 1...12 {
            let bounded = SessionGrouping.byState(sessions, limit: limit)
            let shown = bounded.groups.flatMap(\.sessions).count
            XCTAssertEqual(shown, min(limit, 12), "limit=\(limit)")
            XCTAssertEqual(shown + bounded.hiddenCount, 12, "limit=\(limit)")
        }
    }

    // MARK: - Budget en RANGÉES DESSINÉES (audit du 2026-07-27)

    /// Le bug : `limit:` compte des sessions, mais chaque groupe dessine EN PLUS
    /// une ligne d'en-tête. Quatre sessions sur quatre états = huit rangées,
    /// pour un budget calibré sur quatre — le quota sortait du cadre.
    func testRowBudgetCountsGroupHeaders() {
        let sessions = [
            session("a", .awaitingPermission(tool: "Bash")),
            session("b", .awaitingInput),
            session("c", .working(tool: nil)),
            session("d", .done),
        ]
        let bounded = SessionGrouping.byState(sessions, rowBudget: 4)
        let rows = bounded.groups.count + bounded.groups.reduce(0) { $0 + $1.sessions.count }
        XCTAssertLessThanOrEqual(rows, 4)
        XCTAssertEqual(bounded.hiddenCount, sessions.count - bounded.groups.reduce(0) { $0 + $1.sessions.count })
    }

    /// Quel que soit le budget et la répartition, on ne dessine JAMAIS plus de
    /// rangées que le budget, et rien n'est perdu du décompte.
    func testRowBudgetNeverExceededAndNothingLost() {
        let sessions = (0..<12).map { i -> AgentSession in
            let statuses: [AgentSession.Status] = [.awaitingPermission(tool: "t"), .awaitingInput, .working(tool: nil), .done]
            return session("s\(i)", statuses[i % 4])
        }
        for budget in 0...16 {
            let bounded = SessionGrouping.byState(sessions, rowBudget: budget)
            let shown = bounded.groups.reduce(0) { $0 + $1.sessions.count }
            let rows = bounded.groups.count + shown
            XCTAssertLessThanOrEqual(rows, budget, "budget=\(budget)")
            XCTAssertEqual(shown + bounded.hiddenCount, 12, "budget=\(budget)")
        }
    }

    /// Un groupe ne s'ouvre pas pour n'afficher que son en-tête.
    func testRowBudgetNeverOpensAnEmptyGroup() {
        let sessions = [session("a", .awaitingPermission(tool: "t")), session("b", .done)]
        let bounded = SessionGrouping.byState(sessions, rowBudget: 3)
        XCTAssertTrue(bounded.groups.allSatisfy { !$0.sessions.isEmpty })
        // 3 rangées = 1 en-tête + 1 session, puis plus la place d'ouvrir le 2e.
        XCTAssertEqual(bounded.groups.count, 1)
        XCTAssertEqual(bounded.hiddenCount, 1)
    }

    func testBannerShrinksTheBudget() {
        XCTAssertLessThan(IslandRowBudget.rows(bannerShown: true),
                          IslandRowBudget.rows(bannerShown: false))
    }

    func testBucketTitlesAreDistinct() {
        XCTAssertEqual(Set(SessionStateBucket.allCases.map(\.title)).count,
                       SessionStateBucket.allCases.count)
    }
}
