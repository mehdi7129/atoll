import Foundation

/// Une tâche lancée EXPLICITEMENT depuis le notch (`claude --bg`), suivie jusqu'à
/// son terme.
///
/// Pourquoi ce type existe : le cockpit ambiant (Phase 9) savait démarrer une
/// tâche et l'arrêter, mais RIEN ne prévenait à la fin — on lance, on part, et il
/// faut revenir regarder. Or c'est justement la seule catégorie de sessions dont
/// Atoll a une connaissance de PREMIÈRE MAIN : il les a lancées lui-même.
///
/// On ne se fie PAS au champ `kind` de `claude agents --json` pour reconnaître une
/// tâche de fond : le code de `AgentSessionInfo.Kind` documente qu'il n'est pas
/// fiable (une session interactive a déjà été rapportée `background`). L'identité
/// vient du lancement, pas d'une devinette.
public struct LaunchedTask: Equatable, Sendable, Codable, Identifiable {
    /// Identité LOCALE, stable dès le lancement — l'identifiant de session, lui,
    /// peut être inconnu (sortie de `--bg` illisible) ou n'arriver qu'après.
    public let id: UUID
    /// Le texte de la tâche demandée — sert de titre, et de repli quand le modèle
    /// n'a pas laissé de dernier message exploitable.
    public let task: String
    public let cwd: String
    public let launchedAt: Date
    /// Id rapporté par `claude --bg`. Peut être TRONQUÉ (8 hex) : le format de
    /// cette sortie n'est pas garanti (cf. `FleetLaunch.parseSessionID`), d'où la
    /// comparaison par préfixe dans `matchesSessionID`.
    public var sessionID: String?
    public var completedAt: Date?
    /// Résumé d'une ligne tiré du dernier message de l'assistant (hook `Stop`).
    public var summary: String?
    /// Une tâche n'est notifiée QU'UNE FOIS, même si plusieurs signaux de fin
    /// arrivent (hook `Stop`, puis disparition de la flotte).
    public var notified: Bool
    /// L'utilisateur a-t-il vu le résultat (bannière du notch écartée) ?
    public var acknowledged: Bool
    /// A-t-on vu cette tâche VIVRE dans la flotte au moins une fois ?
    ///
    /// C'est ce qui distingue « elle a tourné puis s'est terminée » (→ annoncer)
    /// de « elle n'est jamais apparue » (→ un lancement raté : abandonner en
    /// silence, surtout ne pas claironner qu'une tâche jamais partie est finie).
    public var seenAlive: Bool

    public init(id: UUID = UUID(), task: String, cwd: String, launchedAt: Date,
                sessionID: String? = nil, completedAt: Date? = nil,
                summary: String? = nil, notified: Bool = false,
                acknowledged: Bool = false, seenAlive: Bool = false) {
        self.id = id
        self.task = task
        self.cwd = cwd
        self.launchedAt = launchedAt
        self.sessionID = sessionID
        self.completedAt = completedAt
        self.summary = summary
        self.notified = notified
        self.acknowledged = acknowledged
        self.seenAlive = seenAlive
    }

    /// Décodage EXPLICITE et tolérant aux champs absents.
    ///
    /// Le décodage synthétisé exige toutes les clés non-optionnelles, valeur par
    /// défaut ou pas : ajouter un champ ferait échouer la lecture de TOUS les
    /// journaux écrits par une version antérieure — et le journal repartirait à
    /// zéro, donc les tâches en cours ne seraient jamais annoncées. Ce piège a
    /// déjà coûté l'historique d'apprentissage en Phase 12 : on ne le refait pas.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        task = try container.decodeIfPresent(String.self, forKey: .task) ?? ""
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        launchedAt = try container.decodeIfPresent(Date.self, forKey: .launchedAt) ?? Date()
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        notified = try container.decodeIfPresent(Bool.self, forKey: .notified) ?? false
        acknowledged = try container.decodeIfPresent(Bool.self, forKey: .acknowledged) ?? false
        seenAlive = try container.decodeIfPresent(Bool.self, forKey: .seenAlive) ?? false
    }

    public var isComplete: Bool { completedAt != nil }

    /// Nom court du dossier — ce que l'utilisateur reconnaît (« Dynamic_Island »).
    public var projectName: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    /// Cet identifiant de session désigne-t-il cette tâche ?
    ///
    /// `claude --bg` peut n'imprimer qu'un PRÉFIXE de l'identifiant (8 hex) là où
    /// les hooks portent l'UUID complet : comparer par égalité seule raterait
    /// toutes les tâches dans ce cas — donc jamais de notification. On accepte
    /// donc qu'un des deux soit le préfixe de l'autre, avec un plancher de 8
    /// caractères (en dessous, une collision devient plausible).
    public func matchesSessionID(_ other: String) -> Bool {
        guard let mine = sessionID else { return false }
        return LaunchedTask.sessionIDsMatch(mine, other)
    }

    public static func sessionIDsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.lowercased(), b = rhs.lowercased()
        if a == b { return !a.isEmpty }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        guard short.count >= 8 else { return false }
        return long.hasPrefix(short)
    }
}

