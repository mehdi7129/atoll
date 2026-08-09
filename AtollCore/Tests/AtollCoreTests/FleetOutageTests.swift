import XCTest
@testable import AtollCore

/// Sonde de flotte : distinguer « aucune session » de « je n'ai pas compris »,
/// et ne pas conclure à une extinction générale sur une passe aveugle.
///
/// Principe : des sessions sans rapport entre elles ne s'éteignent pas toutes
/// dans le même intervalle de sonde — une telle passe décrit une panne, pas
/// N décès simultanés. Seuil à 2 sessions : nos flottes se comptent en unités.
final class FleetOutageTests: XCTestCase {

    // MARK: - Décodage : le tableau vide n'est pas une panne

    func testTableauVideEstUneReponseValide() {
        // Le CLI a répondu et il n'y a aucune session : c'est une VRAIE réponse,
        // le retrait par absence doit pouvoir s'appliquer.
        XCTAssertEqual(AgentsSnapshot.decodeOutcome(Data("[]".utf8)), .sessions([]))
    }

    func testJSONInvalideEstUneSondeNonConcluante() {
        XCTAssertEqual(AgentsSnapshot.decodeOutcome(Data("pas du json".utf8)), .unrecognized)
        XCTAssertEqual(AgentsSnapshot.decodeOutcome(Data()), .unrecognized)
    }

    /// LE cas qui motive tout : un format futur. Avant, il rendait `[]` et
    /// l'îlot en concluait que toute la flotte était terminée.
    func testFormatInconnuEstUneSondeNonConcluante() {
        let objet = Data(#"{"error":"unknown flag"}"#.utf8)
        XCTAssertEqual(AgentsSnapshot.decodeOutcome(objet), .unrecognized)

        let scalaire = Data("42".utf8)
        XCTAssertEqual(AgentsSnapshot.decodeOutcome(scalaire), .unrecognized)
    }

    /// Tolérance de forme : si le tableau se retrouve enveloppé demain, on le
    /// lit — plutôt que de déclarer une panne permanente.
    func testTableauEnveloppeEstReconnu() {
        let enveloppe = Data("""
        {"sessions":[{"sessionId":"abc","status":"busy"}]}
        """.utf8)
        guard case .sessions(let infos) = AgentsSnapshot.decodeOutcome(enveloppe) else {
            return XCTFail("l'enveloppe aurait dû être reconnue")
        }
        XCTAssertEqual(infos.count, 1)
        XCTAssertEqual(infos.first?.status, .busy)
    }

    /// `decode` garde son contrat historique : un tableau, jamais un throw.
    func testDecodeResteCompatible() {
        XCTAssertEqual(AgentsSnapshot.decode(Data(#"{"nope":1}"#.utf8)).count, 0)
        XCTAssertEqual(AgentsSnapshot.decode(Data("[]".utf8)).count, 0)
    }

    // MARK: - Disjoncteur de passe

    func testAucuneSessionVueSurPlusieursSuiviesEstUnePanne() {
        XCTAssertTrue(FleetReconciler.isProbeOutage(trackedAlive: 4, seen: 0, degradedStreak: 0))
        XCTAssertTrue(FleetReconciler.isProbeOutage(trackedAlive: 2, seen: 0, degradedStreak: 1))
    }

    /// Une seule session suivie qui disparaît, c'est le cas NORMAL (elle s'est
    /// terminée) : le disjoncteur ne doit pas s'y opposer.
    func testUneSeuleSessionNeDeclenchePasLeDisjoncteur() {
        XCTAssertFalse(FleetReconciler.isProbeOutage(trackedAlive: 1, seen: 0, degradedStreak: 0))
        XCTAssertFalse(FleetReconciler.isProbeOutage(trackedAlive: 0, seen: 0, degradedStreak: 0))
    }

    func testUneSeuleSessionVueSuffitAEcarterLaPanne() {
        XCTAssertFalse(FleetReconciler.isProbeOutage(trackedAlive: 5, seen: 1, degradedStreak: 0))
    }

    /// LE test qui compte : le disjoncteur se RÉ-ARME. Un verrou qui bloque sa
    /// propre file est la faute déjà commise avec l'anti-double-spawn — ici, une
    /// panne durable finirait par empêcher toute clôture, à jamais.
    func testLeDisjoncteurSeReArmeApresDeuxPasses() {
        XCTAssertTrue(FleetReconciler.isProbeOutage(trackedAlive: 3, seen: 0, degradedStreak: 0))
        XCTAssertTrue(FleetReconciler.isProbeOutage(trackedAlive: 3, seen: 0, degradedStreak: 1))
        // Troisième passe consécutive : on laisse la passe de retrait conclure.
        XCTAssertFalse(FleetReconciler.isProbeOutage(trackedAlive: 3, seen: 0, degradedStreak: 2))
        XCTAssertFalse(FleetReconciler.isProbeOutage(trackedAlive: 3, seen: 0, degradedStreak: 9))
    }
}
