import XCTest
@testable import AtollCore

final class SessionReducerTests: XCTestCase {

    private func event(
        _ kind: ParsedHookEvent.Kind,
        tool: String? = nil,
        toolInput: [String: Any]? = nil,
        notificationType: String? = nil,
        reason: String? = nil
    ) -> ParsedHookEvent {
        var payload: [String: Any] = [
            "hook_event_name": kind.rawValue,
            "session_id": "s-1",
            "transcript_path": "/tmp/t.jsonl",
            "cwd": "/Users/x/proj",
        ]
        if let tool { payload["tool_name"] = tool }
        if let toolInput { payload["tool_input"] = toolInput }
        if let notificationType { payload["notification_type"] = notificationType }
        if let reason { payload["reason"] = reason }
        return ParsedHookEvent(envelope: ["v": 1, "payload": payload])!
    }

    func testHappyPathLifecycle() {
        var phase = SessionPhase.starting
        phase = SessionReducer.reduce(phase, event(.sessionStart))
        XCTAssertEqual(phase, .waitingInput)
        phase = SessionReducer.reduce(phase, event(.userPromptSubmit))
        XCTAssertEqual(phase, .busy)
        phase = SessionReducer.reduce(phase, event(.preToolUse, tool: "Bash", toolInput: ["command": "ls"]))
        XCTAssertEqual(phase, .toolRunning(tool: "Bash(ls)"))
        phase = SessionReducer.reduce(phase, event(.postToolUse, tool: "Bash"))
        XCTAssertEqual(phase, .busy)
        phase = SessionReducer.reduce(phase, event(.stop))
        XCTAssertEqual(phase, .waitingInput)
        phase = SessionReducer.reduce(phase, event(.sessionEnd, reason: "other"))
        XCTAssertEqual(phase, .ended)
    }

    func testPermissionFlowViaNotification() {
        var phase = SessionPhase.busy
        phase = SessionReducer.reduce(phase, event(.notification, tool: "Edit", notificationType: "permission_prompt"))
        XCTAssertEqual(phase, .waitingPermission(tool: "Edit"))
        // L'utilisateur répond dans le terminal → l'outil s'exécute.
        phase = SessionReducer.reduce(phase, event(.postToolUse, tool: "Edit"))
        XCTAssertEqual(phase, .busy)
    }

    func testPermissionDeniedReturnsToBusy() {
        let phase = SessionReducer.reduce(.waitingPermission(tool: "Bash(rm x)"), event(.permissionDenied, tool: "Bash"))
        XCTAssertEqual(phase, .busy)
    }

    func testUnknownNotificationTypeKeepsPhase() {
        let phase = SessionReducer.reduce(.busy, event(.notification, notificationType: "auth_success"))
        XCTAssertEqual(phase, .busy)
    }

    func testCompactCycle() {
        var phase = SessionReducer.reduce(.busy, event(.preCompact))
        XCTAssertEqual(phase, .compacting)
        phase = SessionReducer.reduce(phase, event(.postCompact))
        XCTAssertEqual(phase, .busy)
    }

    func testEndedIsTerminal() {
        for kind in ParsedHookEvent.Kind.allCases {
            XCTAssertEqual(SessionReducer.reduce(.ended, event(kind)), .ended,
                           "\(kind) ne doit pas ressusciter une session terminée")
        }
    }

    func testSubagentEventsKeepBusy() {
        XCTAssertEqual(SessionReducer.reduce(.busy, event(.subagentStart)), .busy)
        XCTAssertEqual(SessionReducer.reduce(.toolRunning(tool: "Task"), event(.subagentStop)), .busy)
    }

    func testLateCompletionEventsDoNotStrandWaitingInput() {
        // Un PostToolUse tardif (outil asynchrone) après Stop ne doit pas
        // remettre un spinner sans porte de sortie.
        XCTAssertEqual(SessionReducer.reduce(.waitingInput, event(.postToolUse, tool: "Bash")), .waitingInput)
        XCTAssertEqual(SessionReducer.reduce(.waitingInput, event(.subagentStop)), .waitingInput)
        XCTAssertEqual(SessionReducer.reduce(.waitingInput, event(.permissionDenied)), .waitingInput)
    }

    func testUIStatusProjection() {
        XCTAssertEqual(SessionPhase.toolRunning(tool: "Bash(ls)").uiStatus, .working(tool: "Bash(ls)"))
        XCTAssertEqual(SessionPhase.waitingPermission(tool: nil).uiStatus, .awaitingPermission(tool: "permission"))
        XCTAssertEqual(SessionPhase.waitingInput.uiStatus, .awaitingInput)
        XCTAssertEqual(SessionPhase.ended.uiStatus, .done)
        XCTAssertFalse(SessionPhase.ended.isAlive)
    }

    // MARK: - L'attente de décision ne se quitte pas sur n'importe quoi (2026-08-14)

