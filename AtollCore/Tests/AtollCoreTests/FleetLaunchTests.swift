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
