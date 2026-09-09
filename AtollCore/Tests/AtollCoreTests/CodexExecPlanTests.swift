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

    // MARK: - Schéma strict OpenAI

    /// LE DÉFAUT QUI A BLOQUÉ LE LOT, mesuré le 2026-09-07 : envoyé tel quel, le
    /// schéma du bilan est refusé par l'API — « 'required' is required to be
    /// supplied and to be an array including every key in properties. Missing
    /// 'confidence' » (HTTP 400, aucun fichier produit).
    func testEveryPropertyEndsUpRequired() throws {
        let json = try XCTUnwrap(CodexExecPlan.openAISchema(from: RetrospectivePrompt.jsonSchema))
        try assertRequiredCoversProperties(in: json)
        let curation = try XCTUnwrap(CodexExecPlan.openAISchema(from: NotesCurationPrompt.jsonSchema))
        try assertRequiredCoversProperties(in: curation)
    }

    /// Rendre `similar_existing` obligatoire forcerait le modèle à INVENTER une
    /// capacité existante que sa proposition recoupe — exactement ce que
    /// l'antériorité sert à éviter. Il devient donc nullable, pas requis-non-nul.
    func testPreviouslyOptionalFieldsBecomeNullable() throws {
        let json = try XCTUnwrap(CodexExecPlan.openAISchema(from: RetrospectivePrompt.jsonSchema))
        let root = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any])
        let skills = try XCTUnwrap(((root["properties"] as? [String: Any])?["skills"] as? [String: Any]))
        let item = try XCTUnwrap(skills["items"] as? [String: Any])
        let properties = try XCTUnwrap(item["properties"] as? [String: Any])
        let similar = try XCTUnwrap(properties["similar_existing"] as? [String: Any])
        XCTAssertEqual(similar["type"] as? [String], ["string", "null"])
        // `slug` était déjà requis : il ne devient PAS nullable.
        let slug = try XCTUnwrap(properties["slug"] as? [String: Any])
        XCTAssertEqual(slug["type"] as? String, "string")
    }

    /// Un enum rendu nullable doit accepter `null`, sinon la valeur qu'on vient
    /// d'autoriser n'est valide pour aucune branche.
    func testNullableEnumAcceptsNull() throws {
        let json = try XCTUnwrap(CodexExecPlan.openAISchema(from: RetrospectivePrompt.jsonSchema))
        let root = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any])
        let notes = try XCTUnwrap(((root["properties"] as? [String: Any])?["notes"] as? [String: Any]))
        let item = try XCTUnwrap(notes["items"] as? [String: Any])
        let confidence = try XCTUnwrap((item["properties"] as? [String: Any])?["confidence"] as? [String: Any])
        let options = try XCTUnwrap(confidence["enum"] as? [Any])
        XCTAssertTrue(options.contains { $0 is NSNull })
    }

    /// Mots-clés refusés par le mode strict. Les retirer est SANS DANGER : les
    /// bornes sont réappliquées en Swift, « indépendamment du schéma du CLI ».
    func testUnsupportedKeywordsAreStripped() throws {
        let json = try XCTUnwrap(CodexExecPlan.openAISchema(from: RetrospectivePrompt.jsonSchema))
        for keyword in ["pattern", "maxLength", "maxItems", "minLength"] {
            XCTAssertFalse(json.contains("\"\(keyword)\""), "\(keyword) subsiste")
        }
        // `additionalProperties: false` est EXIGÉ, lui : il doit survivre.
        XCTAssertTrue(json.contains("\"additionalProperties\":false"))
    }

    func testMalformedSchemaYieldsNilInsteadOfGarbage() {
        XCTAssertNil(CodexExecPlan.openAISchema(from: "pas du json"))
        XCTAssertNil(CodexExecPlan.openAISchema(from: "[1,2,3]"))
    }

    // MARK: - Rapports RÉELS produits par Codex

    /// Sortie VERBATIM de `codex exec` le 2026-09-07 (exit 0, 7 s), avec le
    /// schéma converti. C'est la seule preuve qui compte : un test sur un
    /// payload fabriqué à la main n'aurait pas vu le refus du schéma.
    func testRealCodexRetrospectiveIsParsed() throws {
        let real = #"""
        {"notes":[{"category":"pitfall","confidence":"high","content":"Le build a échoué avec « missing Metal Toolchain ». Dans cette session, la commande `xcodebuild -downloadComponent MetalToolchain` a réussi et le build est redevenu vert après le téléchargement du composant.","slug":"missing-metal-toolchain"}],"nothing_learned":false,"session_summary":"L’échec du build lié à la Metal Toolchain manquante a été résolu en téléchargeant le composant via xcodebuild.","skills":[]}
        """#
        guard case .success(let report) = RetrospectiveReport.parse(codexOutput: Data(real.utf8))
        else { return XCTFail("rapport Codex RÉEL refusé par le parseur") }
        XCTAssertEqual(report.notes.count, 1)
        XCTAssertEqual(report.notes.first?.slug, "missing-metal-toolchain")
        XCTAssertEqual(report.notes.first?.confidence, "high")
        XCTAssertFalse(report.nothingLearned)
        XCTAssertTrue(report.skills.isEmpty)
    }

    /// Idem pour la curation — même run, même jour.
    func testRealCodexCurationIsParsed() throws {
        let real = #"""
        {"contradictions":[],"notes":[{"content":"Depuis Xcode 26, la Metal Toolchain est un composant à télécharger séparément avec `xcodebuild -downloadComponent MetalToolchain`.","sources":["build-metal","metal-again"],"title":"Téléchargement de la Metal Toolchain"}]}
        """#
        let output = try XCTUnwrap(NotesCurationOutput.parse(codexOutput: Data(real.utf8)))
        XCTAssertEqual(output.notes.count, 1)
        XCTAssertEqual(output.notes.first?.sources, ["build-metal", "metal-again"])
        XCTAssertTrue(output.contradictions.isEmpty)
    }

    private func assertRequiredCoversProperties(in json: String, file: StaticString = #filePath,
                                                line: UInt = #line) throws {
        let root = try XCTUnwrap((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any])
        func walk(_ node: [String: Any], path: String) {
            if let properties = node["properties"] as? [String: Any] {
                let required = Set(node["required"] as? [String] ?? [])
                XCTAssertEqual(required, Set(properties.keys),
                               "required incomplet en \(path)", file: file, line: line)
                for (key, value) in properties {
                    if let child = value as? [String: Any] { walk(child, path: "\(path).\(key)") }
                }
            }
            if let items = node["items"] as? [String: Any] { walk(items, path: "\(path)[]") }
        }
        walk(root, path: "$")
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
