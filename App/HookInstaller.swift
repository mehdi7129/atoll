import Foundation
import AtollCore

/// Façade de l'app vers le helper embarqué (une seule implémentation de
/// l'installation, dans atoll-bridge : voir Bridge/main.swift).
@MainActor
enum HookInstaller {
    static var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/atoll-bridge")
    }

    static var isInstalled: Bool {
        HookSettingsEditor.isInstalled(in: try? Data(contentsOf: BridgePaths.claudeSettingsURL))
    }

    static var backupExists: Bool {
        FileManager.default.fileExists(atPath: BridgePaths.settingsBackupURL.path)
    }

    enum InstallerError: LocalizedError {
        case helperMissing
        case helperFailed(String)

        var errorDescription: String? {
            switch self {
            case .helperMissing:
                return "Helper atoll-bridge introuvable dans le bundle."
            case .helperFailed(let message):
                return message.isEmpty ? "Le helper a échoué." : message
            }
        }
    }

    static func install() throws {
        try runHelper("install")
    }

    static func uninstall() throws {
        try runHelper("uninstall")
    }

    // MARK: - Rockstar : suspension des règles deny

    /// Les règles `permissions.deny` sont-elles actuellement parquées ?
    static var denyRulesParked: Bool {
        FileManager.default.fileExists(atPath: BridgePaths.rockstarParkedDenyURL.path)
    }

    /// Entrée en Rockstar : suspend les règles deny de l'utilisateur (elles
    /// s'exécutent dans Claude Code AVANT nos hooks — même en bypassPermissions,
    /// vérifié CLI 2.1.215 — les parquer est le seul moyen de tout autoriser).
    static func parkDenyRules() throws {
        try runHelper("rockstar-park")
    }

    /// Sortie de Rockstar : restaure les règles parquées.
    static func restoreDenyRules() throws {
        try runHelper("rockstar-restore")
    }

    /// Aligne le parking des règles deny sur le niveau d'autonomie. Appelé au
    /// changement de niveau, au lancement (récupération après crash : ne
    /// jamais laisser des règles parquées hors Rockstar, ni des règles actives
    /// en Rockstar) et après (dés)installation des hooks. Le parking exige
    /// Rockstar ET les hooks installés : sans hooks, Atoll ne pilote rien et
    /// n'a aucune légitimité à retirer les règles de l'utilisateur (sinon la
    /// réconciliation au lancement défait la restitution de la désinstallation).
    /// Renvoie un message d'erreur à afficher, nil si OK.
    @discardableResult
    static func syncDenyParking(level: AutonomyLevel) -> String? {
        do {
            if level == .rockstar && isInstalled {
                // Idempotent : reparque aussi des règles (ré)apparues entre-temps.
                try parkDenyRules()
            } else if denyRulesParked {
                try restoreDenyRules()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// À chaque lancement : si les hooks sont installés, réexécute `install`
    /// (idempotent) pour réparer le wrapper si l'app a été déplacée.
    static func repairIfInstalled() {
        guard isInstalled else { return }
        try? runHelper("install")
    }

    private static func runHelper(_ verb: String) throws {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw InstallerError.helperMissing
        }
        let process = Process()
        process.executableURL = helperURL
        process.arguments = [verb]
        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            throw InstallerError.helperFailed(String(decoding: data, as: UTF8.self))
        }
    }
}
