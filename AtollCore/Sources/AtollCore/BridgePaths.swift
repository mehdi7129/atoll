import Foundation

/// Chemins partagés entre l'app, le helper `atoll-bridge` et l'installeur.
public enum BridgePaths {
    /// Socket Unix sur lequel l'app écoute les événements de hooks.
    public static var socketPath: String {
        "/tmp/atoll-\(getuid()).sock"
    }

    public static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// Répertoire du wrapper stable référencé par settings.json.
    public static var binDirectory: URL {
        homeDirectory.appendingPathComponent(".atoll/bin", isDirectory: true)
    }

    /// Wrapper shell stable : `~/.atoll/bin/atoll-bridge` (exec le binaire du bundle).
    public static var wrapperURL: URL {
        binDirectory.appendingPathComponent("atoll-bridge")
    }

    /// La commande inscrite dans settings.json. `$HOME` est développé par le shell
    /// qui exécute les hooks — le chemin reste valable si le home change de volume.
    public static let hookCommand = "\"$HOME/.atoll/bin/atoll-bridge\""

    public static var claudeSettingsURL: URL {
        homeDirectory.appendingPathComponent(".claude/settings.json")
    }

    /// Backup unique, créé avant la toute première écriture, jamais écrasé.
    public static var settingsBackupURL: URL {
        homeDirectory.appendingPathComponent(".claude/settings.json.atoll-backup")
    }
}