    /// Les hooks d'outil d'un SOUS-AGENT portent le `session_id` du PARENT.
    /// La v0.16.1 a protégé la CARTE d'être effacée par eux, mais pas la PHASE :
    /// l'îlot cessait d'alerter pendant qu'un helper restait bloqué.
    func testUnSousAgentNeQuittePasLAttenteDeDecision() {
        let attente = SessionPhase.waitingPermission(tool: "Bash")
        for kind in [ParsedHookEvent.Kind.subagentStart, .subagentStop] {
            XCTAssertEqual(SessionReducer.reduce(attente, event(kind)), attente,
                           "\(kind) ne prouve rien sur la session parente")
        }
        // Un outil DIFFÉRENT ne prouve rien non plus : c'est le sous-agent.
        XCTAssertEqual(SessionReducer.reduce(attente, event(.postToolUse, tool: "Read")), attente)
        // Ni un événement sans nom d'outil exploitable — l'ambiguïté ne quitte rien.
        XCTAssertEqual(SessionReducer.reduce(attente, event(.postToolUse)), attente)
    }

    /// Le MÊME outil, lui, prouve que la demande a été tranchée ailleurs.
    func testLeMemeOutilQuitteLAttente() {
        let attente = SessionPhase.waitingPermission(tool: "Bash")
        XCTAssertEqual(SessionReducer.reduce(attente, event(.postToolUse, tool: "Bash")), .busy)
    }

    /// `permissionDenied` PROUVE la décision, quel que soit l'outil rapporté.
    func testUnRefusQuitteToujoursLAttente() {
        let attente = SessionPhase.waitingPermission(tool: "Bash")
        XCTAssertEqual(SessionReducer.reduce(attente, event(.permissionDenied)), .busy)
        XCTAssertEqual(SessionReducer.reduce(attente, event(.permissionDenied, tool: "Read")), .busy)
    }

    /// Les quatre événements qui prouvent que la session a avancé continuent de
    /// sortir de l'attente — le correctif ne doit rien bloquer.
    func testLesEvenementsDeProgresSortentToujours() {
        let attente = SessionPhase.waitingPermission(tool: "Bash")
        XCTAssertEqual(SessionReducer.reduce(attente, event(.stop)), .waitingInput)
        XCTAssertEqual(SessionReducer.reduce(attente, event(.userPromptSubmit)), .busy)
        XCTAssertEqual(SessionReducer.reduce(attente, event(.sessionEnd)), .ended)
    }

    /// Hors attente de décision, rien ne change.
    func testHorsAttenteLeComportementEstInchange() {
        XCTAssertEqual(SessionReducer.reduce(.busy, event(.subagentStop)), .busy)
        XCTAssertEqual(SessionReducer.reduce(.waitingInput, event(.postToolUse)), .waitingInput)
        XCTAssertEqual(SessionReducer.reduce(.toolRunning(tool: "Bash"), event(.postToolUse, tool: "Bash")), .busy)
    }

    // MARK: - Les deux fautes que la revue a trouvées DANS le correctif

    /// `preToolUse` est l'événement de sous-agent le PLUS fréquent, et il arrive
    /// AVANT `postToolUse` : ne garder que la complétion laissait la faille
    /// grande ouverte.
    func testUnPreToolUseDeSousAgentNeQuittePasLAttente() {
        let attente = SessionPhase.waitingPermission(tool: "Bash(git push)")
        XCTAssertEqual(SessionReducer.reduce(attente, event(.preToolUse, tool: "Read")), attente)
        XCTAssertEqual(SessionReducer.reduce(attente, event(.preToolUse)), attente)
        // Le MÊME outil, lui, passe : c'est l'approbation qui a été honorée.
        XCTAssertEqual(SessionReducer.reduce(attente, event(.preToolUse, tool: "Bash")),
                       .toolRunning(tool: "Bash"))
    }

    /// LE DISCRIMINANT EST LE NOM D'OUTIL, PAS LE RÉSUMÉ.
    ///
    /// La phase mémorise `toolSummary`, qui inclut les ARGUMENTS
    /// (« Bash(git push) »). Comparer des résumés faisait échouer TOUTE sortie
    /// légitime — l'événement de complétion ne porte pas les mêmes arguments —
    /// et la session serait restée en alerte pour toujours.
    func testLaSortieCompareLeNomDoutilEtNonLeResume() {
        let attente = SessionPhase.waitingPermission(tool: "Bash(git push --force)")
        XCTAssertEqual(SessionReducer.reduce(attente, event(.postToolUse, tool: "Bash")), .busy,
                       "le même OUTIL doit sortir, quels que soient les arguments mémorisés")
        XCTAssertEqual(
            SessionReducer.reduce(attente, event(.postToolUse, tool: "Bash",
                                                 toolInput: ["command": "git status"])),
            .busy)
    }

    /// Le nom porté par un résumé est lu là où il est construit.
    func testNomDoutilExtraitDunResume() {
        XCTAssertEqual(ParsedHookEvent.toolName(ofSummary: "Bash(git push)"), "Bash")
        XCTAssertEqual(ParsedHookEvent.toolName(ofSummary: "Read"), "Read")
        XCTAssertEqual(ParsedHookEvent.toolName(ofSummary: ""), "")
    }
}
