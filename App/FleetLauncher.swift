import Foundation
import Observation
import OSLog
import AtollCore

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "launcher")

/// ARRÊTE une session Claude Code (`claude stop <id>`) depuis le détail d'une
/// session — le kill-switch, avec confirmation.
///
/// Le LANCEMENT (`claude --bg`, la fenêtre ⌘N du « cockpit ambiant ») a été
/// retiré le 2026-08-03. Deux raisons, la seconde étant la vraie :
/// - il n'avait JAMAIS servi — `~/.atoll/launched-tasks.json` valait `{"tasks":[]}`
///   depuis la Phase 9 ;
/// - il lançait `claude --bg` **sans `-w/--worktree`**, alors que le drapeau
///   existe : une tâche écrivait directement dans l'arbre de travail de
///   l'utilisateur, pendant qu'il éditait, en Rockstar, sans rien demander.
/// `claude --bg` depuis le terminal fait le même travail, sans ce piège.
@MainActor
@Observable
final class FleetLauncher {
    static let shared = FleetLauncher()

    private(set) var lastError: String?

    /// Chemin claude résolu.
    @ObservationIgnored private var claudePath: String?
    /// Résolution coûteuse (login shell) tentée une seule fois — comme le
    /// FleetPoller (sinon re-source du profil à chaque launch/stop en échec).
    @ObservationIgnored private var triedLoginResolve = false

    /// Arrête une session (kill-switch par session — `claude stop <id>`).
    /// Renvoie true si `claude stop` a réussi ; sur échec, renseigne `lastError`
    /// (un kill-switch ne doit pas mentir sur son résultat).
    @discardableResult
    func stop(sessionID: String) async -> Bool {
        guard let claude = await resolveClaudePath() else {
            lastError = "Binaire claude introuvable — arrêt impossible."
            return false
        }
        // `claude stop` attend le PRÉFIXE de 8 hex, jamais l'UUID complet — voir
        // `FleetLaunch.jobIdentifier`. Passer `session.id` en entier faisait
        // échouer le kill-switch à tous les coups, depuis la Phase 9.
        guard let jobID = FleetLaunch.jobIdentifier(for: sessionID) else {
            lastError = "Cette session n'a pas d'identifiant que claude sache arrêter."
            log.error("identifiant inattendu, arrêt impossible : \(sessionID, privacy: .public)")
            return false
        }
        let outcome = await Task.detached(priority: .utility) { () -> (ok: Bool, message: String) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claude)
            process.arguments = ["stop", jobID]
            process.standardOutput = FileHandle.nullDevice
            // Un kill-switch ne doit pas mentir sur son résultat : on RAPPORTE ce
            // que la CLI a dit plutôt que d'inventer une cause. Le message est
            // court (« No job matching '…' ») — pas de risque de blocage de pipe,
            // et il est drainé avant `waitUntilExit`.
            let pipe = Pipe()
            process.standardError = pipe
            guard (try? process.run()) != nil else { return (false, "claude stop n'a pas pu être lancé.") }
            Self.armWatchdog(process, seconds: 10)
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            let stderr = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if process.terminationStatus == 0 { return (true, "") }
            return (false, stderr.isEmpty
                    ? "L'arrêt a échoué — la session tourne peut-être encore."
                    : "Arrêt refusé par claude : \(stderr.prefix(160))")
        }.value
        if outcome.ok {
            log.info("session arrêtée : \(jobID, privacy: .public)")
        } else {
            lastError = outcome.message
            log.error("échec de l'arrêt de \(jobID, privacy: .public) : \(outcome.message, privacy: .public)")
        }
        return outcome.ok
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
