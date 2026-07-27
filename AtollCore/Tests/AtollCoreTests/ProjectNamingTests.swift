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
}
