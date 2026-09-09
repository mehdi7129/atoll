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
        public init(pid: Int32, cwd: String) {
            self.pid = pid
            self.cwd = cwd
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
    }

    /// Âge maximal d'un rollout pour qu'on le rattache à un processus vivant.
    ///
    /// Le processus prouve la vie ; cette borne évite seulement d'exhumer un
    /// rollout d'il y a trois jours parce qu'une session tourne aujourd'hui
    /// dans le même dossier. Large à dessein : une session peut rester ouverte
    /// et silencieuse pendant des heures.
    public static let maxRolloutAge: TimeInterval = 24 * 3_600

    /// Apparie processus et rollouts PAR DOSSIER DE TRAVAIL.
    ///
    /// `known` = les sessions déjà connues par les hooks : elles font autorité
    /// et ne doivent jamais être dupliquées par cette heuristique.
    public static func discover(processes: [RunningProcess],
                                rollouts: [Rollout],
                                known: Set<String>,
                                now: Date = Date()) -> [Discovered] {
        // Un dossier peut porter plusieurs rollouts ; on ne garde que le plus
        // récent. Deux sessions simultanées dans le même dossier sont
        // indiscernables ici — en inventer deux serait pire que d'en montrer une.
        var newestByCwd: [String: Rollout] = [:]
        for rollout in rollouts {
            guard now.timeIntervalSince(rollout.modifiedAt) <= maxRolloutAge,
                  rollout.modifiedAt <= now else { continue }
            if let existing = newestByCwd[rollout.cwd], existing.modifiedAt >= rollout.modifiedAt {
                continue
            }
            newestByCwd[rollout.cwd] = rollout
        }

        var seen = Set<String>()
        return processes.compactMap { process -> Discovered? in
            guard let rollout = newestByCwd[process.cwd] else { return nil }
            let id = "codex:" + rollout.sessionID
            // Les hooks font autorité : une session déjà connue n'est jamais
            // redécouverte, sinon l'îlot l'afficherait deux fois.
            guard !known.contains(id), seen.insert(id).inserted else { return nil }
            return Discovered(sessionID: id, cwd: rollout.cwd,
                              transcriptPath: rollout.path, startedAt: rollout.modifiedAt)
        }
    }
}
