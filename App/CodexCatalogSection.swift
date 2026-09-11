import SwiftUI
import AtollCore

struct CodexCatalogSection: View {
    let projectPath: String
    let executableOverride: String
    let chooseProject: () -> Void
    @State private var skills: [CatalogEntry] = []
    @State private var plugins: CodexPluginCatalog?
    @State private var reading = false
    @State private var message = "Catalogue non chargé."
    @State private var query = ""
    @State private var issues: [String] = []

    var body: some View {
        Section {
            if !issues.isEmpty {
                Text(issues.joined(separator: "\n")).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            DisclosureGroup("Skills et plugins Codex") {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsHelp("Les skills et plugins disponibles dans le projet choisi. Le rappel de souvenirs se présente dans Apprentissage → Mémoire commune.")
                    if projectPath.isEmpty {
                        Button("Choisir le dossier du projet…", action: chooseProject)
                    } else {
                        HStack {
                            Text(URL(fileURLWithPath: projectPath).lastPathComponent)
                                .lineLimit(1).truncationMode(.middle).help(projectPath)
                            Spacer()
                            Button("Changer de projet…", action: chooseProject)
                        }
                    }
                    Button(reading ? "Lecture du catalogue…" : "Lire le catalogue de ce projet") { refresh() }
                        .disabled(reading || !projectPath.hasPrefix("/") || CodexPaths.configurationError != nil)
                    SettingsHelp(message).textSelection(.enabled)
                }
                .padding(.vertical, 8)
                if !skills.isEmpty || plugins != nil {
                    TextField("Rechercher localement un nom ou une description", text: $query)
                    ForEach(skills.filter { matches("\($0.id) \($0.description)") }, id: \.path) { entry in
                        DisclosureGroup("\(entry.name) · \(entry.isAvailable ? "activé" : "désactivé")") {
                            Text(entry.description).font(.callout)
                            Text("\(entry.origin) · \(entry.path.path)").font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    if let plugins {
                        ForEach(plugins.marketplaces.indices, id: \.self) { index in
                            let market = plugins.marketplaces[index]
                            ForEach(market.plugins.filter { matches($0.name) }, id: \.id) { plugin in
                                VStack(alignment: .leading) {
                                    Text("\(plugin.name) · \(plugin.installed ? "installé" : "disponible") · \(plugin.enabled ? "activé" : "désactivé")")
                                    Text(market.name + (plugin.availability == "DISABLED_BY_ADMIN" ? " · indisponible par décision administrateur" : "")
                                         + (plugin.disabledReason.map { " · \($0)" } ?? ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                SettingsHelp("Gère les plugins dans Codex avec /plugins. Les souvenirs sont rappelés à ta demande ; les skills appris restent soumis à ta revue.")
                    .textSelection(.enabled)
            }
        }
        .onChange(of: projectPath) { _, _ in invalidate() }
        .onChange(of: executableOverride) { _, _ in invalidate() }
    }

    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedStandardContains(query) }
    private func invalidate() { skills = []; plugins = nil; issues = []; message = "Catalogue à relire pour ce projet et ce binaire." }

    private func refresh() {
        guard !CodexPreview.enabled else {
            if CommandLine.arguments.contains("--preview-catalog-error") {
                issues = ["Catalogue indisponible : réessaie la lecture dans Codex."]
            } else { message = "Aucun skill dans ce projet de démonstration." }
            return
        }
        let home = CodexPaths.homeURL, cwd = projectPath, override = executableOverride
        reading = true
        issues = []
        Task { @MainActor in
            defer { reading = false }
            guard let path = await CodexExecutable.resolve(overridePath: override) else {
                message = CodexExecutable.notFoundMessage; issues = [message]; return
            }
            let results = await Task.detached(priority: .utility) {
                let executable = URL(fileURLWithPath: path)
                return (CodexReadClient.read(.skills(cwd: cwd), executable: executable, home: home),
                        CodexReadClient.read(.plugins(cwd: cwd), executable: executable, home: home))
            }.value
            guard home == CodexPaths.homeURL, cwd == projectPath, override == executableOverride else { return }
            var notes: [String] = []
            skills = []; plugins = nil
            switch results.0 {
            case .available(let data):
                if let catalog = CodexSkillCatalog.parse(data, cwd: cwd) {
                    skills = catalog.entries
                    notes.append("\(skills.count) skills · scope et activation fournis par Codex")
                    issues += catalog.errors
                } else { issues.append("Format skills/list non reconnu.") }
            case .unavailable(let reason): issues.append(reason)
            }
            switch results.1 {
            case .available(let data):
                plugins = try? JSONDecoder().decode(CodexPluginCatalog.self, from: data)
                if let plugins {
                    notes.append("\(plugins.marketplaces.reduce(0) { $0 + $1.plugins.count }) plugins locaux recensés")
                    issues += (plugins.marketplaceLoadErrors ?? []).map { "\($0.marketplacePath) : \($0.message)" }
                } else { issues.append("Format plugin/list non reconnu.") }
            case .unavailable(let reason): issues.append("Plugins : " + reason)
            }
            message = notes.joined(separator: "\n")
        }
    }
}
