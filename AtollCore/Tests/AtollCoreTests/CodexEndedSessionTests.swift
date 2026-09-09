import XCTest
@testable import AtollCore

/// Les faits qu'une session Codex terminée doit rendre au bilan de fin de
/// session. Sans eux, fermer Claude Code éteint toute la boucle d'apprentissage
/// — zéro note, zéro skill (constat du 2026-09-09).
final class CodexEndedSessionTests: XCTestCase {

    private func event(_ kind: String, turn: String? = "t1", prompt: String? = nil,
                       path: String? = "/Users/m/.codex/sessions/2026/09/09/rollout-x.jsonl",
                       cwd: String? = "/Users/m/projet", model: String? = "gpt-6-astra")
    -> CodexHookEvent {
        var payload: [String: Any] = ["hook_event_name": kind, "session_id": "s1"]
        if let turn { payload["turn_id"] = turn }
        if let prompt { payload["prompt"] = prompt }
        if let path { payload["transcript_path"] = path }
        if let cwd { payload["cwd"] = cwd }
        if let model { payload["model"] = model }
        return CodexHookEvent(envelope: ["v": 1, "provider": "codex", "payload": payload])!
    }

    func testSessionEndYieldsTheFactsTheGateNeeds() throws {
        var sessions = CodexSessions()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        sessions.apply(event("SessionStart", turn: nil), now: start)
        sessions.apply(event("UserPromptSubmit", prompt: "un"), now: start)
        sessions.apply(event("Stop"), now: start)
        sessions.apply(event("UserPromptSubmit", turn: "t2", prompt: "deux"), now: start)

        let ended = try XCTUnwrap(sessions.apply(event("SessionEnd", turn: nil)))
        XCTAssertEqual(ended.sessionID, "codex:s1")
        XCTAssertEqual(ended.transcriptPath, "/Users/m/.codex/sessions/2026/09/09/rollout-x.jsonl")
        XCTAssertEqual(ended.cwd, "/Users/m/projet")
        XCTAssertEqual(ended.model, "gpt-6-astra")
        XCTAssertEqual(ended.startedAt, start)
        // COMPTÉS, jamais devinés : `LearningGate` refuse une session qui n'a
        // pas assez de prompts, et une valeur inventée fausserait sa décision
        // dans le sens le plus coûteux — lancer une analyse pour rien.
        XCTAssertEqual(ended.userPromptCount, 2)
    }

    /// Seule la fin rend des faits ; tout le reste rend `nil`, sinon chaque
    /// événement enfilerait un bilan payant.
    func testOnlySessionEndYieldsFacts() {
        var sessions = CodexSessions()
        for kind in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                     "Stop", "Interrupt", "PermissionRequest", "PreCompact", "PostCompact"] {
            XCTAssertNil(sessions.apply(event(kind)), kind)
        }
        XCTAssertNotNil(sessions.apply(event("SessionEnd", turn: nil)))
    }

    /// La fin d'une session jamais vue ne doit rien déclencher : il n'y a aucun
    /// fait à analyser, et un chemin de transcript seul n'en fait pas une.
    func testEndOfAnUnknownSessionYieldsNothing() {
        var sessions = CodexSessions()
        XCTAssertNil(sessions.apply(event("SessionEnd", turn: nil)))
    }

    /// Le chemin de l'événement de FIN fait autorité ; on se rabat sur le
    /// dernier connu quand il manque, plutôt que de perdre le rollout.
    func testTranscriptPathFallsBackToTheLastKnownOne() throws {
        var sessions = CodexSessions()
        sessions.apply(event("SessionStart", turn: nil, path: "/chemin/connu.jsonl"))
        let ended = try XCTUnwrap(sessions.apply(event("SessionEnd", turn: nil, path: nil)))
        XCTAssertEqual(ended.transcriptPath, "/chemin/connu.jsonl")
    }

    /// Une session sans rollout connu ne doit pas prétendre en avoir un :
    /// l'appelant s'abstient plutôt que d'analyser un fichier deviné — c'est la
    /// raison pour laquelle les sessions synthétiques sont exclues côté Claude.
    func testNoTranscriptPathStaysNil() throws {
        var sessions = CodexSessions()
        sessions.apply(event("SessionStart", turn: nil, path: nil))
        let ended = try XCTUnwrap(sessions.apply(event("SessionEnd", turn: nil, path: nil)))
        XCTAssertNil(ended.transcriptPath)
    }

    /// Les prompts d'un tour CLOS ne comptent pas deux fois : la clôture
    /// monotone doit aussi tenir sur ce compteur.
    func testLatePromptOfAClosedTurnIsNotCounted() throws {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", prompt: "un"))
        sessions.apply(event("Stop"))
        sessions.apply(event("UserPromptSubmit", prompt: "un")) // retardataire de t1
        let ended = try XCTUnwrap(sessions.apply(event("SessionEnd", turn: nil)))
        XCTAssertEqual(ended.userPromptCount, 1, "un prompt d'un tour mort a été compté")
    }
}

