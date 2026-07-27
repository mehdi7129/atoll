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
            AlertsPane()
                .tabItem { Label("Alertes", systemImage: "bell") }
                .tag("alertes")
            LearningPane()
                .tabItem { Label("Apprentissage", systemImage: "graduationcap") }
                .tag("apprentissage")
            UpdatesPane(updaterModel: updaterModel)
                .tabItem { Label("Mises à jour", systemImage: "arrow.triangle.2.circlepath") }
                .tag("maj")
            AboutPane()
                .tabItem { Label("À propos", systemImage: "info.circle") }
                .tag("apropos")
        }
        // 640 et non 480 : à 7 onglets, la barre débordait et macOS repliait
        // « Mises à jour » et « À propos » derrière un chevron « » » (vu en
        // capture) — des réglages invisibles sont des réglages morts.
        .frame(width: 640)
    }
}

// MARK: - Général (apparence + comportement)

private struct GeneralPane: View {
    @AppStorage(ThemeManager.themeKey) private var themePreference = ThemePreference.system.rawValue
    @AppStorage("paletteID") private var paletteID = Palette.monoOrange.id
    @AppStorage("hoverDelay") private var hoverDelay = 0.15
    @AppStorage(VisualEffects.enabledKey) private var visualEffects = true
    @AppStorage(VisualEffects.glassIntensityKey) private var glassIntensity = VisualEffects.defaultGlassIntensity
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

