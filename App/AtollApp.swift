import SwiftUI

@main
struct AtollApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
