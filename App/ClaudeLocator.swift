import Foundation
import OSLog

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "claude-locator")

/// Retrouve le binaire `claude` à spawner. Les apps GUI héritent d'un PATH
/// minimal → on résout via un shell de login, avec sondes de secours.
/// (Voir docs/research/research-macos-app.md.)
enum ClaudeLocator {
    /// Chemins d'installation connus, du plus courant au moins courant.
    static let probes = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "\(NSHomeDirectory())/.claude/local/claude",
    ]

    private static var cached: String?

    /// Chemin résolu (mis en cache). nil si introuvable.
    static func resolve() -> String? {
        if let cached { return cached }

        // 1. Sondes directes (rapide, pas de shell).
        for path in probes where FileManager.default.isExecutableFile(atPath: path) {
            cached = path
            return path
        }

        // 2. Shell de login : `zsh -l -c 'command -v claude'` (source /etc/zprofile).
        if let viaShell = resolveViaLoginShell() {
            cached = viaShell
            return viaShell
        }

        log.error("binaire claude introuvable")
        return nil
    }

    private static func resolveViaLoginShell() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (!path.isEmpty && FileManager.default.isExecutableFile(atPath: path)) ? path : nil
    }

    /// PATH enrichi pour l'environnement du sous-processus (le binaire natif de
    /// claude relance parfois des outils via PATH).
    static var augmentedPATH: String {
        let base = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let extra = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        return base.isEmpty ? extra : "\(extra):\(base)"
    }
}
