import SwiftUI
import ServiceManagement
import AtollCore

struct SettingsView: View {
    @AppStorage(ThemeManager.themeKey) private var themePreference = ThemePreference.system.rawValue
    @AppStorage("paletteID") private var paletteID = Palette.monoOrange.id
    @AppStorage("hoverDelay") private var hoverDelay = 0.15

    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Apparence") {
                Picker("Thème", selection: $themePreference) {
                    ForEach(ThemePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference.rawValue)
                    }
                }
                .onChange(of: themePreference) { _, newValue in
                    ThemeManager.apply(ThemePreference(rawValue: newValue) ?? .system)
                }

                Picker("Palette", selection: $paletteID) {
                    ForEach(Palette.all) { palette in
                        Text(palette.displayName).tag(palette.id)
                    }
                }
            }

            Section("Comportement") {
                VStack(alignment: .leading) {
                    Slider(value: $hoverDelay, in: 0...0.5, step: 0.05) {
                        Text("Délai d'ouverture au survol")
                    }
                    Text("\(Int(hoverDelay * 1000)) ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("Lancer au démarrage", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }

            Section("À propos") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Licence", value: "GPL-3.0-or-later")
                Text("Atoll — une Dynamic Island ASCII pour Claude Code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // L'utilisateur a pu refuser ; on resynchronise l'interrupteur avec l'état réel.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
