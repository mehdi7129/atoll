import SwiftUI
import ServiceManagement
import AtollCore

struct SettingsView: View {
    @AppStorage(ThemeManager.themeKey) private var themePreference = ThemePreference.system.rawValue
    @AppStorage("paletteID") private var paletteID = Palette.monoOrange.id
    @AppStorage("hoverDelay") private var hoverDelay = 0.15

    @State private var launchAtLogin = false
    @State private var hooksInstalled = false
    @State private var hookError: String?
    @AppStorage(InteractionCenter.autoAcceptKey) private var autoAccept = false

    private var store: SessionStore { .shared }
    private var center: InteractionCenter { .shared }

    var body: some View {
        Form {
            Section("Claude Code") {
                LabeledContent("Hooks", value: hooksInstalled ? "installés ✓" : "non installés")
                LabeledContent(
                    "Réception",
                    value: store.serverRunning
                        ? "active · \(store.eventCount) événement(s)"
                        : "inactive"
                )
                Button(hooksInstalled ? "Désinstaller les hooks" : "Installer les hooks") {
                    toggleHooks()
                }
                if let hookError {
                    Text(hookError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("""
                Fail-open : Atoll fermé ou planté, Claude Code fonctionne exactement comme avant. \
                Vos hooks existants sont préservés ; backup unique dans \
                ~/.claude/settings.json.atoll-backup. Les sessions déjà ouvertes prennent \
                les hooks à leur prochain démarrage.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Auto-accept") {
                Toggle("Auto-accepter les permissions", isOn: $autoAccept)
                if autoAccept, center.autoAcceptedCount > 0 {
                    LabeledContent("Auto-acceptées", value: "\(center.autoAcceptedCount)")
                }
                Text("""
                Claude avance sans attendre : les permissions d'outils sûres sont approuvées \
                automatiquement (badge [ AUTO ] sur l'îlot). Garde-fous — vos règles deny et vos \
                hooks bloquants s'exécutent AVANT Atoll et ne peuvent pas être outrepassés ; les \
                commandes destructrices (rm, sudo, force-push, pipe-to-shell…), la validation des \
                plans et les questions restent toujours manuelles.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

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
            hooksInstalled = HookInstaller.isInstalled
        }
    }

    private func toggleHooks() {
        hookError = nil
        do {
            if hooksInstalled {
                try HookInstaller.uninstall()
            } else {
                try HookInstaller.install()
            }
        } catch {
            hookError = error.localizedDescription
        }
        hooksInstalled = HookInstaller.isInstalled
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
