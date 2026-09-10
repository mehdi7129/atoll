import Foundation
import AtollCore

/// Destination figée avant préparation, indépendante de la vue et du payeur.
struct SkillDestination: Equatable, Sendable {
    let provider: AgentProvider
    let home: URL
    let executableOverride: String

    @MainActor static func capture(origin: AgentProvider) throws -> Self {
        let provider = AgentProvider(rawValue: UserDefaults.standard.string(forKey: LearningSettings.skillDestinationKey) ?? "") ?? origin
        return Self(provider: provider,
            home: provider == .codex ? try CodexPaths.validatedHome() : BridgePaths.homeDirectory.appendingPathComponent(".claude"),
            executableOverride: UserDefaults.standard.string(forKey: CodexExecutable.overrideKey) ?? "")
    }

    var store: LearnedSkillStore {
        LearnedSkillStore(skillsRoot: home.appendingPathComponent("skills"), destination: provider)
    }

    @MainActor func catalog(project: URL?) async throws -> [CatalogEntry] {
        if provider == .claude {
            return await Task.detached(priority: .utility) { SkillCatalog(projectDirectory: project).entries() }.value
        }
        guard let executable = await CodexExecutable.resolve(overridePath: executableOverride) else {
            throw AnalysisExecution.Failure(CodexExecutable.notFoundMessage)
        }
        let cwd = (project ?? home).resolvingSymlinksInPath().path
        let result = await Task.detached(priority: .utility) {
            CodexReadClient.read(.skills(cwd: cwd), executable: URL(fileURLWithPath: executable), home: home)
        }.value
        guard case .available(let data) = result,
              let catalog = CodexSkillCatalog.parse(data, cwd: cwd), catalog.errors.isEmpty else {
            throw AnalysisExecution.Failure("Catalogue Codex indisponible ou incomplet : vérifie les skills dans le CLI avant de proposer ou d'activer un skill.")
        }
        return catalog.entries
    }

    static func summary(_ entries: [CatalogEntry]) -> String {
        var result = "Catalogue de la destination : \(entries.count) capacités.\n"
        for entry in entries {
            let line = "- \(entry.id) [\(entry.origin); \(entry.isAvailable ? "actif" : "désactivé")] : \(entry.description)\n"
            if result.count + line.count > SkillCatalog.maxSummaryCharacters {
                result += "Catalogue tronqué : cette liste ne prouve pas l'absence d'autres capacités.\n"
                break
            }
            result += line
        }
        return result
    }
}
