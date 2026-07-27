import Foundation
import Observation
import OSLog
import AtollCore

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "session-store")

/// Source de vérité des sessions Claude Code.
///
/// Signaux combinés (voir docs/research/research-followup-session-liveness.md) :
/// 1. hooks (temps réel, riches) → machine à états SessionReducer ;
/// 2. kqueue NOTE_EXIT sur le pid → mort instantanée, même sur SIGKILL/crash ;
/// 3. réconciliation périodique (kill(pid,0) + découverte des sessions hookless) ;
/// 4. tail du transcript → détection des interruptions Échap (aucun hook n'existe).
@MainActor
@Observable
final class SessionStore {
    static let shared = SessionStore()

    struct Tracked: Identifiable {
        let id: String
        var pid: pid_t?
        var pidStartTime: Double?
        var cwd: String?
        var transcriptPath: String?
        var phase: SessionPhase
        var title: String?
        var terminalHint: String?
        var isSynthetic: Bool
        var firstSeenAt: Date
        var lastEventAt: Date
        var missedScans = 0
        // Enrichissements.
        var model: String?
        var gitBranch: String?
        var subagentCount = 0
        var mcpServers: Set<String> = []
        var contextUsedFraction: Double?
        var costUSD: Double?
        // Ancrage terminal (jump-back).
        var tty: String?
        var bundleID: String?
        var termProgram: String?
        var entrypoint: String?
        var env: [String: String] = [:]
        /// Nombre de prompts utilisateur (hooks UserPromptSubmit) — critère de
        /// « session substantielle » pour la rétrospective. 0 pour les synthétiques.
        var userPromptCount = 0

        var terminalAnchor: TerminalAnchor {
            TerminalAnchor(cwd: cwd, tty: tty, bundleID: bundleID, termProgram: termProgram,
                           entrypoint: entrypoint, env: env)
        }
    }

    private(set) var sessions: [Tracked] = []
    private(set) var eventCount = 0
    var serverRunning = false
    /// Vrai quota serveur (statusline). nil tant qu'aucun payload reçu.
    private(set) var realQuota: QuotaSnapshot?

    /// Clés d'environnement conservées pour l'ancrage terminal (jump-back).
    static let anchorEnvKeys: Set<String> = [
        "__CFBundleIdentifier", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
        "ITERM_SESSION_ID", "TMUX", "TMUX_PANE", "KITTY_WINDOW_ID", "KITTY_LISTEN_ON",
        "WEZTERM_PANE", "GHOSTTY_RESOURCES_DIR", "ALACRITTY_WINDOW_ID",
        "VSCODE_INJECTION", "CURSOR_TRACE_ID", "WARP_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT",
    ]

    /// Raison du passage terminal — pour les logs et la rétrospective.
    enum SessionEndReason: String { case hookEnded, pidExited, reconcileGC }

    /// Tiré EXACTEMENT UNE FOIS par transition vivante → ended, avec le
    /// snapshot complet de la session AVANT sa purge (fenêtre de 8 s).
    /// Branché par l'AppDelegate vers le RetrospectiveRunner.
    @ObservationIgnored var onSessionEnded: ((Tracked, SessionEndReason) -> Void)?
    /// Une session .ended ressuscite via `claude --resume` (même session_id).
    @ObservationIgnored var onSessionResumed: ((String) -> Void)?

    /// Pids des claude lancés PAR ATOLL (rétrospectives) : jamais des sessions
    /// utilisateur — reconcile() les ignore. Le marqueur d'env
    /// ATOLL_RETROSPECTIVE=1 couvre le cas d'un redémarrage d'Atoll en plein vol.
    @ObservationIgnored private var internalPids: Set<pid_t> = []

    func registerInternalPid(_ pid: pid_t) { internalPids.insert(pid) }
    func unregisterInternalPid(_ pid: pid_t) { internalPids.remove(pid) }

    /// Vrai quand `claude agents --json` répond : c'est alors l'AUTORITÉ de
    /// découverte (le scan de processus est rétrogradé au repli). Le daemon
    /// d'arrière-plan casse le scan → cette bascule est le cœur du Milestone A.
    @ObservationIgnored private(set) var fleetAvailable = false
    /// La flotte a-t-elle été sondée au moins une fois ? Tant que non, on ne fait
    /// PAS le scan de processus (sinon on créerait un synthétique `pid-<pid>` juste
    /// avant que le premier poll ne le remplace par la vraie session — course vécue).
    @ObservationIgnored private var fleetPolled = false
    /// Compteur d'absences consécutives du JSON par session de flotte (tolérance
    /// avant clôture : un snapshot transitoirement vide ne tue pas une session).
    @ObservationIgnored private var fleetMissed: [String: Int] = [:]

