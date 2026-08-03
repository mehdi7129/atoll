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

    // MARK: - jobIdentifier : ce que `claude stop` sait résoudre

    /// LE cas qui a cassé le bouton ARRÊTER pendant toute la Phase 9 : la CLI
    /// apparie le nom d'un dossier de 8 hex contre l'argument reçu, donc l'UUID
    /// complet ne résout jamais. Mesuré sur `1b6e885d` : préfixe EXIT=0,
    /// UUID complet EXIT=1.
    func testJobIdentifierKeepsOnlyTheEightHexPrefix() {
        XCTAssertEqual(FleetLaunch.jobIdentifier(for: "1b6e885d-60ff-4bfa-bd56-353e6f4ba7c8"), "1b6e885d")
        XCTAssertEqual(FleetLaunch.jobIdentifier(for: "72838db5-930a-4d7e-9c49-816f70a046fe"), "72838db5")
    }

    /// Un identifiant DÉJÀ tronqué (la sortie de `claude --bg` n'imprime parfois
    /// que le préfixe) doit passer tel quel, pas être refusé.
    func testJobIdentifierAcceptsAnAlreadyShortIdentifier() {
        XCTAssertEqual(FleetLaunch.jobIdentifier(for: "3dac7149"), "3dac7149")
    }

    /// Trop court : la CLI le filtrerait (`^[a-f0-9]{8}$`). On refuse AVANT
    /// plutôt que d'envoyer un préfixe qui apparierait plusieurs jobs.
    func testJobIdentifierRejectsTooShort() {
        for raw in ["", "1b6e", "1b6e885", "-"] {
            XCTAssertNil(FleetLaunch.jobIdentifier(for: raw), raw)
        }
    }

    /// Non-hexadécimal : un identifiant synthétique d'Atoll (session découverte
    /// par scan) ne doit pas être passé à `stop` — il désignerait au mieux rien,
    /// au pire un job homonyme.
    func testJobIdentifierRejectsNonHexadecimal() {
        for raw in ["session-1", "zzzzzzzz-0000-0000-0000-000000000000", "atoll-fake-id", "1b6e885 "] {
            XCTAssertNil(FleetLaunch.jobIdentifier(for: raw), raw)
        }
    }

    /// Majuscules refusées : le filtre de la CLI est `[a-f0-9]`, pas `[A-Fa-f0-9]`.
    /// Abaisser la casse nous-mêmes serait une supposition sur son comportement.
    func testJobIdentifierRejectsUppercaseHex() {
        XCTAssertNil(FleetLaunch.jobIdentifier(for: "1B6E885D-60ff-4bfa-bd56-353e6f4ba7c8"))
    }

    /// Les chiffres non-ASCII satisfont `isHexDigit` en Swift : ils ne doivent
    /// PAS produire un argument que la CLI rejetterait de toute façon.
    func testJobIdentifierRejectsNonASCIIDigits() {
        XCTAssertNil(FleetLaunch.jobIdentifier(for: "١٢٣٤٥٦٧٨-60ff-4bfa-bd56-353e6f4ba7c8"))
    }
}
