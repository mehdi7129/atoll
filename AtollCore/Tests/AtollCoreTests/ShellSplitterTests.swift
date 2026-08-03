import XCTest
@testable import AtollCore

/// `ShellSplitter` découpe une ligne de shell en segments de commande.
///
/// CE FICHIER EXISTE POUR UNE RAISON PRÉCISE (2026-08-03). Le splitter n'avait
/// **aucun test à lui** : sa seule couverture venait d'`AutoAcceptPolicyTests`,
/// supprimé en même temps que le niveau « Auto ». Retirer les deux d'un même
/// geste aurait ôté la dernière preuve qu'un composant ENCORE UTILISÉ
/// (`SoundHookEditor`, qui décide quels hooks de l'utilisateur sont parqués)
/// fonctionne. Les cas ci-dessous reprennent ceux qui avaient été trouvés en
/// revue adversariale — chacun a coûté un défaut réel.
final class ShellSplitterTests: XCTestCase {

    // MARK: - Les opérateurs

    func testSplitsOnEveryChainingOperator() {
        XCTAssertEqual(ShellSplitter.meaningfulSegments("a && b"), ["a", "b"])
        XCTAssertEqual(ShellSplitter.meaningfulSegments("a || b"), ["a", "b"])
        XCTAssertEqual(ShellSplitter.meaningfulSegments("a | b"), ["a", "b"])
        XCTAssertEqual(ShellSplitter.meaningfulSegments("a ; b"), ["a", "b"])
    }

    /// LE défaut critique de l'audit du 2026-07-27 : `&` n'était pas un
    /// séparateur, si bien que `git status & git push --force` passait la garde
    /// anti-force-push — seul le premier mot était examiné.
    func testAmpersandIsASeparator() {
        XCTAssertEqual(ShellSplitter.meaningfulSegments("git status & git push --force"),
                       ["git status", "git push --force"])
    }

    func testTrailingAmpersandLeavesNoPhantomSegment() {
        XCTAssertEqual(ShellSplitter.meaningfulSegments("afplay son.wav &"), ["afplay son.wav"])
        // …mais `segments` le CONSERVE : l'appelant décide de son sens.
        XCTAssertEqual(ShellSplitter.segments("afplay son.wav &").count, 2)
    }

    // MARK: - Les redirections, qui contiennent un `&` littéral

    /// `2>&1` et `&>` ne sont pas des enchaînements. Les couper faisait prendre
    /// `afplay son.wav >/dev/null 2>&1` pour deux commandes — donc refuser de
    /// parquer un hook sonore parfaitement ordinaire.
    func testRedirectionsKeepTheirAmpersand() {
        XCTAssertEqual(ShellSplitter.meaningfulSegments("afplay son.wav >/dev/null 2>&1"),
                       ["afplay son.wav >/dev/null 2>&1"])
        XCTAssertEqual(ShellSplitter.meaningfulSegments("cmd &>fichier"), ["cmd &>fichier"])
        XCTAssertEqual(ShellSplitter.meaningfulSegments("cmd >&2"), ["cmd >&2"])
    }

    /// La forme complète d'un vrai hook sonore : redirections ET arrière-plan.
    func testRealSoundHookSplitsIntoOneCommandAndNothingElse() {
        XCTAssertEqual(
            ShellSplitter.meaningfulSegments("afplay -v 0.1 '/Users/x/son.mp3' >/dev/null 2>&1 &"),
            ["afplay -v 0.1 '/Users/x/son.mp3' >/dev/null 2>&1"])
    }

    // MARK: - Les guillemets

    /// Un opérateur ENTRE GUILLEMETS est un caractère ordinaire. Sans cela,
    /// `git commit -m "a & b"` était lu comme un enchaînement.
    func testOperatorsInsideQuotesAreLiteral() {
        XCTAssertEqual(ShellSplitter.meaningfulSegments("git commit -m \"a & b\""),
                       ["git commit -m \"a & b\""])
        XCTAssertEqual(ShellSplitter.meaningfulSegments("echo 'a | b ; c'"), ["echo 'a | b ; c'"])
    }

    func testQuotesOfOneKindDoNotCloseTheOther() {
        XCTAssertEqual(ShellSplitter.meaningfulSegments("echo \"il n'y a qu'un ; segment\""),
                       ["echo \"il n'y a qu'un ; segment\""])
    }

    /// Guillemet jamais refermé : on ne coupe plus, plutôt que d'inventer une
    /// frontière. Le texte reste entier — à l'appelant de juger.
    func testUnclosedQuoteSwallowsTheRest() {
        XCTAssertEqual(ShellSplitter.meaningfulSegments("echo \"a & b"), ["echo \"a & b"])
    }

    // MARK: - L'échappement

    func testBackslashEscapesAnOperator() {
        XCTAssertEqual(ShellSplitter.meaningfulSegments("echo a \\& b"), ["echo a \\& b"])
    }

    // MARK: - Les retours à la ligne

    func testNewlinesSplitByDefault() {
        XCTAssertEqual(ShellSplitter.meaningfulSegments("a\nb\r\nc"), ["a", "b", "c"])
    }

    /// `splitOnNewlines: false` : le seul appelant en était `AutoAcceptPolicy`.
    /// Le paramètre reste couvert — un jour quelqu'un en aura besoin, et il ne
    /// doit pas découvrir alors qu'il n'a jamais été testé.
    func testNewlinesCanBeKept() {
        XCTAssertEqual(ShellSplitter.segments("a\nb", splitOnNewlines: false), ["a\nb"])
        XCTAssertEqual(ShellSplitter.meaningfulSegments("a\nb && c", splitOnNewlines: false),
                       ["a\nb", "c"])
    }

    // MARK: - Cas limites

    func testEmptyAndBlankInputs() {
        XCTAssertEqual(ShellSplitter.meaningfulSegments(""), [])
        XCTAssertEqual(ShellSplitter.meaningfulSegments("   \n  "), [])
        XCTAssertEqual(ShellSplitter.segments("").count, 1, "une ligne vide reste UN segment vide")
    }

    func testConsecutiveOperatorsProduceNoMeaningfulEmpties() {
        XCTAssertEqual(ShellSplitter.meaningfulSegments("a ;; b"), ["a", "b"])
        XCTAssertEqual(ShellSplitter.meaningfulSegments("a && && b"), ["a", "b"])
    }

    func testSegmentsAreTrimmedOnlyInTheMeaningfulVariant() {
        XCTAssertEqual(ShellSplitter.segments("a ; b"), ["a ", " b"])
        XCTAssertEqual(ShellSplitter.meaningfulSegments("a ; b"), ["a", "b"])
    }
}
