import XCTest
@testable import AtollCore

/// Un `~/.claude/settings.json` de ZÉRO OCTET ne doit jamais être confondu avec
/// un fichier absent.
///
/// Les deux tombaient dans la même branche (`guard let data, !data.isEmpty`), et
/// l'écriture qui suit reposait alors un fichier ne contenant QUE nos hooks :
/// statusLine, `permissions` (allow ET deny), `env`, `model` et tous les hooks
/// tiers disparaissaient en silence. Trois écrivains se partagent ce fichier sur
/// la machine — il suffit d'en attraper un en pleine troncature.
///
/// `nil` (fichier ABSENT) reste une création délibérée : ce cas doit continuer
/// de marcher, sinon plus personne ne peut installer Atoll sur une machine
/// neuve.
final class SettingsBlankFileTests: XCTestCase {

    private let command = "/Users/x/.atoll/bin/atoll-bridge"

    // MARK: - HookSettingsEditor

    func testFichierAbsentInstalleNormalement() throws {
        let produced = try HookSettingsEditor.install(into: nil, command: command)
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: produced) as? [String: Any])
        XCTAssertNotNil(root["hooks"], "l'installation sur machine neuve doit marcher")
    }

    func testFichierDeZeroOctetEstRefuse() {
        XCTAssertThrowsError(try HookSettingsEditor.install(into: Data(), command: command)) {
            XCTAssertEqual($0 as? HookSettingsEditor.EditorError, .unparseableSettings)
        }
    }

    /// Un fichier réduit à des blancs est tout aussi suspect qu'un fichier vide :
    /// il n'y a aucun JSON à préserver, et rien ne prouve qu'il n'y en avait pas.
    func testFichierBlancEstRefuse() {
        for blanc in ["   ", "\n", "\r\n", "\t \n  "] {
            XCTAssertThrowsError(
                try HookSettingsEditor.install(into: Data(blanc.utf8), command: command),
                "« \(blanc.debugDescription) » aurait dû être refusé")
        }
    }

    func testUnJSONValideResteAccepte() throws {
        let existing = Data(#"{"statusLine":{"type":"command","command":"maligne"}}"#.utf8)
        let produced = try HookSettingsEditor.install(into: existing, command: command)
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: produced) as? [String: Any])
        XCTAssertNotNil(root["statusLine"], "la configuration existante doit survivre")
        XCTAssertNotNil(root["hooks"])
    }

    func testDesinstallationRefuseAussiUnFichierVide() {
        XCTAssertThrowsError(try HookSettingsEditor.uninstall(from: Data()))
    }

    // MARK: - isBlank

    func testIsBlank() {
        XCTAssertTrue(HookSettingsEditor.isBlank(Data()))
        XCTAssertTrue(HookSettingsEditor.isBlank(Data("  \n\t ".utf8)))
        XCTAssertFalse(HookSettingsEditor.isBlank(Data("{}".utf8)))
        XCTAssertFalse(HookSettingsEditor.isBlank(Data(" {} ".utf8)))
    }

    // MARK: - SoundHookEditor (même défaut, chemin plus dangereux : il RETIRE)

    /// `park` retire des hooks de l'utilisateur : sur un fichier vide, il ne
    /// retirerait rien mais réécrirait par-dessus sa configuration.
    func testParkDesHooksSonoresRefuseUnFichierVide() {
        XCTAssertThrowsError(try SoundHookEditor.park(in: Data())) {
            XCTAssertEqual($0 as? SoundHookEditor.EditorError, .unparseableSettings)
        }
    }

    func testParkDesHooksSonoresAccepteUnFichierAbsent() {
        // Rien à parquer, mais surtout : aucune erreur (machine neuve).
        XCTAssertNoThrow(try SoundHookEditor.park(in: nil))
    }

    func testRestitutionDesHooksSonoresRefuseUnFichierVide() {
        XCTAssertThrowsError(try SoundHookEditor.restore(into: Data(), parked: []))
    }
}
