import Foundation

/// Sous-ensemble en lecture seule du contrat officiel plugin/list (0.153.4).
/// Les mutations et le catalogue distant restent dans le gestionnaire Codex.
public struct CodexPluginCatalog: Decodable, Sendable {
    public struct Plugin: Decodable, Sendable {
        public let id: String
        public let name: String
        public let installed: Bool
        public let enabled: Bool
        public let availability: String?
        public let disabledReason: String?
    }
    public struct Marketplace: Decodable, Sendable {
        public let name: String
        public let path: String?
        public let plugins: [Plugin]
    }
    public struct LoadError: Decodable, Sendable {
        public let marketplacePath: String
        public let message: String
    }
    public let marketplaces: [Marketplace]
    public let marketplaceLoadErrors: [LoadError]?
}
