import Foundation

public enum AgentProvider: String, Sendable {
    case claude, codex
    public var label: String { self == .claude ? "Claude" : "Codex" }
}

/// Separate wire contract: never send Codex events through Claude's permissions,
/// transcript parser, fleet reconciliation or proactive memory injection.
public struct CodexHookEvent: Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case sessionStart = "SessionStart", sessionEnd = "SessionEnd"
        case userPromptSubmit = "UserPromptSubmit", preToolUse = "PreToolUse"
        case postToolUse = "PostToolUse", permissionRequest = "PermissionRequest"
        case stop = "Stop", interrupt = "Interrupt"
        case preCompact = "PreCompact", postCompact = "PostCompact"
    }
    public let kind: Kind
    public let sessionID: String
    public let turnID: String?
    public let cwd: String?
    public let model: String?
    public let prompt: String?
    public let tool: String?
    /// Ancre terminal, si le helper l'a capturée.
    ///
    /// POURQUOI ELLE EXISTE ICI. Mehdi a tranché le 2026-09-09 : Codex tourne
    /// TOUJOURS dans un Cursor, comme Claude Code, et passer de l'un à l'autre
    /// doit être transparent. Or `TerminalJumpService.focusIDE` n'utilise que
    /// `cwd` et `bundleID` — rien de spécifique à Claude. Le seul obstacle au
    /// jump-back Codex n'était donc PAS le fournisseur, c'était que cette
    /// enveloppe ne portait pas l'environnement du hook. VÉRIFIÉ : un processus
    /// lancé dans le terminal de Cursor hérite bien de
    /// `__CFBundleIdentifier = com.todesktop.230313mzl4w4u92`, que
    /// `TerminalTarget.resolve` reconnaît comme `vscodeFamily(cli: "cursor")`.
    public let anchor: TerminalAnchor?

    public init?(envelope: [String: Any]) {
        guard envelope["provider"] as? String == "codex",
              let payload = envelope["payload"] as? [String: Any],
              let name = payload["hook_event_name"] as? String,
              let kind = Kind(rawValue: name),
              let id = payload["session_id"] as? String, !id.isEmpty,
              (payload["agent_id"] as? String).map({ $0.isEmpty }) ?? true
        else { return nil }
        self.kind = kind
        sessionID = "codex:" + id
        turnID = payload["turn_id"] as? String
        cwd = payload["cwd"] as? String
        model = payload["model"] as? String
        prompt = (payload["prompt"] as? String).map { String($0.prefix(200)) }
        tool = ParsedHookEvent.summarize(toolName: payload["tool_name"] as? String,
                                         input: payload["tool_input"] as? [String: Any])

        let enrich = envelope["enrich"] as? [String: Any] ?? [:]
        let environment = enrich["env"] as? [String: String] ?? [:]
        let hint = enrich["terminalHint"] as? String
        // Une ancre sans AUCUN moyen d'identifier le terminal ne sert à rien :
        // on ne la fabrique pas pour rien (le bouton resterait mort, ce que la
        // leçon du bouton ARRÊTER interdit — n'afficher que ce qui peut agir).
        if cwd != nil, hint != nil || !environment.isEmpty {
            anchor = TerminalAnchor(
                cwd: cwd,
                tty: enrich["tty"] as? String,
                bundleID: environment["__CFBundleIdentifier"] ?? hint,
                termProgram: environment["TERM_PROGRAM"],
                entrypoint: nil, // propre à Claude Code
                env: environment
            )
        } else {
            anchor = nil
        }
    }
}

/// Hook-only observation, not a claimed inventory of every Codex desktop/CLI thread.
public struct CodexSessions: Sendable {
    private struct Entry: Sendable {
        var session: AgentSession
        var turnID: String?
        var lastEvent: Date
        /// Dernière ancre connue. CONSERVÉE quand un événement n'en porte pas :
        /// tous les hooks n'ont pas le même environnement, et perdre l'ancre
        /// éteindrait le bouton au milieu d'une session vivante.
        var anchor: TerminalAnchor?
        /// Le tour courant est-il CLÔTURÉ (`Stop` ou `Interrupt` reçu) ?
        var turnIsClosed = false
        /// Tours déjà clôturés, du plus ancien au plus récent. BORNÉ : une
        /// session peut enchaîner des centaines de tours, la mémoire n'a pas à
        /// croître avec eux — seuls les retardataires proches importent.
        var closedTurns: [String] = []
    }

