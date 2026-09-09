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
    /// Chemin du rollout de la session (`~/.codex/sessions/**/*.jsonl`).
    /// PRÉSENT SUR TOUS LES ÉVÉNEMENTS, `SessionEnd` compris (vérifié sur
    /// `codex-cli 0.153.4`) — c'est lui qui permet au bilan de fin de session
    /// de trouver quoi analyser, sans jamais avoir à deviner un fichier.
    public let transcriptPath: String?
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

        transcriptPath = payload["transcript_path"] as? String
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
        /// Rollout de la session, pour le bilan de fin de session.
        var transcriptPath: String?
        /// Prompts utilisateur COMPTÉS, jamais devinés : `LearningGate` refuse
        /// une session qui n'en a pas assez, et une valeur inventée fausserait
        /// sa décision dans le sens le plus coûteux (lancer pour rien).
        var userPromptCount = 0
    }

    /// Faits d'une session Codex terminée, pour le bilan de fin de session.
    /// Le miroir de ce que `SessionStore.Tracked` fournit côté Claude.
    public struct EndedSession: Equatable, Sendable {
        public let sessionID: String
        public let transcriptPath: String?
        public let cwd: String?
        public let model: String?
        public let userPromptCount: Int
        public let startedAt: Date
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

    /// Rollout d'une session Codex vivante — pendant de
    /// `SessionStore.transcriptPath(for:)`.
    public func transcriptPath(for sessionID: String) -> String? {
        entries[sessionID]?.transcriptPath
    }

    /// Ce que la projection a fait d'un événement.
    ///
    /// ⚠️ `accepted` EXISTE PARCE QUE `nil` NE SUFFISAIT PAS. `apply` rendait
    /// `nil` aussi bien pour « événement REJETÉ — il appartient à un tour clos
    /// ou périmé » que pour « accepté, aucune session terminée » : l'appelant ne
    /// pouvait donc pas distinguer les deux, et il enregistrait la carte
    /// d'autorisation dans les DEUX cas. Le filtrage des tours protégeait l'état
    /// de session et pas l'interaction — une permission retardataire d'un tour
    /// déjà clos créait quand même une carte. Constat de Codex, revue du
    /// 2026-09-09.
    public struct Applied: Sendable, Equatable {
        /// Ce que la projection sait du TOUR de l'événement.
        ///
        /// ⚠️ « REJETÉ » NE VEUT PAS DIRE « PÉRIMÉ ». Un booléen ne suffisait
        /// pas ici, et le croire a produit une régression mesurée par Codex le
        /// 2026-09-09, dans le correctif du matin même : `UserPromptSubmit`
        /// est ASYNC, donc une `PermissionRequest(t2)` peut arriver AVANT le
        /// prompt qui ouvre `t2`. Le garde « ce n'est pas le tour courant » la
        /// rejetait — à raison pour l'état de session — et l'appelant, qui ne
        /// lisait qu'un `accepted == false`, rendait aussitôt la main : une
        /// demande VIVANTE perdait sa carte, définitivement, puisque rien ne la
        /// recrée quand le prompt arrive enfin.
        ///
        /// Le doute et la certitude n'appellent donc pas le même geste : on ne
        /// détruit une carte que sur un tour CERTAINEMENT clos.
        public enum Turn: Sendable, Equatable {
            /// Événement retenu.
            case current
            /// Tour dont on sait qu'il est CLOS — la demande ne vaut plus rien.
            case closed
            /// Tour ni courant ni connu comme clos : l'état de session ne bouge
            /// pas, mais l'interaction est laissée intacte. Une carte de trop se
            /// ferme au clic ou expire ; une carte détruite est perdue.
            case unknown
        }

        /// Ce que cet événement vient de CLORE, s'il clôt quelque chose.
        ///
        /// `unnamed` existe parce qu'un `Stop` ou un `Interrupt` peut arriver
        /// SANS `turn_id` : le rendre `nil` confondait « rien de clos » et
        /// « clos, mais sans nom », et le repli de l'appelant devenait
        /// inatteignable. Constat de Codex sur ce même correctif.
        public enum Closure: Sendable, Equatable {
            case none
            case named(String)
            case unnamed
        }

        public let turn: Turn
        /// Faits de la session quand elle vient de SE TERMINER — `nil` sinon.
        public let ended: EndedSession?
        public let closure: Closure

        /// L'événement a été retenu par la projection.
        public var accepted: Bool { turn == .current }
        /// La demande d'autorisation qu'il porte, s'il en porte une, est morte.
        public var cardIsStale: Bool { turn == .closed }

        public init(turn: Turn, ended: EndedSession? = nil, closure: Closure = .none) {
            self.turn = turn
            self.ended = ended
            self.closure = closure
        }
    }

    /// `apply` rend les faits de la session quand elle vient de SE TERMINER —
    /// `nil` sinon. C'est ce que l'appelant transmet au bilan de fin de session.
    ///
    /// Vue étroite d'`applyEvent`, conservée parce qu'elle se lit bien là où le
    /// verdict n'importe pas. Une SEULE logique, deux lectures : deux
    /// implémentations divergeraient au premier correctif.
    @discardableResult
    public mutating func apply(_ event: CodexHookEvent, now: Date = Date()) -> EndedSession? {
        applyEvent(event, now: now).ended
    }

    @discardableResult
    public mutating func applyEvent(_ event: CodexHookEvent, now: Date = Date()) -> Applied {
        if event.kind == .sessionEnd {
            let ended = entries.removeValue(forKey: event.sessionID).map {
                EndedSession(sessionID: event.sessionID,
                             // Le chemin de l'événement de fin fait autorité ; on
                             // se rabat sur le dernier connu s'il manque.
                             transcriptPath: event.transcriptPath ?? $0.transcriptPath,
                             cwd: event.cwd ?? $0.session.cwd,
                             model: $0.session.model,
                             userPromptCount: $0.userPromptCount,
                             startedAt: $0.session.startedAt)
            }
            return Applied(turn: .current, ended: ended)
        }
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
        // Tour explicitement mémorisé comme clos : certitude.
        if let turn = event.turnID, entry.closedTurns.contains(turn) { return Applied(turn: .closed) }

        // Un événement d'un AUTRE tour ne finit pas le tour courant (garde
        // d'origine). `userPromptSubmit` en est exempté : c'est lui qui ouvre.
        // Tour DIFFÉRENT du courant, et pas dans la mémoire des tours clos : on
        // ne sait pas s'il est ancien ou s'il vient de s'ouvrir (le prompt qui
        // l'ouvre est async, il peut arriver après). L'état ne bouge pas, la
        // carte est laissée en vie.
        if event.kind != .userPromptSubmit, let turn = event.turnID,
           let current = entry.turnID, turn != current { return Applied(turn: .unknown) }

        // Un tour clos ne se rouvre que par un PROMPT explicite. Sans cela, un
        // retardataire SANS `turn_id` — que les deux gardes ci-dessus laissent
        // passer — ferait repartir l'activité tout seul.
        // Tour courant clos. Un événement qui le NOMME est périmé pour de bon ;
        // un événement sans `turn_id` peut appartenir au tour suivant, dont le
        // prompt n'est pas encore arrivé — doute, donc on ne détruit rien.
        if entry.turnIsClosed, event.kind != .userPromptSubmit {
            let named = event.turnID != nil && event.turnID == entry.turnID
            return Applied(turn: named ? .closed : .unknown)
        }

        if event.kind == .userPromptSubmit || entry.turnID == nil { entry.turnID = event.turnID }
        if event.kind == .userPromptSubmit { entry.turnIsClosed = false }
        if let cwd = event.cwd {
            entry.session.cwd = cwd
            entry.session.projectName = URL(fileURLWithPath: cwd).lastPathComponent
        }
        if let model = event.model { entry.session.model = model }
        if let path = event.transcriptPath { entry.transcriptPath = path }
        if let anchor = event.anchor { entry.anchor = anchor }
        if event.kind == .userPromptSubmit { entry.userPromptCount += 1 }
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
        // `Stop` et `Interrupt` closent le tour : l'appelant retire les cartes
        // qui lui appartenaient. Le tour COURANT sert de repli quand
        // l'événement de clôture ne porte pas de `turn_id` — la projection le
        // connaît, elle, et le taire rendait le nettoyage inatteignable.
        let closure: Applied.Closure
        if event.kind == .stop || event.kind == .interrupt {
            closure = (event.turnID ?? entry.turnID).map { .named($0) } ?? .unnamed
        } else {
            closure = .none
        }
        return Applied(turn: .current, closure: closure)
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

    /// Adopte les sessions retrouvées par le scan de processus.
    ///
    /// ⚠️ LES HOOKS FONT AUTORITÉ, TOUJOURS. Une session déjà connue n'est
    /// jamais écrasée : le scan ne sait ni quel outil tourne, ni si une
    /// autorisation attend, et remplacer un état confirmé par une supposition
    /// serait exactement l'erreur qu'`AgentSession.stateConfirmedByHook` existe
    /// pour empêcher (v0.16.1).
    ///
    /// Les sessions adoptées naissent `stateConfirmedByHook = false` : l'îlot
    /// les range dans « EN COURS », qui ne réclame aucune action — jamais dans
    /// « en attente de toi », qui convoquerait l'utilisateur au nom d'une
    /// session dont on ne sait rien.
    public mutating func adopt(_ discovered: [CodexSessionDiscovery.Discovered],
                               now: Date = Date()) {
        for session in discovered where entries[session.sessionID] == nil {
            var agent = AgentSession(
                id: session.sessionID,
                projectName: URL(fileURLWithPath: session.cwd).lastPathComponent,
                status: .awaitingInput, startedAt: session.startedAt,
                cwd: session.cwd, provider: .codex)
            agent.stateConfirmedByHook = false
            entries[session.sessionID] = Entry(
                session: agent, turnID: nil, lastEvent: now,
                transcriptPath: session.transcriptPath)
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
    /// ⚠️ `permissionRequest` EST REVENU DANS CETTE LISTE le 2026-09-09, et le
    /// retirer casserait la carte de l'îlot : **un hook `async` ne peut pas
    /// décider**. Codex ne l'attend pas, affiche donc son invite native, et on
    /// se retrouverait avec DEUX interfaces concurrentes pour une seule
    /// décision — pire que de ne rien faire.
    static let synchronousEvents: Set<CodexHookEvent.Kind> = [.stop, .sessionEnd, .permissionRequest]

    /// Délai laissé à une décision humaine. Défaut documenté des hooks Codex ;
    /// le helper, lui, s'arrête AVANT (voir `CodexPermissionTiming`) pour que
    /// Codex ne tue jamais le hook lui-même.
    static let permissionTimeoutSeconds = Int(CodexPermissionTiming.codexTimeoutSeconds)

    /// Message montré par la TUI pendant que le hook bloque. Ici le texte n'est
    /// PAS du bruit — contrairement aux annonces « hook: … » qu'on a fait
    /// taire : il explique pourquoi Codex attend et où agir.
    static let permissionStatusMessage = "Waiting for approval in Atoll"

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
                if kind == .permissionRequest {
                    handler["timeout"] = permissionTimeoutSeconds
                    handler["statusMessage"] = permissionStatusMessage
                }
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