    @ObservationIgnored private var exitWatchers: [pid_t: DispatchSourceProcess] = [:]
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private let tailer = TranscriptTailer()
    /// Minuteurs d'inactivité par session synthétique : pas d'écriture pendant
    /// ce délai → la session repasse « en attente » (pas de hook pour le dire).
    @ObservationIgnored private var idleTimers: [String: Task<Void, Never>] = [:]
    /// Au-delà, une session synthétique dont le transcript n'a pas bougé est
    /// considérée inactive (« en attente ») plutôt que « en cours ». Assez long
    /// pour ne pas clignoter pendant un outil silencieux, assez court pour ne
    /// pas mentir (le bug : une session inactive depuis 16 min affichée « busy »).
    private static let syntheticIdleSeconds: TimeInterval = 15

    // MARK: - Cycle de vie

    func start() {
        // Quota mis en cache au lancement (v0.12.0) : il n'arrive que par la
        // statusline d'une session à TUI. Sans ce rechargement, toute fin de
        // session survenant avant la première statusline — donc après chaque
        // redémarrage d'Atoll, et pour toute session `claude --bg` — était
        // refusée par le gate d'apprentissage faute de quota connu.
        realQuota = Self.loadCachedQuota()

        tailer.onInterrupt = { [weak self] sessionID in
            self?.transcriptInterrupted(sessionID)
        }
        tailer.onTitle = { [weak self] sessionID, title in
            self?.setTitle(sessionID, title: title)
        }
        tailer.onMeta = { [weak self] sessionID, model, gitBranch in
            self?.setMeta(sessionID, model: model, gitBranch: gitBranch)
        }
        tailer.onActivity = { [weak self] sessionID in
            self?.transcriptActivity(sessionID)
        }
        reconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.reconcile()
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    // MARK: - Projection UI

    var uiSessions: [AgentSession] {
        let sorted = sessions.sorted { lhs, rhs in
            let lr = rank(lhs), rr = rank(rhs)
            if lr != rr { return lr < rr }
            return lhs.firstSeenAt < rhs.firstSeenAt
        }
        // Désambiguïsation des noms : un dossier nommé « claude » (vécu : le
        // projet drones de l'utilisateur) ou deux projets homonymes affichent
        // leurs deux derniers composants (« Blender/claude »).
        let baseNames = sorted.map { ($0.cwd as NSString?)?.lastPathComponent ?? "claude" }
        return zip(sorted, baseNames).map { tracked, base in
            let isAmbiguous = base == "claude"
                || baseNames.filter { $0 == base }.count > 1
            var name = base
            if isAmbiguous, let cwd = tracked.cwd {
                let components = (cwd as NSString).pathComponents.suffix(2)
                if components.count == 2 {
                    name = components.joined(separator: "/")
                }
            }
            return AgentSession(
                id: tracked.id,
                projectName: name,
                gitBranch: tracked.gitBranch,
                status: tracked.phase.uiStatus,
                subtitle: tracked.title,
                startedAt: tracked.firstSeenAt,
                model: tracked.model,
                subagentCount: tracked.subagentCount,
                mcpServers: tracked.mcpServers.sorted(),
                contextUsedFraction: tracked.contextUsedFraction,
                costUSD: tracked.costUSD,
                cwd: tracked.cwd
            )
        }
    }

    /// Quota affiché : vrai serveur uniquement — jamais de données factices
    /// (les vues masquent les jauges tant que hasRealQuota est faux).
    var displayQuota: UsageSnapshot {
        guard let realQuota else {
            return UsageSnapshot(fiveHourFraction: 0, sevenDayFraction: 0)
        }
        return UsageSnapshot(
            fiveHourFraction: realQuota.fiveHour.usedFraction,
            sevenDayFraction: realQuota.sevenDay.usedFraction
        )
    }

    var quotaResets: (five: Date?, seven: Date?) {
        (realQuota?.fiveHour.resetsAt, realQuota?.sevenDay.resetsAt)
    }

    var hasRealQuota: Bool { realQuota != nil }
    /// Quand le dernier vrai quota a été reçu (pour l'indicateur d'âge).
    var quotaReceivedAt: Date? { realQuota?.receivedAt }

    /// Ancre terminal d'une session (pour le jump-back).
    func terminalAnchor(for id: String) -> TerminalAnchor? {
        sessions.first { $0.id == id }?.terminalAnchor
    }

    /// Une permission a été auto-approuvée (auto-accept / rockstar) : la session
    /// n'attend plus, l'outil va s'exécuter → repasser en « busy » (sinon elle
    /// resterait affichée « en attente d'approbation »).
    func markAutoApproved(_ sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        if case .waitingPermission = sessions[index].phase {
            sessions[index].phase = .busy
            scheduleSnapshot()
        }
    }

    private func rank(_ session: Tracked) -> Int {
        switch session.phase {
        case .waitingPermission: return 0
        case .waitingInput: return 1
        case .busy, .toolRunning, .compacting, .starting: return 2
        case .ended: return 3
        }
    }

    // MARK: - Événements hooks

    func apply(_ event: ParsedHookEvent) {
        eventCount += 1
        let now = Date()

        // Course terminal ↔ îlot : un événement de résolution signifie que la
        // demande a été tranchée ailleurs → annuler nos cartes en attente pour
        // cette session (fermeture silencieuse, le terminal garde la main).
        switch event.kind {
        case .postToolUse, .postToolUseFailure, .permissionDenied, .stop, .sessionEnd, .userPromptSubmit:
            // userPromptSubmit inclus : un nouveau prompt prouve qu'aucun dialogue
            // de permission n'est plus en attente pour cette session.
            InteractionCenter.shared.cancelForSession(event.sessionID)
        default:
            break
        }

        if let index = sessions.firstIndex(where: { $0.id == event.sessionID }) {
            var session = sessions[index]
            // Un hook prouve que la session est désormais pilotée par les hooks
            // (machine à états fine) : si la flotte l'avait d'abord découverte
            // (isSynthetic), on rebascule — sinon sa phase resterait pilotée par
            // le statut grossier de `agents --json`.
            session.isSynthetic = false
            let previousPhase = session.phase
            var resurrected = false
            // Résurrection : `claude --resume` reprend le MÊME session_id après un
            // SessionEnd(reason=resume) — .ended étant terminal dans le reducer,
            // un SessionStart relance explicitement le cycle de vie.
            if session.phase == .ended, event.kind == .sessionStart {
                session.phase = SessionReducer.reduce(.starting, event)
                session.missedScans = 0
                resurrected = true
            } else {
                session.phase = SessionReducer.reduce(session.phase, event)
            }
            update(&session, from: event, at: now)
            sessions[index] = session
            if resurrected { onSessionResumed?(session.id) }
            // Transition vivante → ended : passage terminal unifié (le seul
            // endroit qui tire onSessionEnded pour les fins signalées par hook).
            if previousPhase.isAlive, sessions[index].phase == .ended {
                markEnded(at: index, reason: .hookEnded)
            }
        } else {
            // Un SessionEnd pour une session inconnue n'a rien à créer.
            guard event.kind != .sessionEnd else { return }
            // Reprise APRÈS la purge de 8 s (le cas courant : --resume minutes
            // plus tard) : la Tracked n'existe plus, mais le session_id repris
            // est identique → prévenir le runner AVANT de recréer la session,
            // sinon une rétrospective en vol analyserait un transcript en cours
            // d'écriture (revue). No-op si le runner ne suit pas cet id.
            if event.kind == .sessionStart {
                onSessionResumed?(event.sessionID)
            }
            // Une session hook remplace la session synthétique du même pid.
            if let pid = event.claudePid {
                for synthetic in sessions.filter({ $0.isSynthetic && $0.pid == pid }) {
                    tailer.stopWatching(synthetic.id)
                    idleTimers[synthetic.id]?.cancel()
                    idleTimers[synthetic.id] = nil
                }
                sessions.removeAll { $0.isSynthetic && $0.pid == pid }
            }
            var session = Tracked(
                id: event.sessionID,
                pid: nil,
                pidStartTime: nil,
                cwd: nil,
                transcriptPath: nil,
                phase: SessionReducer.reduce(.starting, event),
                title: nil,
                terminalHint: nil,
                isSynthetic: false,
                firstSeenAt: now,
                lastEventAt: now
            )
            update(&session, from: event, at: now)
            sessions.append(session)
        }

        scheduleSnapshot()
    }

    /// Passage terminal UNIFIÉ — les 3 chemins (hook SessionEnd, kqueue
    /// NOTE_EXIT, GC de reconcile) convergent ici. L'APPELANT garantit la
    /// transition (phase vivante avant l'appel) : le callback n'est jamais
    /// ré-émis pour une session déjà terminée.
    private func markEnded(at index: Int, reason: SessionEndReason) {
        sessions[index].phase = .ended
        let snapshot = sessions[index]
        fleetMissed[snapshot.id] = nil
        tailer.stopWatching(snapshot.id)
        InteractionCenter.shared.cancelForSession(snapshot.id)
        idleTimers[snapshot.id]?.cancel()
        idleTimers[snapshot.id] = nil
        scheduleRemoval(snapshot.id)
        onSessionEnded?(snapshot, reason)
        scheduleSnapshot()
    }

    private func update(_ session: inout Tracked, from event: ParsedHookEvent, at now: Date) {
        session.lastEventAt = now
        if let cwd = event.cwd { session.cwd = cwd }
        if let hint = event.terminalHint { session.terminalHint = hint }
        // Ancrage terminal capté aux premiers événements (SessionStart, etc.).
        if session.tty == nil, let tty = event.tty { session.tty = tty }
        if session.bundleID == nil { session.bundleID = event.env["__CFBundleIdentifier"] ?? event.terminalHint }
        if session.termProgram == nil { session.termProgram = event.env["TERM_PROGRAM"] }
        if session.entrypoint == nil { session.entrypoint = event.entrypoint }
        if session.env.isEmpty, !event.env.isEmpty { session.env = event.env }
        if let transcript = event.transcriptPath { session.transcriptPath = transcript }
        // Tentée à chaque événement (le tailer ignore les doublons) : couvre les
        // échecs d'open transitoires ET la reprise après résurrection --resume.
        if session.phase.isAlive, let path = session.transcriptPath {
            tailer.watch(sessionID: session.id, path: path)
        }
        if session.title == nil, let prompt = event.promptText {
            session.title = Self.condense(prompt)
        }
        if let pid = event.claudePid, session.pid != pid {
            session.pid = pid
            session.pidStartTime = event.claudeStartTime
            armExitWatch(pid: pid)
        }

        // Sous-agents actifs (compteur) et serveurs MCP utilisés.
        switch event.kind {
        case .userPromptSubmit:
            session.userPromptCount += 1
        case .subagentStart:
            session.subagentCount += 1
        case .subagentStop:
            session.subagentCount = max(0, session.subagentCount - 1)
        case .preToolUse:
            if let tool = event.toolName, let server = ParsedHookEvent.mcpServerName(tool) {
                session.mcpServers.insert(server)
            }
        case .stop, .sessionEnd:
            session.subagentCount = 0 // fin de tour : plus de sous-agents en vol
            // Fin de tour = le transcript vient d'être complété → indexation
            // mémoire quasi temps réel (coalescée côté indexeur).
            if let path = session.transcriptPath {
                MemoryIndexer.shared.nudge(transcriptPath: path)
            }
        default:
            break
        }

        if session.phase == .ended {
            tailer.stopWatching(session.id)
        }
    }

    private static func condense(_ text: String, maxLength: Int = 64) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.count > maxLength
            ? String(flattened.prefix(maxLength)) + "…"
            : flattened
    }

