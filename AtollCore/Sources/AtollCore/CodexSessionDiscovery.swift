import Foundation

/// Retrouve les sessions Codex VIVANTES qu'Atoll n'a pas vues démarrer.
///
/// POURQUOI CE TYPE EXISTE. Atoll ne connaît une session Codex que par les
/// hooks reçus DEPUIS SON PROPRE LANCEMENT. Redémarre-le — mise à jour, plantage,
/// reboot — et les sessions Codex ouvertes deviennent invisibles jusqu'au
/// prochain prompt. Côté Claude, `claude agents --json` les retrouve tout de
/// suite ; côté Codex il n'existe pas d'équivalent branché (`thread/loaded/list`
/// ne répond que sur le daemon partagé, désactivé chez Mehdi).
///
/// ⚠️ C'EST DE L'HEURISTIQUE, comme le scan de processus qui sert de repli côté
/// Claude, et elle doit se tromper DANS LE BON SENS : mieux vaut manquer une
/// session que d'en annoncer une morte. D'où l'exigence d'un PROCESSUS VIVANT —
/// un rollout récent seul ne prouve rien, le fichier reste après la fermeture.
///
/// DEUX LIMITES ASSUMÉES, mesurées le 2026-09-09 :
/// - une session ouverte qui n'a encore rien fait n'écrit AUCUN rollout : elle
///   restera invisible, et c'est correct (on ne sait rien d'elle) ;
/// - deux sessions dans le même dossier sont ambiguës — on ne garde alors que
///   la plus récente, plutôt que d'en inventer deux ou de se tromper de moitié.
public enum CodexSessionDiscovery {

    /// Un processus `codex` vivant, tel que l'appelant l'a observé.
    public struct RunningProcess: Equatable, Sendable {
        public let pid: Int32
        public let cwd: String
        public let startTime: Double?
        public let sessionID: String?
        public init(pid: Int32, cwd: String, startTime: Double? = nil, sessionID: String? = nil) {
            self.pid = pid
            self.cwd = cwd
            self.startTime = startTime
            self.sessionID = sessionID
        }
    }

    /// Un rollout sur disque, réduit à ce qui sert ici.
    public struct Rollout: Equatable, Sendable {
        public let path: String
        public let sessionID: String
        public let cwd: String
        public let modifiedAt: Date
        public init(path: String, sessionID: String, cwd: String, modifiedAt: Date) {
            self.path = path
            self.sessionID = sessionID
            self.cwd = cwd
            self.modifiedAt = modifiedAt
        }
    }

    /// Une session retrouvée, prête à être projetée dans l'îlot.
    public struct Discovered: Equatable, Sendable {
        public let sessionID: String        // déjà préfixé « codex: »
        public let cwd: String
        public let transcriptPath: String
        public let startedAt: Date
        public let process: ProcessIdentity?
        public let anchor: TerminalAnchor?

        public init(sessionID: String, cwd: String, transcriptPath: String, startedAt: Date,
                    process: ProcessIdentity? = nil, anchor: TerminalAnchor? = nil) {
            self.sessionID = sessionID
            self.cwd = cwd
            self.transcriptPath = transcriptPath
            self.startedAt = startedAt
            self.process = process
            self.anchor = anchor
        }
    }

    /// Compatibilité du premier collecteur ; le collecteur courant utilise
    /// CodexSessionRegistry. Appariement par identité capturée, jamais par cwd.
    ///
    /// `known` = les sessions déjà connues par les hooks : elles font autorité
    /// et ne doivent jamais être dupliquées par cette heuristique.
    public static func discover(processes: [RunningProcess],
                                rollouts: [Rollout],
                                known: Set<String>,
                                now: Date = Date()) -> [Discovered] {
        var seen = Set<String>()
        return processes.compactMap { process -> Discovered? in
            // Le cwd n'est JAMAIS une identité. L'association provient d'un
            // hook capturé, puis la sonde doit confirmer la même incarnation.
            guard let sessionID = process.sessionID, let start = process.startTime,
                  let identity = ProcessIdentity(pid: process.pid, startedAt: start),
                  let rollout = rollouts.first(where: { $0.sessionID == sessionID && $0.cwd == process.cwd }),
                  rollout.modifiedAt <= now else { return nil }
            let id = "codex:" + rollout.sessionID
            // Les hooks font autorité : une session déjà connue n'est jamais
            // redécouverte, sinon l'îlot l'afficherait deux fois.
            guard !known.contains(id), seen.insert(id).inserted else { return nil }
            return Discovered(sessionID: id, cwd: rollout.cwd,
                              transcriptPath: rollout.path, startedAt: Date(timeIntervalSince1970: start),
                              process: identity)
        }
    }
}
