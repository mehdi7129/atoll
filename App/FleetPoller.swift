import Foundation
import Observation
import OSLog
import AtollCore

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "fleet")

/// Interroge périodiquement `claude agents --json --all` — l'interface SUPPORTÉE
/// d'énumération de la flotte — et en fait l'AUTORITÉ de découverte des sessions.
///
/// Pourquoi : le daemon d'arrière-plan de Claude Code a rendu le scan de processus
/// non fiable (les sessions d'arrière-plan sont des descendants du daemon, exclues
/// comme subagents). `agents --json` les liste nativement, avec leur vrai id, leur
/// nom et leur statut. Si la commande échoue (CLI trop ancien, pas de daemon),
/// `available` repasse à false et SessionStore reprend le scan de processus en
/// repli — dégradation gracieuse, jamais de perte de fonctionnalité.
@MainActor
@Observable
final class FleetPoller {
    static let shared = FleetPoller()

    /// La commande `agents --json` a-t-elle répondu au dernier tour ? (affiché
    /// dans les Réglages : source « agents --json ✓ » vs « repli scan »).
    private(set) var available = false

    @ObservationIgnored private var task: Task<Void, Never>?
    /// Chemin du binaire `claude`, résolu puis mis en cache.
    @ObservationIgnored private var claudePath: String?
    /// La résolution COÛTEUSE (login shell) a-t-elle déjà été tentée ? Sur échec,
    /// on ne re-source PAS le profil à chaque poll (repli scan silencieux).
    @ObservationIgnored private var triedLoginResolve = false
    /// Cadence courante (adaptative — voir `nextInterval`).
    @ObservationIgnored private var lastActive = false

    /// Au-delà, un `claude` figé est tué : un daemon bloqué ne doit JAMAIS geler
    /// la boucle de poll (readToEnd ignore l'annulation de Task) ni empêcher le
    /// repli scan de se réengager.
    nonisolated private static let commandTimeout: TimeInterval = 5

    // Chaque poll spawne un process `claude` (~0,34 s). Les hooks couvrant déjà
    // le temps réel des sessions à hooks, le poll n'est qu'un filet de découverte :
    // rapide quand quelque chose travaille, lent au repos — pour ne pas churner un
    // process node en boucle sur une app quasi-inerte.
    private static let activeInterval: Duration = .seconds(2)
    private static let idleInterval: Duration = .seconds(6)

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                let interval = (self?.lastActive ?? false) ? Self.activeInterval : Self.idleInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func pollOnce() async {
        let path = await resolveClaudePath()
        guard let path else {
            available = false
            SessionStore.shared.applyFleetSnapshot([], available: false)
            return
        }
        if let data = await Self.runAgentsJSON(claudePath: path) {
            let infos = AgentsSnapshot.decode(data)
            available = true
            // Cadence rapide seulement si une session travaille ou attend une
            // réponse — sinon on ralentit (au repos, un poll lent suffit ; les
            // hooks réveillent le temps réel quand ça bouge).
            lastActive = infos.contains { $0.status == .busy || $0.status == .needsInput }
            SessionStore.shared.applyFleetSnapshot(infos, available: true)
        } else {
            available = false
            lastActive = false
            SessionStore.shared.applyFleetSnapshot([], available: false)
        }
    }

    private func resolveClaudePath() async -> String? {
        if let claudePath { return claudePath }
        // Chemin usuel de l'installeur natif : vérif CHEAP (pas de shell),
        // retentée à chaque poll (claude peut apparaître après coup).
        let common = ("~/.local/bin/claude" as NSString).expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: common) { claudePath = common; return common }
        // Résolution via login shell : COÛTEUSE (source le profil) → EXACTEMENT
        // une fois. Sur échec, on ne la répète pas (repli scan silencieux).
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
            Self.armWatchdog(process)
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (process.terminationStatus == 0 && !path.isEmpty
                    && FileManager.default.isExecutableFile(atPath: path)) ? path : nil
        }.value
        claudePath = resolved
        return resolved
    }

    /// Exécute `claude agents --json` (exec direct — pas de shell). Renvoie stdout
    /// si exit 0, nil sinon (commande absente/erreur/daemon figé → repli scan).
    /// BORNÉ par un watchdog : un `claude` qui hang est tué (sinon la boucle de
    /// poll gèlerait à jamais et le repli ne se réengagerait pas).
    private static func runAgentsJSON(claudePath: String) async -> Data? {
        await Task.detached(priority: .utility) { () -> Data? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claudePath)
            // SANS --all : seules les sessions ACTIVES (une session terminée
            // sort du snapshot → Atoll la clôt).
            process.arguments = ["agents", "--json"]
            process.standardInput = FileHandle.nullDevice
            let out = Pipe()
            process.standardError = FileHandle.nullDevice
            process.standardOutput = out
            guard (try? process.run()) != nil else { return nil }
            armWatchdog(process)
            let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            // Tué par le watchdog → status ≠ 0 → nil → available=false → repli.
            return process.terminationStatus == 0 ? data : nil
        }.value
    }

    /// Tue un process qui dépasse `commandTimeout` (SIGTERM puis SIGKILL). Le
    /// terminate ferme stdout → readToEnd retourne, la boucle continue.
    nonisolated private static func armWatchdog(_ process: Process) {
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + commandTimeout) {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }
}