    /// Combien de tours clôturés on retient. Huit suffisent très largement : un
    /// hook async retardataire arrive dans la seconde, pas huit tours plus tard.
    private static let closedTurnMemory = 8
    private var entries: [String: Entry] = [:]
    public init() {}

    /// Ancre terminal d'une session Codex — le pendant de
    /// `SessionStore.terminalAnchor(for:)` côté Claude.
    public func anchor(for sessionID: String) -> TerminalAnchor? {
        entries[sessionID]?.anchor
    }

    public mutating func apply(_ event: CodexHookEvent, now: Date = Date()) {
        if event.kind == .sessionEnd { entries.removeValue(forKey: event.sessionID); return }
        var entry = entries[event.sessionID] ?? Entry(session: AgentSession(
            id: event.sessionID,
            projectName: event.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex",
            status: .awaitingInput, startedAt: now, cwd: event.cwd, provider: .codex
        ), lastEvent: now)
        // ⚠️ LA CLÔTURE D'UN TOUR EST MONOTONE : une fois `Stop` ou `Interrupt`
        // reçu, plus RIEN de ce tour ne peut le rouvrir.
        //
        // DÉFAUT TROUVÉ PAR CODEX le 2026-09-09, sur sa propre machine à états,
        // et introduit par le passage des hooks en `async`. `Stop` est resté
        // synchrone, ce qui garantit sa LIVRAISON — pas qu'il arrive après les
        // processus async déjà lancés. Un retardataire du MÊME tour passait
        // alors le garde (`turn_id` identique) et remettait la session en
        // `.working` : fausse activité jusqu'à la péremption de quinze minutes.
        //
        // Le cas le plus grave était un `UserPromptSubmit` retardataire, parce
        // que cette branche est EXEMPTÉE du garde : arrivé après le prompt d'un
        // tour plus récent, il replaçait `entry.turnID` sur l'ancien tour, et
        // tous les événements du vrai tour courant étaient ensuite rejetés.
        // La session se figeait pour de bon.
        if let turn = event.turnID, entry.closedTurns.contains(turn) { return }

        // Un événement d'un AUTRE tour ne finit pas le tour courant (garde
        // d'origine). `userPromptSubmit` en est exempté : c'est lui qui ouvre.
        if event.kind != .userPromptSubmit, let turn = event.turnID,
           let current = entry.turnID, turn != current { return }

        // Un tour clos ne se rouvre que par un PROMPT explicite. Sans cela, un
        // retardataire SANS `turn_id` — que les deux gardes ci-dessus laissent
        // passer — ferait repartir l'activité tout seul.
        if entry.turnIsClosed, event.kind != .userPromptSubmit { return }

        if event.kind == .userPromptSubmit || entry.turnID == nil { entry.turnID = event.turnID }
        if event.kind == .userPromptSubmit { entry.turnIsClosed = false }
        if let cwd = event.cwd {
            entry.session.cwd = cwd
            entry.session.projectName = URL(fileURLWithPath: cwd).lastPathComponent
        }
        if let model = event.model { entry.session.model = model }
        if let anchor = event.anchor { entry.anchor = anchor }
        entry.lastEvent = now
        entry.session.stateConfirmedByHook = true
        if event.kind == .stop || event.kind == .interrupt {
            entry.turnIsClosed = true
            if let turn = event.turnID, !entry.closedTurns.contains(turn) {
                entry.closedTurns.append(turn)
                entry.closedTurns = Array(entry.closedTurns.suffix(Self.closedTurnMemory))
            }
        }
        switch event.kind {
        case .sessionStart, .stop, .interrupt: entry.session.status = .awaitingInput
        case .userPromptSubmit:
            entry.session.status = .working(tool: nil)
            entry.session.subtitle = event.prompt
        case .preToolUse: entry.session.status = .working(tool: event.tool)
        case .postToolUse, .postCompact: entry.session.status = .working(tool: nil)
        case .preCompact: entry.session.status = .working(tool: "compactage")
        case .permissionRequest:
            entry.session.status = .awaitingPermission(tool: event.tool ?? "Codex")
        case .sessionEnd: break
        }
        entries[event.sessionID] = entry
    }

