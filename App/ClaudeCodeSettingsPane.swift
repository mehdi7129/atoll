import SwiftUI
import AtollCore

struct ClaudeCodePane: View {
    let onShowAnalyses: () -> Void
    @AppStorage(ModelQuotaPoller.enabledKey) private var perModelQuota = false
    @State private var hooksInstalled = false
    @State private var hookError: String?
    @State private var confirmingUninstall = false
    @State private var denyParkingError: String?
    @State private var plugins = PluginInventory.shared
    @State private var pluginError: String?
    @State private var pluginNeed = ""
    @State private var confirmingInstall: PluginSearchResult.Match?

    private var store: SessionStore { .shared }

    var body: some View {
        Form {
            Section("Intégration Atoll") {
                LabeledContent("Claude Code", value: hooksInstalled ? "Installée" : "À installer")
                if !hooksInstalled {
                    Button("Installer l'intégration Claude Code") { toggleHooks() }
                        .buttonStyle(.borderedProminent)
                    SettingsHelp("Reprends ensuite tes sessions Claude Code pour activer le suivi.")
                } else {
                    SettingsHelp("Les sessions et leurs demandes apparaissent dans l'îlot.")
                }
                if let hookError { Text(hookError).foregroundStyle(.red) }
                if let denyParkingError { Text(denyParkingError).foregroundStyle(.red) }
            }
            Section("Quota") {
                Toggle("Afficher le détail par modèle", isOn: $perModelQuota)
                    .onChange(of: perModelQuota) { _, _ in
                        if !CodexPreview.enabled { ModelQuotaPoller.shared.syncWithSettings() }
                    }
                SettingsHelp("Ajoute les jauges disponibles pour chaque modèle. macOS peut demander l'accès au trousseau.")
            }
            Section("Analyses d'Atoll") {
                SettingsHelp("Le moteur et les modèles se choisissent dans Apprentissage, pour les bilans, les notes et la recherche IA de plugins.")
                Button("Régler les analyses…", action: onShowAnalyses)
            }
            Section {
                // Les anomalies précèdent le volet fermé, jamais cachées dans l'inventaire.
                if let error = pluginError ?? plugins.lastError {
                    Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if let snapshot = plugins.snapshot {
                    if !snapshot.broken.isEmpty {
                        Text("Plugins incomplets : " + snapshot.broken.map { "\($0.name) (\($0.isEnabled ? "activé" : "désactivé"))" }.joined(separator: ", "))
                            .font(.callout).foregroundStyle(.red)
                    }
                    if !snapshot.duplicateNames.isEmpty {
                        Text("Présents dans plusieurs marketplaces : " + snapshot.duplicateNames.joined(separator: ", "))
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
                DisclosureGroup(plugins.snapshot.map { "Plugins Claude Code · \($0.installed.count) installés" } ?? "Plugins Claude Code") {
                    pluginInventory
                    DisclosureGroup("Trouver un plugin") { pluginSearch }
                }
            }
            Section {
                DisclosureGroup("Dépannage") {
                    LabeledContent("Réception globale d'Atoll", value: CodexPreview.enabled ? "active · exemple"
                        : store.serverRunning ? "active · \(store.eventCount) événement(s)" : "inactive")
                        .font(.callout)
                    SettingsHelp("Ce compteur comprend les événements des deux CLI.")
                    if hooksInstalled {
                        Button("Retirer l'intégration Claude Code…") {
                            if !CodexPreview.enabled, !SkillReviewCenter.shared.installed.isEmpty {
                                confirmingUninstall = true
                            } else { toggleHooks() }
                        }
                        SettingsHelp("Retire les hooks Atoll et archive les skills appris pour Claude. Les anciens sons sont restaurés ; tes autres hooks sont conservés.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Installer ce plugin ?", isPresented: Binding(
            get: { confirmingInstall != nil },
            set: { if !$0 { confirmingInstall = nil } }
        ), presenting: confirmingInstall) { match in
            Button("Annuler", role: .cancel) { confirmingInstall = nil }
            Button("Installer", role: .destructive) {
                let id = match.pluginID
                confirmingInstall = nil
                if !CodexPreview.enabled { Task { pluginError = await plugins.install(pluginID: id) } }
            }
        } message: { match in
            Text("\(match.pluginID) sera installé par Claude Code. Un plugin peut enregistrer des hooks et lancer des serveurs MCP : ce code tiers s'exécutera avec tes droits. Il restera désactivable à tout moment.")
        }
        .alert("Retirer l'intégration Claude Code ?", isPresented: $confirmingUninstall) {
            Button("Annuler", role: .cancel) { }
            Button("Retirer", role: .destructive) { toggleHooks() }
        } message: {
            let names = SkillReviewCenter.shared.installed.map { SkillSlug.dirName(for: $0.skill.slug) }.joined(separator: ", ")
            Text("Cela retire aussi les skills appris de ~/.claude/skills (\(names)). Ils sont copiés dans ~/.atoll/learning/archive/uninstalled/. Réinstaller l'intégration ne les remettra pas en place ; il faudra les recopier. Tes anciens hooks sonores sont restaurés.")
        }
        .onAppear {
            hooksInstalled = CodexPreview.enabled ? !CommandLine.arguments.contains("--preview-uninstalled") : HookInstaller.isInstalled
            if CodexPreview.enabled, CommandLine.arguments.contains("--preview-plugin-error") {
                pluginError = "Inventaire indisponible : réessaie la lecture des plugins."
            }
        }
    }

    private var pluginInventory: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = plugins.snapshot {
                LabeledContent("Installés", value: pluginSummary(snapshot))
                if let date = plugins.lastRefreshedAt {
                    SettingsHelp("Lu à \(date.formatted(date: .omitted, time: .shortened)). Actualise pour relire l'état du CLI.")
                }
                ForEach(snapshot.installed.filter(\.isEnabled)) { plugin in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(plugin.name)
                            Text(pluginDetail(plugin)).font(.caption)
                                .foregroundStyle(plugin.hasLoadError ? .red : .secondary)
                        }
                        Spacer()
                        Button("Désactiver") {
                            if !CodexPreview.enabled { Task { pluginError = await plugins.setEnabled(false, pluginID: plugin.id) } }
                        }
                        .help("Le plugin reste installé ; réactivation avec claude plugin enable.")
                        .buttonStyle(.borderless).disabled(plugins.busyPluginID != nil)
                    }
                }
                if !snapshot.installedButDisabled.isEmpty {
                    SettingsHelp("\(snapshot.installedButDisabled.count) installés mais inactifs : aucun coût en contexte.")
                }
            } else if plugins.isRefreshing {
                ProgressView("Lecture…").controlSize(.small)
            } else { SettingsHelp("Lis l'inventaire pour afficher les plugins installés.") }
            HStack {
                Button("Actualiser l'inventaire") {
                    pluginError = nil
                    if !CodexPreview.enabled { plugins.refresh() }
                }
                .disabled(plugins.isRefreshing)
                Button("Estimer le contexte des plugins") {
                    guard !CodexPreview.enabled else { return }
                    for plugin in plugins.snapshot?.installed.filter(\.isEnabled) ?? [] {
                        plugins.loadTokenCost(for: plugin.id)
                    }
                }
                .disabled(plugins.snapshot == nil)
            }
            SettingsHelp("Désactiver conserve l'installation. Le coût affiché est une estimation par session.")
        }
        .padding(.vertical, 4)
    }

    private var pluginSearch: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Décris ton besoin", text: $pluginNeed)
                    .textFieldStyle(.roundedBorder).onSubmit { runPluginSearch() }
                Button("Chercher") { runPluginSearch() }
                    .disabled(pluginNeed.trimmingCharacters(in: .whitespaces).isEmpty || plugins.isSearching)
            }
            Button("Affiner avec l'IA") { runPluginSearch(useAI: true) }
                .disabled(pluginNeed.trimmingCharacters(in: .whitespaces).isEmpty || plugins.isSearching)
            if plugins.isSearching {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Recherche…")
                    Button("Annuler") { if !CodexPreview.enabled { plugins.cancel() } }
                }
            }
            ForEach(plugins.searchMatches, id: \.pluginID) { match in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(match.pluginID)
                        Text(match.reason).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Installer…") { confirmingInstall = match }
                        .buttonStyle(.borderless).disabled(plugins.busyPluginID != nil)
                }
            }
            SettingsHelp("Catalogue Claude Code. L'option IA utilise l'abonnement choisi dans Apprentissage et transmet ton besoin et les descriptions du catalogue.")
        }
        .padding(.vertical, 4)
    }

    private func runPluginSearch(useAI: Bool = false) {
        guard !CodexPreview.enabled else { pluginError = "Recherche simulée : aucun plugin installé."; return }
        let need = pluginNeed
        Task { pluginError = await plugins.search(need: need, useAI: useAI) }
    }

    /// « 31 installés · 4 activés · 1 cassé ».
    private func pluginSummary(_ snapshot: PluginSnapshot) -> String {
        var parts = ["\(snapshot.installed.count) installés",
                     "\(snapshot.enabledCount) activés"]
        if !snapshot.broken.isEmpty { parts.append("\(snapshot.broken.count) cassé(s)") }
        return parts.joined(separator: " · ")
    }

    /// « v6.2.0 · ~688 tok/session · 2 serveurs MCP ».
    private func pluginDetail(_ plugin: InstalledPlugin) -> String {
        var parts: [String] = []
        if let version = plugin.version, version != "unknown" { parts.append("v\(version)") }
        if let tokens = plugins.tokenCosts[plugin.id] {
            parts.append("~\(tokens) tok/session")
        }
        if !plugin.mcpServerNames.isEmpty {
            parts.append("\(plugin.mcpServerNames.count) serveur(s) MCP")
        }
        if plugin.hasLoadError { parts.append("chargement en échec") }
        return parts.isEmpty ? (plugin.marketplace ?? "") : parts.joined(separator: " · ")
    }

    private func toggleHooks() {
        hookError = nil
        guard !CodexPreview.enabled else { hooksInstalled.toggle(); return }
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
        let level = AutonomyLevel.resolve(UserDefaults.standard.string(forKey: InteractionCenter.autonomyKey))
        denyParkingError = HookInstaller.syncDenyParking(level: level)
    }
}
