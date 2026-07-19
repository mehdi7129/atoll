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
    @State private var denyParkingError: String?

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
                            // Quitter Rockstar restaure les règles deny parquées.
                            denyParkingError = HookInstaller.syncDenyParking(level: newLevel)
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

                if currentLevel == .rockstar, HookInstaller.denyRulesParked {
                    LabeledContent("Règles deny", value: "suspendues")
                }

                if currentLevel != .rockstar, HookInstaller.denyRulesParked {
                    // État le plus dangereux : parqué HORS Rockstar (restauration
                    // échouée ?). Toujours visible, jamais silencieux.
                    Text("⚠ Vos règles deny sont encore suspendues — restauration à retenter (relancez Atoll ou rechangez de niveau).")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if let denyParkingError {
                    Text(denyParkingError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("""
                Auto garde des garde-fous (allowlist ; destructif, plans et questions restent \
                manuels). Rockstar n'en a AUCUN : tout est approuvé et vos règles deny \
                (ex. Bash(rm -rf *)) sont suspendues — parquées tant que le niveau reste \
                Rockstar, même app fermée, puis restaurées dès que vous le quittez. Les \
                sessions déjà ouvertes gardent les règles qu'elles ont lues : redémarrez-les \
                pour appliquer. Vos propres hooks bloquants restent toujours actifs.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .alert("Activer le mode Rockstar ?", isPresented: $confirmingRockstar) {
                Button("Annuler", role: .cancel) { }
                Button("Activer", role: .destructive) {
                    autonomyRaw = AutonomyLevel.rockstar.rawValue
                    // Entrer en Rockstar suspend (parque) les règles deny et
                    // résout les cartes déjà en attente.
                    denyParkingError = HookInstaller.syncDenyParking(level: .rockstar)
                    InteractionCenter.shared.resolvePendingAsRockstar()
                }
            } message: {
                Text("""
                Plus AUCUNE protection : Claude approuvera TOUTES les demandes (y compris \
                destructrices) et répondra seul aux questions et plans — effet immédiat, \
                sessions en cours comprises. Vos règles deny (rm -rf, sudo, .env…) sont \
                suspendues jusqu'à la sortie de ce mode ; les sessions déjà ouvertes les \
                ayant déjà lues, redémarrez-les pour en profiter.
                """)
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
            // Auto-réparation : si un état incohérent subsiste (règles parquées
            // hors Rockstar après un échec), on retente en ouvrant les Réglages.
            denyParkingError = HookInstaller.syncDenyParking(level: currentLevel)
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
        // Le parking suit la disponibilité des hooks : désinstaller restaure les
        // règles (fait par le helper), réinstaller en Rockstar les reparque.
        denyParkingError = HookInstaller.syncDenyParking(level: currentLevel)
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
