import Foundation
import Observation
import AtollCore

/// Chat actif partagé entre les écrans (comme InteractionCenter). Un seul chat
/// à la fois en v1 : lancer une nouvelle conversation Claude depuis l'îlot.
@MainActor
@Observable
final class ChatCenter {
    static let shared = ChatCenter()

    private(set) var active: ChatDriver?

    var isActive: Bool { active != nil }

    /// Démarre une nouvelle conversation dans `cwd`.
    func startNew(cwd: String) {
        active?.stop()
        let driver = ChatDriver(cwd: cwd)
        active = driver
        driver.start()
    }

    func close() {
        active?.stop()
        active = nil
    }
}
