import XCTest
@testable import AtollCore

/// Chaque test correspond à un trou RÉEL relevé par Codex en revue le
/// 2026-09-09. Ils sont écrits pour être sabotables un par un — c'est la seule
/// façon de savoir qu'ils gardent quelque chose.
final class CodexCardReaperTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ id: String, pid: Int32 = 4242, start: Double? = 1000,
                      secondsAgo: TimeInterval = 5) -> CodexCardReaper.Card {
        .init(id: id, helperPid: pid, helperStartTime: start,
              receivedAt: now.addingTimeInterval(-secondsAgo))
    }

    private func expired(_ cards: [CodexCardReaper.Card],
                         probe: @escaping (Int32) -> CodexCardReaper.Probe) -> [String] {
        CodexCardReaper.expired(cards, now: now, probe: probe)
    }

    private func alive(_ start: Double?) -> (Int32) -> CodexCardReaper.Probe {
        { _ in .init(isAlive: true, startTime: start) }
    }

    private let dead: (Int32) -> CodexCardReaper.Probe = { _ in .init(isAlive: false, startTime: nil) }

    /// Le cas nominal : le helper attend, la carte reste.
    func testALiveHelperKeepsItsCard() {
        XCTAssertEqual(expired([card("a")], probe: alive(1000)), [])
    }

    /// Terminal fermé d'un coup, `SIGKILL` : le helper n'est plus là.
    func testADeadHelperLosesItsCard() {
        XCTAssertEqual(expired([card("a")], probe: dead), ["a"])
    }

    /// TROU N° 1 — `LOCAL_PEERPID` a échoué, le pid vaut 0. L'ancienne garde
    /// « pid > 0 » excluait ces cartes du nettoyage : elles ne partaient JAMAIS.
    func testACardWithoutAKnownPidStillLeavesOnTheAbsoluteNet() {
        let young = card("jeune", pid: 0, start: nil, secondsAgo: 10)
        let old = card("vieille", pid: 0, start: nil,
                       secondsAgo: CodexCardReaper.absoluteLifetime + 1)
        // Elle n'est pas retirée AUSSITÔT — le helper peut très bien attendre.
        XCTAssertEqual(expired([young], probe: dead), [])
        // …mais elle finit par partir, sans qu'aucune sonde puisse le dire.
        XCTAssertEqual(expired([old], probe: alive(1000)), ["vieille"])
    }

    /// TROU N° 2 — le PID a été recyclé : le processus vivant sous ce numéro
    /// n'est PAS notre helper. Sans le couple (pid, démarrage), `kill(pid, 0)`
    /// répondait « vivant » et la carte survivait à son helper.
    func testARecycledPidIsNotTheSameProcess() {
        XCTAssertEqual(expired([card("a", start: 1000)], probe: alive(9999)), ["a"])
    }

    /// La tolérance d'une seconde : `sysctl` n'est pas plus précis que ça, et
    /// un écart de quelques centièmes ne prouve rien.
    func testASubSecondDriftIsNotARecycledPid() {
        XCTAssertEqual(expired([card("a", start: 1000)], probe: alive(1000.4)), [])
    }

    /// ⚠️ ABSENCE D'INFORMATION ≠ PREUVE. Une sonde qui ne sait pas dire
    /// l'instant de démarrage ne doit pas faire disparaître une carte vivante :
    /// on retomberait sur le filet absolu, et c'est le bon comportement.
    func testAnUnreadableStartTimeDoesNotKillALiveCard() {
        XCTAssertEqual(expired([card("a", start: 1000)], probe: alive(nil)), [])
        XCTAssertEqual(expired([card("a", start: nil)], probe: alive(1000)), [])
    }

    /// TROU N° 3 — le filet absolu vaut MÊME pour un processus vivant : au-delà
    /// du plafond de Codex, le hook a été tué, plus personne ne lit la réponse.
    /// Le pid peut très bien appartenir à un `codex` toujours en vie.
    func testTheAbsoluteNetAppliesEvenToALiveProcess() {
        let old = card("a", secondsAgo: CodexCardReaper.absoluteLifetime + 1)
        XCTAssertEqual(expired([old], probe: alive(1000)), ["a"])
    }

    /// Le filet est posé APRÈS le plafond de Codex, jamais avant : sinon Atoll
    /// retirerait la carte pendant que le helper attend encore.
    func testTheNetIsNeverTighterThanTheHelperDeadline() {
        XCTAssertGreaterThan(CodexCardReaper.absoluteLifetime,
                             CodexPermissionTiming.helperDeadlineSeconds)
        let justBefore = card("a", secondsAgo: CodexCardReaper.absoluteLifetime - 1)
        XCTAssertEqual(expired([justBefore], probe: alive(1000)), [])
    }

    /// Plusieurs cartes sont jugées INDÉPENDAMMENT : une seule décision pour
    /// tout le lot refermerait des cartes vivantes.
    func testCardsAreJudgedIndependently() {
        let cards = [card("vivante", pid: 1), card("morte", pid: 2)]
        let ids = expired(cards) { pid in
            pid == 1 ? .init(isAlive: true, startTime: 1000) : .init(isAlive: false, startTime: nil)
        }
        XCTAssertEqual(ids, ["morte"])
    }
}
