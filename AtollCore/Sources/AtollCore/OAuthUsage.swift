import Foundation

/// Lecture DÉFENSIVE de `GET https://api.anthropic.com/api/oauth/usage` —
/// l'endpoint NON documenté qu'utilise la page « Utilisation » de claude.ai.
///
/// Périmètre volontairement minimal : SEULES les jauges par modèle
/// (`limits[] kind=weekly_scoped`, ex. « Fable : 27 % ») en sont extraites —
/// le 5 h / 7 j global vient de la statusline (canal officiel, source
/// primaire). Opt-in explicite de l'utilisateur ; lecture seule avec son
/// propre jeton ; JAMAIS de refresh du jeton (désynchroniserait le CLI).
/// L'endpoint peut changer ou être coupé à tout moment → tout échec de
/// parsing rend simplement une liste vide.
public struct OAuthUsage: Equatable, Sendable {

    public struct ScopedLimit: Equatable, Sendable {
        /// Nom affichable (« Fable », « Opus »…).
        public let label: String
        /// 0…1.
        public let usedFraction: Double
        public let resetsAt: Date?

        public init(label: String, usedFraction: Double, resetsAt: Date?) {
            self.label = label
            self.usedFraction = usedFraction
            self.resetsAt = resetsAt
        }
    }

    /// Jauges hebdomadaires par modèle, dans l'ordre du serveur.
    public let scopedLimits: [ScopedLimit]

    public init?(data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let limits = root["limits"] as? [[String: Any]] else { return nil }

        var scoped: [ScopedLimit] = []
        for limit in limits {
            guard limit["kind"] as? String == "weekly_scoped",
                  let percent = limit["percent"] as? NSNumber,
                  let scope = limit["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any] else { continue }
            // display_name direct, sinon id prettifié, sinon on saute.
            let label = (model["display_name"] as? String)
                ?? (model["id"] as? String).map(ModelName.display)
            guard let label, !label.isEmpty else { continue }
            scoped.append(ScopedLimit(
                label: label,
                usedFraction: min(max(percent.doubleValue / 100.0, 0), 1),
                resetsAt: (limit["resets_at"] as? String).flatMap(Self.parseISO8601)
            ))
        }
        scopedLimits = scoped
    }

    /// ISO-8601 avec fractions de seconde (« 2026-07-26T01:59:59.754069+00:00 »)
    /// ou sans — les deux formes existent côté serveur.
    static func parseISO8601(_ string: String) -> Date? {
        let withFractions = ISO8601DateFormatter()
        withFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractions.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
