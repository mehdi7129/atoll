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

    /// Le panneau chat est plus haut que le panneau standard : toute mutation
    /// de `active` s'anime avec les mêmes springs que l'expansion de l'îlot.
    private func setActive(_ driver: ChatDriver?) {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            active = driver
        }
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

        guard let path = SessionStore.shared.transcriptPath(for: sessionID) else { return }
        // Fichiers jusqu'à 88 Mo : lecture fenêtrée HORS du main thread.
        Task.detached(priority: .userInitiated) {
            let history = TranscriptHistory.load(path: path)
            guard !history.isEmpty else { return }
            await MainActor.run { driver.preloadHistory(history) }
        }
    }

    func close() {
        active?.stop()
        setActive(nil)
    }
}
