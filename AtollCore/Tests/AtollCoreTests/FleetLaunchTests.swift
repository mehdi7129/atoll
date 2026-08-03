import XCTest
@testable import AtollCore

/// Ce qui reste de `FleetLaunch` après le retrait du cockpit (2026-08-03) :
/// l'échappement shell, encore utilisé par le bilan de fin de session,
/// l'inventaire de plugins et le rangement des notes — trois endroits où une
/// apostrophe dans un chemin casserait la commande.
final class FleetLaunchTests: XCTestCase {

    func testShellQuoteWrapsInSingleQuotes() {
        XCTAssertEqual(FleetLaunch.shellQuote("simple"), "'simple'")
        XCTAssertEqual(FleetLaunch.shellQuote("avec espaces"), "'avec espaces'")
    }

    /// LE cas qui compte, et il est fréquent chez cet utilisateur : ses dossiers
    /// de projet portent des noms français. À l'intérieur de guillemets simples
    /// rien n'est échappé — il faut fermer, insérer, rouvrir.
    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(FleetLaunch.shellQuote("l'îlot"), "'l'\\''îlot'")
        XCTAssertEqual(FleetLaunch.shellQuote("Vaux-le-Vicomte/l'été"), "'Vaux-le-Vicomte/l'\\''été'")
    }

    /// Les métacaractères restent INERTES : c'est tout l'intérêt de la fonction.
    func testShellQuoteNeutralisesMetacharacters() {
        for raw in ["$(whoami)", "a; b", "a && b", "`id`", "a | b", "*", "~/Desktop"] {
            let quoted = FleetLaunch.shellQuote(raw)
            XCTAssertTrue(quoted.hasPrefix("'") && quoted.hasSuffix("'"), raw)
            XCTAssertEqual(quoted.dropFirst().dropLast(), raw[...], raw)
        }
    }

    func testEmptyStringStaysQuoted() {
        XCTAssertEqual(FleetLaunch.shellQuote(""), "''")
    }
}
