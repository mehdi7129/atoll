import Foundation

/// Regroupement des sessions par ÉTAT — le second mode d'affichage de l'îlot.
///
/// Le groupement par projet (v0.9.1) répond à « où ça se passe ». À partir de
/// quatre ou cinq sessions, la vraie question devient « laquelle attend quelque
/// chose de MOI ». D'où un ordre IMPOSÉ, du plus urgent au plus dormant : ce
/// classement est la valeur de cette vue, pas un détail cosmétique.
public enum SessionStateBucket: Int, CaseIterable, Sendable, Comparable {
    /// Une carte attend une décision : c'est bloquant, ça passe en premier.
    case awaitingDecision = 0
    /// La session a rendu la main et attend un prompt.
    case awaitingInput = 1
    /// Elle travaille — rien à faire pour l'instant.
    case working = 2
    /// Terminée (en cours de retrait de la liste).
    case done = 3

    public var title: String {
        switch self {
        case .awaitingDecision: return "À EXAMINER"
        case .awaitingInput: return "EN ATTENTE DE TOI"
        case .working: return "EN COURS"
        case .done: return "TERMINÉES"
        }
    }

    public static func bucket(for status: AgentSession.Status) -> SessionStateBucket {
        switch status {
        case .awaitingPermission: return .awaitingDecision
        case .awaitingInput: return .awaitingInput
        case .working: return .working
        case .done: return .done
        }
    }

    public static func < (lhs: SessionStateBucket, rhs: SessionStateBucket) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Ordre dans lequel les rangées sont ATTRIBUÉES quand il n'y en a pas pour
    /// tout le monde — distinct de l'ordre d'AFFICHAGE (`rawValue`).
    ///
    /// L'affichage répond à « qu'est-ce qui m'attend » : ce qui dort figure haut
    /// dans la liste parce que c'est à moi de jouer. Mais quand le budget est
    /// serré, c'est l'inverse qu'il faut : trois sessions DORMANTES ne doivent
    /// pas évincer la seule qui TRAVAILLE. Le cas est réel — budget de 4 rangées
    /// (une bannière est affichée), 3 sessions au repos et 1 en cours : l'ancien
    /// remplissage séquentiel donnait quatre rangées de sessions dormantes et
    /// renvoyait la seule session active derrière « +1 autre ». Depuis que le
    /// badge a disparu de ces lignes-là, elles ne portent même plus d'état :
    /// le panneau se remplissait de rien.
    var allocationPriority: Int {
        switch self {
        case .awaitingDecision: return 0   // bloquant : toujours en premier
        case .working: return 1            // ce qui se passe maintenant
        case .awaitingInput: return 2      // au repos : ça peut attendre une ligne
        case .done: return 3
        }
    }
}

public struct SessionStateGroup: Identifiable, Equatable, Sendable {
    public let bucket: SessionStateBucket
    public let sessions: [AgentSession]

    public var id: Int { bucket.rawValue }

    public init(bucket: SessionStateBucket, sessions: [AgentSession]) {
        self.bucket = bucket
        self.sessions = sessions
    }
}

/// Résultat d'un regroupement BORNÉ : le panneau de l'îlot a une hauteur fixe,
/// une flotte de douze sessions ne peut pas y tenir dépliée (vu en capture : la
/// dernière ligne coupée et le quota poussé hors du cadre).
public struct BoundedStateGrouping: Equatable, Sendable {
    public let groups: [SessionStateGroup]
    /// Sessions écartées faute de place — toujours les MOINS urgentes.
    public let hiddenCount: Int

    public init(groups: [SessionStateGroup], hiddenCount: Int) {
        self.groups = groups
        self.hiddenCount = hiddenCount
    }
}

public enum SessionGrouping {
    /// Groupes par état, du plus urgent au plus dormant. Les états sans session
    /// sont OMIS (un en-tête « À EXAMINER » vide occuperait une ligne de l'îlot
    /// pour ne rien dire). L'ordre d'arrivée est conservé à l'intérieur d'un
    /// groupe : le store a déjà trié.
    public static func byState(_ sessions: [AgentSession]) -> [SessionStateGroup] {
        var byBucket: [SessionStateBucket: [AgentSession]] = [:]
        for session in sessions {
            byBucket[SessionStateBucket.bucket(for: session.status), default: []].append(session)
        }
        return SessionStateBucket.allCases.compactMap { bucket in
            guard let sessions = byBucket[bucket], !sessions.isEmpty else { return nil }
            return SessionStateGroup(bucket: bucket, sessions: sessions)
        }
    }

