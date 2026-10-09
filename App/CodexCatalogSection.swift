import SwiftUI
import AtollCore

struct CodexCatalogSection: View {
    let projectPath: String
    let executableOverride: String
    let home: URL
    let chooseProject: () -> Void
    @State private var catalog = CodexCatalogState()
    @State private var query = ""

    private var context: CodexCatalogState.Context {
        .init(projectPath: projectPath, executableOverride: executableOverride, home: home)
    }

    var body: some View {
        Section {
            if !catalog.issues.isEmpty {
                Text(catalog.issues.joined(separator: "\n")).font(.callout).foregroundStyle(.orange)
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
                    Button(catalog.reading ? "Lecture du catalogue…" : "Lire le catalogue de ce projet") { refresh() }
                        .disabled(catalog.reading || !projectPath.hasPrefix("/") || CodexPaths.configurationError != nil)
                    SettingsHelp(catalog.message).textSelection(.enabled)
                }
                .padding(.vertical, 8)
                if !catalog.skills.isEmpty || catalog.plugins != nil {
                    TextField("Rechercher localement un nom ou une description", text: $query)
                    ForEach(catalog.skills.filter { matches("\($0.id) \($0.description)") }, id: \.path) { entry in
                        DisclosureGroup("\(entry.name) · \(entry.isAvailable ? "activé" : "désactivé")") {
                            Text(entry.description).font(.callout)
                            Text("\(entry.origin) · \(entry.path.path)").font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    if let plugins = catalog.plugins {
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
        .onChange(of: context, initial: true) { _, next in catalog.updateContext(next) }
    }

    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedStandardContains(query) }

    private func refresh() {
        guard !CodexPreview.enabled else {
            catalog.showPreview(error: CommandLine.arguments.contains("--preview-catalog-error"))
            return
        }
        catalog.refresh(context: context)
    }
}
