import SwiftUI
import Darwin

@main
struct AtollApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Ceinture et bretelles : écrire dans un socket dont le pair est mort ne
        // doit jamais tuer l'app (SO_NOSIGPIPE couvre déjà chaque fd client).
        signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu()
        } label: {
            Image(systemName: "water.waves")
        }

        Settings {
            SettingsView()
        }
    }
}

struct MenuBarMenu: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // App LSUIElement : sans activation explicite, la fenêtre Réglages
        // s'ouvrirait derrière l'app frontale, sans focus.
        Button("Réglages…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quitter Atoll") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
