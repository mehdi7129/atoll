import XCTest
@testable import AtollCore

final class ProjectNamingTests: XCTestCase {

    func testOrdinaryPathKeepsLastComponent() {
        XCTAssertEqual(
            ProjectNaming.displayName(for: "/Users/m/Desktop/Dynamic_Island", siblings: []),
            "Dynamic_Island")
    }

    /// Le cas vécu : un dossier réellement nommé « claude ». Seul, il ne dit
    /// rien — l'îlot affichait « claude · 2 ».
    func testGenericClaudeFolderShowsTwoComponents() {
        XCTAssertEqual(
            ProjectNaming.displayName(for: "/Users/m/Dropbox/Blender/claude", siblings: []),
            "Blender/claude")
    }

    func testHomonymProjectsShowTwoComponents() {
        let paths = ["/Users/m/a/app", "/Users/m/b/app"]
        XCTAssertEqual(ProjectNaming.displayNames(for: paths), ["a/app", "b/app"])
    }

    func testDistinctSiblingsKeepShortNames() {
        let paths = ["/Users/m/a/atoll", "/Users/m/b/valdisere"]
        XCTAssertEqual(ProjectNaming.displayNames(for: paths), ["atoll", "valdisere"])
    }

    /// Un chemin d'un seul composant n'a pas de « deux derniers » : on rend ce
    /// qu'on a plutôt qu'une chaîne vide.
    func testSingleComponentPathDegradesGracefully() {
        XCTAssertEqual(ProjectNaming.displayName(for: "/claude", siblings: []), "claude")
        XCTAssertEqual(ProjectNaming.displayName(for: "", siblings: []), "")
    }

    /// La liste des voisins peut contenir le chemin lui-même : sa propre
    /// présence ne doit pas le rendre « ambigu ».
    func testSelfInSiblingsIsNotADuplicate() {
        XCTAssertEqual(
            ProjectNaming.displayName(for: "/Users/m/atoll", siblings: ["/Users/m/atoll"]),
            "atoll")
    }

    /// Deux SESSIONS du même projet ne sont pas deux projets homonymes.
    ///
    /// `siblings` reçoit une entrée par session : le comptage par occurrences
    /// allongeait le nom dès qu'on ouvrait une seconde session dans le même
    /// dossier — le cas ordinaire — alors qu'aucune ambiguïté n'existait.
    func testDeuxSessionsDuMemeProjetNAllongentPasLeNom() {
        let projet = "/Users/moi/Desktop/Dynamic_Island"
        XCTAssertEqual(ProjectNaming.displayNames(for: [projet, projet]),
                       ["Dynamic_Island", "Dynamic_Island"])
        XCTAssertEqual(ProjectNaming.displayNames(for: [projet, projet, projet]),
                       ["Dynamic_Island", "Dynamic_Island", "Dynamic_Island"])
    }

    /// Contrôle : deux projets RÉELLEMENT homonymes s'allongent toujours.
    func testDeuxProjetsHomonymesSAllongentToujours() {
        let noms = ProjectNaming.displayNames(for: [
            "/Users/moi/Desktop/Dynamic_Island",
            "/Users/moi/archive/Dynamic_Island",
        ])
        XCTAssertEqual(noms, ["Desktop/Dynamic_Island", "archive/Dynamic_Island"])
    }
}
