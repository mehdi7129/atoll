import Foundation
import Observation
import AtollCore

/// État partagé entre les rendus SwiftUI : une tâche conserve sa génération,
/// pas les anciennes valeurs de la struct View qui l'a lancée.
@MainActor
@Observable
final class CodexCatalogState {
    struct Context: Equatable, Sendable {
        let projectPath: String
        let executableOverride: String
        let home: URL
    }
    typealias Results = (CodexReadClient.Outcome, CodexReadClient.Outcome)
    typealias Resolver = @MainActor (String) async -> String?
    typealias Reader = @Sendable (Context, String) async -> Results

    private(set) var skills: [CatalogEntry] = []
    private(set) var plugins: CodexPluginCatalog?
    private(set) var reading = false
    private(set) var message = "Catalogue non chargé."
    private(set) var issues: [String] = []
    @ObservationIgnored private var context: Context?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let resolve: Resolver
    @ObservationIgnored private let read: Reader

    init(resolve: @escaping Resolver = { await CodexExecutable.resolve(overridePath: $0) },
         read: @escaping Reader = { context, path in await CodexCatalogState.readCatalog(context, executable: path) }) {
        self.resolve = resolve
        self.read = read
    }

    func updateContext(_ next: Context) {
        guard context != next else { return }
        let hadContext = context != nil
        context = next
        generation = UUID()
        task?.cancel()
        task = nil
        reading = false
        skills = []; plugins = nil; issues = []
        if hadContext { message = "Catalogue à relire pour ce projet et ce binaire." }
    }

    func refresh(context requested: Context) {
        updateContext(requested)
        guard !reading else { return }
        let request = UUID()
        generation = request
        reading = true
        issues = []
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == request { reading = false; task = nil }
            }
            let path = await resolve(requested.executableOverride)
            guard isCurrent(request, context: requested) else { return }
            guard let path else {
                message = CodexExecutable.notFoundMessage; issues = [message]; return
            }
            let results = await read(requested, path)
            guard isCurrent(request, context: requested) else { return }
            apply(results, cwd: requested.projectPath)
        }
    }

    private func isCurrent(_ request: UUID, context requested: Context) -> Bool {
        generation == request && context == requested && !Task.isCancelled
    }

    private func apply(_ results: Results, cwd: String) {
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

    nonisolated private static func readCatalog(_ context: Context, executable path: String) async -> Results {
        let worker = Task.detached(priority: .utility) {
            let executable = URL(fileURLWithPath: path)
            let skills = CodexReadClient.read(.skills(cwd: context.projectPath), executable: executable,
                home: context.home, cancelled: { Task.isCancelled })
            let plugins = CodexReadClient.read(.plugins(cwd: context.projectPath), executable: executable,
                home: context.home, cancelled: { Task.isCancelled })
            return (skills, plugins)
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    func showPreview(error: Bool) {
        if error { issues = ["Catalogue indisponible : réessaie la lecture dans Codex."] }
        else { message = "Aucun skill dans ce projet de démonstration." }
    }
}
