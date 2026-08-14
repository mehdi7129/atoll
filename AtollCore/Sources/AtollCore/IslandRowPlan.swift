import Foundation

// Mise en page de la liste de sessions du panneau déployé — la LOGIQUE, pas le
// dessin.
//
// POURQUOI CE FICHIER EXISTE (2026-08-14). Ce calcul vivait dans
// `App/ExpandedView.swift`, donc dans une `View` SwiftUI, donc hors de portée
// des tests : `App/` compte 10 878 lignes et ZÉRO test, quand `AtollCore` en
// compte 700. Les campagnes de relecture ont mesuré la conséquence — 5,2 défauts
// par millier de lignes dans `App/` contre 3,3 dans `AtollCore` — et DEUX des
// défauts sérieux trouvés étaient précisément ici, dans ce calcul-là.
//
// La règle du projet dit « ce qui peut être testé sans AppKit vit dans
// AtollCore, avec ses tests ». Un plan de rangées est une fonction pure de
// (groupes, budget, dossiers dépliés) vers (rangées, nombre de cachées) : rien
// n'y demandait SwiftUI.
//
// LA CONTRAINTE QU'IL SERT : le panneau a une hauteur FIXE. Dépasser le budget
// ne coupe pas la liste — ça pousse le QUOTA hors du cadre, en silence (vu en
// capture, audit du 2026-07-27). Et une liste tronquée sans le dire ferait
// croire à une flotte plus petite qu'elle n'est : le surplus est TOUJOURS
// annoncé.

/// Un projet et les sessions qu'il contient, tel qu'affiché dans l'îlot.
public struct ProjectGroup: Identifiable, Equatable, Sendable {
    /// Chemin de la racine du projet — sert de clé de groupe et d'identité.
    public let id: String
    /// Nom affiché (dernier composant, désambiguïsé par `ProjectNaming`).
    public let name: String
    public let sessions: [AgentSession]

    public init(id: String, name: String, sessions: [AgentSession]) {
        self.id = id
        self.name = name
        self.sessions = sessions
    }
}

public enum IslandRowPlan {

    /// Une rangée dessinable.
    public enum Row: Identifiable, Equatable {
        /// En-tête pliable d'un projet à plusieurs sessions.
        case folder(ProjectGroup)
        /// Une session ; `indented` quand elle est sous un dossier déplié.
        case session(AgentSession, indented: Bool)

        public var id: String {
            switch self {
            case .folder(let group): return "f:" + group.id
            case .session(let session, _): return "s:" + session.id
            }
        }
    }

    public struct Plan: Equatable {
        public let rows: [Row]
        /// Sessions qu'on n'a PAS pu dessiner faute de place.
        ///
        /// Les sessions d'un dossier REPLIÉ n'en font pas partie : leur nombre
        /// est déjà porté par l'en-tête (« ▸ Atoll · 3 »), elles ne sont pas
        /// cachées, elles sont résumées.
        public let hiddenCount: Int

        public init(rows: [Row], hiddenCount: Int) {
            self.rows = rows
            self.hiddenCount = hiddenCount
        }
    }

    /// Aplatit les groupes en rangées, dans la limite du budget.
    ///
    /// `rowBudget` est le nombre total de rangées dessinables, LIGNE DE PIED
    /// COMPRISE (« clique une session… » ou « +N autres ») : la vue par projet
    /// en dessine toujours une, elle est donc déduite ici et non par l'appelant.
    ///
    /// UN DOSSIER DÉPLIÉ QUI NE PEUT MONTRER AUCUNE SESSION EST DESSINÉ REPLIÉ.
    ///
    /// Il affichait son en-tête puis rien, et comptait toutes ses sessions comme
    /// « cachées » : l'utilisateur voyait « ▸ Atoll · 3 » ET « +3 autres », soit
    /// deux fois la même information, dont une alarmante.
    ///
    /// Première correction essayée, puis ABANDONNÉE le jour même sur la revue
    /// adversariale : ne rien dessiner du tout. C'était pire — le projet
    /// disparaissait ENTIÈREMENT de l'îlot, son nom, son compte et son glyphe
    /// d'attention avec lui. Perdre de l'information vaut toujours moins que
    /// d'en montrer une redondante.
    ///
    /// Il est donc traité comme REPLIÉ : l'en-tête porte le compte, et ses
    /// sessions ne sont pas « cachées » puisqu'elles sont résumées — la même
    /// règle que tous les autres dossiers repliés.
    public static func byProject(
        _ groups: [ProjectGroup],
        rowBudget: Int,
        expanded: Set<String>
    ) -> Plan {
        var rows: [Row] = []
        var remaining = rowBudget - IslandRowBudget.projectFooterCost
        var hidden = 0

        for group in groups {
            guard remaining > 0 else {
                hidden += group.sessions.count
                continue
            }
            // Un seul projet, une seule session : ligne directe, pas de dossier
            // inutile.
            if group.sessions.count == 1 {
                rows.append(.session(group.sessions[0], indented: false))
                remaining -= 1
                continue
            }
            // Replié — ou déplié sans la place de montrer une seule session,
            // auquel cas l'ouvrir ne dirait rien de plus : l'en-tête porte le
            // compte, rien n'est « caché ».
            guard expanded.contains(group.id), remaining >= 2 else {
                rows.append(.folder(group))
                remaining -= 1
                continue
            }
            rows.append(.folder(group))
            remaining -= 1
            let shown = group.sessions.prefix(remaining)
            rows.append(contentsOf: shown.map { .session($0, indented: true) })
            remaining -= shown.count
            hidden += group.sessions.count - shown.count
        }
        return Plan(rows: rows, hiddenCount: hidden)
    }
}
