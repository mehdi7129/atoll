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

    func testBucketTitlesAreDistinct() {
        XCTAssertEqual(Set(SessionStateBucket.allCases.map(\.title)).count,
                       SessionStateBucket.allCases.count)
    }
}
