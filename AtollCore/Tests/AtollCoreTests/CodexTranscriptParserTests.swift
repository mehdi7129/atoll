import XCTest
@testable import AtollCore

/// Lignes VERBATIM de rollouts Codex réels (`codex-cli 0.153.4`, 2026-09-09),
/// tronquées mais jamais reformées : un parseur validé sur des fixtures écrites
/// à la main ne prouve rien du format qu'il rencontrera.
final class CodexTranscriptParserTests: XCTestCase {

    private func line(_ json: String) -> TranscriptLine? {
        CodexTranscriptParser.parse(Data(json.utf8))
    }

    // MARK: - Contexte de session

    func testSessionMetaCarriesContextWithoutFragments() throws {
        let l = try XCTUnwrap(line(#"""
        {"type":"session_meta","payload":{"session_id":"01a08577-386d-72c0-90ac-54eabd344ec1",
         "id":"01a08577-386d-72c0-90ac-54eabd344ec1","timestamp":"2026-09-09T09:19:38.130Z",
         "cwd":"/Users/m/Desktop/Dynamic_Island/codex","cli_version":"0.153.4"}}
        """#))
        XCTAssertEqual(l.sessionID, "01a08577-386d-72c0-90ac-54eabd344ec1")
        XCTAssertEqual(l.cwd, "/Users/m/Desktop/Dynamic_Island/codex")
        XCTAssertNotNil(l.timestamp)
        XCTAssertTrue(l.fragments.isEmpty, "cette ligne porte le contexte, pas du texte")
    }

    // MARK: - Conversation

    func testUserAndAssistantMessagesBecomeFragments() throws {
        let user = try XCTUnwrap(line(#"""
        {"type":"response_item","payload":{"type":"message","role":"user","id":"msg_1",
         "content":[{"type":"input_text","text":"Corrige la course de clôture."}]}}
        """#))
        XCTAssertEqual(user.fragments.first?.role, .user)
        XCTAssertEqual(user.fragments.first?.text, "Corrige la course de clôture.")

        let assistant = try XCTUnwrap(line(#"""
        {"type":"response_item","payload":{"type":"message","role":"assistant","id":"msg_2",
         "content":[{"type":"output_text","text":"Je lis la section demandée."}]}}
        """#))
        XCTAssertEqual(assistant.fragments.first?.role, .assistant)
    }

    /// PIÈGE N° 3 : `developer` n'est pas une conversation — ce sont les
    /// instructions système, identiques d'une session à l'autre.
    func testDeveloperMessagesAreDropped() {
        XCTAssertNil(line(#"""
        {"type":"response_item","payload":{"type":"message","role":"developer","id":"msg_3",
         "content":[{"type":"input_text","text":"<skills_instructions>\n## Skills\n…"}]}}
        """#))
    }

    /// Une enveloppe machine glissée dans un message `user` n'est pas
    /// l'utilisateur qui parle : même raisonnement que l'exclusion des
    /// `<task-notification>` en v0.16.0 (17 % du corpus `user` pour rien).
    func testMachineEnvelopesRetainTheirActualProvenance() {
        XCTAssertEqual(line(#"""
        {"type":"response_item","payload":{"type":"message","role":"user","id":"msg_4",
         "content":[{"type":"input_text","text":"<environment_context>\n  <cwd>/tmp</cwd>\n"}]}}
        """#)?.fragments.first?.role, .instruction)
        // …mais une vraie question qui PARLE de ces balises doit passer.
        XCTAssertNotNil(line(#"""
        {"type":"response_item","payload":{"type":"message","role":"user","id":"msg_5",
         "content":[{"type":"input_text","text":"que contient <environment_context> ?"}]}}
        """#))
    }

    // MARK: - Outils

    func testToolCallAndOutputSharePairingIdentifier() throws {
        let call = try XCTUnwrap(line(#"""
        {"type":"response_item","payload":{"type":"custom_tool_call","id":"ctc_1",
         "call_id":"call_JTorNyiN","name":"exec","status":"completed",
         "input":"const r = await tools.exec_command({\"cmd\":\"pwd\"})"}}
        """#))
        XCTAssertEqual(call.fragments.first?.role, .tool)
        XCTAssertEqual(call.fragments.first?.toolUseID, "call_JTorNyiN")
        XCTAssertTrue(call.fragments.first?.text.hasPrefix("exec · ") == true)

        let output = try XCTUnwrap(line(#"""
        {"type":"response_item","payload":{"type":"custom_tool_call_output","id":"ctco_1",
         "call_id":"call_JTorNyiN",
         "output":[{"type":"input_text","text":"Script completed"},
                   {"type":"input_text","text":"/Users/m/Desktop"}]}}
        """#))
        XCTAssertEqual(output.fragments.first?.role, .toolResult)
        XCTAssertEqual(output.fragments.first?.toolUseID, "call_JTorNyiN",
                       "sans cet identifiant, le condensé apparie par POSITION")
        XCTAssertTrue(output.fragments.first?.text.contains("/Users/m/Desktop") == true)
    }

    /// `isError` reste NIL : le rollout ne porte aucun verdict d'échec, et le
    /// deviner en cherchant « error » dans la sortie a été mesuré à 5× trop de
    /// faux positifs côté Claude. Une information absente reste absente.
    func testToolOutputNeverInventsAnErrorVerdict() throws {
        let l = try XCTUnwrap(line(#"""
        {"type":"response_item","payload":{"type":"custom_tool_call_output","id":"c",
         "call_id":"x","output":[{"type":"input_text","text":"error: file not found"}]}}
        """#))
        XCTAssertNil(l.fragments.first?.isError)
    }

    // MARK: - Les deux pièges qui rempliraient la base de bruit

    /// PIÈGE N° 2 : `encrypted_content` est du chiffré. L'indexer noierait la
    /// base sous du base64 illisible et pèserait sur chaque recherche.
    func testEncryptedReasoningIsNeverIndexed() {
        XCTAssertNil(line(#"""
        {"type":"response_item","payload":{"type":"reasoning","id":"rs_1","summary":[],
         "encrypted_content":"gAAAAABqoSURXyGnH32yrN8Mxkcdt04fhzumcGY8au3Q9_hGVtO93KgFFXfTyivVVz5"}}
        """#))
    }

    func testReasoningSummaryIsIndexedWhenPresent() throws {
        let l = try XCTUnwrap(line(#"""
        {"type":"response_item","payload":{"type":"reasoning","id":"rs_2",
         "summary":[{"type":"summary_text","text":"Je vérifie d'abord la config chargée."}],
         "encrypted_content":"gAAAAAB…"}}
        """#))
        XCTAssertEqual(l.fragments.first?.role, .thinking)
        XCTAssertEqual(l.fragments.first?.text, "Je vérifie d'abord la config chargée.")
        XCTAssertFalse(l.fragments.first?.text.contains("gAAAAAB") == true)
    }

    /// PIÈGE N° 1 : `event_msg` reporte le contenu que `response_item` porte
    /// déjà. Tout lire, c'est indexer chaque conversation DEUX fois.
    func testEventMessagesAreDroppedAsDuplicates() {
        XCTAssertNil(line(#"""
        {"type":"event_msg","payload":{"type":"item_completed","thread_id":"t","turn_id":"u",
         "item":{"type":"UserMessage","id":"i","content":[{"type":"text","text":"Bonjour"}]}}}
        """#))
        XCTAssertNil(line(#"""
        {"type":"event_msg","payload":{"type":"task_complete","turn_id":"u",
         "last_agent_message":"Rapport ajouté."}}
        """#))
    }

    func testTelemetryLinesAreDropped() {
        for kind in ["token_usage_record", "world_state", "turn_context"] {
            XCTAssertNil(line("{\"type\":\"\(kind)\",\"payload\":{\"a\":1}}"), kind)
        }
    }

    // MARK: - Défense

    /// Format interne et instable (règle n° 3) : rien ne doit lever, rien ne
    /// doit interrompre l'ingestion.
    func testMalformedLinesAreSurvivedNotThrown() {
        for raw in ["", "pas du json", "[]", "{}", #"{"type":"response_item"}"#,
                    #"{"payload":{"type":"message"}}"#,
                    #"{"type":"response_item","payload":{"type":"message","role":"user"}}"#,
                    #"{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}"#,
                    #"{"type":"response_item","payload":{"type":"inconnu_demain"}}"#] {
            XCTAssertNil(line(raw), raw.isEmpty ? "(vide)" : raw)
        }
    }

    /// Une sortie d'outil de plusieurs mégaoctets ne doit pas entrer telle
    /// quelle dans l'index.
    func testHugeToolOutputIsBounded() throws {
        let huge = String(repeating: "A", count: 50_000)
        let l = try XCTUnwrap(line(#"""
        {"type":"response_item","payload":{"type":"custom_tool_call_output","id":"c",
         "call_id":"x","output":[{"type":"input_text","text":"\#(huge)"}]}}
        """#))
        XCTAssertLessThan(l.fragments.first?.text.count ?? .max, 2_100)
    }
}

/// L'horodatage d'un nom de rollout contient des tirets, comme l'uuid : un
/// découpage naïf sur `-` mélangerait les deux.
final class CodexRolloutNameTests: XCTestCase {
    func testSessionIdIsExtractedByShapeNotByPosition() {
        XCTAssertEqual(
            CodexRollout.sessionID(fromFileName:
                "rollout-2026-09-09T11-19-38-01a08577-386d-72c0-90ac-54eabd344ec1.jsonl"),
            "01a08577-386d-72c0-90ac-54eabd344ec1")
    }

    func testUnknownShapeFallsBackToTheStemInsteadOfDroppingTheFile() {
        // Règle n° 3 : le format ne nous appartient pas. Mieux vaut un
        // identifiant inhabituel qu'un fichier jamais indexé.
        XCTAssertEqual(CodexRollout.sessionID(fromFileName: "autre-nom.jsonl"), "autre-nom")
        XCTAssertEqual(CodexRollout.sessionID(fromFileName: ".jsonl"), ".jsonl")
    }

    func testRealFileNamesFromDiskAreAllRecognised() throws {
        let root = BridgePaths.codexSessionsURL
        guard FileManager.default.fileExists(atPath: root.path),
              let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { throw XCTSkip("aucun rollout Codex sur cette machine") }
        var checked = 0
        for case let file as URL in walker where file.pathExtension == "jsonl" {
            let id = CodexRollout.sessionID(fromFileName: file.lastPathComponent)
            XCTAssertEqual(id.count, 36, "nom non reconnu : \(file.lastPathComponent)")
            checked += 1
            if checked >= 30 { break }
        }
        XCTAssertGreaterThan(checked, 0)
    }
}

extension CodexTranscriptParserTests {
    /// L'horodatage est sur l'ENVELOPPE, pas dans le payload. L'oublier faisait
    /// afficher « date inconnue » sur chaque extrait Codex du recall — et la
    /// récence, que `MemoryRanking` pondère à 0,25, entrait à l'aveugle.
    func testEnvelopeTimestampIsRead() throws {
        let l = try XCTUnwrap(line(#"""
        {"type":"response_item","timestamp":"2026-09-09T09:19:41.482Z","ordinal":3,
         "payload":{"type":"message","role":"assistant","id":"m",
         "content":[{"type":"output_text","text":"Réponse."}]}}
        """#))
        XCTAssertNotNil(l.timestamp, "date inconnue sur tous les extraits Codex")
        XCTAssertEqual(l.timestamp?.timeIntervalSince1970 ?? 0, 1788945581.482, accuracy: 1)
    }

    func testMissingEnvelopeTimestampStaysNilRatherThanInvented() throws {
        let l = try XCTUnwrap(line(#"""
        {"type":"response_item","payload":{"type":"message","role":"user","id":"m",
         "content":[{"type":"input_text","text":"Bonjour"}]}}
        """#))
        XCTAssertNil(l.timestamp)
    }
}
