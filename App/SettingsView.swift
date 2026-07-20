import SwiftUI
import ServiceManagement
import AtollCore

/// Réglages en ONGLETS (standard macOS) : chaque volet reste compact — la
/// fenêtre s'adapte à l'onglet au lieu d'empiler 7 sections plus hautes que
/// l'écran (vécu). La sélection est persistée (et pilotable en debug pour les
/// captures d'écran).
struct SettingsView: View {
    let updaterModel: UpdaterModel

    @AppStorage("settingsTab") private var selectedTab = "general"

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralPane()
                .tabItem { Label("Général", systemImage: "paintpalette") }
                .tag("general")
            ClaudeCodePane()
                .tabItem { Label("Claude Code", systemImage: "terminal") }
                .tag("claude")
            AutonomyPane()
                .tabItem { Label("Autonomie", systemImage: "bolt") }
                .tag("autonomie")
            UpdatesPane(updaterModel: updaterModel)
                .tabItem { Label("Mises à jour", systemImage: "arrow.triangle.2.circlepath") }
                .tag("maj")
            AboutPane()
                .tabItem { Label("À propos", systemImage: "info.circle") }
                .tag("apropos")
        }
        .frame(width: 480)
    }
}

// MARK: - Général (apparence + comportement)

private struct GeneralPane: View {
    @AppStorage(ThemeManager.themeKey) private var themePreference = ThemePreference.system.rawValue
    @AppStorage("paletteID") private var paletteID = Palette.monoOrange.id
    @AppStorage("hoverDelay") private var hoverDelay = 0.15
    @State private var launchAtLogin = false
    /// Recalculé à l'apparition (branchement/débranchement d'écran).
    @State private var screens: [ScreenChoice] = []

    /// Un écran connecté : identifiant stable + libellé lisible.
    private struct ScreenChoice: Identifiable {
        let id: String       // displayUUIDString
        let label: String
    }

    var body: some View {
        Form {
            Section("Taille de l'îlot") {
                // Réglable INDÉPENDAMMENT par écran (ex. large sur le moniteur
                // externe, petit sur le MacBook). N'affecte que la barre compacte.
                ForEach(screens) { screen in
                    Picker(screen.label, selection: widthBinding(for: screen.id)) {
                        ForEach(IslandWidth.allCases) { width in
                            Text(width.displayName).tag(width)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Text("La largeur de la petite barre autour du notch (et de la pilule sur un écran sans encoche). L'encoche physique, elle, ne change pas.")
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
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            refreshScreens()
        }
    }

    private func refreshScreens() {
        let main = NSScreen.main
        screens = NSScreen.screens.enumerated().map { index, screen in
            var label = screen.localizedName
            if screen == main { label += " · principal" }
            if !screen.hasNotch { label += " · sans encoche" }
            return ScreenChoice(id: screen.displayUUIDString, label: label)
        }
    }

    private func widthBinding(for displayID: String) -> Binding<IslandWidth> {
        Binding(
            get: { IslandSettings.shared.width(for: displayID) },
            set: { IslandSettings.shared.setWidth($0, for: displayID) }
        )
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // L'utilisateur a pu refuser ; on resynchronise l'interrupteur.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Claude Code (hooks + quota)

private struct ClaudeCodePane: View {
    @State private var hooksInstalled = false
    @State private var hookError: String?
    @State private var denyParkingError: String?

    private var store: SessionStore { .shared }

    var body: some View {
        Form {
            Section("Branchement") {
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
                if let denyParkingError {
                    Text(denyParkingError)
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

            Section("Quota") {
                Toggle("Jauges par modèle (Fable…)", isOn: perModelQuota)
                Text("""
                Complète le 5h/7j officiel avec le détail par modèle de la page \
                Utilisation de claude.ai (endpoint non documenté, lecture seule avec \
                votre jeton local, jamais de renouvellement). Peut cesser de fonctionner \
                à tout moment ; macOS demandera une fois l'accès au trousseau.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { hooksInstalled = HookInstaller.isInstalled }
    }

    private var perModelQuota: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: ModelQuotaPoller.enabledKey) },
            set: {
                UserDefaults.standard.set($0, forKey: ModelQuotaPoller.enabledKey)
                ModelQuotaPoller.shared.syncWithSettings()
            }
        )
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
        let level = AutonomyLevel(rawValue: UserDefaults.standard.string(forKey: InteractionCenter.autonomyKey) ?? "") ?? .manual
        denyParkingError = HookInstaller.syncDenyParking(level: level)
    }
}

// MARK: - Autonomie

private struct AutonomyPane: View {
    @AppStorage(InteractionCenter.autonomyKey) private var autonomyRaw = AutonomyLevel.manual.rawValue
    @State private var confirmingRockstar = false
    @State private var denyParkingError: String?

    private var center: InteractionCenter { .shared }
    private var currentLevel: AutonomyLevel { AutonomyLevel(rawValue: autonomyRaw) ?? .manual }

    var body: some View {
        Form {
            Section("Niveau d'autonomie") {
                // Un seul réglage exclusif : Manuel / Auto / Rockstar.
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
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            // Auto-réparation : si un état incohérent subsiste (règles parquées
            // hors Rockstar après un échec), on retente en ouvrant les Réglages.
            denyParkingError = HookInstaller.syncDenyParking(level: currentLevel)
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
    }
}

// MARK: - Mises à jour

private struct UpdatesPane: View {
    let updaterModel: UpdaterModel

    var body: some View {
        Form {
            Section("Mises à jour") {
                Toggle("Vérifier automatiquement", isOn: automaticUpdateChecks)
                Text("""
                Opt-in — désactivé, Atoll ne contacte jamais le réseau (zéro télémétrie). \
                Activé, Sparkle interroge une fois par jour le flux du projet (GitHub Pages) \
                et signale les mises à jour d'un ◆ discret dans le menu. Vérification \
                manuelle à tout moment via le menu ≋.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Persisté par Sparkle dans les user defaults (prime sur l'Info.plist).
    private var automaticUpdateChecks: Binding<Bool> {
        Binding(
            get: { updaterModel.updater.automaticallyChecksForUpdates },
            set: { updaterModel.updater.automaticallyChecksForUpdates = $0 }
        )
    }
}

// MARK: - À propos

private struct AboutPane: View {
    var body: some View {
        Form {
            Section("À propos") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Licence", value: "GPL-3.0-or-later")
                Text("Atoll — une Dynamic Island ASCII pour Claude Code.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
