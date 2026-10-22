import SwiftUI
import ServiceManagement
import AtollCore

/// Cinq volets redimensionnables : apparence, connexions, skills et maintenance.
///
/// La fenêtre garde une taille STABLE d'un onglet à l'autre et se
/// redimensionne librement — chaque volet remplit la fenêtre et son Form
/// défile. C'est l'inverse du réglage d'origine, où chaque volet imposait sa
/// hauteur : « À propos » rétrécissait la fenêtre, « Claude Code » ne pouvait
/// pas grandir, et rien ne s'étirait.
///
/// La sélection est persistée (et pilotable en debug pour les captures).
struct SettingsView: View {
    let updaterModel: UpdaterModel

    @AppStorage("settingsTab") private var selectedTab = "general"
    @State private var analysisFocusRequest: UUID?

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralPane()
                .tabItem { Label("Général", systemImage: "paintpalette") }
                .tag("general")
            ConnectionsPane(onShowAnalyses: showAnalyses)
                .tabItem { Label("Connexions", systemImage: "link") }
                .tag("connexions")
            LearningPane(focusRequest: analysisFocusRequest)
                .tabItem { Label("Skills", systemImage: "graduationcap") }
                .tag("apprentissage")
            UpdatesPane(updaterModel: updaterModel)
                .tabItem { Label("Mises à jour", systemImage: "arrow.triangle.2.circlepath") }
                .tag("maj")
            AboutPane()
                .tabItem { Label("À propos", systemImage: "info.circle") }
                .tag("apropos")
        }
        // Fenêtre REDIMENSIONNABLE, et une taille qui ne saute plus d'un
        // onglet à l'autre.
        //
        // Avant : `.frame(width: 640)` figeait la largeur (impossible
        // d'étirer), et chaque volet imposait sa propre hauteur — les uns par
        // `fixedSize` (fenêtre riquiqui sur « À propos »), les autres par un
        // plafond à 620 (impossible d'agrandir « Claude Code »). Le plancher
        // de 640 conserve une largeur lisible pour les formulaires.
        .frame(minWidth: 640, idealWidth: 700, maxWidth: .infinity,
               minHeight: 520, idealHeight: 640, maxHeight: .infinity)
        .background(ResizableWindow())
        .onAppear {
            if ["claude", "codex", "autonomie", "alertes"].contains(selectedTab) { selectedTab = "connexions" }
        }
        .disclosureGroupStyle(SettingsDisclosureStyle())
    }

    private func showAnalyses() {
        analysisFocusRequest = UUID()
        selectedTab = "apprentissage"
    }

    #if DEBUG
    /// Les mêmes vues sur préférences privées ; leurs actions externes sont
    /// neutralisées en aperçu, sans désactiver navigation, volets et contrôles.
    @ViewBuilder static func previewPane(_ pane: String) -> some View {
        Group {
            if pane == "general" { GeneralPane() }
            else if ["claude", "codex", "connections"].contains(pane) { ConnectionsPane(onShowAnalyses: {}) }
            else if pane == "about" { AboutPane() }
            else { LearningPane() }
        }
        .disclosureGroupStyle(SettingsDisclosureStyle())
    }
    #endif
}

/// Rend la fenêtre des Réglages étirable.
///
/// Une scène `Settings` produit une fenêtre NON redimensionnable, et
/// `.windowResizability(.contentMinSize)` n'y change rien : vérifié en capture,
/// le bouton zoom restait désactivé et la fenêtre refusait toute autre taille
/// que celle de son contenu. On ajoute donc le style à la fenêtre elle-même,
/// dès qu'elle existe. Les bornes de taille restent celles déclarées par la
/// vue (plancher 640 × 520).
private struct ResizableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // La fenêtre n'est pas encore attachée pendant `makeNSView`.
        DispatchQueue.main.async {
            view.window?.styleMask.insert(.resizable)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // Le volet est reconstruit à chaque changement d'onglet : on réaffirme
        // le style, au cas où la scène le réinitialiserait.
        view.window?.styleMask.insert(.resizable)
    }
}

// MARK: - Général (apparence + comportement)

private struct GeneralPane: View {
    @AppStorage(ThemeManager.themeKey) private var themePreference = ThemePreference.system.rawValue
    @AppStorage("paletteID") private var paletteID = Palette.monoOrange.id
    @AppStorage(ProviderPreferences.codexPaletteKey) private var codexPaletteID = Palette.monoCyan.id
    @AppStorage("hoverDelay") private var hoverDelay = 0.15
    @AppStorage(VisualEffects.enabledKey) private var visualEffects = true
    @AppStorage(VisualEffects.glassIntensityKey) private var glassIntensity = VisualEffects.defaultGlassIntensity
    @State private var launchAtLogin = false
    @State private var launchError: String?
    @State private var previewWidths: [String: IslandWidth] = [:]
    /// Recalculé à l'apparition (branchement/débranchement d'écran).
    @State private var screens: [ScreenChoice] = []

