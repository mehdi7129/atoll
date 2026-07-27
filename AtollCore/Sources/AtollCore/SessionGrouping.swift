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
}
