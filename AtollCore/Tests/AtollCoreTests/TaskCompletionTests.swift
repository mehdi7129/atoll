import XCTest
@testable import AtollCore

final class TaskCompletionTests: XCTestCase {

    // MARK: - Markdown → une ligne lisible

    func testFlattensMultilineMarkdown() {
        let message = """
        ## Résultat

        - Les imports sont **rangés**
        - Les tests passent
        """
        XCTAssertEqual(TaskCompletion.plainText(message),
                       "Résultat Les imports sont rangés Les tests passent")
    }

    func testStripsFencedCodeBlocks() {
        let message = """
        Voici le correctif :

        ```swift
        let x = 1
        print(x)
        ```

        Tout compile.
        """
        let summary = TaskCompletion.plainText(message)
        XCTAssertEqual(summary, "Voici le correctif : Tout compile.")
        XCTAssertFalse(summary?.contains("print") ?? true)
    }

    /// Message coupé en plein bloc de code (ou tronqué par `inputCap`) : on
    /// jette la fin plutôt que d'afficher du code brut.
    func testStripsUnterminatedCodeFence() {
        XCTAssertEqual(TaskCompletion.plainText("C'est fait.\n\n```sh\nrm -rf /tmp/x"),
                       "C'est fait.")
    }

    func testKeepsLinkLabelsWithoutURLs() {
        let summary = TaskCompletion.plainText("Voir [le rapport](https://example.com/tres/long) pour le détail")
        XCTAssertEqual(summary, "Voir le rapport pour le détail")
    }

    func testStripsListMarkersAndCheckboxes() {
        XCTAssertEqual(TaskCompletion.plainText("- [x] build\n- [ ] tests\n1. publier"),
                       "build tests publier")
    }

    func testStripsTableRulesAndQuotes() {
        XCTAssertEqual(TaskCompletion.plainText("> note\n---\nfini"), "note fini")
    }

    func testStripsHTMLTags() {
        XCTAssertEqual(TaskCompletion.plainText("<p>terminé</p>"), "terminé")
        XCTAssertEqual(TaskCompletion.plainText("<br/>fini"), "fini")
    }

    /// Trouvé en revue adversariale : un motif « tout ce qui est entre deux
    /// chevrons » dévorait la prose ordinaire d'un projet Swift, et produisait
    /// un résumé grammatical qui disait le CONTRAIRE du vrai. C'est pire que
    /// pas de résumé du tout.
    func testDoesNotEatComparisonsOrGenerics() {
        XCTAssertEqual(TaskCompletion.plainText("Corrigé : la condition i < n && n > 0 était fausse."),
                       "Corrigé : la condition i < n && n > 0 était fausse.")
        XCTAssertEqual(TaskCompletion.plainText("Le build passe si len < 10 et count > 3, sinon non."),
                       "Le build passe si len < 10 et count > 3, sinon non.")
        XCTAssertEqual(TaskCompletion.plainText("J'ai remplacé Array<String> par [String] partout."),
                       "J'ai remplacé Array<String> par [String] partout.")
    }

    /// Les quantificateurs bornés évitent le balayage quadratique mesuré à
    /// 3,2 s sur 20 000 crochets non appariés — sur le MainActor.
    func testUnmatchedBracketsStayCheap() {
        let hostile = String(repeating: "[", count: TaskCompletion.inputCap)
        let started = Date()
        _ = TaskCompletion.plainText(hostile)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
    }

    /// Les `_` isolés vivent dans les identifiants : les retirer rendrait
    /// `snake_case` illisible. Seuls `**`, `__` et les accents graves partent.
    func testPreservesUnderscoresInsideIdentifiers() {
        XCTAssertEqual(TaskCompletion.plainText("`last_assistant_message` est **décodé**"),
                       "last_assistant_message est décodé")
    }

    func testReturnsNilWhenNothingReadableRemains() {
        XCTAssertNil(TaskCompletion.plainText(""))
        XCTAssertNil(TaskCompletion.plainText("   \n\n  "))
        XCTAssertNil(TaskCompletion.plainText("```\nseulement du code\n```"))
    }

    // MARK: - Troncature

