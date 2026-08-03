import XCTest
@testable import AtollCore

/// Le niveau d'autonomie après le retrait d'« Auto » (2026-08-03).
///
/// LA QUESTION QUI DÉCIDAIT DE LA SÛRETÉ DU RETRAIT : que devient un utilisateur
/// dont le réglage stocké vaut `auto` ? S'il retombait en Rockstar, on
/// suspendrait ses règles `permissions.deny` sans qu'il ait rien demandé. Ces
/// tests sont la preuve exécutable qu'il retombe en Manuel.
final class AutonomyLevelTests: XCTestCase {

    /// LE test du retrait : un réglage devenu orphelin ne promeut personne.
    func testRemovedAutoFallsBackToTheSafestLevel() {
        XCTAssertEqual(AutonomyLevel.resolve("auto"), .manual)
    }

    func testKnownLevelsSurvive() {
        XCTAssertEqual(AutonomyLevel.resolve("manual"), .manual)
        XCTAssertEqual(AutonomyLevel.resolve("rockstar"), .rockstar)
    }

    func testMissingOrGarbageFallsBackToManual() {
        XCTAssertEqual(AutonomyLevel.resolve(nil), .manual)
        XCTAssertEqual(AutonomyLevel.resolve(""), .manual)
        XCTAssertEqual(AutonomyLevel.resolve("n'importe quoi"), .manual)
    }

    /// Sensible à la casse, comme `rawValue` : « ROCKSTAR » n'active RIEN.
    /// Un réglage trafiqué ou recopié à la main ne doit pas suspendre les règles
    /// `deny` de quelqu'un.
    func testResolutionIsCaseSensitive() {
        XCTAssertEqual(AutonomyLevel.resolve("ROCKSTAR"), .manual)
        XCTAssertEqual(AutonomyLevel.resolve("Rockstar"), .manual)
    }

    /// Le sélecteur des Réglages est construit sur `allCases` : deux niveaux, et
    /// « Auto » ne doit plus pouvoir être choisi.
    func testOnlyTwoLevelsRemain() {
        XCTAssertEqual(AutonomyLevel.allCases, [.manual, .rockstar])
        XCTAssertFalse(AutonomyLevel.allCases.contains { $0.displayName == "Auto" })
    }

    /// Les `rawValue` sont la CLÉ de stockage : les renommer changerait
    /// silencieusement le niveau de tous les utilisateurs.
    func testRawValuesAreStorageAndMustNotDrift() {
        XCTAssertEqual(AutonomyLevel.manual.rawValue, "manual")
        XCTAssertEqual(AutonomyLevel.rockstar.rawValue, "rockstar")
    }

    /// Le libellé de Rockstar doit rester un avertissement, pas une étiquette.
    func testRockstarStillWarns() {
        XCTAssertTrue(AutonomyLevel.rockstar.summary.contains("Aucune protection"))
        XCTAssertTrue(AutonomyLevel.rockstar.summary.contains("deny"))
    }
}