/// Le condensé DOIT être lu par le parseur du bon fournisseur.
final class CodexDigestProviderTests: XCTestCase {

    /// Lignes verbatim d'un rollout réel (`codex-cli 0.153.4`).
    private let rollout = [
        #"{"type":"session_meta","timestamp":"2026-09-09T09:19:38.130Z","payload":{"session_id":"s","id":"s","timestamp":"2026-09-09T09:19:38.130Z","cwd":"/p"}}"#,
        #"{"type":"response_item","timestamp":"2026-09-09T09:20:00.000Z","payload":{"type":"message","role":"user","id":"m1","content":[{"type":"input_text","text":"Corrige la course de clôture des tours."}]}}"#,
        #"{"type":"response_item","timestamp":"2026-09-09T09:20:05.000Z","payload":{"type":"custom_tool_call","id":"c1","call_id":"k1","name":"exec","input":"swift test"}}"#,
        #"{"type":"response_item","timestamp":"2026-09-09T09:20:07.000Z","payload":{"type":"custom_tool_call_output","id":"o1","call_id":"k1","output":[{"type":"input_text","text":"852 tests, 0 failures"}]}}"#,
        #"{"type":"response_item","timestamp":"2026-09-09T09:20:09.000Z","payload":{"type":"message","role":"assistant","id":"m2","content":[{"type":"output_text","text":"La clôture est monotone, tous les tests passent."}]}}"#,
    ]

    private func lines(using codex: Bool) -> [TranscriptLine] {
        rollout.compactMap {
            codex ? CodexTranscriptParser.parse(Data($0.utf8))
                  : TranscriptLineParser.parse(Data($0.utf8))
        }
    }

    /// MESURÉ sur un rollout réel de 914 Ko : le parseur Claude en tire **0
    /// ligne, 0 entrée, 0 caractère**. Sans `Job.transcriptProvider`, le bilan
    /// partirait donc sur un condensé VIDE — et paierait un run pour rien.
    func testClaudeParserYieldsNothingOnACodexRollout() {
        let digest = TranscriptDigest.make(lines: lines(using: false))
        XCTAssertEqual(digest.entriesKept, 0)
        XCTAssertTrue(digest.text.isEmpty)
    }

    func testCodexParserFeedsTheDigestWithRealContent() {
        let digest = TranscriptDigest.make(lines: lines(using: true))
        XCTAssertGreaterThan(digest.entriesKept, 0)
        XCTAssertTrue(digest.text.contains("course de clôture"), "le prompt manque")
        // L'INVOCATION d'un outil qui a réussi est retenue ; sa SORTIE ne l'est
        // pas — c'est la règle du condensé côté Claude, et elle vaut ici sans
        // changement puisque le parseur produit le même type pivot.
        XCTAssertTrue(digest.text.contains("swift test"), "la commande réussie manque")
    }

    /// Une sortie d'outil en ÉCHEC, elle, doit être retenue : c'est le cœur du
    /// condensé (« ce qui a raté, et comment ça a été résolu »). Le rollout ne
    /// portant aucun verdict, la détection retombe sur le texte — même repli
    /// que côté Claude quand `is_error` est absent.
    func testFailedToolOutputIsKeptOnTheCodexPathToo() {
        let failing = #"{"type":"response_item","timestamp":"2026-09-09T09:21:00.000Z","payload":{"type":"custom_tool_call_output","id":"o2","call_id":"k2","output":[{"type":"input_text","text":"error: build failed with 3 errors"}]}}"#
        let lines = (rollout + [failing]).compactMap {
            CodexTranscriptParser.parse(Data($0.utf8))
        }
        let digest = TranscriptDigest.make(lines: lines)
        XCTAssertTrue(digest.text.contains("build failed"),
                      "un échec d'outil doit entrer dans le condensé")
    }
}
