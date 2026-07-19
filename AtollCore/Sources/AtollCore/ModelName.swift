import Foundation

/// Rend un identifiant de modèle lisible : « claude-fable-5 » → « Fable 5 ».
/// La statusline fournit déjà un display_name propre ; ceci sert de repli quand
/// on ne dispose que de l'id brut du transcript.
public enum ModelName {
    public static func display(_ raw: String) -> String {
        // Déjà lisible (fourni par la statusline, contient un espace ou une majuscule).
        if raw.contains(" ") { return raw }

        var id = raw
        if id.hasPrefix("claude-") { id.removeFirst("claude-".count) }
        // Retire un éventuel suffixe de date (…-20250101) ou de contexte ([1m]).
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        id = id.replacingOccurrences(of: #"-\d{6,8}$"#, with: "", options: [.regularExpression])

        let parts = id.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return raw }

        // « opus-4-8 » → « Opus 4.8 » ; « fable-5 » → « Fable 5 ».
        let name = parts[0].prefix(1).uppercased() + parts[0].dropFirst()
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? name : "\(name) \(version)"
    }
}
