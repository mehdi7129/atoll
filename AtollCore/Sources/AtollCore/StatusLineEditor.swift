import Foundation

/// Édition chirurgicale de la clé `statusLine` de `~/.claude/settings.json`.
///
/// Une seule statusline est autorisée par le CLI : on ne peut donc pas
/// coexister, il faut CHAÎNER. On remplace `statusLine.command` par notre
/// wrapper (qui met en cache les rate_limits puis exécute la commande d'origine
/// en passthrough) et on renvoie la commande d'origine pour la restituer à la
/// désinstallation. Refus si la statusline existante nous est inconnue et qu'on
/// ne l'a pas mémorisée — on ne veut jamais écraser silencieusement (leçon
/// Vibe Island issue #107).
public enum StatusLineEditor {
    public static let marker = ".atoll/bin/atoll-statusline"

    public struct InstallResult: Equatable {
        public let settings: Data
        /// Commande statusline d'origine à mémoriser (nil si aucune, ou déjà la nôtre).
        public let originalCommand: String?
    }

    /// Intervalle (s) posé par Atoll quand l'utilisateur n'en a pas : le quota
    /// continue d'arriver pendant l'inactivité. Sert aussi de sentinelle à la
    /// désinstallation (retiré seulement si la valeur est restée la nôtre).
    public static let managedRefreshInterval = 60

    /// Remplace la commande statusline par `wrapperCommand`.
    public static func install(into data: Data?, wrapperCommand: String) throws -> InstallResult {
        var settings = try parse(data)
        var statusLine = settings["statusLine"] as? [String: Any] ?? [:]
        let existing = statusLine["command"] as? String

        var original: String?
        if let existing, !existing.contains(marker) {
            original = existing // à mémoriser pour la restitution
        }

        statusLine["type"] = "command"
        statusLine["command"] = wrapperCommand
        // Sans refreshInterval, la statusline (donc rate_limits) ne se met à
        // jour qu'aux messages assistant : le quota gèle pendant l'inactivité.
        // 60 s comble les trous (recommandation du rapport quota) ; une valeur
        // posée par l'utilisateur est respectée.
        if statusLine["refreshInterval"] == nil {
            statusLine["refreshInterval"] = Self.managedRefreshInterval
        }
        settings["statusLine"] = statusLine
        return InstallResult(settings: try serialize(settings), originalCommand: original)
    }

    /// Migration douce d'une statusline DÉJÀ chaînée : ajoute refreshInterval
    /// s'il manque. nil = rien à changer (aucune écriture).
    public static func addRefreshIntervalIfMissing(into data: Data?) throws -> Data? {
        var settings = try parse(data)
        guard var statusLine = settings["statusLine"] as? [String: Any],
              (statusLine["command"] as? String)?.contains(marker) == true,
              statusLine["refreshInterval"] == nil else { return nil }
        statusLine["refreshInterval"] = managedRefreshInterval
        settings["statusLine"] = statusLine
        return try serialize(settings)
    }

    /// Restaure la commande d'origine (ou retire la statusline si aucune).
    public static func uninstall(from data: Data?, originalCommand: String?) throws -> Data {
        var settings = try parse(data)
        guard var statusLine = settings["statusLine"] as? [String: Any] else {
            return try serialize(settings)
        }
        // Ne touche à rien si la statusline actuelle n'est pas la nôtre.
        guard (statusLine["command"] as? String)?.contains(marker) == true else {
            return try serialize(settings)
        }
        // Retirer NOTRE refreshInterval (valeur sentinelle exacte : une valeur
        // différente a été posée/modifiée par l'utilisateur → conservée).
        if (statusLine["refreshInterval"] as? Int) == Self.managedRefreshInterval {
            statusLine["refreshInterval"] = nil
        }
        if let originalCommand, !originalCommand.isEmpty {
            statusLine["command"] = originalCommand
            settings["statusLine"] = statusLine
        } else {
            settings["statusLine"] = nil
        }
        return try serialize(settings)
    }

    public static func isInstalled(in data: Data?) -> Bool {
        guard let settings = try? parse(data),
              let statusLine = settings["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String else { return false }
        return command.contains(marker)
    }

    /// Commande statusline actuelle (pour détecter une config utilisateur à mémoriser).
    public static func currentCommand(in data: Data?) -> String? {
        guard let settings = try? parse(data),
              let statusLine = settings["statusLine"] as? [String: Any] else { return nil }
        return statusLine["command"] as? String
    }

    // MARK: - Interne

    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw HookSettingsEditor.EditorError.unparseableSettings
        }
        return dict
    }

    private static func serialize(_ settings: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }
}
