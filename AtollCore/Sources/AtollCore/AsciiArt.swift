import Foundation

/// Vocabulaire visuel ASCII d'Atoll : spinners, barres, badges.
/// Tout est de la donnée pure (chaînes), le rendu appartient à l'app.
public enum AsciiArt {

    // MARK: - Spinner

    /// Le spinner braille classique de cli-spinners ("dots"), 80 ms par frame.
    public static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    public static let spinnerInterval: TimeInterval = 0.08

    /// Frame de spinner pour une date donnée (déterministe, pilotable par TimelineView).
    public static func spinnerFrame(at date: Date) -> String {
        let index = Int(date.timeIntervalSinceReferenceDate / spinnerInterval)
        return spinnerFrames[((index % spinnerFrames.count) + spinnerFrames.count) % spinnerFrames.count]
    }

    // MARK: - Barre de progression

    /// Blocs partiels (huitièmes) : résolution 8× sous-caractère.
    static let eighthBlocks = ["▏", "▎", "▍", "▌", "▋", "▊", "▉"]

    /// Barre de progression en blocs : `progressBar(fraction: 0.27, cells: 7)` → "█▉░░░░░".
    /// Cellules pleines `█`, cellule partielle en huitième de bloc, vide `░`.
    public static func progressBar(fraction: Double, cells: Int) -> String {
        guard cells > 0 else { return "" }
        guard fraction.isFinite else { return String(repeating: "░", count: cells) }
        let clamped = min(max(fraction, 0), 1)
        let totalEighths = Int((clamped * Double(cells) * 8).rounded())
        let fullCells = totalEighths / 8
        let remainder = totalEighths % 8
        var bar = String(repeating: "█", count: min(fullCells, cells))
        if fullCells < cells, remainder > 0 {
            bar += eighthBlocks[remainder - 1]
        }
        if bar.count < cells {
            bar += String(repeating: "░", count: cells - bar.count)
        }
        return bar
    }

    // MARK: - Sparkline

    static let sparkBlocks = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    /// Sparkline : une valeur 0…1 par colonne.
    public static func sparkline(_ values: [Double]) -> String {
        values.map { value in
            guard value.isFinite else { return sparkBlocks[0] }
            let clamped = min(max(value, 0), 1)
            let index = min(Int(clamped * 8), 7)
            return sparkBlocks[index]
        }.joined()
    }

    // MARK: - Badges d'état

    public static func statusBadge(_ status: AgentSession.Status) -> String {
        switch status {
        case .working: return "[ WORKING ]"
        case .awaitingPermission: return "[ APPROVE? ]"
        case .awaitingInput: return "[ INPUT? ]"
        case .done: return "[ DONE ]"
        }
    }

    // MARK: - Règles / séparateurs

    /// Séparateur horizontal : `rule(12)` → "────────────".
    public static func rule(_ cells: Int) -> String {
        String(repeating: "─", count: max(cells, 0))
    }

    /// Titre de section encadré : `sectionHeader("SESSIONS", width: 16)` → "── SESSIONS ────".
    public static func sectionHeader(_ title: String, width: Int) -> String {
        let prefix = "── \(title) "
        guard width > prefix.count else { return prefix }
        return prefix + String(repeating: "─", count: width - prefix.count)
    }
}
