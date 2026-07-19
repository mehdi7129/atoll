import Foundation
import Observation
import SwiftUI
import AtollCore

/// Chat actif partagé entre les écrans (comme InteractionCenter). Un seul chat
/// à la fois en v1 : lancer une nouvelle conversation Claude depuis l'îlot,
/// ou REPRENDRE celle d'une session existante (fork `--resume` + historique).
@MainActor
@Observable
final class ChatCenter {
    static let shared = ChatCenter()

    private(set) var active: ChatDriver?

    var isActive: Bool { active != nil }

    /// Le panneau chat est plus haut que le panneau standard : ouvrir un chat
    /// utilise le spring d'ouverture ; le fermer (retour 560→340) utilise le
    /// spring de fermeture (amorti, sans rebond) — cohérent avec l'îlot.
    private func setActive(_ driver: ChatDriver?) {
        let spring: Animation = driver == nil
            ? .spring(response: 0.45, dampingFraction: 1.0)
            : .spring(response: 0.42, dampingFraction: 0.8)
        withAnimation(spring) { active = driver }
    }

    /// Démarre une nouvelle conversation dans `cwd`.
    func startNew(cwd: String) {
        active?.stop()
        let driver = ChatDriver(cwd: cwd)
        setActive(driver)
        driver.start()
    }

    /// Reprend la conversation d'une session existante : `claude --resume`
    /// FORKE la session (impossible d'injecter dans le terminal — limite CLI),
    /// et l'historique du transcript est préchargé pour donner le contexte.
    /// Dégradation propre : sans transcript lisible, chat vide fonctionnel.
    func resume(sessionID: String, cwd: String?) {
        active?.stop()
        let driver = ChatDriver(cwd: cwd ?? NSHomeDirectory())
        setActive(driver)
        driver.start(resume: sessionID)

        guard let path = SessionStore.shared.transcriptPath(for: sessionID) else {
            driver.preloadHistory([]) // pas de transcript : lever « en chargement… »
            return
        }
        // Fichiers jusqu'à 88 Mo : lecture fenêtrée HORS du main thread.
        Task.detached(priority: .userInitiated) { [weak self] in
            let history = TranscriptHistory.load(path: path)
            await MainActor.run {
                // Le chat a pu être fermé/remplacé entre-temps : ne préremplir
                // QUE s'il est toujours le chat actif (sinon fuite/incohérence).
                guard self?.active === driver else { return }
                driver.preloadHistory(history)
            }
        }
    }

    func close() {
        active?.stop()
        setActive(nil)
    }
}