    public func sessions(now: Date = Date()) -> [AgentSession] {
        entries.values.compactMap { entry -> AgentSession? in
            let age = now.timeIntervalSince(entry.lastEvent)
            guard age < 86_400 else { return nil } // crashed/abandoned clients
            var session = entry.session
            // Codex has no PermissionDenied hook. Silence isn't proof of an
            // outstanding approval, nor proof that a long-running tool finished.
            if age > (session.needsAttention ? 120 : 900) {
                session.status = .awaitingInput
                session.stateConfirmedByHook = false
            }
            return session
        }.sorted {
            if $0.needsAttention != $1.needsAttention { return $0.needsAttention }
            return $0.startedAt > $1.startedAt
        }
    }

    public mutating func prune(now: Date = Date()) {
        entries = entries.filter { now.timeIntervalSince($0.value.lastEvent) < 86_400 }
    }
}

/// Hooks d'OBSERVATION : aucune sortie, aucune décision, aucune lecture de
/// transcript.
public enum CodexHookSettingsEditor {
    public static let command = "\"$HOME/.atoll/bin/atoll-codex-bridge\""
    public enum EditError: Error { case invalidSettings }

    /// Les seuls événements posés en SYNCHRONE. Tous les autres sont `async`.
    ///
    /// ⚠️ MESURÉ LE 2026-09-09, ET C'ÉTAIT UNE GÊNE RÉELLE POUR L'UTILISATEUR.
    /// Un hook synchrone est ANNONCÉ par Codex dans sa sortie : « hook: PreToolUse »
    /// puis « hook: PreToolUse Completed ». La première version posait les dix
    /// événements en synchrone — **dix lignes de bruit pour un tour d'un seul
    /// outil**, infligées en permanence dès l'installation d'Atoll. C'est la
    /// règle n° 1 du projet qui tranche : rien de ce qu'Atoll installe ne doit
    /// gêner le CLI. Or Atoll n'attend RIEN de ces hooks — il observe.
    ///
    /// Pourquoi `Stop` reste synchrone malgré le bruit qu'il coûte : en `async`
    /// il est fire-and-forget, et le process se termine avant que le hook n'ait
    /// écrit. MESURÉ : tout en async ⇒ **`Stop` perdu**, donc l'îlot ne saurait
    /// pas que le tour est fini et laisserait la session « en cours » jusqu'à sa
    /// péremption de 15 min. Deux lignes de bruit valent mieux qu'un état faux.
    /// `SessionEnd` est de toute façon FORCÉ synchrone par Codex lui-même
    /// (vérifié : `hooks/list` rend `async: false` quoi qu'on écrive).
    ///
    /// Relevé des trois configurations, même prompt, même machine :
    /// tout synchrone → 10 lignes / 6 événements ; tout async → 0 ligne /
    /// 5 événements ; ce compromis → **2 lignes / 6 événements**.
    static let synchronousEvents: Set<CodexHookEvent.Kind> = [.stop, .sessionEnd]

    public static func edit(_ data: Data?, install: Bool) throws -> Data {
        var root: [String: Any] = [:]
        if let data {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw EditError.invalidSettings }
            root = decoded
        }
        if let hooks = root["hooks"], !(hooks is [String: Any]) { throw EditError.invalidSettings }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for kind in CodexHookEvent.Kind.allCases {
            if let value = hooks[kind.rawValue], !(value is [[String: Any]]) {
                throw EditError.invalidSettings
            }
            var groups = hooks[kind.rawValue] as? [[String: Any]] ?? []
            groups = try groups.compactMap { group in
                guard let handlers = group["hooks"] as? [[String: Any]] else {
                    throw EditError.invalidSettings
                }
                let kept = handlers.filter { $0["command"] as? String != command }
                if kept.count == handlers.count { return group }
                guard !kept.isEmpty else { return nil }
                var copy = group
                copy["hooks"] = kept
                return copy
            }
            if install {
                var handler: [String: Any] = ["type": "command", "command": command, "timeout": 3]
                if !synchronousEvents.contains(kind) { handler["async"] = true }
                groups.append(["hooks": [handler]])
            }
            if groups.isEmpty { hooks.removeValue(forKey: kind.rawValue) }
            else { hooks[kind.rawValue] = groups }
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    public static func isInstalled(_ data: Data?) -> Bool {
        guard let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return CodexHookEvent.Kind.allCases.allSatisfy { kind in
            (hooks[kind.rawValue] as? [[String: Any]] ?? []).contains { group in
                (group["hooks"] as? [[String: Any]] ?? []).contains {
                    $0["command"] as? String == command
                }
            }
        }
    }
}
