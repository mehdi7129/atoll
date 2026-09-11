import SwiftUI
import AppKit
import AtollCore

struct CodexSettingsPane: View {
    let onShowAnalyses: () -> Void
    @AppStorage(CodexService.quotaEnabledKey) private var quotaEnabled = false
    @AppStorage(CodexService.executableKey) private var executablePath = ""
    @AppStorage(LearningSettings.analysisProviderKey) private var analysisProvider = AgentProvider.claude.rawValue
    @AppStorage(LearningSettings.failoverEnabledKey) private var analysisFallback = false
    @AppStorage(LearningSettings.codexModelKey) private var analysisModel = ""
    @AppStorage("codexDiagnosticProjectPath") private var projectPath = ""
    @State private var installed = false
    @State private var message: String?
    @State private var homePath = CodexPreview.enabled ? "" : CodexPaths.configuredHome ?? ""
    @State private var diagnostic: String?
    @State private var checking = false
    @State private var diagnosticExpanded = false
    @State private var advancedExpanded = false

    private var configurationError: String? { CodexPreview.enabled ? nil : CodexPaths.configurationError }
    private var lastEvent: Date? {
        if CodexPreview.enabled {
            return CommandLine.arguments.contains("--preview-connected") ? Date() : nil
        }
        return CodexService.shared.lastEventAt
    }

