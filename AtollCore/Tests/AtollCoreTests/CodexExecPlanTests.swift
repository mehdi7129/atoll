import XCTest
@testable import AtollCore

final class CodexExecPlanTests: XCTestCase {

    // MARK: - Arguments

    func testArgumentsCarryTheReadOnlyContract() {
        let arguments = CodexExecPlan.arguments(
            schemaPath: "/tmp/s.json", outputPath: "/tmp/o.json", workingDirectory: "/tmp/p")
        XCTAssertEqual(arguments.first, "exec")
        XCTAssertTrue(arguments.contains("--ephemeral"))
        XCTAssertTrue(arguments.contains("--ignore-user-config"))
        // Le bac à sable read-only remplace `--tools ""` : le modèle n'écrit rien.
        XCTAssertEqual(argument(after: "--sandbox", in: arguments), "read-only")
        // Sans cette politique, une demande d'approbation suspendrait le process
        // jusqu'au watchdog : personne n'est là pour répondre.
        XCTAssertTrue(arguments.contains("approval_policy=\"never\""))
        XCTAssertEqual(argument(after: "--output-schema", in: arguments), "/tmp/s.json")
        XCTAssertEqual(argument(after: "--output-last-message", in: arguments), "/tmp/o.json")
        XCTAssertEqual(argument(after: "--cd", in: arguments), "/tmp/p")
    }

    /// Un nom de modèle Anthropic passé à Codex ferait échouer le run : on ne
    /// passe AUCUN `--model`, le défaut du compte est le choix de l'utilisateur.
    func testArgumentsNeverCarryAModel() {
        let arguments = CodexExecPlan.arguments(
            schemaPath: "/tmp/s", outputPath: "/tmp/o", workingDirectory: nil)
        XCTAssertFalse(arguments.contains("--model"))
        XCTAssertFalse(arguments.contains("-m"))
    }

    func testEmptyWorkingDirectoryIsOmittedNotPassedEmpty() {
        for directory in [nil, ""] as [String?] {
            let arguments = CodexExecPlan.arguments(
                schemaPath: "/tmp/s", outputPath: "/tmp/o", workingDirectory: directory)
            XCTAssertFalse(arguments.contains("--cd"), "directory=\(String(describing: directory))")
        }
    }

    func testPromptKeepsSystemAndTaskSeparated() {
        let prompt = CodexExecPlan.fullPrompt(system: "RÈGLES", user: "TÂCHE")
        XCTAssertTrue(prompt.hasPrefix("RÈGLES"))
        XCTAssertTrue(prompt.hasSuffix("TÂCHE"))
        XCTAssertTrue(prompt.contains("---"))
    }

    // MARK: - Lecture de la sortie Codex

    /// Codex écrit le payload NU, sans l'enveloppe Anthropic : le parseur doit
    /// l'accepter tel quel — et appliquer la MÊME revalidation.
    func testBareStructuredPayloadIsAccepted() {
        let payload = """
        {"session_summary":"Un bilan","nothing_learned":false,
         "notes":[{"slug":"note-utile","category":"technique",
                   "content":"Un fait mesuré.","confidence":"high"}],
         "skills":[]}
        """
        guard case .success(let report) = RetrospectiveReport.parse(codexOutput: Data(payload.utf8))
        else { return XCTFail("payload Codex refusé") }
        XCTAssertEqual(report.sessionSummary, "Un bilan")
        XCTAssertEqual(report.notes.count, 1)
        // Pas de facturation à l'appel sur abonnement : le coût est vide, et
        // c'est exact — pas une donnée manquante.
        XCTAssertNil(report.costUSD)
        XCTAssertTrue(report.modelCosts.isEmpty)
    }

    func testCodexOutputWrappedInMarkdownFencesIsAccepted() {
        let payload = """
        ```json
        {"session_summary":"Bilan","nothing_learned":true,"notes":[],"skills":[]}
        ```
        """
        guard case .success(let report) = RetrospectiveReport.parse(codexOutput: Data(payload.utf8))
        else { return XCTFail("fences non retirées") }
        XCTAssertTrue(report.nothingLearned)
    }

    func testCodexOutputThatIsNotJSONFails() {
        // Une phrase en prose (le modèle a ignoré le schéma) n'est pas un rapport.
        guard case .failure(let error) =
                RetrospectiveReport.parse(codexOutput: Data("Je n'ai rien trouvé.".utf8))
        else { return XCTFail("prose acceptée comme rapport") }
        XCTAssertEqual(error, .notJSON)
    }

    func testEmptyCodexOutputFails() {
        guard case .failure = RetrospectiveReport.parse(codexOutput: Data())
        else { return XCTFail("sortie vide acceptée") }
    }

    /// La revalidation partagée doit mordre par le chemin Codex EXACTEMENT comme
    /// par le chemin Claude : un rapport sans contenu ni `nothing_learned` est
    /// refusé des deux côtés.
    func testSharedValidationRejectsAnEmptyReportOnBothPaths() {
        let bare = Data(#"{"session_summary":"","notes":[],"skills":[]}"#.utf8)
        guard case .failure(let codexError) = RetrospectiveReport.parse(codexOutput: bare)
        else { return XCTFail("rapport vide accepté (Codex)") }
        XCTAssertEqual(codexError, .empty)

        let wrapped = Data(#"{"structured_output":{"session_summary":"","notes":[],"skills":[]}}"#.utf8)
        guard case .failure(let claudeError) = RetrospectiveReport.parse(cliOutput: wrapped)
        else { return XCTFail("rapport vide accepté (Claude)") }
        XCTAssertEqual(claudeError, .empty)
    }

    /// Le préfixe réservé `atoll-` est retiré par le chemin Codex aussi — le
    /// modèle le propose spontanément, et un skill `atoll-…` est inapprouvable.
    func testReservedSlugPrefixIsStrippedOnTheCodexPathToo() {
        let payload = """
        {"session_summary":"S","notes":[],"skills":[
          {"slug":"atoll-release-pipeline","title":"T","description":"D",
           "skill_md":"# T\\nUn contenu suffisamment long pour être retenu par la validation.",
           "rationale":"R","confidence":"high"}]}
        """
        guard case .success(let report) = RetrospectiveReport.parse(codexOutput: Data(payload.utf8))
        else { return XCTFail("payload refusé") }
        XCTAssertEqual(report.skills.first?.slug, "release-pipeline")
    }

    // MARK: - Curation

    func testCurationBarePayloadIsAccepted() {
        let payload = """
        {"notes":[{"title":"Un titre","content":"Un contenu consolidé.",
                   "category":"technique","sources":["a.md","b.md"]}],
         "contradictions":[]}
        """
        guard let output = NotesCurationOutput.parse(codexOutput: Data(payload.utf8))
        else { return XCTFail("payload de curation refusé") }
        XCTAssertEqual(output.notes.count, 1)
        XCTAssertEqual(output.notes.first?.sources.count, 2)
    }

    func testCurationRejectsNonJSON() {
        XCTAssertNil(NotesCurationOutput.parse(codexOutput: Data("pas du JSON".utf8)))
    }

    private func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.index(after: index) < arguments.endIndex else { return nil }
        return arguments[arguments.index(after: index)]
    }
}
