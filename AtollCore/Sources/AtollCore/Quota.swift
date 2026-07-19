import Foundation

/// Une fenêtre de quota (5 h ou 7 j) telle que fournie par le serveur Anthropic
/// via la statusline (données exactes, jamais estimées).
public struct RateLimit: Equatable, Sendable {
    /// Fraction utilisée, 0…1.
    public let usedFraction: Double
    /// Instant de réinitialisation, nil si inconnu/expiré.
    public let resetsAt: Date?

    public init(usedFraction: Double, resetsAt: Date?) {
        self.usedFraction = min(max(usedFraction, 0), 1)
        self.resetsAt = resetsAt
    }
}

/// Instantané de quota complet, avec l'âge de la donnée (le champ rate_limits est
/// absent d'environ 23 % des appels statusline → on sert le dernier connu avec
/// un indicateur d'âge plutôt que de clignoter).
public struct QuotaSnapshot: Equatable, Sendable {
    public let fiveHour: RateLimit
    public let sevenDay: RateLimit
    public let receivedAt: Date

    public init(fiveHour: RateLimit, sevenDay: RateLimit, receivedAt: Date) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.receivedAt = receivedAt
    }
}

/// Données par session extraites du même payload statusline (modèle, contexte, coût).
public struct SessionUsage: Equatable, Sendable {
    public let modelDisplayName: String?
    public let contextUsedFraction: Double?
    public let costUSD: Double?

    public init(modelDisplayName: String?, contextUsedFraction: Double?, costUSD: Double?) {
        self.modelDisplayName = modelDisplayName
        self.contextUsedFraction = contextUsedFraction.map { min(max($0, 0), 1) }
        self.costUSD = costUSD
    }
}

/// Parse défensivement le JSON reçu sur stdin par la statusline (schéma vérifié
/// sur Claude Code 2.1.214 — voir docs/research/research-followup-usage-quota.md).
public struct StatusLinePayload: Equatable, Sendable {
    public let sessionID: String?
    public let usage: SessionUsage
    /// nil si rate_limits est absent de ce payload (fréquent).
    public let quota: QuotaSnapshot?

    public init?(data: Data, now: Date) {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return nil }

        sessionID = root["session_id"] as? String

        // Modèle : { id, display_name }.
        let model = root["model"] as? [String: Any]
        let modelName = (model?["display_name"] as? String) ?? (model?["id"] as? String)

        // Contexte : used_percentage 0…100.
        let context = root["context_window"] as? [String: Any]
        let contextFraction = (context?["used_percentage"] as? NSNumber).map { $0.doubleValue / 100 }

        // Coût cumulé.
        let cost = root["cost"] as? [String: Any]
        let costUSD = (cost?["total_cost_usd"] as? NSNumber)?.doubleValue

        usage = SessionUsage(
            modelDisplayName: modelName,
            contextUsedFraction: contextFraction,
            costUSD: costUSD
        )

        // Quota serveur : rate_limits { five_hour, seven_day }.
        if let rateLimits = root["rate_limits"] as? [String: Any],
           let five = Self.parseWindow(rateLimits["five_hour"]),
           let seven = Self.parseWindow(rateLimits["seven_day"]) {
            quota = QuotaSnapshot(fiveHour: five, sevenDay: seven, receivedAt: now)
        } else {
            quota = nil
        }
    }

    /// { used_percentage: 0…100, resets_at: epoch secondes }.
    private static func parseWindow(_ value: Any?) -> RateLimit? {
        guard let dict = value as? [String: Any],
              let percent = dict["used_percentage"] as? NSNumber else { return nil }
        let resetsAt = (dict["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return RateLimit(usedFraction: percent.doubleValue / 100, resetsAt: resetsAt)
    }
}
