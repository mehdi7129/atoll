import Foundation

/// Helpers PURS du lancement de sessions d'arrière-plan (`claude --bg`).
///
/// L'id renvoyé sur stdout par `--bg` n'a PAS de format garanti (leçon de la revue
/// du Milestone A) : on l'extrait au mieux, mais la source d'autorité reste le
/// `FleetPoller` (`claude agents --json`) qui découvrira la session de toute façon.
public enum FleetLaunch {
    /// Extrait un identifiant de session de la sortie de `claude --bg`.
    /// Best-effort : cherche le premier motif d'UUID (préfixe de 8 hex, éventuel
    /// reste), tolère les couleurs ANSI et le texte autour (« backgrounded · … »).
    /// nil si rien de plausible — l'appelant s'appuie alors sur le poll de flotte.
    public static func parseSessionID(_ output: String) -> String? {
        // Retire les séquences ANSI (le CLI colore l'id).
        let stripped = output.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        // UUID complet d'abord, sinon un id court (>= 8 hex).
        let patterns = [
            "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
            "\\b[0-9a-f]{8}\\b",
        ]
        for pattern in patterns {
            if let range = stripped.range(of: pattern, options: .regularExpression) {
                return String(stripped[range])
            }
        }
        return nil
    }

    /// Échappe un argument pour `/bin/zsh -c` (guillemets simples POSIX).
    public static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// La tâche saisie est-elle exploitable ? (non vide après trim.)
    public static func isValidTask(_ task: String) -> Bool {
        !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
