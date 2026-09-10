import XCTest
@testable import AtollCore

final class CodexIntegrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func envelope(_ kind: String, extra: [String: Any] = [:]) -> [String: Any] {
        var payload: [String: Any] = ["hook_event_name": kind, "session_id": "same-id", "cwd": "/tmp/project"]
        payload.merge(extra) { _, new in new }
        return ["provider": "codex", "payload": payload]
    }

    func testProviderIsolationAndLegacyCompatibility() throws {
        let wire = envelope("PermissionRequest")
        XCTAssertNil(ParsedHookEvent(envelope: wire))
        XCTAssertEqual(CodexHookEvent(envelope: wire)?.sessionID, "codex:same-id")
        var legacy = wire
        legacy.removeValue(forKey: "provider")
        XCTAssertNotNil(ParsedHookEvent(envelope: legacy))
        XCTAssertNil(CodexHookEvent(envelope: legacy))
        legacy["provider"] = "future-provider"
        XCTAssertNil(ParsedHookEvent(envelope: legacy))
        XCTAssertNil(CodexHookEvent(envelope: legacy))
        legacy["provider"] = NSNull()
        XCTAssertNil(ParsedHookEvent(envelope: legacy))
        XCTAssertEqual(AgentSession(projectName: "legacy", status: .done).provider, .claude)
    }

    func testRejectsInvalidPayloadsAndKeepsChildIdentity() {
        XCTAssertNil(CodexHookEvent(envelope: [:]))
        XCTAssertNil(CodexHookEvent(envelope: envelope("FutureEvent")))
        XCTAssertEqual(CodexHookEvent(envelope: envelope("Stop", extra: ["agent_id": "child"]))?.agentID, "child")
        XCTAssertNil(CodexHookEvent(envelope: envelope("SubagentStart")))
        XCTAssertNil(CodexHookEvent(envelope: envelope("SessionStart", extra: ["session_id": ""])))
        XCTAssertNotNil(CodexHookEvent(envelope: envelope("SessionStart", extra: ["transcript_path": NSNull()])))
    }

    func testMainLifecycleAndNativePermissionObservation() throws {
        var sessions = CodexSessions()
        func apply(_ kind: String, extra: [String: Any] = [:]) throws {
            sessions.apply(try XCTUnwrap(CodexHookEvent(envelope: envelope(kind, extra: extra))), now: now)
        }
        try apply("SessionStart", extra: ["model": "gpt-6"])
        XCTAssertEqual(sessions.sessions(now: now).first?.provider, .codex)
        XCTAssertEqual(sessions.sessions(now: now).first?.model, "gpt-6")
        try apply("UserPromptSubmit", extra: ["prompt": "bonjour", "turn_id": "t1"])
        XCTAssertTrue(try XCTUnwrap(sessions.sessions(now: now).first).isActive)
        try apply("PermissionRequest", extra: ["tool_name": "Bash", "tool_input": ["command": "git push"]])
        XCTAssertEqual(sessions.sessions(now: now).first?.status, .awaitingPermission(tool: "Bash(git push)"))
        try apply("PostToolUse")
        XCTAssertTrue(try XCTUnwrap(sessions.sessions(now: now).first).isActive)
        try apply("Stop")
        XCTAssertEqual(sessions.sessions(now: now).first?.status, .awaitingInput)
        try apply("SessionEnd")
        XCTAssertTrue(sessions.sessions(now: now).isEmpty)
    }

    func testInterruptAndOldTurnStop() throws {
        var sessions = CodexSessions()
        for (kind, turn) in [("UserPromptSubmit", "old"), ("UserPromptSubmit", "new"), ("Stop", "old")] {
            sessions.apply(try XCTUnwrap(CodexHookEvent(envelope: envelope(kind, extra: ["turn_id": turn]))), now: now)
        }
        XCTAssertTrue(try XCTUnwrap(sessions.sessions(now: now).first).isActive)
        sessions.apply(try XCTUnwrap(CodexHookEvent(envelope: envelope("Interrupt", extra: ["turn_id": "new"]))), now: now)
        XCTAssertEqual(sessions.sessions(now: now).first?.status, .awaitingInput)
    }

    func testSilenceNeverLeavesPermanentAttention() throws {
        var sessions = CodexSessions()
        sessions.apply(try XCTUnwrap(CodexHookEvent(envelope: envelope("PermissionRequest"))), now: now)
        let stale = try XCTUnwrap(sessions.sessions(now: now.addingTimeInterval(121)).first)
        XCTAssertFalse(stale.needsAttention)
        XCTAssertFalse(stale.stateConfirmedByHook)
        sessions.prune(now: now.addingTimeInterval(86_401))
        XCTAssertTrue(sessions.sessions(now: now.addingTimeInterval(86_401)).isEmpty)
    }

    func testLongActivityBecomesUnknownNotConfirmedIdle() throws {
        var sessions = CodexSessions()
        sessions.apply(try XCTUnwrap(CodexHookEvent(envelope: envelope("PreToolUse"))), now: now)
        XCTAssertTrue(try XCTUnwrap(sessions.sessions(now: now.addingTimeInterval(899)).first).isActive)
        XCTAssertFalse(try XCTUnwrap(sessions.sessions(now: now.addingTimeInterval(901)).first).stateConfirmedByHook)
    }

    func testHooksInstallIdempotentAndUninstallPreservesForeignHandlers() throws {
        let original = Data(#"{"description":"mine","other":true,"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"my-script"}]}],"FutureEvent":[{"custom":true}]}}"#.utf8)
        let installed = try CodexHookSettingsEditor.edit(original, install: true)
        XCTAssertTrue(CodexHookSettingsEditor.isInstalled(installed))
        XCTAssertEqual(installed, try CodexHookSettingsEditor.edit(installed, install: true))
        let removed = try CodexHookSettingsEditor.edit(installed, install: false)
        XCTAssertFalse(CodexHookSettingsEditor.isInstalled(removed))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: original) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: removed) as? NSDictionary)
    }

    func testHookEditorNeverOverwritesMalformedConfig() {
        for raw in ["not json", "[]", #"{"hooks":[]}"#, #"{"hooks":{"Stop":42}}"#,
                    #"{"hooks":{"Stop":[{"hooks":"oops"}]}}"#] {
            XCTAssertThrowsError(try CodexHookSettingsEditor.edit(Data(raw.utf8), install: true))
        }
    }

    func testManagedHandlerRemovedWithoutRemovingItsNeighbours() throws {
        let root: [String: Any] = ["hooks": ["Stop": [["matcher": "*", "hooks": [
            ["command": CodexHookSettingsEditor.command], ["command": "echo atoll-codex-bridge"]
        ]]]]]
        let data = try JSONSerialization.data(withJSONObject: root)
        let removed = try CodexHookSettingsEditor.edit(data, install: false)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: removed) as? [String: Any])
        let hooks = try XCTUnwrap(decoded["hooks"] as? [String: [[String: Any]]])
        let group = try XCTUnwrap(hooks["Stop"]?.first)
        XCTAssertEqual((group["hooks"] as? [[String: String]])?.first?["command"], "echo atoll-codex-bridge")
    }

    /// ⚠️ L'ATTENTE `async == nil` A ÉTÉ RETIRÉE ICI le 2026-09-09, et ce n'est
    /// pas un détail : elle figeait un choix de conception explicite de la PR
    /// (« les hooks sont synchrones pour garder leur ordre »). Ce qui l'a
    /// renversé est une MESURE, pas une préférence — un hook synchrone est
    /// ANNONCÉ par Codex dans sa sortie, soit dix lignes de bruit par tour d'un
    /// seul outil, infligées en permanence dès l'installation. La règle n° 1 du
    /// projet tranche : rien de ce qu'Atoll installe ne doit gêner le CLI.
    ///
    /// CE QU'ON PERD, et qu'il faut assumer : l'ordre d'arrivée n'est plus
    /// garanti entre hooks async. Sans conséquence connue — le seul état que
    /// l'ordre protège est « quel outil tourne », transitoire et cosmétique, et
    /// la fin de tour (`Stop`) reste synchrone précisément pour ne jamais être
    /// perdue. Le garde de tour (`turn_id`) couvre déjà le vrai risque.
    ///
    /// Ce que le test continue de garantir, et qui EST son intention : les
    /// hooks restent bornés (timeout 3 s) et purement observateurs.
    func testInstalledHooksAreBoundedObservationOnly() throws {
        let data = try CodexHookSettingsEditor.edit(nil, install: true)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(root["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(hooks.count, CodexHookEvent.Kind.allCases.count)
        for (event, groups) in hooks {
            let handler = try XCTUnwrap((groups.first?["hooks"] as? [[String: Any]])?.first)
            // Les hooks d'OBSERVATION restent bornés à 3 s — ils ne demandent
            // rien à personne. Seul `PermissionRequest` attend une décision
            // HUMAINE : lui imposer 3 s reviendrait à ne jamais laisser à Mehdi
            // le temps de cliquer, donc à toujours s'abstenir (2026-09-09).
            XCTAssertEqual(handler["timeout"] as? Int, event == "PermissionRequest" ? 600 : 3, event)
            // Aucun handler ne réclame de sortie ni de décision : le contrat
            // d'observation de la PR est intact.
            XCTAssertNil(handler["decision"], event)
            XCTAssertEqual(handler["type"] as? String, "command", event)
        }
    }
}