    /// Même regroupement, borné à `limit` sessions affichées.
    ///
    /// La coupe se fait dans l'ordre d'urgence : ce qui saute est toujours ce
    /// qui dort. Un groupe vidé par la coupe disparaît (pas d'en-tête orphelin),
    /// et le nombre d'écartées revient à l'appelant pour qu'il le DISE — une
    /// liste tronquée en silence ferait croire à une flotte plus petite.
    public static func byState(_ sessions: [AgentSession], limit: Int) -> BoundedStateGrouping {
        let full = byState(sessions)
        guard limit > 0 else {
            return BoundedStateGrouping(groups: [], hiddenCount: sessions.count)
        }
        var remaining = limit
        var kept: [SessionStateGroup] = []
        for group in full {
            guard remaining > 0 else { break }
            let slice = Array(group.sessions.prefix(remaining))
            remaining -= slice.count
            kept.append(SessionStateGroup(bucket: group.bucket, sessions: slice))
        }
        let shown = kept.reduce(0) { $0 + $1.sessions.count }
        return BoundedStateGrouping(groups: kept, hiddenCount: max(0, sessions.count - shown))
    }

    /// Même regroupement, borné en RANGÉES DESSINÉES — en-têtes de groupe
    /// compris.
    ///
    /// Pourquoi pas `limit:` : ce dernier compte des sessions, or chaque groupe
    /// ajoute une ligne d'en-tête que le panneau doit dessiner. Quatre sessions
    /// réparties sur quatre états, c'est huit rangées, soit le double du budget
    /// — et le quota sortait du cadre (audit du 2026-07-27). Un groupe dont il
    /// ne resterait que l'en-tête n'est pas ouvert du tout.
    public static func byState(_ sessions: [AgentSession], rowBudget: Int) -> BoundedStateGrouping {
        let full = byState(sessions)
        guard rowBudget > 0, !full.isEmpty else {
            return BoundedStateGrouping(groups: [], hiddenCount: sessions.count)
        }

        // Attribution PAR TOURS, dans l'ordre d'`allocationPriority` : chaque
        // état non vide reçoit son en-tête et UNE session avant qu'un autre n'en
        // reçoive une deuxième. Le remplissage séquentiel d'avant laissait le
        // premier état de la liste manger tout le budget — voir le commentaire
        // d'`allocationPriority`.
        //
        // Un état non ouvert coûte 2 rangées (en-tête + 1re session), un état
        // déjà ouvert n'en coûte plus qu'une : un groupe ne s'ouvre donc jamais
        // pour n'afficher que son en-tête.
        let order = full.indices.sorted {
            full[$0].bucket.allocationPriority < full[$1].bucket.allocationPriority
        }
        var shown = [Int](repeating: 0, count: full.count)
        var remaining = rowBudget
        var progressed = true
        while remaining > 0, progressed {
            progressed = false
            for index in order {
                guard shown[index] < full[index].sessions.count else { continue }
                let cost = shown[index] == 0 ? 2 : 1
                guard remaining >= cost else { continue }
                remaining -= cost
                shown[index] += 1
                progressed = true
                if remaining == 0 { break }
            }
        }

        // …mais l'AFFICHAGE reprend l'ordre d'urgence pour l'utilisateur.
        let kept = full.indices.filter { shown[$0] > 0 }.map { index in
            SessionStateGroup(bucket: full[index].bucket,
                              sessions: Array(full[index].sessions.prefix(shown[index])))
        }
        let total = shown.reduce(0, +)
        return BoundedStateGrouping(groups: kept, hiddenCount: max(0, sessions.count - total))
    }
}

/// Combien de rangées le panneau étendu peut DESSINER sans pousser le quota
/// hors du cadre.
///
/// Le panneau a une hauteur FIXE (`IslandGeometry.expandedSize.height`) et il
/// est `.clipShape`é : tout ce qui dépasse disparaît SANS le dire. Les valeurs
/// ci-dessous sont mesurées en capture, pas devinées — environ 209 pt utiles
/// entre l'en-tête et le quota, une rangée de session en coûtant ~33 (deux
/// lignes : titre + détail) et un en-tête de groupe ~19.
public enum IslandRowBudget {
    /// Sans bannière sous la liste.
    public static let plain = 6
    /// La vue par PROJET dessine TOUJOURS une ligne de pied (« clique une
    /// session… » ou « +N autres »), que la vue par état n'a pas. Elle coûte
    /// donc une rangée de plus (revue des corrections, 2026-07-27).
    public static let projectFooterCost = 1
    /// Avec une bannière (tâche terminée, ou skill proposé) : elle mange ~66 pt.
    public static let withBanner = 4

    public static func rows(bannerShown: Bool) -> Int {
        bannerShown ? withBanner : plain
    }
}