    func testTruncatesOnWordBoundary() {
        let message = String(repeating: "alpha ", count: 100)
        let summary = TaskCompletion.plainText(message, maxLength: 20)
        XCTAssertNotNil(summary)
        XCTAssertLessThanOrEqual(summary!.count, 20)
        XCTAssertTrue(summary!.hasSuffix("…"))
        XCTAssertFalse(summary!.contains("alph…"), "coupe au milieu d'un mot")
    }

    /// Un seul mot plus long que la limite : on coupe quand même (mieux qu'un
    /// résumé vide), sans remonter au début du texte.
    func testTruncatesSingleLongWord() {
        let summary = TaskCompletion.plainText(String(repeating: "z", count: 100), maxLength: 10)
        XCTAssertEqual(summary?.count, 10)
    }

    func testShortMessageIsUntouched() {
        XCTAssertEqual(TaskCompletion.plainText("fini"), "fini")
    }

    func testIgnoresInputBeyondCap() {
        // La substance d'une conclusion est au début ; au-delà on ne lit pas
        // (les expressions régulières travaillent en O(n)).
        let message = String(repeating: "a", count: TaskCompletion.inputCap + 5_000)
        XCTAssertNotNil(TaskCompletion.plainText(message))
    }

    // MARK: - Repli sur la tâche demandée

    func testSummarizeFallsBackToTaskText() {
        XCTAssertEqual(
            TaskCompletion.summarize(lastAssistantMessage: nil, fallback: "ranger les imports"),
            "ranger les imports")
        XCTAssertEqual(
            TaskCompletion.summarize(lastAssistantMessage: "   ", fallback: "ranger les imports"),
            "ranger les imports")
        XCTAssertEqual(
            TaskCompletion.summarize(lastAssistantMessage: "```\ncode\n```", fallback: "ranger"),
            "ranger")
    }

    func testSummarizeUsesMessageWhenUsable() {
        XCTAssertEqual(
            TaskCompletion.summarize(lastAssistantMessage: "**Terminé** : 3 fichiers modifiés",
                                     fallback: "ranger les imports"),
            "Terminé : 3 fichiers modifiés")
    }

    func testFallbackIsAlsoFlattenedAndTruncated() {
        let summary = TaskCompletion.summarize(lastAssistantMessage: nil,
                                               fallback: "ligne 1\n\nligne 2",
                                               maxLength: 40)
        XCTAssertEqual(summary, "ligne 1 ligne 2")
    }

    /// Deux comparaisons dans une phrase ont la forme d'une balise à attributs.
    /// « i<n et j>0 » devenait « i 0 » : le résumé disait le CONTRAIRE du vrai,
    /// en notification macOS (audit du 2026-07-27).
    func testProseWithTwoComparisonsSurvives() {
        let resume = TaskCompletion.summarize(
            lastAssistantMessage: "Corrigé : la boucle s'arrête quand i<n et j>0, plus de débordement.",
            fallback: "tâche")
        XCTAssertTrue(resume.contains("i<n"), "obtenu : \(resume)")
        XCTAssertTrue(resume.contains("j>0"), "obtenu : \(resume)")
    }

    /// Les balises SANS attribut valué (`<br />`, `<hr />`) doivent partir
    /// aussi : exiger un `=` les avait rendues invisibles au nettoyage, et
    /// elles s'affichaient telles quelles dans la notification (revue des
    /// corrections, 2026-07-27).
    func testSelfClosingTagsWithoutAttributesAreStripped() {
        let resume = TaskCompletion.summarize(
            lastAssistantMessage: "Terminé.<br />Tout est vert.<hr />",
            fallback: "tâche")
        XCTAssertFalse(resume.contains("<br"), "obtenu : \(resume)")
        XCTAssertFalse(resume.contains("<hr"), "obtenu : \(resume)")
        XCTAssertTrue(resume.contains("Terminé"))
        XCTAssertTrue(resume.contains("Tout est vert"))
    }

    /// …sans cesser de retirer les VRAIES balises.
    func testRealHtmlTagsAreStillStripped() {
        let resume = TaskCompletion.summarize(
            lastAssistantMessage: "<p>Terminé</p> et <div class=\"x\">rangé</div>",
            fallback: "tâche")
        XCTAssertFalse(resume.contains("<p>"))
        XCTAssertFalse(resume.contains("class="))
        XCTAssertTrue(resume.contains("Terminé"))
        XCTAssertTrue(resume.contains("rangé"))
    }
}
