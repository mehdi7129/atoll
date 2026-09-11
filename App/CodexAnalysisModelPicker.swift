import SwiftUI
import AtollCore

/// Le choix explicite dans Apprentissage. Lire le catalogue
/// n'autorise aucune analyse et ne sélectionne jamais un modèle par défaut.
struct CodexAnalysisModelPicker: View {
    var focusRequest: UUID? = nil
    @AppStorage(LearningSettings.codexModelKey) private var selection = ""
    @AppStorage(CodexService.executableKey) private var executablePath = ""
    @State private var models: [CodexModel] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var failure: String?
    @State private var requestID = UUID()
    @FocusState private var modelFocused: Bool

    private var configuration: [String] { [CodexPaths.homeURL.path, executablePath] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("Modèle Codex", selection: $selection) {
                    Text("Choisir un modèle…").tag("")
                    if !selection.isEmpty && !models.contains(where: { $0.model == selection && !$0.hidden }) {
                        Text(selection + (loaded ? " · indisponible" : " · à vérifier")).tag(selection)
                    }
                    ForEach(models.filter { !$0.hidden }) { model in
                        Text(model.displayName + (model.isDefault ? " · défaut Codex" : "")).tag(model.model)
                    }
                }
                .accessibilityIdentifier("codex-analysis-model")
                .focused($modelFocused)
                if loading {
                    ProgressView().controlSize(.small).accessibilityLabel("Lecture des modèles")
                } else {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Actualiser les modèles disponibles")
                    .accessibilityLabel("Actualiser les modèles")
                }
            }
            if loaded, !selection.isEmpty, !models.contains(where: { $0.model == selection && !$0.hidden }) {
                SettingsHelp("Ce modèle n'est plus proposé. Choisis-en un autre pour les prochaines analyses.")
            } else if selection.isEmpty {
                SettingsHelp("Choisis un modèle pour les analyses d'Atoll avec Codex.")
            }
            if let failure {
                SettingsHelp(failure)
            } else if loaded && models.filter({ !$0.hidden }).isEmpty {
                SettingsHelp("Aucun modèle disponible dans le catalogue Codex.")
            }
        }
        .padding(.vertical, 4)
        .task(id: configuration) { await refresh() }
        .task(id: focusRequest) {
            if focusRequest != nil {
                modelFocused = true
            }
        }
    }

    private func refresh() async {
        let ticket = UUID(), settings = configuration
        requestID = ticket
        loading = true
        loaded = false
        models = []
        failure = nil
        defer { if requestID == ticket { loading = false } }

        let catalog: CodexModel.Catalog
        if CodexPreview.enabled {
            catalog = CodexPreview.modelCatalog
        } else if let error = CodexPaths.configurationError {
            catalog = .unavailable(error)
        } else {
            guard let path = await CodexExecutable.resolve(overridePath: settings[1]) else {
                if !Task.isCancelled, requestID == ticket { failure = CodexExecutable.notFoundMessage }
                return
            }
            let home = URL(fileURLWithPath: settings[0])
            catalog = await Task.detached(priority: .utility) {
                CodexRun.readModelCatalog(executable: URL(fileURLWithPath: path), home: home)
            }.value
        }
        guard !Task.isCancelled, requestID == ticket, configuration == settings else { return }
        switch catalog {
        case .available(let values): models = values; loaded = true
        case .unavailable(let reason): failure = "Catalogue indisponible : " + reason
        }
    }
}
