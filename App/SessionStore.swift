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
    }

    private(set) var sessions: [Tracked] = []
    private(set) var eventCount = 0
    var serverRunning = false
    /// Quota factice jusqu'à la Phase 5 (statusline).
    var usage = MockData.usage

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
        reconcileTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.reconcile()
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    // MARK: - Projection UI

    var uiSessions: [AgentSession] {
        sessions
            .sorted { lhs, rhs in
                let lr = rank(lhs), rr = rank(rhs)
                if lr != rr { return lr < rr }
                return lhs.firstSeenAt < rhs.firstSeenAt
            }
            .map { tracked in
                AgentSession(
                    id: tracked.id,
                    projectName: tracked.cwd.map { ($0 as NSString).lastPathComponent } ?? "claude",
                    gitBranch: nil,
                    status: tracked.phase.uiStatus,
                    subtitle: tracked.title,
                    startedAt: tracked.firstSeenAt
                )
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
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        switch sessions[index].phase {
        case .busy, .toolRunning, .starting:
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
                if !sessions[index].isSynthetic,
                   Date().timeIntervalSince(sessions[index].lastEventAt) > 1800 {
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
            guard let cwd = ProcessInspector.currentWorkingDirectory(of: pid) else {
                log.debug("pid \(pid): cwd illisible, ignoré")
                continue
            }
            // Les worktrees de subagents ne sont pas des sessions utilisateur.
            if cwd.contains("/.claude/worktrees/") { continue }
            let transcript = Self.newestTranscript(forCwd: cwd)
            var session = Tracked(
                id: "pid-\(pid)-\(Int(ProcessInspector.startTime(of: pid) ?? 0))",
                pid: pid,
                pidStartTime: ProcessInspector.startTime(of: pid),
                cwd: cwd,
                transcriptPath: transcript?.path,
                phase: .waitingInput,
                title: nil,
                terminalHint: nil,
                isSynthetic: true,
                firstSeenAt: Date(),
                lastEventAt: Date()
            )
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
            "sessions": list,
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
