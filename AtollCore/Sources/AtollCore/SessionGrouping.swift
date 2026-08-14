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

    /// Seau d'une session, en tenant compte de ce qu'on SAIT réellement d'elle.
    ///
    /// « EN ATTENTE DE TOI » est une affirmation forte : elle réclame une action.
    /// On ne la porte donc que sur un état CONFIRMÉ par un hook. Une session
    /// seulement découverte par `agents --json` et rapportée `idle` est rangée
    /// avec celles qui tournent : c'est imprécis, mais ça ne réclame rien —
    /// alors que la ranger « en attente de toi » te convoquait au nom d'une
    /// session qui ne demandait rien, en permanence, sur une bonne partie de la
    /// flotte. C'est le même arbitrage que le retrait du badge « INPUT? » en
    /// Phase 14, appliqué au regroupement par état.
    ///
    /// EFFET DE BORD ASSUMÉ : `working` a une priorité d'ALLOCATION plus haute
    /// (1 contre 2). Au-delà de quatre sessions, une session réellement en
    /// attente peut donc être reléguée derrière une session non confirmée. Le
    /// mensonge permanent coûte plus cher que ce cas de bord — à revoir si le
    /// panneau se met à mentir dans l'autre sens.
    public static func bucket(for session: AgentSession) -> SessionStateBucket {
        if case .awaitingInput = session.status, !session.stateConfirmedByHook {
            return .working
        }
        return bucket(for: session.status)
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
            byBucket[SessionStateBucket.bucket(for: session), default: []].append(session)
        }
        return SessionStateBucket.allCases.compactMap { bucket in
            guard let sessions = byBucket[bucket], !sessions.isEmpty else { return nil }
            guard bucket == .working else {
                return SessionStateGroup(bucket: bucket, sessions: sessions)
            }
            // Les sessions NON CONFIRMÉES sont rangées ici faute de mieux (voir
            // `bucket(for:)`), et elles y arrivent en tête : `SessionStore.rank`
            // classe `waitingInput` AVANT `busy`. Quand le budget coupe, la
            // seule session qui travaille vraiment se retrouvait alors derrière
            // « +N autres » — mesuré : budget 4, trois dormantes non confirmées
            // et une active donnaient « EN COURS : idleA, idleB, idleC ».
            //
            // C'est exactement l'invariant qu'`allocationPriority` protège
            // (« trois sessions DORMANTES ne doivent pas évincer la seule qui
            // TRAVAILLE ») — sauf qu'il ne peut plus rien ici : il arbitre ENTRE
            // les seaux, et la fusion n'en laisse qu'un. On rétablit donc
            // l'ordre À L'INTÉRIEUR du seau.
            //
            // Partition explicite plutôt que `sorted` : le tri de Swift n'est
            // pas stable, et deux regroupements successifs doivent rendre
            // exactement le même ordre (sinon l'îlot se réagence tout seul).
            var actives: [AgentSession] = []
            var dormantes: [AgentSession] = []
            for session in sessions {
                if case .awaitingInput = session.status {
                    dormantes.append(session)
                } else {
                    actives.append(session)
                }
            }
            return SessionStateGroup(bucket: bucket, sessions: actives + dormantes)
        }
    }

    /// Regroupement borné en RANGÉES DESSINÉES — en-têtes de groupe compris.
    ///
    /// ⛔️ Une variante `limit:` a existé, qui comptait des SESSIONS. Elle a été
    /// remplacée par celle-ci (audit du 2026-07-27 : chaque groupe ajoute une
    /// ligne d'en-tête, donc quatre sessions sur quatre états font huit rangées,
    /// le double du budget — le quota sortait du cadre), puis SUPPRIMÉE le
    /// 2026-08-14 : elle n'avait plus aucun appelant hors de ses propres tests,
    /// et elle coupait dans l'ordre d'AFFICHAGE sans consulter
    /// `allocationPriority`. La réutiliser aurait réintroduit mot pour mot la
    /// régression mesurée en v0.16.1 — la seule session qui travaille reléguée
    /// derrière « +1 autre ». Une API morte que ses tests font paraître sûre.
    ///
    /// La coupe se fait dans l'ordre d'urgence : ce qui saute est toujours ce
    /// qui dort. Un groupe dont il ne resterait que l'en-tête n'est pas ouvert
    /// du tout, et le nombre d'écartées revient à l'appelant pour qu'il le DISE
    /// — une liste tronquée en silence ferait croire à une flotte plus petite.
    /// ⚠️ LE BUDGET EST INTÉGRALEMENT POUR LE CONTENU — la mention « +N autres »
    /// NE DOIT PAS y prendre une rangée, et la vue ne doit donc pas lui en
    /// dessiner une à part (elle la porte sur l'en-tête du dernier groupe, cf.
    /// `ExpandedView`).
    ///
    /// Essayé le 2026-08-14, et ANNULÉ le jour même : réserver ici une rangée
    /// pour ce pied faisait tomber le budget de 4 à 3, et un budget de 3 ne peut
    /// plus ouvrir DEUX groupes (un groupe non ouvert coûte 2 rangées). Le
    /// groupe « en cours » disparaissait alors derrière « +N autres » quand des
    /// sessions dormantes remplissaient le budget — mot pour mot la régression
    /// mesurée en v0.16.1, que `allocationPriority` existe pour empêcher. Les
    /// deux tests qui l'ont attrapée sont `testWorkingSurvivesABudgetFilledBy
    /// IdleSessions` et `testAwaitingDecisionIsServedFirst`.
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
