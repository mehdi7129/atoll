import Foundation

/// Adaptation du contrat skills/list de codex-cli 0.153.4, sans réimplémenter
/// ses règles de découverte, scopes, priorités ou activation des plugins.
public struct CodexSkillCatalog: Sendable {
    public let cwd: String
    public let entries: [CatalogEntry]
    public let errors: [String]

    public static func parse(_ data: Data, cwd: String) -> Self? {
        struct Skill: Decodable {
            let name: String
            let description: String
            let path: String
            let scope: String
            let enabled: Bool
            let pluginId: String?
        }
        struct Issue: Decodable { let path: String; let message: String }
        struct Listing: Decodable { let cwd: String; let skills: [Skill]; let errors: [Issue] }
        struct Response: Decodable { let data: [Listing] }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let listing = response.data.first(where: {
                  URL(fileURLWithPath: $0.cwd).resolvingSymlinksInPath() == URL(fileURLWithPath: cwd).resolvingSymlinksInPath()
              }) else { return nil }
        var errors = listing.errors.map { "\($0.path) : \($0.message)" }
        let entries = listing.skills.compactMap { skill -> CatalogEntry? in
            guard !skill.name.isEmpty, skill.path.hasPrefix("/"), !skill.path.contains("\0") else {
                errors.append("Entrée de skill invalide dans le catalogue natif.")
                return nil
            }
            return CatalogEntry(id: skill.name, name: skill.name, description: String(skill.description.prefix(300)),
                kind: skill.pluginId == nil ? .userSkill : .pluginSkill,
                origin: "Codex · \(skill.scope)" + (skill.pluginId.map { " · \($0)" } ?? ""),
                isAvailable: skill.enabled, path: URL(fileURLWithPath: skill.path))
        }
        return Self(cwd: listing.cwd, entries: entries, errors: errors)
    }
}
