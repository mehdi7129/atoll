import XCTest
@testable import AtollCore

/// Le plan de rangées du panneau déployé — extrait de `App/ExpandedView.swift`
/// le 2026-08-14, où il vivait dans une `View` SwiftUI et n'avait donc AUCUN
/// test. Deux des défauts sérieux de la campagne de relecture étaient là.
final class IslandRowPlanTests: XCTestCase {

    private func session(_ name: String) -> AgentSession {
        AgentSession(id: name, projectName: name, status: .working(tool: nil))
    }

    private func group(_ id: String, _ count: Int) -> ProjectGroup {
        ProjectGroup(id: id, name: id,
                     sessions: (0..<count).map { session("\(id)-\($0)") })
    }

    /// Nombre de rangées réellement produites — le pied n'en fait pas partie,
    /// il est déduit du budget en entrée.
    private func drawn(_ plan: IslandRowPlan.Plan) -> Int { plan.rows.count }

    // MARK: - Le budget est tenu

    /// Le panneau a une HAUTEUR FIXE : dépasser ne coupe pas la liste, ça pousse
    /// le quota hors du cadre. La ligne de pied fait partie du budget.
    func testLeBudgetEstTenuPiedCompris() {
        for budget in 1...8 {
            let plan = IslandRowPlan.byProject(
                [group("a", 3), group("b", 3), group("c", 3)],
                rowBudget: budget,
                expanded: ["a", "b", "c"]
            )
            XCTAssertLessThanOrEqual(drawn(plan) + IslandRowBudget.projectFooterCost, budget,
                                     "budget \(budget) dépassé")
        }
    }

    /// Rien ne disparaît en silence : ce qui n'est pas dessiné est compté.
    func testToutCeQuiNestPasDessineEstCompte() {
        let groups = [group("a", 3), group("b", 3)]
        let total = groups.reduce(0) { $0 + $1.sessions.count }
        let plan = IslandRowPlan.byProject(groups, rowBudget: 4, expanded: ["a", "b"])
        let visibles = plan.rows.filter { if case .session = $0 { return true } else { return false } }.count
        // Les sessions d'un dossier REPLIÉ ne sont pas « cachées » : leur nombre
        // est porté par l'en-tête. Ici les deux sont dépliés.
        XCTAssertEqual(visibles + plan.hiddenCount, total)
    }

    // MARK: - Le défaut trouvé le 2026-08-14

    /// Un dossier déplié qui ne peut montrer AUCUNE session est dessiné REPLIÉ :
    /// son en-tête porte le compte, et rien n'est annoncé comme caché puisque
    /// rien ne l'est.
    ///
    /// ⚠️ CE TEST A ÉTÉ RÉÉCRIT le 2026-08-14 : sa première version bouclait sur
    /// `plan.rows` pour vérifier « aucun dossier sans enfant », et cette boucle
    /// ne s'exécutait JAMAIS puisque le plan ne contenait alors aucun dossier.
    /// Une assertion jamais atteinte, présentée comme la preuve du correctif —
    /// exactement le défaut corrigé le matin même dans `ProactiveRecallTests`.
    /// On assert désormais le plan EXACT, ligne par ligne.
    func testUnDossierSansPlaceEstDessineReplie() {
        // Budget 3 → 2 rangées de contenu. « a » (1 session) en prend une ; il
        // reste 1 rangée, insuffisante pour ouvrir « b » (en-tête + session).
        let plan = IslandRowPlan.byProject(
            [group("a", 1), group("b", 4)],
            rowBudget: 3,
            expanded: ["b"]
        )
        XCTAssertEqual(plan.rows.map(\.id), ["s:a-0", "f:b"],
                       "« b » reste visible, replié — le perdre entièrement serait pire")
        // Aucune session indentée : le dossier n'a PAS été ouvert.
        XCTAssertFalse(plan.rows.contains { row in
            if case .session(_, let indented) = row { return indented } else { return false }
        })
        XCTAssertEqual(plan.hiddenCount, 0,
                       "un dossier replié RÉSUME ses sessions, il ne les cache pas")
    }

    /// Le projet ne disparaît jamais tant qu'il reste une rangée : c'est la
    /// régression que la revue adversariale a trouvée dans la première version
    /// du correctif ci-dessus.
    func testUnProjetNeDisparaitPasQuandIlResteUneRangee() {
        let plan = IslandRowPlan.byProject([group("z", 5)], rowBudget: 2, expanded: ["z"])
        XCTAssertEqual(plan.rows.map(\.id), ["f:z"], "le nom et le compte du projet restent visibles")
    }

    /// Le contrôle : dès qu'il y a la place pour l'en-tête ET une session, le
    /// dossier s'ouvre normalement.
    func testUnDossierSOuvreDesQuIlPeutMontrerQuelqueChose() {
        let plan = IslandRowPlan.byProject([group("b", 4)], rowBudget: 3, expanded: ["b"])
        XCTAssertEqual(plan.rows.count, 2, "en-tête + 1 session")
        XCTAssertEqual(plan.hiddenCount, 3)
    }

    // MARK: - Les règles d'affichage

    /// Un projet à session unique n'a pas de dossier : ligne directe.
    func testUnProjetAUneSeuleSessionNaPasDeDossier() {
        let plan = IslandRowPlan.byProject([group("a", 1)], rowBudget: 6, expanded: [])
        XCTAssertEqual(plan.rows.count, 1)
        if case .session(_, let indented) = plan.rows[0] {
            XCTAssertFalse(indented, "une session sans dossier n'est pas indentée")
        } else {
            XCTFail("attendu une ligne de session, pas un dossier")
        }
    }

    /// Un dossier REPLIÉ ne cache rien : son en-tête porte le compte.
    func testUnDossierReplieNeCacheRien() {
        let plan = IslandRowPlan.byProject([group("a", 5)], rowBudget: 6, expanded: [])
        XCTAssertEqual(plan.rows.count, 1)
        XCTAssertEqual(plan.hiddenCount, 0, "les 5 sessions sont résumées, pas cachées")
    }

    /// L'ordre d'entrée est préservé — c'est l'ordre de première apparition des
    /// projets, que l'appelant a déjà décidé.
    func testLOrdreDentreeEstPreserve() {
        let plan = IslandRowPlan.byProject(
            [group("a", 1), group("b", 1), group("c", 1)],
            rowBudget: 6, expanded: []
        )
        XCTAssertEqual(plan.rows.map(\.id), ["s:a-0", "s:b-0", "s:c-0"])
    }

    /// Budget nul ou négatif : rien n'est dessiné, tout est annoncé.
    func testBudgetNulNeDessineRien() {
        for budget in [0, 1, -3] {
            let plan = IslandRowPlan.byProject([group("a", 2)], rowBudget: budget, expanded: ["a"])
            XCTAssertTrue(plan.rows.isEmpty, "budget \(budget)")
            XCTAssertEqual(plan.hiddenCount, 2, "budget \(budget)")
        }
    }

    /// Aucun groupe : plan vide, aucun compte fantôme.
    func testAucunGroupe() {
        let plan = IslandRowPlan.byProject([], rowBudget: 6, expanded: [])
        XCTAssertTrue(plan.rows.isEmpty)
        XCTAssertEqual(plan.hiddenCount, 0)
    }
}
