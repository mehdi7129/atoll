import SwiftUI
import Darwin
import Combine
import Sparkle

@main
struct AtollApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Sparkle. En Debug l'updater ne démarre PAS : le build de dev pointerait
    /// le flux de production et s'auto-remplacerait par la release notarisée.
    /// Vérifications automatiques OPT-IN (Réglages) — zéro réseau par défaut.
    private let updaterModel: UpdaterModel

    init() {
        // Ceinture et bretelles : écrire dans un socket dont le pair est mort ne
        // doit jamais tuer l'app (SO_NOSIGPIPE couvre déjà chaque fd client).
        signal(SIGPIPE, SIG_IGN)
        #if DEBUG
        updaterModel = UpdaterModel(startsUpdater: false)
        #else
        updaterModel = UpdaterModel(startsUpdater: true)
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(model: updaterModel)
        } label: {
            Image(systemName: "water.waves")
        }

        Settings {
            SettingsView(updaterModel: updaterModel)
        }
    }
}

/// Enrobe SPUStandardUpdaterController pour une app de barre de menus
/// (LSUIElement) : les alertes de mise à jour PLANIFIÉES s'afficheraient
/// derrière les autres fenêtres — on opte pour les « gentle reminders » de
/// Sparkle : un signal discret dans le menu, l'alerte ne surgit qu'au clic.
@MainActor
final class UpdaterModel: NSObject, ObservableObject, SPUStandardUserDriverDelegate {
    @Published var canCheckForUpdates = false
    /// Une mise à jour attend : signalée dans le menu (◆ Mise à jour disponible…).
    @Published var updateAvailable = false

    private var controller: SPUStandardUpdaterController!
    var updater: SPUUpdater { controller.updater }

    init(startsUpdater: Bool) {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: startsUpdater, updaterDelegate: nil, userDriverDelegate: self)
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    // MARK: - SPUStandardUserDriverDelegate (gentle reminders)

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        // Check planifié dont Sparkle ne gère pas l'affichage → notre rappel doux.
        guard !state.userInitiated else { return }
        DispatchQueue.main.async { self.updateAvailable = true }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        DispatchQueue.main.async { self.updateAvailable = false }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        DispatchQueue.main.async { self.updateAvailable = false }
    }
}

struct MenuBarMenu: View {
    @ObservedObject var model: UpdaterModel

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // App LSUIElement : sans activation explicite, la fenêtre Réglages
        // s'ouvrirait derrière l'app frontale, sans focus.
        Button("Réglages…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Button("Bienvenue…") {
            (NSApp.delegate as? AppDelegate)?.showOnboarding()
        }

        Divider()

        Button(model.updateAvailable
               ? "◆ Mise à jour disponible…"
               : "Rechercher les mises à jour…") {
            model.checkForUpdates()
        }
        .disabled(!model.canCheckForUpdates)

        Divider()

        Button("Quitter Atoll") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
