import XCTest
@testable import AtollCore

/// « EN ATTENTE DE TOI » réclame une action : on ne le dit que d'un état
/// CONFIRMÉ par un hook.
///
/// `claude agents --json` ne connaît que `busy`/`idle`, et `idle` recouvre aussi
/// bien « elle attend ton prompt » que « elle est bloquée sur une erreur réseau »
/// ou « elle a fini sans être nettoyée ». Toute session découverte par la flotte
/// naît dans cet état : le panneau convoquait donc l'utilisateur au nom de
/// sessions qui ne demandaient rien. Même arbitrage que le retrait du badge
/// « INPUT? » en Phase 14, appliqué cette fois au regroupement.
final class UnconfirmedStateTests: XCTestCase {

    private func session(_ id: String,
                         status: AgentSession.Status,
                         confirmed: Bool) -> AgentSession {
        AgentSession(id: id, projectName: "proj", status: status,
                     stateConfirmedByHook: confirmed)
    }

    func testSessionNonConfirmeeNeReclamePasTonAttention() {
        let s = session("a", status: .awaitingInput, confirmed: false)
        XCTAssertEqual(SessionStateBucket.bucket(for: s), .working)
    }

    func testSessionConfirmeeResteEnAttenteDeToi() {
        let s = session("b", status: .awaitingInput, confirmed: true)
        XCTAssertEqual(SessionStateBucket.bucket(for: s), .awaitingInput)
    }

    /// Le défaut de confirmation ne doit toucher QUE `awaitingInput` : une carte
    /// de permission est un fait dur (un helper est bloqué), et `busy` vient du
    /// daemon sans ambiguïté.
    func testLesAutresEtatsNeSontPasAffectes() {
        let permission = session("c", status: .awaitingPermission(tool: "Bash"), confirmed: false)
        XCTAssertEqual(SessionStateBucket.bucket(for: permission), .awaitingDecision)

        let travail = session("d", status: .working(tool: nil), confirmed: false)
        XCTAssertEqual(SessionStateBucket.bucket(for: travail), .working)

        let finie = session("e", status: .done, confirmed: false)
        XCTAssertEqual(SessionStateBucket.bucket(for: finie), .done)
    }

    /// Défaut du modèle : confirmé. Une session construite sans préciser (tous
    /// les appelants historiques, dont les tests) ne change pas de comportement.
    func testDefautDuModeleEstConfirme() {
        let s = AgentSession(projectName: "proj", status: .awaitingInput)
        XCTAssertTrue(s.stateConfirmedByHook)
        XCTAssertEqual(SessionStateBucket.bucket(for: s), .awaitingInput)
    }

    /// LA régression que la revue adversariale a trouvée, et qui justifie à elle
    /// seule d'avoir fait relire ce lot.
    ///
    /// En rangeant les non confirmées dans `.working`, il ne reste qu'UN seau :
    /// `allocationPriority` n'arbitre plus rien (il arbitre ENTRE les seaux), et
    /// l'ordre interne est celui d'`uiSessions`, où `rank` classe `waitingInput`
    /// avant `busy`. La seule session qui travaille passait donc derrière
    /// « +N autres » — mot pour mot l'invariant qu'`allocationPriority` avait
    /// été écrit pour protéger.
    func testLaSessionActiveNEstJamaisEvinceeParDesDormantes() {
        // Ordre d'entrée = celui d'`uiSessions` : les dormantes d'abord.
        let sessions = [
            session("idleA", status: .awaitingInput, confirmed: false),
            session("idleB", status: .awaitingInput, confirmed: false),
            session("idleC", status: .awaitingInput, confirmed: false),
            session("busy", status: .working(tool: nil), confirmed: true),
        ]
        let bounded = SessionGrouping.byState(sessions, rowBudget: 4)
        let affichees = bounded.groups.flatMap { $0.sessions.map(\.id) }
        XCTAssertTrue(affichees.contains("busy"),
                      "la session qui TRAVAILLE ne doit pas être évincée par des dormantes")
        XCTAssertEqual(affichees.first, "busy", "elle doit même passer en tête du seau")
    }

    /// Même invariant sans bannière (budget 6) et avec une majorité écrasante de
    /// dormantes : c'est le cas réel, `agents --json` listant tous les projets.
    func testInvariantTenuAvecSixSessions() {
        var sessions = (0..<5).map {
            session("idle\($0)", status: .awaitingInput, confirmed: false)
        }
        sessions.append(session("busy", status: .working(tool: nil), confirmed: true))
        let bounded = SessionGrouping.byState(sessions, rowBudget: IslandRowBudget.plain)
        let affichees = bounded.groups.flatMap { $0.sessions.map(\.id) }
        XCTAssertTrue(affichees.contains("busy"))
    }

    /// L'ordre doit être STABLE : deux regroupements successifs rendent
    /// exactement la même chose, sinon l'îlot se réagence tout seul sous l'œil.
    func testOrdreStable() {
        let sessions = [
            session("idleA", status: .awaitingInput, confirmed: false),
            session("busy1", status: .working(tool: "Bash"), confirmed: true),
            session("idleB", status: .awaitingInput, confirmed: false),
            session("busy2", status: .working(tool: nil), confirmed: true),
        ]
        let premier = SessionGrouping.byState(sessions).flatMap { $0.sessions.map(\.id) }
        let second = SessionGrouping.byState(sessions).flatMap { $0.sessions.map(\.id) }
        XCTAssertEqual(premier, second)
        XCTAssertEqual(premier, ["busy1", "busy2", "idleA", "idleB"],
                       "actives d'abord, dormantes ensuite, ordre d'entrée préservé de part et d'autre")
    }

    /// Le regroupement complet ne doit plus afficher de seau « EN ATTENTE DE
    /// TOI » quand aucune session confirmée ne l'est.
    func testLeSeauDisparaitSiPersonneNAttendVraiment() {
        let sessions = [
            session("a", status: .awaitingInput, confirmed: false),
            session("b", status: .awaitingInput, confirmed: false),
        ]
        let groups = SessionGrouping.byState(sessions, rowBudget: 8).groups
        XCTAssertFalse(groups.contains { $0.bucket == .awaitingInput },
                       "aucune session confirmée n'attend : le seau ne doit pas s'afficher")
        XCTAssertEqual(groups.first?.bucket, .working)
        XCTAssertEqual(groups.first?.sessions.count, 2)
    }
}
