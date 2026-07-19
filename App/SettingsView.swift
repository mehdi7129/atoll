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
    @AppStorage(InteractionCenter.autonomyKey) private var autonomyRaw = AutonomyLevel.manual.rawValue
    @State private var confirmingRockstar = false

    private var store: SessionStore { .shared }
    private var center: InteractionCenter { .shared }
    private var currentLevel: AutonomyLevel { AutonomyLevel(rawValue: autonomyRaw) ?? .manual }

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

            Section("Niveau d'autonomie") {
                // Un seul réglage exclusif : Manuel / Auto / Rockstar. Aucun état
                // contradictoire possible.
                Picker("Niveau", selection: Binding(
                    get: { AutonomyLevel(rawValue: autonomyRaw) ?? .manual },
                    set: { newLevel in
                        if newLevel == .rockstar {
                            confirmingRockstar = true // confirmer avant d'activer
                        } else {
                            autonomyRaw = newLevel.rawValue
                        }
                    }
                )) {
                    ForEach(AutonomyLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)

                Text(currentLevel.summary)
                    .font(.caption)
                    .foregroundStyle(currentLevel == .rockstar ? .red : .secondary)

                if currentLevel != .manual, center.autoAcceptedCount > 0 {
                    LabeledContent("Auto-approuvées", value: "\(center.autoAcceptedCount)")
                }

                Text("""
                Garde-fou commun à Auto et Rockstar : vos règles deny et vos hooks bloquants \
                (ex. Bash(rm -rf *)) s'exécutent dans Claude Code AVANT Atoll et ne peuvent jamais \
                être outrepassés. Rockstar n'est activable qu'ici, avec confirmation.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .alert("Activer le mode Rockstar ?", isPresented: $confirmingRockstar) {
                Button("Annuler", role: .cancel) { }
                Button("Activer", role: .destructive) { autonomyRaw = AutonomyLevel.rockstar.rawValue }
            } message: {
                Text("Claude approuvera automatiquement TOUTES les demandes, y compris les commandes destructrices non couvertes par vos règles deny. À utiliser en connaissance de cause.")
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
