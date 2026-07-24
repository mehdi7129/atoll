import Foundation
import Observation
import OSLog
import AtollCore

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "launcher")

/// Lance et arrête des sessions Claude Code d'arrière-plan (`claude --bg` /
/// `claude stop`) depuis le notch — le cœur du « cockpit ambiant » (Milestone C).
///
/// Lancement sur demande EXPLICITE uniquement (choix produit) : jamais d'objectif
/// auto-généré. La session lancée est une session Claude normale (hooks actifs,
/// auth par souscription) → le `FleetPoller` et les hooks la découvrent et la
/// suivent comme n'importe quelle autre ; ses permissions remontent en cartes
/// dans le notch (et s'auto-approuvent en Rockstar → hands-off).
@MainActor
@Observable
final class FleetLauncher {
    static let shared = FleetLauncher()

    /// Dernier dossier utilisé — pré-remplit le lanceur.
    static let lastDirKey = "fleetLauncherLastDir"

    private(set) var lastError: String?
    private(set) var isLaunching = false

    /// Chemin claude résolu.
    @ObservationIgnored private var claudePath: String?
    /// Résolution coûteuse (login shell) tentée une seule fois — comme le
    /// FleetPoller (sinon re-source du profil à chaque launch/stop en échec).
    @ObservationIgnored private var triedLoginResolve = false

    /// Réinitialise l'état transitoire à l'ouverture d'une nouvelle fenêtre
    /// (le singleton persiste sinon une erreur périmée dans une fenêtre vierge).
    func reset() {
        lastError = nil
    }

    /// Dossier à pré-remplir : dernier utilisé, sinon le dossier de la session
    /// sélectionnée, sinon le home.
    func suggestedDirectory(selectedCwd: String?) -> String {
        if let last = UserDefaults.standard.string(forKey: Self.lastDirKey),
           FileManager.default.fileExists(atPath: last) { return last }
        if let selectedCwd { return selectedCwd }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Lance une tâche en arrière-plan dans `cwd`. Renvoie l'id de session si on a
    /// pu l'extraire (best-effort) — le suivi réel passe de toute façon par le
    /// FleetPoller. Erreur mémorisée dans `lastError`.
    @discardableResult
    func launch(task: String, cwd: String) async -> String? {
        // Garde de ré-entrance : `launch` est @MainActor mais suspend sur
        // `await`, ce qui autoriserait une 2e entrée (double-clic, ⌘⏎ maintenu)
        // → deux `claude --bg` identiques (double quota, edits concurrents). Le
        // check + le set sont ATOMIQUES sur le MainActor (aucun await entre eux).
        guard !isLaunching else { return nil }
        lastError = nil
        guard FleetLaunch.isValidTask(task) else {
            lastError = "Tâche vide."
            return nil
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            lastError = "Dossier introuvable : \(cwd)"
            return nil
        }
        isLaunching = true // AVANT tout await (sinon la fenêtre de double-clic reste ouverte)
        defer { isLaunching = false }
        guard let claude = await resolveClaudePath() else {
            lastError = "Binaire claude introuvable."
            return nil
        }
        UserDefaults.standard.set(cwd, forKey: Self.lastDirKey)

        // zsh de login (PATH/profil) ; unset ANTHROPIC_API_KEY pour rester sur
        // l'auth par SOUSCRIPTION (tout l'intérêt) ; PAS de --safe-mode : on VEUT
        // les hooks (pour qu'Atoll suive la session). `--bg` rend la main aussitôt.
        let command = "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; "
            + "exec " + FleetLaunch.shellQuote(claude) + " --bg " + FleetLaunch.shellQuote(task)

        let output: String? = await Task.detached(priority: .userInitiated) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
            process.standardInput = FileHandle.nullDevice
            let out = Pipe()
            process.standardOutput = out
            process.standardError = out
            guard (try? process.run()) != nil else { return nil }
            // `--bg` backgroundise et rend la main : lecture courte + garde-fou.
            Self.armWatchdog(process, seconds: 20)
            let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
        }.value

        guard let output else {
            lastError = "Échec du lancement (claude a renvoyé une erreur)."
            log.error("launch échoué dans \(cwd, privacy: .public)")
            return nil
        }
        let id = FleetLaunch.parseSessionID(output)
        log.info("tâche lancée dans \(cwd, privacy: .public) — id \(id ?? "?", privacy: .public)")
        return id
    }

    /// Arrête une session (kill-switch par session — `claude stop <id>`).
    /// Renvoie true si `claude stop` a réussi ; sur échec, renseigne `lastError`
    /// (un kill-switch ne doit pas mentir sur son résultat).
    @discardableResult
    func stop(sessionID: String) async -> Bool {
        guard let claude = await resolveClaudePath() else {
            lastError = "Binaire claude introuvable — arrêt impossible."
            return false
        }
        let ok = await Task.detached(priority: .utility) { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claude)
            process.arguments = ["stop", sessionID]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            Self.armWatchdog(process, seconds: 10)
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
        if ok {
            log.info("session arrêtée : \(sessionID, privacy: .public)")
        } else {
            lastError = "L'arrêt a échoué — la session tourne peut-être encore."
            log.error("échec de l'arrêt de \(sessionID, privacy: .public)")
        }
        return ok
    }

    // MARK: - Résolution du chemin claude (identique au FleetPoller)

    private func resolveClaudePath() async -> String? {
        if let claudePath { return claudePath }
        let common = ("~/.local/bin/claude" as NSString).expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: common) { claudePath = common; return common }
        // Login shell : UNE seule fois (sinon re-source le profil à chaque échec).
        guard !triedLoginResolve else { return nil }
        triedLoginResolve = true
        let resolved = await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "command -v claude"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            Self.armWatchdog(process, seconds: 10)
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (process.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: path)) ? path : nil
        }.value
        claudePath = resolved
        return resolved
    }

    nonisolated private static func armWatchdog(_ process: Process, seconds: TimeInterval) {
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }
}