    /// Un écran connecté : identifiant stable + libellé lisible.
    private struct ScreenChoice: Identifiable {
        let id: String       // displayUUIDString
        let label: String
    }

    var body: some View {
        Form {
            Section("Apparence") {
                Picker("Thème", selection: $themePreference) {
                    ForEach(ThemePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference.rawValue)
                    }
                }
                .onChange(of: themePreference) { _, newValue in
                    if !CodexPreview.enabled { ThemeManager.apply(ThemePreference(rawValue: newValue) ?? .system) }
                }

                Picker("Couleur de Claude Code", selection: $paletteID) {
                    ForEach(Palette.all) { palette in
                        Text(palette.displayName).tag(palette.id)
                    }
                }
                Picker("Couleur de Codex", selection: $codexPaletteID) {
                    ForEach(Palette.all) { palette in Text(palette.displayName).tag(palette.id) }
                }

                Toggle("Effets visuels", isOn: $visualEffects)
                SettingsHelp("La couleur de l'îlot suit le CLI choisi dans le panneau ouvert.")
                DisclosureGroup("Ajuster les effets") {
                    if #available(macOS 26.0, *) {
                        HStack {
                            Slider(value: $glassIntensity, in: 0...1, step: 0.05) {
                                Text("Intensité du Liquid Glass")
                            }
                            Text("\(Int(glassIntensity * 100)) %").monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                        .disabled(!visualEffects)
                    }
                    SettingsHelp("Une intensité de verre plus faible améliore le contraste (macOS 26).\nL'onde est désactivée avec « Réduire les animations » dans macOS.")
                }
            }

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
                SettingsHelp("La largeur de l'îlot compact se règle séparément pour chaque écran.")
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
                        if !CodexPreview.enabled { setLaunchAtLogin(newValue) }
                    }
                if let launchError { SettingsHelp(launchError) }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            launchAtLogin = CodexPreview.enabled ? true : SMAppService.mainApp.status == .enabled
            refreshScreens()
        }
    }

    private func refreshScreens() {
        if CodexPreview.enabled {
            screens = [ScreenChoice(id: "macbook", label: "Écran du MacBook"),
                       ScreenChoice(id: "external", label: "Écran externe")]
            return
        }
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
            get: { CodexPreview.enabled ? previewWidths[displayID] ?? .medium : IslandSettings.shared.width(for: displayID) },
            set: { value in
                if CodexPreview.enabled { previewWidths[displayID] = value }
                else { IslandSettings.shared.setWidth(value, for: displayID) }
            }
        )
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        launchError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // L'utilisateur a pu refuser ; on resynchronise l'interrupteur.
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchError = "Le lancement au démarrage n'a pas été modifié : " + error.localizedDescription
        }
    }
}

// MARK: - Mises à jour

private struct UpdatesPane: View {
    @ObservedObject var updaterModel: UpdaterModel
    @State private var previewAutomatic = false
    @State private var previewMessage: String?

    var body: some View {
        Form {
            Section("Mises à jour") {
                LabeledContent("Version installée", value: settingsAppVersion)
                Toggle("Vérifier automatiquement", isOn: automaticUpdateChecks)
                SettingsHelp("Vérifie chaque jour si une version est disponible. Désactiver arrête uniquement cette vérification automatique.")
                Button(updaterModel.updateAvailable ? "Voir la mise à jour…" : "Vérifier maintenant") {
                    if CodexPreview.enabled { previewMessage = "Vérification simulée : aucun accès réseau." }
                    else { updaterModel.checkForUpdates() }
                }
                .disabled(!CodexPreview.enabled && !updaterModel.canCheckForUpdates)
                if let previewMessage { SettingsHelp(previewMessage) }
                SettingsHelp("Le quota et les analyses conservent leurs propres réglages. Atoll ne collecte aucune télémétrie.")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var automaticUpdateChecks: Binding<Bool> {
        Binding(
            get: { CodexPreview.enabled ? previewAutomatic : updaterModel.updater.automaticallyChecksForUpdates },
            set: {
                if CodexPreview.enabled { previewAutomatic = $0 }
                else { updaterModel.updater.automaticallyChecksForUpdates = $0 }
            }
        )
    }
}

// MARK: - À propos

private struct AboutPane: View {
    var body: some View {
        Form {
            Section("À propos") {
                LabeledContent("Version", value: settingsAppVersion)
                LabeledContent("Licence", value: "GPL-3.0-or-later")
                SettingsHelp("La Dynamic Island pour Claude Code et Codex CLI.")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}

private var settingsAppVersion: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(version) · build \(build)"
}