/// Journal des tâches lancées depuis le notch — valeur PURE (donc testable et
/// persistable telle quelle en JSON).
///
/// Toutes les décisions de « faut-il prévenir ? » vivent ici, pas dans la couche
/// AppKit : c'est la partie qui doit être juste, et c'est la seule qu'on peut
/// vraiment tester.
public struct LaunchedTaskLog: Equatable, Sendable, Codable {
    /// Plafond dur : ce journal sert à prévenir, pas à archiver. Les plus
    /// anciennes tâches TERMINÉES sautent en premier.
    public static let maxEntries = 50
    /// Au-delà, une tâche terminée n'a plus d'intérêt dans la bannière du notch.
    public static let defaultRetention: TimeInterval = 24 * 3600
    /// Fenêtre de rattrapage quand `claude --bg` n'a pas imprimé d'identifiant
    /// lisible : une session de flotte qui apparaît dans le MÊME dossier peu
    /// après le lancement est très probablement la nôtre.
    public static let defaultAdoptionWindow: TimeInterval = 180

    public private(set) var tasks: [LaunchedTask]

    public init(tasks: [LaunchedTask] = []) {
        self.tasks = tasks
    }

    // MARK: - Cycle de vie

    @discardableResult
    public mutating func register(_ task: LaunchedTask) -> LaunchedTask {
        tasks.append(task)
        enforceCap()
        return task
    }

    /// Tâches encore en cours (lancées, pas terminées).
    public var pending: [LaunchedTask] { tasks.filter { !$0.isComplete } }

    /// Tâches terminées que l'utilisateur n'a pas encore écartées — ce que la
    /// bannière du notch affiche, plus récente d'abord.
    public var unacknowledged: [LaunchedTask] {
        tasks.filter { $0.isComplete && !$0.acknowledged }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    /// Idem, mais en ignorant ce qui a passé la rétention.
    ///
    /// La purge n'a lieu qu'au démarrage : sans ce filtre, une tâche terminée
    /// jamais acquittée garderait sa bannière — et masquerait celle des skills
    /// proposés — aussi longtemps qu'Atoll tourne, la rétention de 24 h ne
    /// s'appliquant qu'au prochain lancement.
    public func unacknowledged(now: Date,
                               retention: TimeInterval = LaunchedTaskLog.defaultRetention) -> [LaunchedTask] {
        unacknowledged.filter { task in
            guard let completedAt = task.completedAt else { return false }
            return now.timeIntervalSince(completedAt) <= retention
        }
    }

    /// Index de la tâche EN COURS que désigne cet identifiant de session.
    public func pendingIndex(forSessionID sessionID: String) -> Int? {
        tasks.firstIndex { !$0.isComplete && $0.matchesSessionID(sessionID) }
    }

    /// Rattrapage : lie une session de flotte à une tâche lancée dont on n'a pas
    /// pu lire l'identifiant. Critères VOLONTAIREMENT stricts — se tromper ferait
    /// annoncer « ta tâche est finie » pour la session d'un autre travail.
    ///
    /// - le même dossier de travail (chemins normalisés) ;
    /// - un démarrage compris entre le lancement et `window` plus tard (une
    ///   session démarrée AVANT le lancement ne peut pas être la nôtre) ;
    /// - la tâche la PLUS ANCIENNE encore sans identifiant (FIFO) si plusieurs
    ///   sont candidates.
    ///
    /// Renvoie l'index adopté, ou nil si rien de sûr.
    @discardableResult
    public mutating func adopt(sessionID: String, cwd: String?, startedAt: Date?,
                               window: TimeInterval = LaunchedTaskLog.defaultAdoptionWindow) -> Int? {
        guard !sessionID.isEmpty, let cwd, let startedAt else { return nil }
        // Déjà connu (par id) → rien à adopter, mais c'est la preuve qu'elle est
        // VIVANTE : on le note (c'est ce qui autorisera l'annonce de sa fin).
        if let known = tasks.firstIndex(where: { $0.matchesSessionID(sessionID) }) {
            tasks[known].seenAlive = true
            return nil
        }
        let target = Self.normalizePath(cwd)
        let candidates = tasks.indices.filter { index in
            let candidate = tasks[index]
            guard candidate.sessionID == nil, !candidate.isComplete else { return false }
            guard Self.normalizePath(candidate.cwd) == target else { return false }
            let delta = startedAt.timeIntervalSince(candidate.launchedAt)
            // Petite tolérance négative : les horloges (ms epoch du CLI vs Date)
            // ne sont pas parfaitement alignées.
            return delta >= -5 && delta <= window
        }
        guard let index = candidates.min(by: { tasks[$0].launchedAt < tasks[$1].launchedAt })
        else { return nil }
        tasks[index].sessionID = sessionID
        tasks[index].seenAlive = true
        return index
    }

    /// Réconciliation avec un instantané de la flotte.
    ///
    /// Sans elle, une tâche qui se termine pendant qu'Atoll ne tourne PAS
    /// n'était jamais annoncée : au redémarrage, sa session n'existe plus, donc
    /// ni le hook `Stop` ni `markEnded` ne la concernent — et le journal
    /// persisté, censé exister exactement pour ce cas, ne servait à rien.
    ///
    /// Deux sorts distincts, et c'est tout l'intérêt de `seenAlive` :
    /// - vue vivante puis absente → **terminée**, on l'annonce (index rendus) ;
    /// - jamais vue et passé le délai de grâce → **lancement raté**, on la clôt
    ///   en SILENCE (rien ne serait plus faux que d'annoncer la fin d'une tâche
    ///   qui n'a jamais démarré).
    ///
    /// `grace` laisse à la flotte le temps de faire apparaître une session
    /// fraîchement lancée (le poll est à 2-6 s, mais le daemon peut traîner).
    /// Renvoie les index à annoncer.
    public mutating func reconcile(activeSessionIDs: Set<String>, now: Date,
                                   grace: TimeInterval = LaunchedTaskLog.defaultAdoptionWindow) -> [Int] {
        var toAnnounce: [Int] = []
        for index in tasks.indices where !tasks[index].isComplete {
            let task = tasks[index]
            let isActive = activeSessionIDs.contains { LaunchedTask.sessionIDsMatch($0, task.sessionID ?? "") }
            if isActive {
                tasks[index].seenAlive = true
                continue
            }
            guard now.timeIntervalSince(task.launchedAt) > grace else { continue }
            if task.seenAlive {
                toAnnounce.append(index)
            } else {
                // Jamais apparue : on la retire sans bruit pour qu'elle ne
                // s'accumule pas en zombie (le plafond sacrifierait alors des
                // résultats que l'utilisateur n'a pas encore vus).
                tasks[index].completedAt = now
                tasks[index].notified = true
                tasks[index].acknowledged = true
            }
        }
        return toAnnounce
    }

    /// Marque une tâche terminée. Renvoie la tâche À NOTIFIER, ou nil si elle
    /// l'était déjà (idempotent : plusieurs signaux de fin peuvent arriver).
    @discardableResult
    public mutating func complete(sessionID: String, at date: Date, summary: String?) -> LaunchedTask? {
        guard let index = pendingIndex(forSessionID: sessionID) else { return nil }
        return complete(at: index, date: date, summary: summary)
    }

    @discardableResult
    public mutating func complete(at index: Int, date: Date, summary: String?) -> LaunchedTask? {
        guard tasks.indices.contains(index), !tasks[index].notified else { return nil }
        tasks[index].completedAt = date
        tasks[index].summary = summary
        tasks[index].notified = true
        return tasks[index]
    }

    public mutating func acknowledge(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].acknowledged = true
    }

