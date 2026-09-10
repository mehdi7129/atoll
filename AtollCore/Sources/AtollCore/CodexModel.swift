import Foundation

public struct CodexModel: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let model: String
    public let displayName: String
    public let isDefault: Bool
    public let hidden: Bool

    public struct Page: Decodable, Sendable {
        public let data: [CodexModel]
        public let nextCursor: String?
    }

    public enum Catalog: Equatable, Sendable {
        case available([CodexModel])
        case unavailable(String)
    }

    /// Un catalogue partiel ne suffit jamais à autoriser une dépense. Garder
    /// la cause permet de distinguer un CLI indisponible d'un modèle absent.
    public static func readCatalog(timeout: TimeInterval = 20, pageLimit: Int = 5,
                                   now: () -> Date = { Date() },
                                   readPage: (String?, TimeInterval) -> CodexReadClient.Outcome) -> Catalog {
        let deadline = now().addingTimeInterval(timeout)
        var cursor: String?
        var visited: Set<String> = []
        var models: [CodexModel] = []
        for _ in 0..<max(0, pageLimit) {
            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0 else { return .unavailable("Délai de lecture du catalogue dépassé.") }
            let data: Data
            switch readPage(cursor, remaining) {
            case .available(let value): data = value
            case .unavailable(let reason): return .unavailable(reason)
            }
            guard let page = try? JSONDecoder().decode(Page.self, from: data) else {
                return .unavailable("Réponse model/list non reconnue.")
            }
            models += page.data
            guard let next = page.nextCursor else { return .available(models) }
            guard visited.insert(next).inserted else {
                return .unavailable("Catalogue incomplet : pagination répétée.")
            }
            cursor = next
        }
        return .unavailable("Catalogue incomplet : trop de pages.")
    }
}
