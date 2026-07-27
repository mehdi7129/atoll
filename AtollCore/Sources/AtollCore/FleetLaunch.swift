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

        // Un UUID complet est une preuve : on le prend sans hésiter.
        if let range = stripped.range(
            of: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
            options: .regularExpression) {
            return String(stripped[range])
        }

        // Un id COURT (8 hex nus) n'est une preuve que s'il est SEUL. Sinon
        // c'est un pari : un hash, un identifiant de plugin ou un simple
        // nombre (« 12345678 » est de l'hexadécimal valide) serait pris pour
        // l'identifiant de session. Et se tromper coûte cher : une tâche liée
        // à un faux id n'est plus rattrapable par dossier (`adopt` n'agit que
        // sur les tâches SANS id), donc sa fin ne serait jamais annoncée.
        // Mieux vaut rendre nil et laisser le rattrapage faire son travail.
        let candidates = shortHexCandidates(in: stripped)
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Tous les groupes de 8 caractères hexadécimaux isolés, dédoublonnés.
    static func shortHexCandidates(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "\\b[0-9a-f]{8}\\b") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var found: [String] = []
        for match in regex.matches(in: text, range: range) {
            guard let sub = Range(match.range, in: text) else { continue }
            let token = String(text[sub])
            if !found.contains(token) { found.append(token) }
        }
        return found
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
