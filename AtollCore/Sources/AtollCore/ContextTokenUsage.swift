import Foundation

/// Dernière taille mesurée du contexte, distincte des tokens cumulés facturés.
public struct ContextTokenUsage: Equatable, Sendable {
    public let usedTokens: Int
    public let windowTokens: Int

    public init?(usedTokens: Int, windowTokens: Int) {
        guard usedTokens >= 0, windowTokens > 0, usedTokens <= windowTokens else { return nil }
        self.usedTokens = usedTokens
        self.windowTokens = windowTokens
    }

    public var fraction: Double { Double(usedTokens) / Double(windowTokens) }

    public var formattedCounts: String {
        "\(usedTokens.formatted()) / \(windowTokens.formatted()) tokens"
    }
}
