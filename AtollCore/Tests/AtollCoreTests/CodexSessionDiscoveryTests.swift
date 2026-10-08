import XCTest
@testable import AtollCore

/// L'adoption ne doit JAMAIS écraser ce que les hooks savent.
final class CodexSessionDiscoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func hookEvent(_ kind: String, session: String = "s1") -> CodexHookEvent {
        CodexHookEvent(envelope: ["v": 1, "provider": "codex", "payload": [
            "hook_event_name": kind, "session_id": session, "turn_id": "t1",
            "cwd": "/p/codex", "tool_name": "shell",
        ]])!
    }

    func testAdoptedSessionsAreNotConfirmedByHook() throws {
        var sessions = CodexSessions()
        sessions.adopt([.init(sessionID: "codex:x", cwd: "/p/codex",
                              transcriptPath: "/r/x.jsonl", startedAt: now)])
        let session = try XCTUnwrap(sessions.sessions().first)
        // Non confirmée ⇒ l'îlot la range dans « EN COURS », qui ne réclame
        // aucune action — jamais dans « en attente de toi ».
        XCTAssertFalse(session.stateConfirmedByHook)
        XCTAssertEqual(session.status, .awaitingInput)
        XCTAssertEqual(sessions.transcriptPath(for: "codex:x"), "/r/x.jsonl")
    }

    /// LE POINT CRITIQUE : un scan ne sait ni quel outil tourne, ni si une
    /// autorisation attend. Écraser un état confirmé par une supposition est
    /// l'erreur que `stateConfirmedByHook` existe pour empêcher (v0.16.1).
    func testAdoptNeverOverwritesAHookKnownSession() throws {
        var sessions = CodexSessions()
        sessions.apply(hookEvent("UserPromptSubmit"))
        sessions.apply(hookEvent("PreToolUse"))
        XCTAssertEqual(sessions.sessions().first?.status, .working(tool: "shell"))

        sessions.adopt([.init(sessionID: "codex:s1", cwd: "/p/codex",
                              transcriptPath: "/r/autre.jsonl", startedAt: now)])
        let session = try XCTUnwrap(sessions.sessions().first)
        XCTAssertEqual(session.status, .working(tool: "shell"), "l'état confirmé a été écrasé")
        XCTAssertTrue(session.stateConfirmedByHook)
    }

    /// Une session adoptée qui reçoit ENSUITE un hook doit basculer sur les
    /// vraies données — c'est le pendant d'`isSynthetic → false` côté Claude.
    func testAHookUpgradesAnAdoptedSession() throws {
        var sessions = CodexSessions()
        sessions.adopt([.init(sessionID: "codex:s1", cwd: "/p/codex",
                              transcriptPath: "/r/x.jsonl", startedAt: now)])
        sessions.apply(hookEvent("UserPromptSubmit"))
        let session = try XCTUnwrap(sessions.sessions().first)
        XCTAssertTrue(session.stateConfirmedByHook)
        XCTAssertEqual(session.status, .working(tool: nil))
        XCTAssertEqual(sessions.sessions().count, 1, "la session a été dupliquée")
    }
}
