import Foundation

/// Une session telle que la rapporte `claude agents --json [--all]` — l'interface
/// SUPPORTÉE et sans TTY d'énumération de la flotte (interactives + arrière-plan).
///
/// C'est désormais l'AUTORITÉ de découverte des sessions (le daemon d'arrière-plan
/// a rendu le scan de processus non fiable : les sessions bg sont des descendants
/// du daemon, exclues comme subagents). Décodage 100 % DÉFENSIF : le schéma n'est
/// pas versionné, donc tout champ manquant ou inattendu dégrade sans jamais crasher.
public struct AgentSessionInfo: Equatable, Sendable {
    /// État normalisé. Le CLI émet aujourd'hui `busy`/`idle`/null ; les autres
    /// valeurs sont anticipées (doc) et tolérées — l'inconnu ne force rien.
    public enum Status: String, Equatable, Sendable {
        case busy          // exécution active (aussi "working")
        case idle          // prête pour un prochain message
        case needsInput    // attend une décision/réponse (aussi "needs_input")
        case completed
        case failed
        case stopped
        case unknown       // valeur absente ou non reconnue → ne rien décider

        /// La session a-t-elle atteint un état terminal côté flotte ?
        public var isTerminal: Bool {
            self == .completed || self == .failed || self == .stopped
        }

        static func parse(_ raw: String?) -> Status {
            switch raw?.lowercased() {
            case "busy", "working", "running": return .busy
            case "idle", "waiting": return .idle
            case "needs_input", "needsinput", "input", "blocked": return .needsInput
            case "completed", "done", "success": return .completed
            case "failed", "error": return .failed
            case "stopped", "cancelled", "canceled": return .stopped
            default: return .unknown
            }
        }
    }

    /// Nature de la session. Non fiable pour distinguer « lancée par l'utilisateur »
    /// vs « arrière-plan » (la topologie daemon la brouille — vu : une session
    /// interactive rapportée `background`) → traité comme un simple indice.
    public enum Kind: String, Equatable, Sendable {
        case interactive
        case background
        case unknown

        static func parse(_ raw: String?) -> Kind {
            switch raw?.lowercased() {
            case "interactive": return .interactive
            case "background", "bg": return .background
            default: return .unknown
            }
        }
    }

    /// Identifiant de session rapporté par le CLI — l'id CANONIQUE à préférer
    /// (les sessions hookless n'ont plus d'id synthétique `pid-<pid>` inventé).
    public let sessionID: String
    /// Peut être absent (session stoppée listée par `--all`).
    public let pid: Int32?
    public let cwd: String?
    /// Nom d'affichage généré par le CLI (ex. « dynamic-island-38 ») → titre.
    public let name: String?
    public let status: Status
    public let kind: Kind
    /// Instant de démarrage (le CLI l'émet en millisecondes epoch).
    public let startedAt: Date?

    public init(sessionID: String, pid: Int32?, cwd: String?, name: String?,
                status: Status, kind: Kind, startedAt: Date?) {
        self.sessionID = sessionID
        self.pid = pid
        self.cwd = cwd
        self.name = name
        self.status = status
        self.kind = kind
        self.startedAt = startedAt
    }
}

/// Décodage défensif de la sortie de `claude agents --json`.
public enum AgentsSnapshot {
    /// Parse un tableau JSON de sessions. Toute entrée sans `sessionId` exploitable
    /// est ignorée ; les champs manquants deviennent nil/unknown. Jamais de throw :
    /// une sortie corrompue ou d'un format futur rend simplement `[]` ou moins
    /// d'entrées, jamais un crash (le schéma du CLI n'est pas un contrat versionné).
    /// Résultat d'un décodage, avec la distinction que `[]` seul ne pouvait pas
    /// porter : « le CLI a répondu, il n'y a aucune session » et « je ne
    /// comprends pas ce que le CLI a répondu » menaient au MÊME tableau vide.
    /// Or le second est une PANNE de sonde : conclure « toutes les sessions ont
    /// disparu » y clôturait la flotte entière en 4 à 12 s, et mettait au
    /// passage un bilan payant en file par session « terminée ».
    /// Le schéma a déjà bougé sous nous (CLI 2.1.223 : des entrées portent
    /// `state` sans `status`, d'autres l'inverse) : le jour où le tableau est
    /// enveloppé dans un objet, cette distinction est tout ce qui protège.
    public enum Outcome: Equatable {
        /// Format reconnu. Le tableau PEUT être vide : c'est une vraie réponse.
        case sessions([AgentSessionInfo])
        /// Sortie illisible ou d'un format inconnu : sonde NON CONCLUANTE.
        case unrecognized
    }

