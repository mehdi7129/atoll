import Foundation

/// Conventions de nommage des rollouts Codex.
public enum CodexRollout {
    /// Extrait l'identifiant de session d'un nom de fichier de rollout —
    /// `rollout-2026-09-09T11-19-38-01a08577-386d-72c0-90ac-54eabd344ec1.jsonl`
    /// → `01a08577-386d-72c0-90ac-54eabd344ec1`.
    ///
    /// ⚠️ L'HORODATAGE CONTIENT DES TIRETS, comme l'uuid : découper naïvement
    /// sur `-` mélangerait les deux. On repère donc l'uuid par sa FORME (cinq
    /// groupes hexadécimaux 8-4-4-4-12), pas par sa position.
    ///
    /// Repli sur le nom sans extension si rien ne correspond : mieux vaut un
    /// identifiant inhabituel qu'aucune indexation (règle n° 3, parsing
    /// défensif — ce format ne nous appartient pas).
    public static func sessionID(fromFileName name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        if let range = stem.range(of: pattern, options: .regularExpression) {
            return String(stem[range])
        }
        return stem
    }
}