                Toggle("Effets visuels", isOn: $visualEffects)
                if #available(macOS 26.0, *) {
                    VStack(alignment: .leading) {
                        Slider(value: $glassIntensity, in: 0...1, step: 0.05) {
                            Text("Intensité du Liquid Glass")
                        }
                        Text("\(Int(glassIntensity * 100)) %")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!visualEffects)
                }
                Text("""
                Fond en Liquid Glass autour du notch (macOS 26 ; aplat sobre en deçà) \
                et une onde discrète à l'ouverture de l'îlot. Plus l'intensité monte, \
                plus le verre réfracte ce qu'il y a derrière (au prix du contraste) ; \
                à 0 %, fond plein, aucun verre. Désactiver coupe verre et animation. \
                L'onde respecte toujours « Réduire les animations » du système.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
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
    @State private var proactiveRecallError: String?
    @State private var plugins = PluginInventory.shared
    @State private var pluginError: String?
    @State private var pluginNeed = ""
    @State private var confirmingInstall: PluginSearchResult.Match?

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

            Section("Mémoire") {
                Toggle("Indexer les sessions passées", isOn: memoryIndexing)
                if let stats = MemoryIndexer.shared.stats {
                    LabeledContent("Index", value: indexSummary(stats))
                }
                Button("Reconstruire l'index") {
                    MemoryIndexer.shared.rebuild()
                }
                .disabled(MemoryIndexer.shared.isIndexing || !memoryIndexing.wrappedValue)
                Text("""
                Index local (~/.atoll/memory.db) de tous vos transcripts, interrogeable \
                par vos sessions Claude via le skill « atoll-recall » — « retrouve quand \
                on a parlé de… ». Rien ne quitte votre machine. Désactiver stoppe \
                l'indexation ; supprimer ~/.atoll efface tout.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Plugins") {
                if let snapshot = plugins.snapshot {
                    LabeledContent("Installés", value: pluginSummary(snapshot))
                    // Les anomalies AVANT la liste : c'est ce pour quoi on
                    // ouvre ce panneau.
                    if !snapshot.broken.isEmpty {
                        Text("⚠ cassé(s) : \(snapshot.broken.map(\.name).joined(separator: ", ")) — activé(s) mais des fichiers déclarés manquent")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if !snapshot.duplicateNames.isEmpty {
                        Text("⚠ présents dans deux marketplaces : \(snapshot.duplicateNames.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ForEach(snapshot.installed.filter(\.isEnabled)) { plugin in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(plugin.name)
                                Text(pluginDetail(plugin))
                                    .font(.caption)
                                    .foregroundStyle(plugin.hasLoadError ? .red : .secondary)
                            }
                            Spacer()
                            Button("Désactiver") {
                                Task { pluginError = await plugins.setEnabled(false, pluginID: plugin.id) }
                            }
                            .help("Le plugin reste installé ; réactivable par `claude plugin enable`.")
                            .buttonStyle(.borderless)
                            .disabled(plugins.busyPluginID != nil)
                        }
                    }
                    if !snapshot.installedButDisabled.isEmpty {
                        LabeledContent("Installés mais inactifs",
                                       value: "\(snapshot.installedButDisabled.count) — aucun coût en contexte")
                            .font(.caption)
                    }
                } else if plugins.isRefreshing {
                    HStack { ProgressView().controlSize(.small); Text("Lecture…").font(.caption) }
                } else {
                    Text("Aucun inventaire — cliquez pour interroger `claude plugin list`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Actualiser") {
                        pluginError = nil // une erreur passée ne survit pas à un succès
                        plugins.refresh()
                    }
                        .disabled(plugins.isRefreshing)
                    Button("Coût en tokens") {
                        // À la demande : `claude plugin details` par plugin activé.
                        for plugin in plugins.snapshot?.installed.filter(\.isEnabled) ?? [] {
                            plugins.loadTokenCost(for: plugin.id)
                        }
                    }
                    .disabled(plugins.snapshot == nil)
                }
                if let error = pluginError ?? plugins.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Text("""
                Ce que vos plugins coûtent à chaque session et ce qui ne tourne pas. \
                Atoll passe TOUJOURS par la commande `claude plugin` — il ne touche \
                jamais lui-même à votre settings.json. Installer un plugin exécute du \
                code tiers (hooks au démarrage, serveurs MCP) : ça ne se fait que sur \
                votre geste explicite.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Trouver un plugin") {
                HStack {
                    TextField("de quoi avez-vous besoin ?", text: $pluginNeed)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { runPluginSearch() }
                    Button("Chercher") { runPluginSearch() }
                        .disabled(pluginNeed.trimmingCharacters(in: .whitespaces).isEmpty
                                  || plugins.isSearching)
                }
                if plugins.isSearching {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("comparaison au catalogue public…").font(.caption)
                    }
                }
                ForEach(plugins.searchMatches, id: \.pluginID) { match in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.pluginID)
                            Text(match.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        // Installer = exécuter du code tiers : confirmation
                        // explicite, jamais un simple clic.
                        Button("Installer…") { confirmingInstall = match }
                            .buttonStyle(.borderless)
                            .disabled(plugins.busyPluginID != nil)
                    }
                }
                Text("""
                Décrivez un besoin en français : Atoll le compare aux 268 plugins du \
                catalogue public (rien n'est envoyé d'autre que votre phrase et les \
                descriptions publiques). Un plugin qu'il aurait inventé est écarté \
                d'office — seul un identifiant présent au catalogue peut être proposé.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Souvenirs proposés d'office") {
                Toggle("Rappeler les sessions liées à chaque message", isOn: proactiveRecall)
                    .disabled(!memoryIndexing.wrappedValue)
                if proactiveRecall.wrappedValue {
                    Picker("Souvenirs injectés", selection: proactiveRecallMaxHits) {
                        ForEach(1...5, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Limiter au projet courant", isOn: proactiveRecallProjectScoped)
                }
                if let proactiveRecallError {
                    Text(proactiveRecallError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("""
                Sans attendre que Claude pense au skill : à chaque message, Atoll cherche \
                localement les extraits de vos sessions passées liés à ce que vous écrivez \
                et les joint en contexte, marqués comme DONNÉES (jamais des instructions). \
                Activer rend le hook UserPromptSubmit bloquant — quelques millisecondes, \
                et fail-open : à la moindre anicroche, rien n'est injecté.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        // Même raison que le volet Apprentissage : avec la section Plugins et
        // sa liste, la hauteur intrinsèque dépassait l'écran.
        .frame(minHeight: 420, idealHeight: 560, maxHeight: 620)
        .alert("Installer ce plugin ?", isPresented: Binding(
            get: { confirmingInstall != nil },
            set: { if !$0 { confirmingInstall = nil } }
        ), presenting: confirmingInstall) { match in
            Button("Annuler", role: .cancel) { confirmingInstall = nil }
            Button("Installer", role: .destructive) {
                let id = match.pluginID
                confirmingInstall = nil
                Task { pluginError = await plugins.install(pluginID: id) }
            }
        } message: { match in
            Text("""
            \(match.pluginID) sera installé par `claude plugin install`. Un plugin \
            peut enregistrer des hooks exécutés au démarrage de CHAQUE session et \
            lancer des serveurs MCP : c'est du code tiers qui s'exécutera avec vos \
            droits. Il restera désactivable à tout moment.
            """)
        }
        .onAppear {
            hooksInstalled = HookInstaller.isInstalled
            MemoryIndexer.shared.refreshStats()
        }
    }

    private func runPluginSearch() {
        let need = pluginNeed
        Task { pluginError = await plugins.search(need: need) }
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

    private var proactiveRecall: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: LearningSettings.proactiveRecallKey) },
            set: {
                UserDefaults.standard.set($0, forKey: LearningSettings.proactiveRecallKey)
                proactiveRecallError = LearningSettings.shared.syncProactiveRecall()
            }
        )
    }

    private var proactiveRecallMaxHits: Binding<Int> {
        Binding(
            get: {
                UserDefaults.standard.object(forKey: LearningSettings.proactiveRecallMaxHitsKey)
                    as? Int ?? ProactiveRecallConfig.defaultMaxHits
            },
            set: {
                UserDefaults.standard.set($0, forKey: LearningSettings.proactiveRecallMaxHitsKey)
                proactiveRecallError = LearningSettings.shared.syncProactiveRecall()
            }
        )
    }

    private var proactiveRecallProjectScoped: Binding<Bool> {
        Binding(
            get: {
                UserDefaults.standard.object(
                    forKey: LearningSettings.proactiveRecallProjectScopedKey) as? Bool ?? true
            },
            set: {
                UserDefaults.standard.set($0, forKey: LearningSettings.proactiveRecallProjectScopedKey)
                proactiveRecallError = LearningSettings.shared.syncProactiveRecall()
            }
        )
    }

    private func indexSummary(_ stats: MemoryIndex.Stats) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: stats.databaseBytes,
                                              countStyle: .file)
        return "\(stats.sessionCount) session(s) · \(stats.messageCount) message(s) · \(bytes)"
    }

    private var memoryIndexing: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.object(forKey: MemoryIndexer.enabledKey) as? Bool ?? true },
            set: { enabled in
                UserDefaults.standard.set(enabled, forKey: MemoryIndexer.enabledKey)
                MemoryIndexer.shared.syncWithSettings()
                // Couper l'indexation coupe aussi le recall proactif (revue) :
                // son interrupteur devient grisé, il ne faut pas qu'il reste
                // actif — et surtout pas que le hook UserPromptSubmit reste
                // BLOQUANT sans plus rien à proposer.
                if !enabled, LearningSettings.shared.isProactiveRecallEnabled {
                    UserDefaults.standard.set(false, forKey: LearningSettings.proactiveRecallKey)
                    proactiveRecallError = LearningSettings.shared.syncProactiveRecall()
                }
            }
        )
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

// MARK: - Apprentissage (mémoire + rétrospective + revue des skills)

private struct LearningPane: View {
    @State private var center = SkillReviewCenter.shared
    @State private var indexer = MemoryIndexer.shared
    @State private var curation = NotesCurationService.shared
    /// Inventaire des notes, relu à l'apparition et après chaque curation.
    @State private var notes: [LearningNoteSummary] = []
    @State private var noteProjects: [(project: String, count: Int)] = []
    @State private var noteVolume = 0
    /// Journal des évaluations de fin de session (relu à l'apparition).
    @State private var attempts: [RetrospectiveRunner.AttemptRecord] = []

    var body: some View {
        Form {
            Section("Rétrospective") {
                Toggle("Apprendre des sessions terminées", isOn: learningEnabled)
                if learningEnabled.wrappedValue {
                    Picker("Seuil de quota 5 h", selection: learningThreshold) {
                        Text("50 %").tag(0.5)
                        Text("60 %").tag(0.6)
                        Text("70 %").tag(0.7)
                        Text("80 %").tag(0.8)
                    }
                }
                Text("""
                Après chaque session substantielle (si votre fenêtre 5 h a de la marge), \
                une analyse en LECTURE SEULE extrait les leçons durables — notes mémoire \
                et skills proposés en QUARANTAINE. Consomme du quota ; désactiver arrête \
                tout immédiatement.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Modèles d'analyse") {
                // Un modèle PAR TÂCHE : chercher (comparer un besoin à des
                // centaines de descriptions) et analyser (extraire un skill
                // d'une session) n'ont ni la même difficulté ni la même
                // fréquence — les payer au même prix serait absurde.
                Picker("Rétrospective", selection: modelBinding(LearningSettings.modelKey, "sonnet")) {
                    ForEach(LearningSettings.availableModels, id: \.self) { Text(modelLabel($0)).tag($0) }
                }
                Picker("Curation", selection: modelBinding(LearningSettings.curationModelKey, "sonnet")) {
                    ForEach(LearningSettings.availableModels, id: \.self) { Text(modelLabel($0)).tag($0) }
                }
                Picker("Recherche", selection: modelBinding(LearningSettings.searchModelKey, "haiku")) {
                    ForEach(LearningSettings.availableModels, id: \.self) { Text(modelLabel($0)).tag($0) }
                }
                Text("""
                La recherche (« ce skill existe-t-il déjà ? », « quel plugin répond à ce \
                besoin ? ») est fréquente et facile : Haiku suffit. L'extraction d'un \
                skill demande du jugement : Sonnet. Opus pour peu de propositions mais \
                excellentes ; Fable pour la vitesse.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Journal d'apprentissage") {
                if attempts.isEmpty {
                    Text("Aucune évaluation enregistrée pour l'instant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Chaque fin de session laisse une trace, même refusée :
                    // c'est ce qui manquait pour comprendre pourquoi rien ne
                    // sortait (le gate refusait en silence).
                    ForEach(attempts) { attempt in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attemptTitle(attempt))
                            Text(attemptDetail(attempt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("""
                Ce que fait Atoll à chaque fin de session : lancé, ou sauté et pourquoi \
                (quota inconnu, session trop courte, déjà traitée…).
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Curation des notes") {
                Toggle("Consolider les notes chaque semaine", isOn: curationScheduled)
                HStack {
                    Button(curation.phase == .running ? "Curation en cours…" : "Curer maintenant") {
                        curation.curateNow()
                    }
                    .disabled(curation.phase == .running || notes.count < 2)
                    if curation.phase == .running {
                        ProgressView().controlSize(.small)
                    }
                }
                if let outcome = curation.lastOutcome {
                    LabeledContent("Dernier passage", value: outcome)
                        .font(.caption)
                }
                ForEach(curation.warnings, id: \.self) { warning in
                    // Les contradictions ne sont JAMAIS tranchées automatiquement :
                    // elles remontent ici, à vous d'arbitrer dans les fichiers.
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("""
                Une analyse en lecture seule relit toutes vos notes et en propose une \
                version fusionnée (doublons réunis, contradictions SIGNALÉES, jamais \
                tranchées). L'ancienne version part d'abord dans ~/.atoll/learning/archive \
                — vérifiée avant tout remplacement. Consomme du quota ; refusée si le \
                corpus est trop gros ou si le résultat rétrécit trop.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Skills proposés (\(center.pendingCount))") {
                if center.proposals.isEmpty {
                    Text("Aucune proposition — elles apparaissent après les rétrospectives.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(center.proposals) { proposal in
                        LabeledContent(proposal.title,
                                       value: proposal.createdAt.formatted(date: .abbreviated, time: .omitted))
                    }
                    Button("Revoir…") { center.requestReviewWindow() }
                }
            }

            Section("Skills appris") {
                if center.installed.isEmpty {
                    Text("Aucun skill appris actif.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(center.installed) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(SkillSlug.dirName(for: row.skill.slug))
                                Text(usageLabel(row))
                                    .font(.caption)
                                    .foregroundStyle(row.suggestedForArchive ? .orange : .secondary)
                            }
                            Spacer()
                            if row.userModified {
                                Text("modifié").font(.caption).foregroundStyle(.orange)
                            }
                            Button("Archiver") { center.archiveInstalled(slug: row.skill.slug) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                ForEach(center.reconcileNotes, id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                Text("""
                Un skill appris est actif dans TOUS vos projets (il vit dans \
                ~/.claude/skills) : ce qu'Atoll apprend d'un dépôt sert aux autres.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Notes mémoire (\(notes.count))") {
                if notes.isEmpty {
                    Text("Aucune note — elles arrivent avec les rétrospectives.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Les 5 plus récentes : un aperçu, pas un explorateur.
                    ForEach(notes.prefix(5)) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title)
                            Text(noteSubtitle(note))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if noteProjects.count > 1 {
                        LabeledContent("Projets", value: projectsSummary)
                            .font(.caption)
                    }
                    LabeledContent("Volume", value: volumeSummary)
                        .font(.caption)
                }
                if let stats = indexer.stats {
                    LabeledContent("Index", value: "\(stats.sessionCount) session(s) · \(stats.messageCount) message(s)")
                }
                Button("Ouvrir le dossier ~/.atoll/learning") {
                    NSWorkspace.shared.open(BridgePaths.learningDirectory)
                }
            }
        }
        .formStyle(.grouped)
        // Seul volet à ne PAS prendre sa hauteur intrinsèque : avec ses six
        // sections (rétrospective, curation, skills proposés, skills appris,
        // notes), `fixedSize` faisait déborder la fenêtre sous le bas de
        // l'écran (vérifié en capture). Hauteur bornée → le Form défile.
        .frame(minHeight: 420, idealHeight: 560, maxHeight: 620)
        .onAppear {
            center.refresh()
            indexer.refreshStats()
            refreshNotes()
            attempts = RetrospectiveRunner.shared.recentAttempts()
        }
        // Une curation qui se termine réécrit les fichiers : on relit.
        .onChange(of: curation.lastRunAt) { _, _ in refreshNotes() }
    }

    private func refreshNotes() {
        let inventory = LearningInventory()
        notes = inventory.notes()
        noteProjects = inventory.projects()
        noteVolume = inventory.totalCharacterCount()
    }

    /// « 12 400 caractères · 15 % du budget de curation » — le budget est ce
    /// qui décide si une curation est possible, autant le montrer.
    private var volumeSummary: String {
        let percent = Int(Double(noteVolume) / Double(NotesCurationPrompt.maxCorpusCharacters) * 100)
        return "\(noteVolume) caractères · \(percent) % du budget de curation"
    }

    /// « pitfall · Dynamic_Island · 20 juil. » — les champs absents disparaissent.
    private func noteSubtitle(_ note: LearningNoteSummary) -> String {
        var parts: [String] = []
        if let category = note.category { parts.append(category) }
        if let project = note.project, !project.isEmpty {
            parts.append((project as NSString).lastPathComponent)
        }
        if let date = note.createdAt {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.isEmpty ? note.fileName : parts.joined(separator: " · ")
    }

    /// « Dynamic_Island 12 · Val d'Isere 3 » (3 premiers projets).
    private var projectsSummary: String {
        noteProjects.prefix(3).map { entry in
            let name = entry.project.isEmpty
                ? "sans projet"
                : (entry.project as NSString).lastPathComponent
            return "\(name) \(entry.count)"
        }
        .joined(separator: " · ")
    }

    private var curationScheduled: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: LearningSettings.curationScheduledKey) },
            set: {
                UserDefaults.standard.set($0, forKey: LearningSettings.curationScheduledKey)
                NotesCurationService.shared.syncWithSettings()
            }
        )
    }

    private func usageLabel(_ row: InstalledSkillRow) -> String {
        if let last = row.lastUsedAt {
            return "\(row.usageCount) usage(s) · dernier \(last.formatted(.relative(presentation: .named)))"
        }
        return row.suggestedForArchive ? "jamais utilisé (inactif > 30 j)" : "jamais utilisé"
    }

    private var learningEnabled: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: LearningSettings.enabledKey) },
            set: {
                UserDefaults.standard.set($0, forKey: LearningSettings.enabledKey)
                LearningSettings.shared.syncWithSettings()
            }
        )
    }

    private var learningThreshold: Binding<Double> {
        Binding(
            get: { UserDefaults.standard.object(forKey: LearningSettings.thresholdKey) as? Double ?? 0.7 },
            set: { UserDefaults.standard.set($0, forKey: LearningSettings.thresholdKey) }
        )
    }

    private func modelBinding(_ key: String, _ fallback: String) -> Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: key) ?? fallback },
            set: { UserDefaults.standard.set($0, forKey: key) }
        )
    }

    private func modelLabel(_ model: String) -> String {
        switch model {
        case "haiku": return "Haiku · rapide"
        case "sonnet": return "Sonnet · équilibré"
        case "opus": return "Opus · le plus fin"
        case "fable": return "Fable · véloce"
        default: return model
        }
    }

    /// « 14:32 · lancée » ou « 14:32 · sautée : quota inconnu ».
    private func attemptTitle(_ attempt: RetrospectiveRunner.AttemptRecord) -> String {
        let time = attempt.decidedAt.formatted(date: .abbreviated, time: .shortened)
        if attempt.decision == "run" {
            return "\(time) · analysée"
        }
        let reason = attempt.decision
            .replacingOccurrences(of: "skip(", with: "")
            .replacingOccurrences(of: ")", with: "")
        return "\(time) · sautée : \(reasonLabel(reason))"
    }

    /// Traduction des raisons du gate — l'utilisateur ne lit pas des rawValue.
    private func reasonLabel(_ raw: String) -> String {
        switch raw {
        case "disabled": return "apprentissage désactivé"
        case "sessionResumed": return "session encore vivante"
        case "sessionTooShort": return "session trop courte"
        case "transcriptMissing": return "transcript introuvable"
        case "transcriptTooSmall": return "session trop légère"
        case "tooFewUserPrompts": return "trop peu d'échanges"
        case "alreadyProcessed": return "déjà analysée"
        case "quotaMissing": return "quota inconnu"
        case "quotaStale": return "quota périmé"
        case "quotaAboveThreshold": return "quota trop consommé"
        case "windowCapReached": return "plafond de la fenêtre 5 h"
        default: return raw
        }
    }

    /// « 2,1 Mo · quota 12 % · 1 note, 1 skill · 0,04 $ ».
    private func attemptDetail(_ attempt: RetrospectiveRunner.AttemptRecord) -> String {
        var parts: [String] = []
        if let bytes = attempt.transcriptBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        if let quota = attempt.quotaFraction {
            parts.append("quota \(Int(quota * 100)) %")
        }
        if let outcome = attempt.outcome {
            parts.append(outcomeLabel(outcome, attempt: attempt))
        }
        if let cost = attempt.costUSD {
            let model = attempt.dominantModel.map { " (\($0.replacingOccurrences(of: "claude-", with: "")))" } ?? ""
            parts.append(String(format: "%.2f $", cost) + model)
        }
        return parts.isEmpty ? attempt.sessionID.prefix(8).description : parts.joined(separator: " · ")
    }

    private func outcomeLabel(_ outcome: String, attempt: RetrospectiveRunner.AttemptRecord) -> String {
        if outcome == "nothing_learned" { return "rien de durable" }
        if outcome.hasPrefix("failed") { return "échec (\(outcome))" }
        let notes = attempt.notesWritten ?? 0
        let skills = attempt.skillsProposed ?? 0
        return "\(notes) note(s), \(skills) skill(s)"
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
