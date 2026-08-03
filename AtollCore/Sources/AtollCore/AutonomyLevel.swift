import Foundation

/// Niveau d'autonomie accordé à Claude — UN SEUL réglage, trois niveaux
/// mutuellement exclusifs. Remplace les deux anciens interrupteurs (auto /
/// rockstar) pour qu'aucun état contradictoire ne soit possible.
/// LE NIVEAU « AUTO » A ÉTÉ RETIRÉ le 2026-08-03, et il ne doit pas revenir sans
/// une raison neuve. Claude Code fournit désormais `claude auto-mode` : un
/// classifieur first-party, actif PAR DÉFAUT, avec 35,5 Ko de politique
/// `allow`/`soft_deny`/`hard_deny` et une commande qui fait critiquer vos propres
/// règles par une IA. En face, notre allowlist Swift avait dû être corrigée DEUX
/// fois pour des contournements, dont un critique (`python3 -c'code'` collé, un
/// jeton unique qui n'égalait aucun drapeau connu). On ne gagne pas cette course,
/// et on n'a pas à la courir : le milieu appartient à Anthropic.
public enum AutonomyLevel: String, CaseIterable, Sendable {
    /// Rien n'est auto-approuvé : l'utilisateur décide de tout.
    case manual
    /// Aucune protection : tout est auto-approuvé (permissions même
    /// destructrices, plans — avec auto-acceptation des éditions —, questions)
    /// et les règles `permissions.deny` de l'utilisateur sont suspendues
    /// (parquées) tant que ce niveau est actif. « À vos risques et périls. »
    case rockstar

    /// Décodage NORMALISÉ d'un réglage stocké. Un seul point de vérité — la
    /// logique de repli était recopiée à cinq endroits sans un seul test.
    ///
    /// Tout ce qui n'est pas reconnu retombe sur `.manual`, le niveau le plus
    /// PRUDENT : c'est ce qui rend le retrait d'« auto » sûr, un réglage devenu
    /// orphelin ne peut pas promouvoir quelqu'un en Rockstar à son insu.
    public static func resolve(_ raw: String?) -> AutonomyLevel {
        guard let raw, let level = AutonomyLevel(rawValue: raw) else { return .manual }
        return level
    }

    public var displayName: String {
        switch self {
        case .manual: return "Manuel"
        case .rockstar: return "Rockstar"
        }
    }

    public var summary: String {
        switch self {
        case .manual:
            return "Vous approuvez chaque demande vous-même."
        case .rockstar:
            return "Aucune protection : tout est approuvé et vos règles deny sont suspendues. À vos risques et périls."
        }
    }
}
