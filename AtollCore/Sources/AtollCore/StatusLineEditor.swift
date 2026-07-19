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
        settings["statusLine"] = statusLine
        return InstallResult(settings: try serialize(settings), originalCommand: original)
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