    var body: some View {
        Form {
            Section("Connexion à Codex") {
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Suivi des sessions", value: configurationError != nil ? "À configurer"
                        : !installed ? "À installer" : lastEvent != nil ? "Événements reçus" : "En attente d'une session")
                    if let error = configurationError {
                        SettingsHelp(error)
                        Button("Ouvrir le dépannage") { advancedExpanded = true }
                    } else if !installed {
                        SettingsHelp("Relie Codex à Atoll pour voir tes sessions et leurs demandes d'autorisation dans l'îlot.")
                        Button("Installer l'intégration Codex") { configure(install: true) }
                            .buttonStyle(.borderedProminent)
                    } else if lastEvent == nil {
                        SettingsHelp("Dans ton terminal Codex, ouvre /hooks et approuve les hooks Atoll.\nEnvoie ensuite un message pour faire apparaître la session.")
                        Button("Copier /hooks") {
                            guard !CodexPreview.enabled else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("/hooks", forType: .string)
                        }
                    } else {
                        SettingsHelp("Tes sessions apparaissent automatiquement dans l'îlot.")
                    }
                    if let message { SettingsHelp(message).textSelection(.enabled) }
                }
                .padding(.vertical, 4)
                DisclosureGroup("Vérifier la connexion", isExpanded: $diagnosticExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Projet à vérifier").fontWeight(.medium)
                            SettingsHelp("Le dossier où tu travailles avec Codex. Ce choix sert uniquement à la vérification et au catalogue de skills.")
                            if !projectPath.isEmpty {
                                Text(projectPath).font(.callout).textSelection(.enabled)
                                    .lineLimit(2).truncationMode(.middle).help(projectPath)
                            }
                            Button("Choisir le dossier du projet…") { chooseProject() }
                        }
                        Button(checking ? "Vérification…" : "Vérifier les hooks") { verify() }
                            .disabled(checking || !validProject || configurationError != nil)
                        if let diagnostic { SettingsHelp(diagnostic).textSelection(.enabled) }
                        if let date = lastEvent {
                            LabeledContent("Dernier événement reçu", value: date.formatted(date: .omitted, time: .standard))
                                .font(.callout)
                        }
                        SettingsHelp("Codex était déjà ouvert lors de l'installation ? Reprends la session avec codex resume.")
                    }
                    .padding(.vertical, 8)
                }
                if !diagnosticExpanded, let diagnostic {
                    SettingsHelp(diagnostic).textSelection(.enabled)
                }
            }
            Section("Analyses d'Atoll") {
                LabeledContent("Moteur", value: analysisProvider == AgentProvider.codex.rawValue ? "Codex CLI" : "Claude Code")
                if analysisProvider == AgentProvider.codex.rawValue || analysisFallback {
                    LabeledContent("Modèle Codex", value: analysisModel.isEmpty ? "À choisir" : analysisModel)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Button((analysisProvider == AgentProvider.codex.rawValue || analysisFallback) && analysisModel.isEmpty
                           ? "Choisir le modèle…" : "Régler les analyses…", action: onShowAnalyses)
                    SettingsHelp("Le moteur, les modèles et les limites se règlent dans Apprentissage.")
                }
            }
            quotaSection
            CodexCatalogSection(projectPath: projectPath, executableOverride: executablePath,
                                chooseProject: chooseProject)
            advancedSettings
        }
        .formStyle(.grouped)
        .disclosureGroupStyle(SettingsDisclosureStyle())
        .onAppear {
            refreshInstalled()
            if CodexPreview.enabled {
                projectPath = "/projets/projet-exemple"
                diagnosticExpanded = CommandLine.arguments.contains("--preview-diagnostic")
                advancedExpanded = CommandLine.arguments.contains("--preview-advanced")
            } else if projectPath.isEmpty, let cwd = CodexService.shared.sessions.first?.cwd {
                projectPath = cwd
            }
        }
    }

    private var quotaSection: some View {
        Section("Quota de l'abonnement") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Afficher le quota Codex", isOn: $quotaEnabled)
                    .onChange(of: quotaEnabled) { _, _ in
                        if !CodexPreview.enabled { CodexService.shared.syncQuotaSettings() }
                    }
                SettingsHelp("Actualisé toutes les 2 minutes, sans générer de message.")
            }
            if quotaEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let quota = CodexService.shared.quota {
                            ForEach(quota.buckets) { bucket in
                                ForEach(bucket.windows) { window in
                                    HStack(alignment: .firstTextBaseline) {
                                        Text("\(bucket.label) · \(window.label)")
                                        Spacer()
                                        if quota.isFresh(at: context.date), window.isCurrent(at: context.date) {
                                            Text("\(Int(window.usedFraction * 100)) % utilisés").monospacedDigit()
                                            if let reset = window.resetsAt { ResetCountdown(resetsAt: reset) }
                                        } else { Text("À actualiser").foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        } else { SettingsHelp(CodexService.shared.status) }
                    }
                    Button("Actualiser le quota") {
                        if !CodexPreview.enabled { CodexService.shared.syncQuotaSettings() }
                    }
                    .disabled(CodexService.shared.isLoading)
                    .controlSize(.small)
                }
            }
            SettingsHelp("Le contexte d'une conversation est visible dans son détail, depuis l'îlot.")
        }
    }

    private var validProject: Bool {
        if CodexPreview.enabled { return !projectPath.isEmpty }
        var directory: ObjCBool = false
        return projectPath.hasPrefix("/") && FileManager.default.fileExists(atPath: projectPath, isDirectory: &directory)
            && directory.boolValue
    }

    private func chooseProject() {
        guard !CodexPreview.enabled else { return }
        let panel = NSOpenPanel()
        panel.title = "Dossier où tu utilises Codex"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            projectPath = url.resolvingSymlinksInPath().path
            diagnostic = nil
        }
    }

    private func configure(install: Bool) {
        guard !CodexPreview.enabled else {
            installed = install
            message = install ? "Approuve les hooks Atoll dans /hooks." : "Intégration retirée pour cet aperçu."
            return
        }
        do {
            try HookInstaller.configureCodex(install: install)
            refreshInstalled()
            diagnostic = nil
            message = install ? "Définitions à jour. Approuve les hooks Atoll dans /hooks."
                : "Intégration retirée. Tes autres hooks et la mémoire commune sont conservés."
        } catch { message = error.localizedDescription }
    }

    private var advancedSettings: some View {
        Section {
            DisclosureGroup("Dépannage", isExpanded: $advancedExpanded) {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        SettingsHelp("Laisse les chemins vides pour la détection automatique.")
                        TextField("CODEX_HOME", text: $homePath, prompt: Text("Détection automatique"))
                            .textFieldStyle(.roundedBorder)
                        Button("Appliquer le dossier Codex") {
                            guard !CodexPreview.enabled else { return }
                            do {
                                let path = homePath.trimmingCharacters(in: .whitespacesAndNewlines)
                                try CodexService.shared.changeHome(to: path.isEmpty ? nil : (path as NSString).expandingTildeInPath)
                                refreshInstalled()
                                diagnostic = nil
                                message = nil
                            } catch { message = error.localizedDescription }
                        }
                        SettingsHelp("Home utilisé : \(CodexPreview.enabled ? "/compte-codex" : CodexPaths.homeURL.path)\nFichier des hooks : \(CodexPreview.enabled ? "/compte-codex/hooks.json" : CodexPaths.hooksURL.path)")
                            .textSelection(.enabled)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Chemin de codex", text: $executablePath, prompt: Text("Détection automatique"))
                            .textFieldStyle(.roundedBorder).onSubmit { applyExecutable() }
                        Button("Appliquer l'exécutable") { applyExecutable() }
                    }
                    if installed {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Réparer les définitions et le lanceur") { configure(install: true) }
                            SettingsHelp("Sauvegarde puis réinstalle les hooks Atoll. Leur approbation reste à faire dans Codex.")
                            Button("Retirer l'intégration Codex") { configure(install: false) }
                        }
                    }
                    SettingsHelp("Tes autres hooks sont préservés. Changer de home conserve l'intégration de l'ancien dossier.")
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func refreshInstalled() {
        installed = CodexPreview.enabled ? !CommandLine.arguments.contains("--preview-uninstalled")
            : CodexHookSettingsEditor.hasManagedHooks(try? Data(contentsOf: CodexPaths.hooksURL))
    }

    private func applyExecutable() {
        guard !CodexPreview.enabled else { return }
        CodexExecutable.invalidateCache()
        CodexService.shared.syncQuotaSettings()
        diagnostic = nil
    }

    private func verify() {
        guard !CodexPreview.enabled else { diagnostic = CodexPreview.hookDiagnosticSummary; return }
        checking = true
        let home = CodexPaths.homeURL, cwd = projectPath, override = executablePath
        Task { @MainActor in
            defer { checking = false }
            guard let path = await CodexExecutable.resolve(overridePath: override) else {
                diagnostic = CodexExecutable.notFoundMessage; return
            }
            let result = await Task.detached(priority: .utility) {
                CodexReadClient.read(.hooks(cwd: cwd), executable: URL(fileURLWithPath: path), home: home)
            }.value
            guard home == CodexPaths.homeURL, cwd == projectPath, override == executablePath else { return }
            switch result {
            case .available(let data): diagnostic = CodexHookDiagnostics(data: data)?.summary ?? "Réponse Codex non reconnue."
            case .unavailable(let reason): diagnostic = reason
            }
        }
    }
}
