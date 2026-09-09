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

        // Famille GPT : « gpt-6-astra » → « GPT-6 Astra ».
        //
        // Le formatage générique ci-dessous, écrit pour les modèles Anthropic,
        // rendait « Gpt 6.astra » — la marque décapitalisée et la variante
        // recollée au numéro comme si c'était une sous-version. Format arrêté
        // avec Codex le 2026-09-09, sur son propre fournisseur : marque en
        // CAPITALES, segments numériques joints en version, variantes en mots.
        // Une branche ici plutôt qu'un court-circuit chez l'appelant : le badge
        // dit déjà quel agent tourne, le nom du modèle doit juste être lisible.
        if parts[0].lowercased() == "gpt" {
            var version: [String] = []
            var words: [String] = []
            for part in parts.dropFirst() {
                if part.first?.isNumber == true { version.append(part) }
                else { words.append(part.prefix(1).uppercased() + part.dropFirst()) }
            }
            let head = version.isEmpty ? "GPT" : "GPT-" + version.joined(separator: ".")
            return words.isEmpty ? head : head + " " + words.joined(separator: " ")
        }

        // « opus-4-8 » → « Opus 4.8 » ; « fable-5 » → « Fable 5 ».
        let name = parts[0].prefix(1).uppercased() + parts[0].dropFirst()
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? name : "\(name) \(version)"
    }
}
