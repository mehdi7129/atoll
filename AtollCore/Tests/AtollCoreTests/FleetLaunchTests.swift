import XCTest
@testable import AtollCore

final class FleetLaunchTests: XCTestCase {
    func testParsesFullUUID() {
        let out = "backgrounded · 3dac7149-1e2f-4c00-9a00-2b7c9d1e5f60\n  claude agents"
        XCTAssertEqual(FleetLaunch.parseSessionID(out), "3dac7149-1e2f-4c00-9a00-2b7c9d1e5f60")
    }

    func testParsesShortIDWithAnsiColors() {
        // Le CLI colore l'id (séquences ANSI) et ne montre parfois que le préfixe.
        let out = "backgrounded · \u{1B}[36ma8558220\u{1B}[39m"
        XCTAssertEqual(FleetLaunch.parseSessionID(out), "a8558220")
    }

    /// Un id court n'est une preuve que s'il est SEUL. Deux candidats = un
    /// pari : lier la tâche au mauvais identifiant DÉSACTIVE le rattrapage par
    /// dossier (`adopt` n'agit que sur les tâches sans id), donc la fin de la
    /// tâche ne serait jamais annoncée. nil est le bon choix : le rattrapage,
    /// lui, sait faire.
    func testAmbiguousShortIDsYieldNil() {
        XCTAssertNil(FleetLaunch.parseSessionID("plugin a1b2c3d4 · session e5f6a7b8"))
        XCTAssertNil(FleetLaunch.parseSessionID("build 12345678 chunk abcdef01 ok"))
    }

    func testLoneShortIDIsStillAccepted() {
        XCTAssertEqual(FleetLaunch.parseSessionID("backgrounded · a8558220"), "a8558220")
        // Répété, c'est le MÊME identifiant : pas d'ambiguïté.
        XCTAssertEqual(FleetLaunch.parseSessionID("a8558220 … suivi de a8558220"), "a8558220")
    }

    /// Un UUID complet reste une preuve, même entouré de bruit hexadécimal.
    func testFullUUIDWinsOverAmbiguousNoise() {
        let out = "sha 1a2b3c4d · id 3dac7149-1e2f-4c00-9a00-2b7c9d1e5f60 · tmp 9f8e7d6c"
        XCTAssertEqual(FleetLaunch.parseSessionID(out), "3dac7149-1e2f-4c00-9a00-2b7c9d1e5f60")
    }

    /// Un hash long ne doit pas fournir de faux candidat court (les frontières
    /// de mot l'excluent) — donc pas d'ambiguïté artificielle.
    func testLongHashDoesNotCreateShortCandidates() {
        let sha = "commit da39a3ee5e6b4b0d3255bfef95601890afd80709 · id a8558220"
        XCTAssertEqual(FleetLaunch.parseSessionID(sha), "a8558220")
    }

    func testFullUUIDWinsOverShort() {
        let out = "id court a8558220 puis complet 3dac7149-1e2f-4c00-9a00-2b7c9d1e5f60"
        XCTAssertEqual(FleetLaunch.parseSessionID(out), "3dac7149-1e2f-4c00-9a00-2b7c9d1e5f60")
    }

    func testReturnsNilWhenNoID() {
        XCTAssertNil(FleetLaunch.parseSessionID("erreur : impossible de lancer"))
        XCTAssertNil(FleetLaunch.parseSessionID(""))
    }

    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(FleetLaunch.shellQuote("l'îlot"), "'l'\\''îlot'")
        XCTAssertEqual(FleetLaunch.shellQuote("simple"), "'simple'")
    }

    func testValidTask() {
        XCTAssertTrue(FleetLaunch.isValidTask("corrige les tests"))
        XCTAssertFalse(FleetLaunch.isValidTask("   \n  "))
        XCTAssertFalse(FleetLaunch.isValidTask(""))
    }
}
