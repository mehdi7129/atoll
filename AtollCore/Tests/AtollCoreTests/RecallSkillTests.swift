import XCTest
@testable import AtollCore

final class RecallSkillTests: XCTestCase {

    /// Le frontmatter YAML est ce que le CLI lit pour charger (ou non) le
    /// skill : il doit ouvrir le fichier, se refermer, et porter name +
    /// description avec les déclencheurs de rappel mémoire.
    func testSkillMarkdownHasFrontmatterNameAndDescription() throws {
        let markdown = RecallSkill.markdown
        XCTAssertTrue(markdown.hasPrefix("---\n"), "le frontmatter ouvre le fichier")

        // Fermeture du frontmatter : un second « --- » seul sur sa ligne.
        let parts = markdown.components(separatedBy: "\n---\n")
        XCTAssertGreaterThanOrEqual(parts.count, 2, "frontmatter non refermé")

        let frontmatter = try XCTUnwrap(parts.first)
        XCTAssertTrue(frontmatter.contains("name: atoll-recall"))
        XCTAssertTrue(frontmatter.contains("description: "))
        // Les déclencheurs qui font surgir le skill au bon moment.
        XCTAssertTrue(frontmatter.contains("« on avait dit »"))
        XCTAssertTrue(frontmatter.contains("« la dernière fois »"))

        // Le corps existe après le frontmatter et se termine proprement.
        let body = try XCTUnwrap(parts.last)
        XCTAssertTrue(body.contains("# Rappel mémoire Atoll"))
        XCTAssertTrue(markdown.hasSuffix("\n"), "fichier terminé par un saut de ligne")
    }

    /// Le corps doit donner la commande exacte (chemin du bridge compris) et
    /// ses options — c'est la seule interface que le modèle connaîtra.
    func testSkillMarkdownMentionsRecallCommand() {
        let markdown = RecallSkill.markdown
        XCTAssertTrue(markdown.contains(#""$HOME/.atoll/bin/atoll-bridge" recall"#))
        XCTAssertTrue(markdown.contains("--limit"))
        XCTAssertTrue(markdown.contains("--project"))
        XCTAssertTrue(markdown.contains("--json"))
        // Fail-open : le skill dit quoi faire quand l'index n'existe pas.
        XCTAssertTrue(markdown.contains("Aucun index mémoire"))
        XCTAssertTrue(markdown.contains("ne jamais bloquer"))
    }
}