    private func setMeta(_ sessionID: String, model: String?, gitBranch: String?) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        // La statusline fournit un nom de modèle plus lisible (« Opus 4.8 ») ;
        // ne pas écraser un modèle déjà connu par l'id brut du transcript.
        if let model, sessions[index].model == nil { sessions[index].model = model }
        if let gitBranch, gitBranch != "HEAD" { sessions[index].gitBranch = gitBranch }
        scheduleSnapshot()
    }

    /// Payload statusline : vrai quota serveur + modèle/contexte/coût par session.
    func applyStatusline(_ envelope: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: envelope),
              let dict = object as? [String: Any],
              let inner = dict["statusline"],
              let innerData = try? JSONSerialization.data(withJSONObject: inner),
              let payload = StatusLinePayload(data: innerData, now: Date()) else { return }

        if let quota = payload.quota {
            // Anti-replay : une session INACTIVE renvoie périodiquement un
            // rate_limits mis en cache. Dans une MÊME fenêtre 5 h (même
            // resets_at), l'utilisation ne peut que croître — une fraction plus
            // basse est un vieux cache qui rafraîchirait receivedAt à tort (le
            // gate de rétrospective croirait à de la marge fraîche — revue).
            let isStaleReplay = realQuota.map { current in
                current.fiveHour.resetsAt == quota.fiveHour.resetsAt
                    && quota.fiveHour.usedFraction < current.fiveHour.usedFraction
            } ?? false
            if !isStaleReplay {
                realQuota = quota
                Self.cacheQuota(quota)
            }
        }

        if let sessionID = payload.sessionID,
           let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            // La statusline est la source autoritaire du modèle courant.
            if let model = payload.usage.modelDisplayName { sessions[index].model = model }
            if let context = payload.usage.contextUsedFraction { sessions[index].contextUsedFraction = context }
            if let cost = payload.usage.costUSD { sessions[index].costUSD = cost }
            sessions[index].lastEventAt = Date()
        }
        scheduleSnapshot()
    }

    private func setTitle(_ sessionID: String, title: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              sessions[index].title == nil else { return }
        sessions[index].title = Self.condense(title)
    }

    // MARK: - Liveness (kqueue)

    private func armExitWatch(pid: pid_t) {
        guard exitWatchers[pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.pidExited(pid)
            }
        }
        source.resume()
        exitWatchers[pid] = source
        // Anti-course : le pid peut être mort avant l'armement — l'événement ne
        // viendrait alors jamais. Différé d'un tour de boucle : armExitWatch est
        // appelé pendant qu'apply() modifie une COPIE locale de la session, un
        // pidExited synchrone serait écrasé par la réécriture qui suit.
        if !ProcessInspector.isAlive(pid) {
            Task { @MainActor [weak self] in
                self?.pidExited(pid)
            }
        }
    }

    private func pidExited(_ pid: pid_t) {
        exitWatchers[pid]?.cancel()
        exitWatchers[pid] = nil
        for index in sessions.indices where sessions[index].pid == pid && sessions[index].phase.isAlive {
            markEnded(at: index, reason: .pidExited)
        }
        scheduleSnapshot()
    }

    private func scheduleRemoval(_ sessionID: String, after seconds: Double = 8) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self else { return }
            if let index = self.sessions.firstIndex(where: { $0.id == sessionID }),
               self.sessions[index].phase == .ended {
                self.tailer.stopWatching(sessionID)
                self.idleTimers[sessionID]?.cancel()
                self.idleTimers[sessionID] = nil
                self.sessions.remove(at: index)
            }
        }
    }

    // MARK: - Transcript

    private func transcriptInterrupted(_ sessionID: String) {
        // Échap au prompt du terminal ne déclenche AUCUN hook : c'est le seul
        // signal qu'un dialogue interactif en cours a été abandonné → on annule
        // notre carte (sinon elle traînerait jusqu'au timeout de 24 h).
        InteractionCenter.shared.cancelForSession(sessionID)
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        switch sessions[index].phase {
        case .busy, .toolRunning, .starting, .waitingPermission:
            sessions[index].phase = .waitingInput
        default:
            break
        }
    }

    /// Le transcript d'une session SYNTHÉTIQUE (découverte par scan, sans hooks)
    /// vient d'être écrit → elle travaille. On la passe « en cours » et on arme
    /// un minuteur d'inactivité : sans nouvelle écriture, elle repassera « en
    /// attente » (aucun hook Stop ne le signalera pour ces sessions). Les
    /// sessions à hooks gardent leur phase pilotée par la machine à états.
    private func transcriptActivity(_ sessionID: String) {
        // Quand la flotte (`agents --json`) pilote la phase, ce signal de secours
        // par transcript devient redondant et pourrait entrer en conflit.
        guard !fleetAvailable else { return }
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              sessions[index].isSynthetic else { return }
        // Ne pas écraser une demande de permission en attente.
        if case .waitingPermission = sessions[index].phase { return }
        if sessions[index].phase != .busy {
            sessions[index].phase = .busy
            scheduleSnapshot()
        }
        idleTimers[sessionID]?.cancel()
        idleTimers[sessionID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.syntheticIdleSeconds))
            guard !Task.isCancelled else { return }
            self?.markSyntheticIdle(sessionID)
        }
    }

    /// Session synthétique sans écriture depuis le délai d'inactivité → en attente.
    private func markSyntheticIdle(_ sessionID: String) {
        idleTimers[sessionID] = nil
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }),
              sessions[index].isSynthetic else { return }
        switch sessions[index].phase {
        case .busy, .toolRunning, .starting:
            sessions[index].phase = .waitingInput
            scheduleSnapshot()
        default:
            break
        }
    }

    // MARK: - Réconciliation

    private func reconcile() {
        // 1. Filet de sécurité derrière kqueue : deux passes manquées = mort.
        //    Et GC des zombies : une session hook sans pid connu dont plus aucun
        //    événement n'arrive (bridge sans ancêtre claude, SessionEnd perdu)
        //    ne doit pas rester immortelle.
        for index in sessions.indices where sessions[index].phase.isAlive {
            // Sessions de flotte : leur liveness est pilotée par `agents --json`
            // (présence dans le snapshot), pas par un pid — qui peut être un
            // processus-hôte transitoire du daemon. On ne les GC pas ici.
            if fleetAvailable, sessions[index].isSynthetic { continue }
            guard let pid = sessions[index].pid else {
                // Session hook SANS pid : rien ne l'ancre à un processus vivant
                // (enveloppe forgée, ancêtre claude introuvable — ex. hook lancé
                // depuis un npm/node non reconnu). 5 min sans événement suffisent
                // pour la déclarer morte — vécu : les sessions de test traînaient.
                // MAIS une carte en attente prouve que la session est vivante
                // (le helper y est bloqué) : ne jamais la GC dans ce cas.
                let hasPendingCard = InteractionCenter.shared.pending.contains { $0.sessionID == sessions[index].id }
                if !sessions[index].isSynthetic, !hasPendingCard,
                   Date().timeIntervalSince(sessions[index].lastEventAt) > 300 {
                    markEnded(at: index, reason: .reconcileGC)
                }
                continue
            }
            if ProcessInspector.isAlive(pid) {
                sessions[index].missedScans = 0
            } else {
                sessions[index].missedScans += 1
                if sessions[index].missedScans >= 2 {
                    pidExited(pid)
                }
            }
        }

        // 1bis. Filet pour les sessions SYNTHÉTIQUES bloquées « en cours » : sans
        //       hooks, seul le transcript dit si elles travaillent. Si le fichier
        //       n'a pas bougé depuis le délai d'inactivité, elles sont « en
        //       attente » (corrige aussi une session découverte « busy » qui
        //       n'a plus jamais écrit — le minuteur temps réel ne s'arme que sur
        //       une écriture, ce filet couvre l'absence d'écriture).
        //       Rétrogradé au repli : quand `agents --json` répond, le statut
        //       du JSON pilote la phase (plus fiable que le mtime du transcript).
        let now = Date()
        if !fleetAvailable {
        for index in sessions.indices
        where sessions[index].isSynthetic && sessions[index].phase.isAlive {
            switch sessions[index].phase {
            case .busy, .toolRunning, .starting:
                let mtime = sessions[index].transcriptPath
                    .flatMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
                    ?? nil
                let stale = mtime.map { now.timeIntervalSince($0) > Self.syntheticIdleSeconds } ?? true
                if stale {
                    sessions[index].phase = .waitingInput
                    idleTimers[sessions[index].id]?.cancel()
                    idleTimers[sessions[index].id] = nil
                }
            default:
                break
            }
        }
        } // fin du filet 1bis (repli seulement)

        // 2. Découverte des sessions hookless — REPLI uniquement, et SEULEMENT
        //    une fois qu'un poll a confirmé que `agents --json` est indisponible
        //    (CLI trop ancien). Tant que la flotte n'a pas répondu (démarrage) ou
        //    qu'elle répond, applyFleetSnapshot() fait la découverte sur une
        //    interface supportée que le daemon ne casse pas.
        guard fleetPolled, !fleetAvailable else {
            scheduleSnapshot()
            return
        }
        let knownPids = Set(sessions.compactMap(\.pid))
        let claudePids = ProcessInspector.allClaudePids()
        log.debug("réconciliation: \(claudePids.count) processus claude, \(knownPids.count) connus")
        for pid in claudePids where !knownPids.contains(pid) {
            // Les rétrospectives lancées PAR Atoll ne sont jamais des sessions
            // utilisateur (double ceinture : set en mémoire + marqueur d'env
            // plus bas, qui survit à un redémarrage d'Atoll).
            if internalPids.contains(pid) { continue }
            // Un claude enfant d'un autre claude (subagent, claude -p spawné par
            // une session, agents de workflow) n'est pas une session utilisateur.
            if let parent = ProcessInspector.parent(of: pid), parent > 1,
               ProcessInspector.findClaudeAncestor(from: parent) != nil {
                continue
            }
            guard let cwd = ProcessInspector.currentWorkingDirectory(of: pid) else {
                log.debug("pid \(pid): cwd illisible, ignoré")
                continue
            }
            // Les worktrees de subagents ne sont pas des sessions utilisateur.
            if cwd.contains("/.claude/worktrees/") { continue }
            let transcript = Self.newestTranscript(forCwd: cwd)
            // Ancre terminal lue directement dans l'environnement du processus
            // (KERN_PROCARGS2) : ces sessions n'ont pas d'enrichissement de hook.
            let procEnv = ProcessInspector.environment(of: pid)
            // Rétrospective orpheline (Atoll a redémarré pendant le run) :
            // reconnue à son marqueur d'env, jamais affichée comme session.
            if procEnv["ATOLL_RETROSPECTIVE"] == "1" { continue }
            let anchorEnv = procEnv.filter { Self.anchorEnvKeys.contains($0.key) }
            var session = Tracked(
                id: "pid-\(pid)-\(Int(ProcessInspector.startTime(of: pid) ?? 0))",
                pid: pid,
                pidStartTime: ProcessInspector.startTime(of: pid),
                cwd: cwd,
                transcriptPath: transcript?.path,
                phase: .waitingInput,
                title: nil,
                terminalHint: procEnv["__CFBundleIdentifier"],
                isSynthetic: true,
                firstSeenAt: Date(),
                lastEventAt: Date()
            )
            session.tty = ProcessInspector.tty(of: pid)
            session.bundleID = procEnv["__CFBundleIdentifier"]
            session.termProgram = procEnv["TERM_PROGRAM"]
            session.entrypoint = procEnv["CLAUDE_CODE_ENTRYPOINT"]
            session.env = anchorEnv
            if let transcript, let mtime = try? transcript.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(mtime) < 8 {
                session.phase = .busy
            }
            sessions.append(session)
            armExitWatch(pid: pid)
        }
        scheduleSnapshot()
    }

    // MARK: - Découverte via `claude agents --json` (autorité)

    /// Réconcilie la flotte rapportée par `claude agents --json` avec les sessions
    /// suivies. Autorité pour l'EXISTENCE, le vrai id, le nom (→ titre) et le
    /// statut des sessions NON pilotées par les hooks ; les hooks restent
    /// autoritaires pour la phase fine (toolRunning/waitingPermission/compacting)
    /// et les permissions. Corrélation par id exact puis par pid (l'id peut
    /// diverger à un fork/compaction, le pid reste stable).
    func applyFleetSnapshot(_ infos: [AgentSessionInfo], available: Bool) {
        fleetAvailable = available
        fleetPolled = true
        guard available else { return }

        // Ids des sessions suivies CORRÉLÉES à une entrée du JSON ce tour-ci —
        // par id OU par pid. La passe de retrait s'appuie dessus (une session
        // corrélée-par-pid ne doit pas être vue « absente » et clôturée à tort).
        var seen = Set<String>()
        // Ne re-render (observation) et ne réécrire state.json QUE si la flotte a
        // réellement changé — sinon un poll sur une flotte inchangée churnerait
        // l'UI toutes les 2-6 s pour rien.
        var changed = false

        for info in infos {
            if let pid = info.pid, internalPids.contains(pid) { continue }
            if let cwd = info.cwd, cwd.contains("/.claude/worktrees/") { continue }
            // Recalculé par itération : appendFleetSession a pu ajouter une session.
            let existing = sessions.map { FleetReconciler.Existing(id: $0.id, pid: $0.pid) }
            switch FleetReconciler.correlate(info, among: existing) {
            case .existing(let id):
                seen.insert(id)
                if let index = sessions.firstIndex(where: { $0.id == id }) {
                    if updateFromFleet(at: index, info) { changed = true }
                }
            case .new:
                // Rétrospective orpheline (Atoll redémarré en plein run) : reconnue
                // à son marqueur d'env, jamais affichée comme session utilisateur.
                if let pid = info.pid,
                   ProcessInspector.environment(of: pid)["ATOLL_RETROSPECTIVE"] == "1" { continue }
                appendFleetSession(info)
                seen.insert(info.sessionID)
                changed = true
            }
        }

        // Retrait : `claude agents --json` liste TOUTES les sessions actives
        // (vérifié : les sessions non lancées par l'agent view y figurent aussi).
        // Une session absente du snapshot est donc terminée — hook comprise (une
        // session bg stoppée sans SessionEnd propre traînerait sinon 5 min).
        // GARDE-FOUS : (1) tolérance de 2 absences consécutives — un snapshot
        // transitoirement vide/partiel ne tue pas une session vivante ; (2) une
        // carte de permission en attente prouve la session vivante (un helper y
        // est bloqué) → jamais clôturée.
        for index in sessions.indices where sessions[index].phase.isAlive {
            let id = sessions[index].id
            if seen.contains(id) {
                fleetMissed[id] = 0
                continue
            }
            // Carte de permission en attente = session vivante (un helper y est
            // bloqué) → jamais clôturée sur simple absence.
            //
            // On NE teste PAS le pid : celui d'une session bg est un processus géré
            // par le daemon qui SURVIT à l'arrêt de la session → il ne dit rien de
            // la vie de la session. Le JSON du daemon est l'autorité (il retire une
            // session stoppée) ; la tolérance de 2 tours couvre les creux transitoires.
            let missed = (fleetMissed[id] ?? 0) + 1
            fleetMissed[id] = missed
            if missed >= 2 {
                markEnded(at: index, reason: .reconcileGC)
                changed = true
            }
        }
        if changed { scheduleSnapshot() }
    }

    /// Met à jour une session existante depuis son entrée `agents --json`.
    /// Retourne `true` si un champ a réellement changé (sinon on n'écrit RIEN,
    /// pour ne pas déclencher d'observation/re-render inutile).
    @discardableResult
    private func updateFromFleet(at index: Int, _ info: AgentSessionInfo) -> Bool {
        var changed = false
        // Titre depuis le nom agent-view : SEULEMENT pour les sessions de flotte.
        // Une session à hooks garde son titre = 1er prompt de l'utilisateur (sinon
        // un poll tombant avant le 1er UserPromptSubmit l'écraserait — régression).
        if sessions[index].isSynthetic,
           sessions[index].title == nil, let name = info.name, !name.isEmpty {
            sessions[index].title = Self.condense(name); changed = true
        }
        if sessions[index].cwd == nil, let cwd = info.cwd { sessions[index].cwd = cwd; changed = true }
        // Pid renseigné pour l'enrichissement/jump-back, mais PAS d'exit-watch :
        // la liveness d'une session de flotte vient du JSON, pas du pid.
        if sessions[index].pid == nil, let pid = info.pid { sessions[index].pid = pid; changed = true }
        // Statut terminal du JSON : vaut pour TOUTES les sessions (hook comprises —
        // `claude stop`, échec — le SessionEnd du hook peut ne pas venir).
        if info.status.isTerminal {
            if sessions[index].phase.isAlive { markEnded(at: index, reason: .reconcileGC); return true }
            return changed
        }
        // Phase courante : SEULEMENT pour les sessions non pilotées par les hooks
        // (les hooks ont une machine à états plus fine — ne pas l'écraser), et
        // seulement si elle DIFFÈRE (sinon pas d'écriture → pas de re-render).
        if sessions[index].isSynthetic,
           let phase = Self.fleetPhase(for: info.status, current: sessions[index].phase),
           sessions[index].phase != phase {
            sessions[index].phase = phase; changed = true
        }
        return changed
    }

    /// Crée une session de flotte depuis son entrée JSON (vrai id, plus de
    /// `pid-<pid>` synthétique). Enrichissement d'ancrage terminal via
    /// ProcessInspector — son rôle rétrogradé (enrichir un pid connu, plus découvrir).
    private func appendFleetSession(_ info: AgentSessionInfo) {
        guard !info.status.isTerminal else { return } // --all liste les finies : ne pas ressusciter
        let now = Date()
        var session = Tracked(
            id: info.sessionID,
            pid: info.pid,
            pidStartTime: info.pid.flatMap { ProcessInspector.startTime(of: $0) },
            cwd: info.cwd,
            transcriptPath: info.cwd.flatMap { Self.newestTranscript(forCwd: $0)?.path },
            phase: Self.fleetPhase(for: info.status, current: .waitingInput) ?? .waitingInput,
            title: info.name.map { Self.condense($0) },
            terminalHint: nil,
            isSynthetic: true,
            firstSeenAt: info.startedAt ?? now,
            lastEventAt: now
        )
        if let pid = info.pid {
            let env = ProcessInspector.environment(of: pid)
            session.tty = ProcessInspector.tty(of: pid)
            session.bundleID = env["__CFBundleIdentifier"]
            session.termProgram = env["TERM_PROGRAM"]
            session.entrypoint = env["CLAUDE_CODE_ENTRYPOINT"]
            session.env = env.filter { Self.anchorEnvKeys.contains($0.key) }
            // Pas d'exit-watch : liveness = présence dans le JSON (le pid peut
            // être un processus-hôte transitoire du daemon).
        }
        sessions.append(session)
        if let path = session.transcriptPath { MemoryIndexer.shared.nudge(transcriptPath: path) }
    }

    /// Traduit un statut `agents --json` en phase, pour les sessions non-hook.
    /// nil = ne rien changer (statut inconnu, ou attente de permission posée par
    /// un hook qu'on ne doit jamais écraser). Le terminal est géré à part.
    private static func fleetPhase(for status: AgentSessionInfo.Status,
                                   current: SessionPhase) -> SessionPhase? {
        if case .waitingPermission = current { return nil }
        switch status {
        case .busy: return .busy
        case .idle, .needsInput: return .waitingInput
        case .completed, .failed, .stopped, .unknown: return nil
        }
    }

    // MARK: - Instantané de debug

    /// État courant écrit dans ~/Library/Application Support/Atoll/state.json —
    /// observable en CLI pour le debug, base de la persistance future.
    private func scheduleSnapshot() {
        snapshotTask?.cancel()
        snapshotTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.writeSnapshot()
        }
    }

    // MARK: - Cache du quota

    /// Écrit le dernier quota connu dans `~/.atoll/quota-cache.json`.
    /// Best-effort : un échec n'a aucune conséquence (on retombe simplement
    /// sur « quota inconnu » au prochain lancement).
    private static func cacheQuota(_ quota: QuotaSnapshot) {
        guard let data = try? JSONEncoder().encode(quota) else { return }
        try? FileManager.default.createDirectory(
            at: BridgePaths.quotaCacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: BridgePaths.quotaCacheURL, options: .atomic)
    }

    /// Relit le cache. `receivedAt` est CONSERVÉ tel quel : le gate a besoin de
    /// savoir que la donnée est vieille — il traite alors la valeur comme un
    /// minorant tant que la fenêtre 5 h n'a pas tourné, et retombe sinon sur sa
    /// règle « quota inconnu ». Un cache dont la fenêtre 5 h est expirée n'a
    /// plus aucune valeur : on ne le charge même pas.
    private static func loadCachedQuota() -> QuotaSnapshot? {
        guard let data = try? Data(contentsOf: BridgePaths.quotaCacheURL),
              let quota = try? JSONDecoder().decode(QuotaSnapshot.self, from: data)
        else { return nil }
        let now = Date()
        if let resetsAt = quota.fiveHour.resetsAt, resetsAt < now { return nil }
        // Horloge qui a reculé (NTP, RTC, réglage manuel) : une lecture datée
        // du FUTUR resterait éternellement « fraîche » et ferait croire au gate
        // qu'il connaît le quota (revue).
        if quota.receivedAt > now { return nil }
        return quota
    }

    private func writeSnapshot() {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atoll", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let list: [[String: Any]] = sessions.map { session in
            var entry: [String: Any] = [
                "id": session.id,
                "phase": String(describing: session.phase),
                "synthetic": session.isSynthetic,
            ]
            if let pid = session.pid { entry["pid"] = Int(pid) }
            if let cwd = session.cwd { entry["cwd"] = cwd }
            if let title = session.title { entry["title"] = title }
            if let hint = session.terminalHint { entry["terminal"] = hint }
            return entry
        }
        let payload: [String: Any] = [
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "eventCount": eventCount,
            "serverRunning": serverRunning,
            "autonomy": InteractionCenter.shared.autonomyLevel.rawValue,
            "sessions": list,
            "pendingInteractions": InteractionCenter.shared.pending.map { request -> [String: Any] in
                var entry: [String: Any] = ["id": request.id, "session": request.sessionID]
                switch request.kind {
                case .permission: entry["kind"] = "permission"
                case .plan: entry["kind"] = "plan"
                case .questions: entry["kind"] = "questions"
                }
                if let tool = request.toolSummary ?? request.toolName { entry["tool"] = tool }
                return entry
            },
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        }
    }

    /// Transcript le plus récent pour un cwd : ~/.claude/projects/<cwd encodé>/*.jsonl.
    /// Heuristique de secours uniquement (l'encodage est lossy) — les sessions
    /// gérées par hooks reçoivent le chemin exact dans le payload.
    static func newestTranscript(forCwd cwd: String) -> URL? {
        let encoded = String(cwd.map { character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        })
        let directory = BridgePaths.homeDirectory
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(encoded)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }
        return entries
            .filter { $0.pathExtension == "jsonl" }
            .max { lhs, rhs in
                let lm = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rm = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lm < rm
            }
    }
}
