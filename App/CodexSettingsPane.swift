import SwiftUI
import AppKit
import AtollCore

struct CodexSettingsPane: View {
    @AppStorage(CodexService.quotaEnabledKey) private var quotaEnabled = false
    @AppStorage(CodexService.executableKey) private var executablePath = ""
    @AppStorage(LearningSettings.codexModelKey) private var analysisModel = ""
    @State private var installed = false
    @State private var message: String?
    @State private var homePath = CodexPaths.configuredHome ?? ""
    @AppStorage("codexDiagnosticProjectPath") private var projectPath = ""
    @State private var diagnostic = "Choisis le dossier où tu utilises Codex, puis vérifie l'intégration."
    @State private var checking = false
    @State private var models: [CodexModel] = []
    @State private var loadingModels = false
    @State private var advancedExpanded = false
    @State private var modelMessage = "Lecture du catalogue natif, sans génération de message."

    var body: some View {
        Form {
            Section("Codex CLI · terminal") {
                LabeledContent("Intégration Atoll", value: installed ? "Installée" : "À installer")
                if let error = CodexPaths.configurationError { Text(error).foregroundStyle(.red) }
                if !installed {
                    Button("Installer l'intégration Codex") { configure(install: true) }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dans ton terminal Codex, ouvre /hooks et approuve les hooks Atoll.")
                    Button("Copier /hooks") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("/hooks", forType: .string)
                    }
                    Text("Envoie ensuite un message dans Codex : la session doit apparaître dans l'îlot.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Projet", value: projectPath.isEmpty ? "Aucun dossier choisi" : projectPath)
                    .textSelection(.enabled)
                Button("Choisir le dossier du projet…") { chooseProject() }
                Button(checking ? "Vérification…" : "Vérifier avec Codex") { verify() }
                    .disabled(checking || !validProject || CodexPaths.configurationError != nil)
                Text(diagnostic).font(.caption).textSelection(.enabled)
                if let date = CodexService.shared.lastEventAt {
                    LabeledContent("Dernier événement reçu", value: date.formatted(date: .omitted, time: .standard))
                } else { Text("En attente du premier événement de Codex.").font(.caption).foregroundStyle(.secondary) }
                if let message { Text(message).font(.caption).textSelection(.enabled) }
                Text("Si Codex était ouvert avant l'installation, reprends la session avec codex resume. Questions et plans restent dans le terminal ; Rockstar est réservé à Claude.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Quota de l'abonnement ChatGPT / Codex") {
                Toggle("Lire le quota Codex (toutes les 2 minutes)", isOn: $quotaEnabled)
                    .onChange(of: quotaEnabled) { _, _ in CodexService.shared.syncQuotaSettings() }
                Button("Actualiser le quota") { CodexService.shared.syncQuotaSettings() }
                    .disabled(CodexService.shared.isLoading)
                Text(CodexService.shared.status).font(.caption).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let quota = CodexService.shared.quota {
                        ForEach(quota.buckets) { bucket in
                            ForEach(bucket.windows) { window in
                                if quota.isFresh(at: context.date), window.isCurrent(at: context.date) {
                                    HStack {
                                        Text("\(bucket.label) · \(window.label)")
                                        Spacer()
                                        Text("\(Int(window.usedFraction * 100)) % utilisés")
                                        if let reset = window.resetsAt { ResetCountdown(resetsAt: reset) }
                                    }
                                } else {
                                    Text("\(bucket.label) · \(window.label) : en attente d'une mesure récente")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Text("Utilise ta connexion codex login, sans générer de message. Le contexte de chaque conversation s'affiche dans son détail, séparément de ce quota d'abonnement.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Analyses Atoll") {
                Button("Choisir le moteur et les limites dans Apprentissage") {
                    UserDefaults.standard.set("apprentissage", forKey: "settingsTab")
                }
            }
            CodexCatalogSection(projectPath: projectPath, executableOverride: executablePath)
            Section {
                DisclosureGroup("Modèle des analyses Codex") {
                    Picker("Modèle", selection: $analysisModel) {
                        Text("Choisir un modèle").tag("")
                        if !analysisModel.isEmpty && !models.contains(where: { $0.model == analysisModel }) {
                            Text("\(analysisModel) · à vérifier").tag(analysisModel)
                        }
                        ForEach(models.filter { !$0.hidden }) { value in
                            Text(value.displayName + (value.isDefault ? " · défaut Codex" : "")).tag(value.model)
                        }
                    }
                    Button(loadingModels ? "Lecture…" : "Actualiser les modèles disponibles") { refreshModels() }
                        .disabled(loadingModels || CodexPaths.configurationError != nil)
                    Text(modelMessage).font(.caption).foregroundStyle(.secondary)
                    Text("Ce choix concerne les analyses d'Atoll ; il n'est pas nécessaire au suivi des sessions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            advancedSettings
        }
        .formStyle(.grouped)
        .onAppear {
            refreshInstalled()
            if CodexPreview.enabled {
                installed = true
                projectPath = "/projet-exemple"
                diagnostic = CodexPreview.hookDiagnosticSummary
                advancedExpanded = CommandLine.arguments.contains("--preview-advanced")
            } else if projectPath.isEmpty, let cwd = CodexService.shared.sessions.first?.cwd {
                projectPath = cwd
            }
        }
    }

    private var validProject: Bool {
        var directory: ObjCBool = false
        return projectPath.hasPrefix("/") && FileManager.default.fileExists(atPath: projectPath, isDirectory: &directory)
            && directory.boolValue
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "Dossier où tu utilises Codex"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            projectPath = url.resolvingSymlinksInPath().path
            diagnostic = "Projet choisi — vérifier l'intégration."
        }
    }

    private func configure(install: Bool) {
        do {
            try HookInstaller.configureCodex(install: install)
            refreshInstalled()
            diagnostic = "Intégration modifiée — vérifier avec Codex."
            message = install ? "Définitions à jour. Approuve les hooks Atoll dans /hooks."
                : "Intégration retirée. Les hooks étrangers et la mémoire commune sont préservés."
        } catch { message = error.localizedDescription }
    }

    private var advancedSettings: some View {
        Section {
            DisclosureGroup("Configuration avancée", isExpanded: $advancedExpanded) {
                TextField("CODEX_HOME (vide = détection)", text: $homePath)
                    .textFieldStyle(.roundedBorder)
                Button("Appliquer le dossier Codex") {
                    do {
                        let path = homePath.trimmingCharacters(in: .whitespacesAndNewlines)
                        try CodexService.shared.changeHome(to: path.isEmpty ? nil : (path as NSString).expandingTildeInPath)
                        refreshInstalled()
                        diagnostic = "Dossier Codex changé — vérifier l'intégration."
                        message = nil
                    } catch { message = error.localizedDescription }
                }
                LabeledContent("Home utilisé", value: CodexPaths.homeURL.path)
                LabeledContent("Fichier des hooks", value: CodexPaths.hooksURL.path)
                TextField("Chemin de codex (vide = détection)", text: $executablePath)
                    .textFieldStyle(.roundedBorder).onSubmit { applyExecutable() }
                Button("Appliquer l'exécutable") { applyExecutable() }
                if installed {
                    Button("Réparer les définitions et le lanceur") { configure(install: true) }
                    Button("Retirer l'intégration Codex") { configure(install: false) }
                }
                Text("Laisse les chemins vides pour la détection automatique. Atoll sauvegarde les hooks avant modification et préserve tes personnalisations au démarrage. « Réparer » réinstalle ses définitions. La confiance reste gérée dans Codex. Changer de home conserve l'installation de l'ancien.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func refreshInstalled() {
        installed = CodexHookSettingsEditor.hasManagedHooks(try? Data(contentsOf: CodexPaths.hooksURL))
    }

    private func applyExecutable() {
        CodexExecutable.invalidateCache()
        CodexService.shared.syncQuotaSettings()
        diagnostic = "exécutable changé — vérifier l'intégration"
    }

    private func refreshModels() {
        loadingModels = true
        let home = CodexPaths.homeURL
        let override = executablePath
        Task { @MainActor in
            defer { loadingModels = false }
            guard let path = await CodexExecutable.resolve(overridePath: override) else {
                modelMessage = CodexExecutable.notFoundMessage; return
            }
            let catalog = await Task.detached(priority: .utility) {
                CodexRun.readModelCatalog(executable: URL(fileURLWithPath: path), home: home)
            }.value
            guard home == CodexPaths.homeURL, override == executablePath else { return }
            switch catalog {
            case .available(let values):
                models = values
                modelMessage = values.isEmpty ? "Catalogue reçu sans modèle disponible."
                    : "\(values.count) modèles disponibles. Sélectionne celui des analyses Atoll."
            case .unavailable(let reason):
                models = []
                modelMessage = "Catalogue indisponible : \(reason)"
            }
        }
    }

    private func verify() {
        checking = true
        let home = CodexPaths.homeURL
        let cwd = projectPath
        let override = executablePath
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
            case .available(let data):
                diagnostic = CodexHookDiagnostics(data: data)?.summary ?? "réponse hooks/list non reconnue"
            case .unavailable(let reason): diagnostic = reason
            }
        }
    }
}
