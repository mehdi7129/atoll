import Foundation

/// Décide quelles cartes d'autorisation Codex n'ont PLUS personne derrière
/// elles, et doivent donc être retirées de l'îlot.
///
/// POURQUOI C'EST ICI ET PAS DANS LA VUE. Ce jugement tient en quinze lignes,
/// mais chacune de ses trois branches a été un défaut réel, trouvé en revue par
/// Codex le 2026-09-09 — et aucune n'était testable tant qu'elle vivait dans une
/// classe `@MainActor` qui appelle `kill(2)`. La sonde est injectée : le test
/// décide qui est vivant, ce qui rend chaque invariant vérifiable **par
/// sabotage**, comme l'exige la méthode du projet.
///
/// LES TROIS TROUS QU'IL FERME :
/// 1. **Une carte sans pid connu n'était jamais retirée.** `LOCAL_PEERPID` peut
///    échouer ; on posait alors 0, et le filtre « pid > 0 » excluait exactement
///    ces cartes-là du nettoyage. Elles restaient jusqu'à la fin de l'app.
/// 2. **Un PID seul n'est pas une identité.** Réutilisé par le système avant le
///    passage du minuteur, il ferait valider un processus ÉTRANGER : la carte
///    survivrait à son helper, et un clic enverrait une décision dans le vide.
///    L'identité est le couple `(pid, instant de démarrage)`.
/// 3. **Aucun filet absolu.** Au-delà du plafond de Codex, plus rien n'attend —
///    quoi qu'en dise la sonde.
///
/// ⚠️ LE SENS DE L'ERREUR EST IMPOSÉ, comme pour `CodexSessionDiscovery` :
/// retirer une carte à tort rend la main à l'invite native de Codex (l'utilisateur
/// décide dans son terminal) ; la garder à tort affiche un bouton qui ne fait
/// rien. On retire donc au moindre doute — mais JAMAIS sur la seule absence
/// d'information : une sonde qui ne sait pas dire l'instant de démarrage laisse
/// la carte vivre jusqu'au filet absolu.
public enum CodexCardReaper {

    /// Ce que la sonde système rapporte d'un processus.
    public struct Probe: Equatable, Sendable {
        public let isAlive: Bool
        /// `nil` quand l'instant de démarrage n'a pas pu être lu — une absence
        /// d'information, jamais une preuve de réutilisation du PID.
        public let startTime: Double?
        public init(isAlive: Bool, startTime: Double?) {
            self.isAlive = isAlive
            self.startTime = startTime
        }
    }

    /// Une carte, réduite à ce qui sert au jugement.
    public struct Card: Equatable, Sendable {
        public let id: String
        public let helperPid: Int32
        public let helperStartTime: Double?
        public let receivedAt: Date
        public init(id: String, helperPid: Int32, helperStartTime: Double?, receivedAt: Date) {
            self.id = id
            self.helperPid = helperPid
            self.helperStartTime = helperStartTime
            self.receivedAt = receivedAt
        }
    }

    /// Durée au-delà de laquelle une carte ne peut PLUS correspondre à un helper
    /// vivant : Codex tue le hook à 600 s et le helper rend la main à 570 s, donc
    /// personne n'attend au-delà. La marge couvre le pas du minuteur (30 s).
    public static let absoluteLifetime: TimeInterval =
        CodexPermissionTiming.codexTimeoutSeconds + 30

    /// Les identifiants des cartes à retirer.
    public static func expired(_ cards: [Card],
                               now: Date,
                               probe: (Int32) -> Probe) -> [String] {
        cards.filter { card in
            let tooOld = now.timeIntervalSince(card.receivedAt) > absoluteLifetime
            // Pid inconnu : la sonde n'a rien à interroger, seul l'âge décide.
            guard card.helperPid > 0 else { return tooOld }
            let seen = probe(card.helperPid)
            if !seen.isAlive { return true }
            // Vivant, mais est-ce le MÊME processus ? Deux instants de démarrage
            // qui diffèrent désignent un PID recyclé. Une seconde de tolérance :
            // la valeur vient de `sysctl` et n'est pas plus fine que ça.
            if let expected = card.helperStartTime, let current = seen.startTime,
               abs(current - expected) > 1 { return true }
            return tooOld
        }.map(\.id)
    }
}