    public mutating func acknowledgeAll() {
        for index in tasks.indices where tasks[index].isComplete {
            tasks[index].acknowledged = true
        }
    }

    /// Purge : les tâches terminées passées la rétention, puis le plafond.
    ///
    /// Les tâches EN COURS ne sont jamais purgées par l'âge — une session `--bg`
    /// peut légitimement tourner longtemps, et l'oublier reviendrait à ne jamais
    /// prévenir. Elles ne sautent qu'au plafond, et en dernier.
    public mutating func prune(now: Date, retention: TimeInterval = LaunchedTaskLog.defaultRetention) {
        tasks.removeAll { task in
            guard let completedAt = task.completedAt else { return false }
            return now.timeIntervalSince(completedAt) > retention
        }
        enforceCap()
    }

    private mutating func enforceCap() {
        guard tasks.count > Self.maxEntries else { return }
        // On sacrifie d'abord les terminées les plus anciennes ; les tâches en
        // cours ne partent que s'il ne reste qu'elles.
        let excess = tasks.count - Self.maxEntries
        var removable = tasks.indices.filter { tasks[$0].isComplete }
            .sorted { (tasks[$0].completedAt ?? .distantPast) < (tasks[$1].completedAt ?? .distantPast) }
        if removable.count < excess {
            let pendingOldest = tasks.indices.filter { !tasks[$0].isComplete }
                .sorted { tasks[$0].launchedAt < tasks[$1].launchedAt }
            removable.append(contentsOf: pendingOldest)
        }
        let doomed = Set(removable.prefix(excess))
        tasks = tasks.enumerated().filter { !doomed.contains($0.offset) }.map(\.element)
    }

    private static func normalizePath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.count > 1 && standardized.hasSuffix("/")
            ? String(standardized.dropLast())
            : standardized
    }
}
