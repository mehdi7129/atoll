import SwiftUI
import AtollCore

struct CodexCatalogSection: View {
    let projectPath: String
    let executableOverride: String
    @State private var skills: [CatalogEntry] = []
    @State private var plugins: CodexPluginCatalog?
    @State private var reading = false
    @State private var message = "Catalogue non chargé."
    @State private var query = ""

    var body: some View {
        Section("Skills et plugins Codex") {
            Text("Recall : invoque $atoll-recall dans Codex après installation des hooks. Sa disponibilité dans ce projet est vérifiée dans le catalogue ci-dessous. Le recall proactif Codex reste désactivé ; aucune injection async n'est supposée transmise au modèle.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Les skills appris sont proposés pour une destination explicite, puis installés après revue. Leur usage Codex reste non mesuré.")
                .font(.caption).foregroundStyle(.secondary)
            Button(reading ? "Lecture du catalogue…" : "Lire le catalogue natif de ce projet") { refresh() }
                .disabled(reading || !projectPath.hasPrefix("/") || CodexPaths.configurationError != nil)
            Text(message).font(.caption).textSelection(.enabled)
            if !skills.isEmpty || plugins != nil {
                TextField("Rechercher localement un nom ou une description", text: $query)
                ForEach(skills.filter { matches("\($0.id) \($0.description)") }, id: \.path) { entry in
                    VStack(alignment: .leading) {
                        Text("\(entry.name) · \(entry.isAvailable ? "activé" : "désactivé")")
                        Text("\(entry.origin) · \(entry.path.path)").font(.caption).foregroundStyle(.secondary)
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
            Text("Installation, retrait, activation et catalogue distant : utilise /plugins dans la TUI Codex, ou codex plugin --help. Ce panneau lit les marketplaces locales de Codex ; la recherche IA de plugins dans Atoll vise le catalogue Claude.")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .onChange(of: projectPath) { _, _ in invalidate() }
        .onChange(of: executableOverride) { _, _ in invalidate() }
    }

    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedStandardContains(query) }
    private func invalidate() { skills = []; plugins = nil; message = "Catalogue à relire pour ce projet et ce binaire." }

    private func refresh() {
        let home = CodexPaths.homeURL, cwd = projectPath, override = executableOverride
        reading = true
        Task { @MainActor in
            defer { reading = false }
            guard let path = await CodexExecutable.resolve(overridePath: override) else {
                message = CodexExecutable.notFoundMessage; return
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
                    notes += catalog.errors
                } else { notes.append("Format skills/list non reconnu.") }
            case .unavailable(let reason): notes.append(reason)
            }
            switch results.1 {
            case .available(let data):
                plugins = try? JSONDecoder().decode(CodexPluginCatalog.self, from: data)
                if let plugins {
                    notes.append("\(plugins.marketplaces.reduce(0) { $0 + $1.plugins.count }) plugins locaux recensés")
                    notes += (plugins.marketplaceLoadErrors ?? []).map { "\($0.marketplacePath) : \($0.message)" }
                } else { notes.append("Format plugin/list non reconnu.") }
            case .unavailable(let reason): notes.append("Plugins : " + reason)
            }
            message = notes.joined(separator: "\n")
        }
    }
}
