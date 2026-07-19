import Foundation

/// Niveau d'autonomie accordé à Claude — UN SEUL réglage, trois niveaux
/// mutuellement exclusifs. Remplace les deux anciens interrupteurs (auto /
/// rockstar) pour qu'aucun état contradictoire ne soit possible.
public enum AutonomyLevel: String, CaseIterable, Sendable {
    /// Rien n'est auto-approuvé : l'utilisateur décide de tout.
    case manual
    /// Les permissions d'outils SÛRES sont auto-approuvées (allowlist) ; les
    /// commandes destructrices, plans et questions restent manuels.
    case auto
    /// Tout est auto-approuvé (permissions même destructrices, plans, questions).
    /// « À vos risques et périls. »
    case rockstar

    public var displayName: String {
        switch self {
        case .manual: return "Manuel"
        case .auto: return "Auto"
        case .rockstar: return "Rockstar"
        }
    }

    public var summary: String {
        switch self {
        case .manual:
            return "Vous approuvez chaque demande vous-même."
        case .auto:
            return "Permissions sûres auto-approuvées ; destructif, plans et questions restent manuels."
        case .rockstar:
            return "Tout est auto-approuvé, même les commandes destructrices. À vos risques et périls."
        }
    }

    /// Ce niveau auto-approuve-t-il au moins quelque chose ? (badge sur l'îlot).
    public var isAutonomous: Bool { self != .manual }
}
