import Foundation
import Observation
import OSLog
import AtollCore

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "fleet")

/// Interroge périodiquement `claude agents --json` — l'interface SUPPORTÉE
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
        let deadline = ContinuousClock.now.advanced(by: .seconds(Self.commandTimeout))
        let path = await resolveClaudePath(deadline: deadline)
        guard !Task.isCancelled else { return }
        guard let path else {
            available = false
            SessionStore.shared.applyFleetSnapshot([], available: false)
            return
        }
        if let data = await Self.runAgentsJSON(claudePath: path, deadline: deadline) {
            // Code de sortie 0 ne veut pas dire « sortie comprise ». Un format
            // non reconnu était décodé en `[]` puis publié avec `available:
            // true` : l'îlot concluait que TOUTES les sessions avaient disparu,
            // les clôturait en deux tours, et le repli par scan de processus ne
            // s'armait jamais (`available` restait vrai). On traite désormais ce
            // cas comme ce qu'il est : une sonde qui n'a rien conclu.
            guard case .sessions(let infos) = AgentsSnapshot.decodeOutcome(data) else {
                available = false
                lastActive = false
                SessionStore.shared.applyFleetSnapshot([], available: false)
                return
            }
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

    private func resolveClaudePath(deadline: ContinuousClock.Instant) async -> String? {
        if let claudePath { return claudePath }
        // Chemin usuel de l'installeur natif : vérif CHEAP (pas de shell),
        // retentée à chaque poll (claude peut apparaître après coup).
        let common = ("~/.local/bin/claude" as NSString).expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: common) { claudePath = common; return common }
        // Résolution via login shell : COÛTEUSE (source le profil) → EXACTEMENT
        // une fois. Sur échec, on ne la répète pas (repli scan silencieux).
        guard !triedLoginResolve else { return nil }
        triedLoginResolve = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", "command -v claude"]
        process.standardInput = FileHandle.nullDevice
        let result = try? await BoundedProcessRunner.run(process,
            timeout: BoundedProcessRunner.remaining(until: deadline), stdoutCap: 16_384)
        let path = result.map { String(decoding: $0.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let resolved = result?.succeeded == true && !path.isEmpty
            && FileManager.default.isExecutableFile(atPath: path) ? path : nil
        claudePath = resolved
        return resolved
    }

    /// Exécute `claude agents --json` (exec direct — pas de shell). Renvoie stdout
    /// si exit 0, nil sinon (commande absente/erreur/daemon figé → repli scan).
    /// La collecte est bornée même si l'enfant ne peut pas être signalé.
    /// Dans ce cas, aucun nouveau poll n'est lancé avant sa vraie sortie.
    private static var activeProbe: Process?
    private static var collectingProbe = false

    static func runAgentsJSON(claudePath: String,
                              deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(5))) async -> Data? {
        guard !collectingProbe, activeProbe?.isRunning != true else { return nil }
        guard BoundedProcessRunner.remaining(until: deadline) > 0, !Task.isCancelled else { return nil }
        let process = Process()
        activeProbe = process
        collectingProbe = true
        defer {
            collectingProbe = false
            if !process.isRunning { activeProbe = nil }
        }
        process.executableURL = URL(fileURLWithPath: claudePath)
        // SANS --all : seules les sessions actives sont demandées, comme avant.
        process.arguments = ["agents", "--json"]
        process.standardInput = FileHandle.nullDevice
        let result = try? await BoundedProcessRunner.run(process,
            timeout: BoundedProcessRunner.remaining(until: deadline), stdoutCap: 4 * 1024 * 1024)
        return result?.succeeded == true ? result?.stdout : nil
    }
}