    /// Décodage qui distingue « aucune session » de « format non reconnu ».
    public static func decodeOutcome(_ data: Data) -> Outcome {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return .unrecognized }
        // Tolérance de forme : le tableau nu d'aujourd'hui, ou un objet qui
        // l'enveloppe demain sous une clé plausible. Tout le reste est inconnu.
        let array: [[String: Any]]
        if let direct = root as? [[String: Any]] {
            array = direct
        } else if let wrapper = root as? [String: Any],
                  let nested = (wrapper["sessions"] ?? wrapper["agents"] ?? wrapper["data"])
                    as? [[String: Any]] {
            array = nested
        } else if let empty = root as? [Any], empty.isEmpty {
            // `[]` : tableau vide bien formé, aucune session. Réponse valide.
            array = []
        } else {
            return .unrecognized
        }
        return .sessions(entries(array))
    }

    public static func decode(_ data: Data) -> [AgentSessionInfo] {
        guard case .sessions(let infos) = decodeOutcome(data) else { return [] }
        return infos
    }

    /// Première clé qui porte VRAIMENT une chaîne — le repli entre noms de champ.
    ///
    /// À écrire ainsi, et PAS `entry["a"] ?? entry["b"]` : sur un
    /// `[String: Any]` venu de JSONSerialization, un `"sessionId": null` devient
    /// `.some(NSNull())`. Le `??` est alors satisfait, la seconde clé n'est
    /// JAMAIS consultée, le `as? String` échoue et la session disparaît en
    /// silence du `compactMap` — c'est-à-dire de l'îlot. Le repli était
    /// neutralisé exactement dans le cas pour lequel il a été écrit.
    /// (Même correctif appliqué au même motif dans `PluginSnapshot`, le
    /// 2026-08-14 : une garde ne vaut que si elle couvre TOUS ses points.)
    private static func firstString(_ entry: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = entry[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func entries(_ array: [[String: Any]]) -> [AgentSessionInfo] {
        array.compactMap { entry in
            // sessionId ?? id : la seule clé requise (sans identité, inexploitable).
            guard let sessionID = firstString(entry, "sessionId", "id", "session_id")
            else { return nil }

            let pid: Int32? = (entry["pid"] as? NSNumber).map { $0.int32Value }
            let cwd = entry["cwd"] as? String
            let name = firstString(entry, "name", "displayName")
            // `status` d'abord, `state` en REPLI.
            //
            // Vérifié sur le CLI 2.1.220 : `agents --json` (ce qu'Atoll lance)
            // ne liste que les sessions vivantes — un état terminal n'y figure
            // pas, et le retrait se fait bien par absence. Mais `--all` prouve
            // que le daemon connaît un second champ, `state`, avec des valeurs
            // terminales (`done`, `stopped`), et que les entrées qui le portent
            // n'ont PAS de `status`. Si une version du CLI se met à les inclure
            // par défaut, les ignorer ressusciterait des sessions mortes.
            // Deux lignes de blindage, aucun changement de comportement
            // aujourd'hui (audit du 2026-07-27).
            var status = AgentSessionInfo.Status.parse(entry["status"] as? String)
            if status == .unknown {
                status = AgentSessionInfo.Status.parse(entry["state"] as? String)
            }
            let kind = AgentSessionInfo.Kind.parse(entry["kind"] as? String)
            // startedAt en millisecondes epoch (heuristique : > an 2001 en ms).
            let startedAt: Date? = (entry["startedAt"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue / 1000)
            }

            return AgentSessionInfo(
                sessionID: sessionID, pid: pid, cwd: cwd, name: name,
                status: status, kind: kind, startedAt: startedAt
            )
        }
    }
}

/// Corrélation PURE entre une entrée `agents --json` et les sessions déjà suivies.
///
/// Clé de jointure : **sessionId exact d'abord, sinon pid** — vérifié en vrai que
/// l'id peut diverger (fork/compaction) alors que le pid reste stable, et qu'une
/// session hookless suivie sous un ancien id synthétique partage son pid avec sa
/// vraie entrée JSON. Le pid évite ainsi de créer un doublon.
public enum FleetReconciler {
    /// Projection minimale d'une session suivie, pour la corrélation.
    public struct Existing: Equatable, Sendable {
        public let id: String
        public let pid: Int32?
        public init(id: String, pid: Int32?) {
            self.id = id
            self.pid = pid
        }
    }

    public enum Match: Equatable, Sendable {
        /// Corrèle à une session déjà suivie (on la met à jour, on n'en crée pas).
        case existing(id: String)
        /// Aucune correspondance : nouvelle session de flotte à créer.
        case new
    }

    /// Nombre maximal de passes consécutives qu'on accepte de DÉGRADER avant de
    /// laisser la passe de retrait faire son travail. Deux, pas plus : un
    /// disjoncteur qui ne se ré-arme jamais est un blocage, pas une sûreté —
    /// c'est exactement la faute du verrou anti-double-spawn qui bloquait sa
    /// propre file (audit du 2026-07-27). Si la panne dure, on finit par
    /// conclure, et le repli par scan a eu le temps de s'armer.
    public static let maxDegradedPasses = 2

    /// Une passe qui ne retrouve AUCUNE des sessions vivantes qu'on suit, alors
    /// qu'on en suivait plusieurs, décrit une panne de sonde bien plus
    /// probablement qu'une extinction simultanée.
    ///
    /// La tolérance existante (2 absences par session) ne protège pas de ça :
    /// elle compte PAR session, donc trois passes en panne clôturent tout le
    /// monde pareil. Ce test-ci porte sur la passe ENTIÈRE.
    ///
    /// Seuil à 2 sessions, pas davantage : au-dessous, « aucune vue » est un
    /// événement banal (une seule session qui se termine vraiment). Le principe :
    /// des sessions sans rapport entre elles ne s'éteignent pas toutes dans le
    /// même intervalle de sonde — ce qui a produit une telle passe est une
    /// panne, pas N décès simultanés.
    public static func isProbeOutage(trackedAlive: Int, seen: Int,
                                     degradedStreak: Int,
                                     maxDegraded: Int = maxDegradedPasses) -> Bool {
        trackedAlive >= 2 && seen == 0 && degradedStreak < maxDegraded
    }

    public static func correlate(_ info: AgentSessionInfo, among existing: [Existing]) -> Match {
        if let byID = existing.first(where: { $0.id == info.sessionID }) {
            return .existing(id: byID.id)
        }
        if let pid = info.pid, pid > 0,
           let byPID = existing.first(where: { $0.pid == pid }) {
            return .existing(id: byPID.id)
        }
        return .new
    }
}
