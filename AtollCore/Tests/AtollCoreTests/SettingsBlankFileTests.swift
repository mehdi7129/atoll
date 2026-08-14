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

    // MARK: - RockstarPermissionsEditor (le chemin le PLUS dangereux)

    /// Le correctif de v0.16.1 avait couvert `HookSettingsEditor`,
    /// `SoundHookEditor` et `refreshBackup` — mais NI celui-ci NI
    /// `StatusLineEditor`, restés au `guard let data, !data.isEmpty`.
    ///
    /// Ici l'écriture est doublement irrattrapable : `performRockstarRestore`
    /// supprime `rockstar-parked-deny.json` juste après avoir écrit, donc la
    /// configuration écrasée n'a plus aucune trace nulle part.
    func testRestitutionRockstarRefuseUnFichierVide() {
        XCTAssertThrowsError(
            try RockstarPermissionsEditor.restore(into: Data(), parked: ["Bash(rm -rf:*)"])
        ) {
            XCTAssertEqual($0 as? RockstarPermissionsEditor.EditorError, .unparseableSettings)
        }
        for blanc in ["   ", "\n", "\r\n"] {
            XCTAssertThrowsError(
                try RockstarPermissionsEditor.restore(into: Data(blanc.utf8), parked: ["x"]),
                "« \(blanc.debugDescription) » aurait dû être refusé")
        }
    }

    /// Machine neuve : aucun settings.json. La restitution doit continuer de
    /// produire un fichier — sinon on ne pourrait plus jamais sortir de Rockstar
    /// sur une installation fraîche.
    func testRestitutionRockstarAccepteUnFichierAbsent() throws {
        let produced = try RockstarPermissionsEditor.restore(into: nil, parked: ["Bash(rm:*)"])
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: produced) as? [String: Any])
        let permissions = try XCTUnwrap(root["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["deny"] as? [String], ["Bash(rm:*)"])
    }

    /// `park` était déjà sain : il sortait en `nil` sans écrire. La garde, posée
    /// sur le `parse` PARTAGÉ, change donc aussi son comportement — il refuse
    /// désormais explicitement.
    ///
    /// La raison écrite ici le 2026-08-12 (« pour que `rockstarPark` ne grave
    /// pas un backup pré-Atoll vide au passage ») est FAUSSE sur ses deux
    /// termes, vérifié le 2026-08-14 : `rockstarPark` sort en 0 dès que `park`
    /// rend `nil`, AVANT d'atteindre `refreshBackup` ; et `refreshBackup` porte
    /// lui-même la garde anti-fichier-blanc depuis la v0.16.1.
    ///
    /// Le refus est CONSERVÉ pour une autre raison, celle-là vraie : un fichier
    /// de zéro octet n'est pas du JSON valide, et la règle n° 2 du projet exige
    /// un refus propre plutôt qu'une lecture optimiste. Lire « aucune règle
    /// deny » dans une troncature ferait entrer en Rockstar en croyant n'avoir
    /// rien à suspendre, alors que les vraies règles reviendront dès que
    /// l'écrivain concurrent aura fini. CONTREPARTIE ASSUMÉE : `syncDenyParking`
    /// tourne à chaque lancement, donc un utilisateur en Rockstar avec un
    /// settings.json tronqué verra cette erreur à chaque démarrage — c'est le
    /// comportement voulu, l'app refuse déjà tout le reste sur ce fichier.
    func testSuspensionRockstarRefuseUnFichierVide() {
        XCTAssertThrowsError(try RockstarPermissionsEditor.park(in: Data()))
    }

    /// La configuration complète survit à une restitution normale — le
    /// correctif ne doit pas transformer le refus en régression fonctionnelle.
    func testRestitutionRockstarPreserveToutLeReste() throws {
        let existing = Data("""
        {"hooks":{"PreToolUse":[]},"statusLine":{"type":"command","command":"maligne"},
         "permissions":{"allow":["Read(*)"]},"env":{"A":"b"},"model":"opus"}
        """.utf8)
        let produced = try RockstarPermissionsEditor.restore(into: existing, parked: ["Bash(rm:*)"])
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: produced) as? [String: Any])
        XCTAssertNotNil(root["hooks"])
        XCTAssertNotNil(root["statusLine"])
        XCTAssertNotNil(root["env"])
        XCTAssertEqual(root["model"] as? String, "opus")
        let permissions = try XCTUnwrap(root["permissions"] as? [String: Any])
        XCTAssertEqual(permissions["allow"] as? [String], ["Read(*)"])
        XCTAssertEqual(permissions["deny"] as? [String], ["Bash(rm:*)"])
    }

    // MARK: - StatusLineEditor (la perte y est DOUBLE)

    /// Sur un fichier vide, `install` reposait `statusLine` seul ET rendait
    /// `originalCommand == nil` : la statusline de l'utilisateur passait pour
    /// inexistante, donc la désinstallation l'aurait supprimée au lieu de la
    /// restituer. Le refus protège les deux.
    func testInstallStatuslineRefuseUnFichierVide() {
        XCTAssertThrowsError(
            try StatusLineEditor.install(into: Data(), wrapperCommand: "/x/atoll-statusline")
        ) {
            XCTAssertEqual($0 as? HookSettingsEditor.EditorError, .unparseableSettings)
        }
    }

    func testInstallStatuslineAccepteUnFichierAbsent() throws {
        let result = try StatusLineEditor.install(into: nil, wrapperCommand: "/x/atoll-statusline")
        XCTAssertNil(result.originalCommand, "aucune statusline préexistante sur machine neuve")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.settings) as? [String: Any])
        XCTAssertNotNil(root["statusLine"])
    }

    func testDesinstallationStatuslineRefuseUnFichierVide() {
        XCTAssertThrowsError(try StatusLineEditor.uninstall(from: Data(), originalCommand: "maligne"))
    }

    func testMigrationRefreshIntervalRefuseUnFichierVide() {
        XCTAssertThrowsError(try StatusLineEditor.addRefreshIntervalIfMissing(into: Data()))
    }

    /// Une vraie configuration doit toujours passer, et la commande d'origine
    /// être mémorisée — c'est elle qui sera restituée à la désinstallation.
    func testInstallStatuslinePreserveEtMemorise() throws {
        let existing = Data(#"{"statusLine":{"type":"command","command":"maligne"},"model":"opus"}"#.utf8)
        let result = try StatusLineEditor.install(into: existing, wrapperCommand: "/x/atoll-statusline")
        XCTAssertEqual(result.originalCommand, "maligne")
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.settings) as? [String: Any])
        XCTAssertEqual(root["model"] as? String, "opus")
    }
}
