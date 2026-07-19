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
    /// Repli factice affiché tant que le vrai quota n'est pas encore arrivé.
    var usage = MockData.usage

    /// Clés d'environnement conservées pour l'ancrage terminal (jump-back).
    static let anchorEnvKeys: Set<String> = [
        "__CFBundleIdentifier", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
        "ITERM_SESSION_ID", "TMUX", "TMUX_PANE", "KITTY_WINDOW_ID", "KITTY_LISTEN_ON",
        "WEZTERM_PANE", "GHOSTTY_RESOURCES_DIR", "ALACRITTY_WINDOW_ID",
        "VSCODE_INJECTION", "CURSOR_TRACE_ID", "WARP_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT",
    ]

    @ObservationIgnored private var exitWatchers: [pid_t: DispatchSourceProcess] = [:]
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private let tailer = TranscriptTailer()

    // MARK: - Cycle de vie

    func start() {
        tailer.onInterrupt = { [weak self] sessionID in
            self?.transcriptInterrupted(sessionID)
        }
        tailer.onTitle = { [weak self] sessionID, title in
            self?.setTitle(sessionID, title: title)
        }
        tailer.onMeta = { [weak self] sessionID, model, gitBranch in
            self?.setMeta(sessionID, model: model, gitBranch: gitBranch)
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

    /// Quota affiché : vrai serveur si disponible, sinon repli factice.
    var displayQuota: UsageSnapshot {
        guard let realQuota else { return usage }
        return UsageSnapshot(
            fiveHourFraction: realQuota.fiveHour.usedFraction,
            sevenDayFraction: realQuota.sevenDay.usedFraction
        )
    }

    var quotaResets: (five: Date?, seven: Date?) {
        (realQuota?.fiveHour.resetsAt, realQuota?.sevenDay.resetsAt)
    }

    var hasRealQuota: Bool { realQuota != nil }

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
            // Résurrection : `claude --resume` reprend le MÊME session_id après un
            // SessionEnd(reason=resume) — .ended étant terminal dans le reducer,
            // un SessionStart relance explicitement le cycle de vie.
            if session.phase == .ended, event.kind == .sessionStart {
                session.phase = SessionReducer.reduce(.starting, event)
                session.missedScans = 0
            } else {
                session.phase = SessionReducer.reduce(session.phase, event)
            }
            update(&session, from: event, at: now)
            sessions[index] = session
        } else {
            // Un SessionEnd pour une session inconnue n'a rien à créer.
            guard event.kind != .sessionEnd else { return }
            // Une session hook remplace la session synthétique du même pid.
            if let pid = event.claudePid {
                for synthetic in sessions.filter({ $0.isSynthetic && $0.pid == pid }) {
                    tailer.stopWatching(synthetic.id)
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

        if let session = sessions.first(where: { $0.id == event.sessionID }),
           session.phase == .ended {
            scheduleRemoval(event.sessionID)
        }
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

        if let quota = payload.quota { realQuota = quota }

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
            sessions[index].phase = .ended
            tailer.stopWatching(sessions[index].id)
            InteractionCenter.shared.cancelForSession(sessions[index].id)
            scheduleRemoval(sessions[index].id)
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

    // MARK: - Réconciliation

    private func reconcile() {
        // 1. Filet de sécurité derrière kqueue : deux passes manquées = mort.
        //    Et GC des zombies : une session hook sans pid connu dont plus aucun
        //    événement n'arrive (bridge sans ancêtre claude, SessionEnd perdu)
        //    ne doit pas rester immortelle.
        for index in sessions.indices where sessions[index].phase.isAlive {
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
                    sessions[index].phase = .ended
                    tailer.stopWatching(sessions[index].id)
                    scheduleRemoval(sessions[index].id)
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

        // 2. Découverte des sessions hookless (claude lancé avant Atoll,
        //    ou hooks non installés).
        let knownPids = Set(sessions.compactMap(\.pid))
        let claudePids = ProcessInspector.allClaudePids()
        log.debug("réconciliation: \(claudePids.count) processus claude, \(knownPids.count) connus")
        for pid in claudePids where !knownPids.contains(pid) {
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
            "rockstar": InteractionCenter.shared.isRockstarEnabled,
            "autoAccept": InteractionCenter.shared.isAutoAcceptEnabled,
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
