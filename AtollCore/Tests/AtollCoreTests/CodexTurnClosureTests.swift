import XCTest
@testable import AtollCore

/// DÉFAUT TROUVÉ PAR CODEX le 2026-09-09, sur sa propre machine à états, et
/// introduit par le passage des hooks en `async` : `Stop` reste synchrone, ce
/// qui garantit sa LIVRAISON — pas qu'il arrive après les processus async déjà
/// lancés. Les deux premiers tests sont ceux qu'il a spécifiés.
final class CodexTurnClosureTests: XCTestCase {

    private func event(_ kind: String, turn: String?, session: String = "s1",
                       tool: String? = nil, prompt: String? = nil) -> CodexHookEvent {
        var payload: [String: Any] = ["hook_event_name": kind, "session_id": session,
                                      "cwd": "/tmp/projet"]
        if let turn { payload["turn_id"] = turn }
        if let tool { payload["tool_name"] = tool }
        if let prompt { payload["prompt"] = prompt }
        return CodexHookEvent(envelope: ["v": 1, "provider": "codex", "payload": payload])!
    }

    private func status(_ sessions: CodexSessions) -> AgentSession.Status? {
        sessions.sessions().first?.status
    }

    // MARK: - Les deux cas spécifiés par Codex

    /// « `Stop(t1)` puis `PreToolUse(t1)` » — un retardataire du MÊME tour
    /// passait le garde et remettait la session en activité, pour quinze
    /// minutes jusqu'à la péremption.
    func testALateEventOfAClosedTurnCannotReopenIt() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "fais ça"))
        sessions.apply(event("Stop", turn: "t1"))
        XCTAssertEqual(status(sessions), .awaitingInput)

        sessions.apply(event("PreToolUse", turn: "t1", tool: "Bash"))
        XCTAssertEqual(status(sessions), .awaitingInput, "un tour clos a été rouvert")

        // Les autres branches d'activité doivent être fermées de même.
        for kind in ["PostToolUse", "PreCompact", "PostCompact", "PermissionRequest"] {
            sessions.apply(event(kind, turn: "t1", tool: "Bash"))
            XCTAssertEqual(status(sessions), .awaitingInput, "rouvert par \(kind)")
        }
    }

    /// « `UserPromptSubmit(t2)` puis ancien `UserPromptSubmit(t1)` après clôture
    /// de `t1` » — LE CAS GRAVE : cette branche est exemptée du garde de tour,
    /// donc le retardataire replaçait `entry.turnID` sur le tour mort, et tous
    /// les événements du vrai tour étaient ensuite rejetés. Session figée.
    func testALateUserPromptOfAClosedTurnCannotHijackTheCurrentOne() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "premier"))
        sessions.apply(event("Stop", turn: "t1"))
        sessions.apply(event("UserPromptSubmit", turn: "t2", prompt: "second"))
        XCTAssertEqual(sessions.sessions().first?.subtitle, "second")

        // Le retardataire de t1 ne doit ni reprendre le tour, ni changer le titre…
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "premier"))
        XCTAssertEqual(sessions.sessions().first?.subtitle, "second",
                       "un prompt d'un tour mort a repris la main")

        // …et surtout, le VRAI tour courant doit continuer d'être accepté.
        sessions.apply(event("PreToolUse", turn: "t2", tool: "Bash"))
        XCTAssertEqual(status(sessions), .working(tool: "Bash"),
                       "la session est figée : t2 n'est plus accepté")
    }

    // MARK: - Cas de bord

    /// Un retardataire SANS `turn_id` passe les deux gardes de tour : il faut
    /// que l'état terminal le retienne, sinon l'activité repart toute seule.
    func testAnEventWithoutTurnIdCannotReopenAClosedTurn() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "p"))
        sessions.apply(event("Stop", turn: "t1"))
        sessions.apply(event("PostToolUse", turn: nil, tool: "Bash"))
        XCTAssertEqual(status(sessions), .awaitingInput)
    }

    /// Une interruption clôt le tour aussi sûrement qu'un `Stop`.
    func testInterruptClosesTheTurnToo() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "p"))
        sessions.apply(event("Interrupt", turn: "t1"))
        sessions.apply(event("PreToolUse", turn: "t1", tool: "Bash"))
        XCTAssertEqual(status(sessions), .awaitingInput)
    }

    /// La clôture ne doit pas GELER la session : un nouveau prompt rouvre.
    func testANewPromptReopensActivity() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1", prompt: "p1"))
        sessions.apply(event("Stop", turn: "t1"))
        sessions.apply(event("UserPromptSubmit", turn: "t2", prompt: "p2"))
        XCTAssertEqual(status(sessions), .working(tool: nil))
        sessions.apply(event("PreToolUse", turn: "t2", tool: "Grep"))
        XCTAssertEqual(status(sessions), .working(tool: "Grep"))
    }

    /// La mémoire des tours clos est BORNÉE : une session enchaîne des centaines
    /// de tours, elle ne doit pas croître avec eux.
    func testClosedTurnMemoryIsBounded() {
        var sessions = CodexSessions()
        for index in 0..<40 {
            sessions.apply(event("UserPromptSubmit", turn: "t\(index)", prompt: "p"))
            sessions.apply(event("Stop", turn: "t\(index)"))
        }
        // Le tour le plus récent reste protégé…
        sessions.apply(event("PreToolUse", turn: "t39", tool: "Bash"))
        XCTAssertEqual(status(sessions), .awaitingInput)
        // …et la session répond toujours normalement à un nouveau tour.
        sessions.apply(event("UserPromptSubmit", turn: "t40", prompt: "encore"))
        XCTAssertEqual(status(sessions), .working(tool: nil))
    }

    /// Deux sessions n'ont pas la même comptabilité de tours.
    func testTurnClosureIsPerSession() {
        var sessions = CodexSessions()
        sessions.apply(event("UserPromptSubmit", turn: "t1", session: "a", prompt: "p"))
        sessions.apply(event("Stop", turn: "t1", session: "a"))
        sessions.apply(event("UserPromptSubmit", turn: "t1", session: "b", prompt: "p"))
        sessions.apply(event("PreToolUse", turn: "t1", session: "b", tool: "Bash"))
        let b = sessions.sessions().first { $0.id == "codex:b" }
        XCTAssertEqual(b?.status, .working(tool: "Bash"),
                       "la clôture d'une session a contaminé l'autre")
    }
}
