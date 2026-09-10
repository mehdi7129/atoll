import SwiftUI
import AtollCore

struct CodexSettingsPane: View {
    @AppStorage(CodexService.quotaEnabledKey) private var quotaEnabled = false
    @AppStorage(CodexService.executableKey) private var executablePath = ""
    @AppStorage(LearningSettings.codexModelKey) private var analysisModel = ""
    @State private var installed = false
    @State private var message: String?
    @State private var homePath = CodexPaths.configuredHome ?? ""
    @State private var projectPath = CodexPaths.homeURL.path
    @State private var diagnostic = "non vérifié — la présence sur disque ne prouve pas la confiance"
    @State private var checking = false
    @State private var models: [CodexModel] = []
    @State private var loadingModels = false
    @State private var modelMessage = "Lecture du catalogue natif, sans génération de message."

    var body: some View {
        Form {
            Section("Codex CLI · terminal") {
                Text("Les sessions et les autorisations sont suivies dans l'îlot. Les questions et les plans restent dans le terminal. Le mode Rockstar s'applique uniquement à Claude.")
                TextField("CODEX_HOME (vide = détection)", text: $homePath)
                    .textFieldStyle(.roundedBorder)
                Button("Appliquer le dossier Codex") {
                    do {
                        let path = homePath.trimmingCharacters(in: .whitespacesAndNewlines)
                        try CodexService.shared.changeHome(to: path.isEmpty ? nil : (path as NSString).expandingTildeInPath)
                        projectPath = CodexPaths.homeURL.path
                        refreshInstalled()
                        diagnostic = "dossier changé — vérifier l'intégration"
                        message = nil
                    } catch { message = error.localizedDescription }
                }
                LabeledContent("Home utilisé", value: CodexPaths.homeURL.path)
                if let error = CodexPaths.configurationError { Text(error).foregroundStyle(.red) }
                LabeledContent("Configuration", value: CodexPaths.hooksURL.path)
                LabeledContent("Hooks Atoll", value: installed ? "présents · confiance à vérifier dans /hooks" : "non installés")
                Button(installed ? "Retirer l'intégration Codex" : "Installer l'intégration Codex") {
                    do {
                        try HookInstaller.configureCodex(install: !installed)
                        refreshInstalled()
                        message = installed
                            ? "Dans Codex, ouvre /hooks et approuve les définitions Atoll, puis démarre une nouvelle session."
                            : "Intégration Codex retirée. Les hooks étrangers, la configuration Claude et la mémoire commune sont préservés."
                    } catch { message = error.localizedDescription }
                }
                if installed {
                    Button("Réparer les définitions et le lanceur") {
                        do {
                            try HookInstaller.configureCodex(install: true)
                            refreshInstalled()
                            message = "Définitions à jour. Vérifie leur confiance dans /hooks."
                        } catch { message = error.localizedDescription }
                    }
                }
                TextField("Dossier du projet à vérifier", text: $projectPath)
                    .textFieldStyle(.roundedBorder)
                Button(checking ? "Vérification…" : "Vérifier avec Codex") { verify() }
                    .disabled(checking || !projectPath.hasPrefix("/") || CodexPaths.configurationError != nil)
                Text(diagnostic).font(.caption).textSelection(.enabled)
                if let date = CodexService.shared.lastEventAt {
                    LabeledContent("Dernier événement reçu", value: date.formatted(date: .omitted, time: .standard))
                } else { Text("Aucun événement reçu dans ce lancement d'Atoll.").font(.caption).foregroundStyle(.secondary) }
                if let message { Text(message).font(.caption).textSelection(.enabled) }
                Text("Installation indépendante de Claude : définitions Atoll sauvegardées dans hooks.json.atoll-backup, lanceur et skill manuel atoll-recall. Le trust et config.toml restent gérés par Codex. Le retrait conserve la mémoire commune et les fichiers personnels. Un seul home Codex est observé à la fois.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Quota de l'abonnement ChatGPT / Codex") {
                Toggle("Lire le quota Codex (toutes les 2 minutes)", isOn: $quotaEnabled)
                    .onChange(of: quotaEnabled) { _, _ in CodexService.shared.syncQuotaSettings() }
                TextField("Chemin de codex (vide = détection)", text: $executablePath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { applyExecutable() }
                Button("Appliquer et actualiser") { applyExecutable() }
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
                Text("Utilise la connexion de ton CLI (codex login) et son app-server officiel. Aucun message généré, aucun jeton de connexion extrait par Atoll. Les comptes API et les quotas absents ne sont pas affichés comme un abonnement à 0 %. Les durées viennent de Codex, elles ne sont pas supposées être 5 h / 7 j.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            AnalysisSettingsSection()
            CodexCatalogSection(projectPath: projectPath, executableOverride: executablePath)
            Section("Modèle des analyses Codex") {
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
                Text("Le modèle sélectionné est revalidé avant chaque analyse. Si Codex fournit plusieurs catégories de quota sans leur correspondance aux modèles, le budget reste inconnu.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Suivi des sessions") {
                Text("Les sessions identifiées par leurs hooks sont retrouvées après un redémarrage d'Atoll tant que leur processus vit. Un dossier commun ne suffit jamais à attribuer une session. Une activité silencieuse reste « état non confirmé » jusqu'au prochain événement ; la mort du processus clôt son suivi.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshInstalled() }
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
            let values = await Task.detached(priority: .utility) {
                CodexRun.readModels(executable: URL(fileURLWithPath: path), home: home)
            }.value
            guard home == CodexPaths.homeURL, override == executablePath else { return }
            models = values
            modelMessage = values.isEmpty ? "Catalogue indisponible — vérifier codex login et le binaire."
                : "\(values.count) modèles disponibles. Sélectionne celui des analyses Atoll."
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
