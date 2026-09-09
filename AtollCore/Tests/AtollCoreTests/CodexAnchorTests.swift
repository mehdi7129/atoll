import XCTest
@testable import AtollCore

/// Le jump-back doit être IDENTIQUE pour les deux fournisseurs : Mehdi a tranché
/// le 2026-09-09 que Codex tourne toujours dans un Cursor, comme Claude Code, et
/// que passer de l'un à l'autre doit être transparent.
final class CodexAnchorTests: XCTestCase {

    /// Environnement RÉEL d'un processus lancé dans le terminal de Cursor,
    /// relevé le 2026-09-09. C'est ce que le helper Codex capturera.
    private let cursorEnvironment = [
        "__CFBundleIdentifier": "com.todesktop.230313mzl4w4u92",
        "TERM_PROGRAM": "vscode",
        "TERM_PROGRAM_VERSION": "3.18.25",
    ]

    private func envelope(enrich: [String: Any]?, cwd: String? = "/Users/m/Desktop/Dynamic_Island",
                          event: String = "UserPromptSubmit") -> [String: Any] {
        var payload: [String: Any] = ["hook_event_name": event, "session_id": "abc",
                                      "turn_id": "t1", "model": "gpt-6-astra"]
        if let cwd { payload["cwd"] = cwd }
        var envelope: [String: Any] = ["v": 1, "provider": "codex", "payload": payload]
        if let enrich { envelope["enrich"] = enrich }
        return envelope
    }

    // MARK: - La liste des clés est PARTAGÉE

    /// Deux copies de cette liste, c'est la garantie qu'un jour l'une perdra une
    /// clé sans que personne ne le voie — le motif de `byCoverage` (v0.16.1).
    func testCaptureKeepsOnlyKnownKeysAndDropsTheRest() {
        let captured = TerminalAnchor.capture(from: cursorEnvironment.merging(
            ["SECRET_TOKEN": "nope", "HOME": "/Users/m"]) { a, _ in a })
        XCTAssertEqual(captured["__CFBundleIdentifier"], "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(captured["TERM_PROGRAM"], "vscode")
        XCTAssertNil(captured["SECRET_TOKEN"], "l'instantané doit rester BORNÉ")
        XCTAssertNil(captured["HOME"])
    }

    func testCaptureOfAnEmptyEnvironmentIsEmpty() {
        XCTAssertTrue(TerminalAnchor.capture(from: [:]).isEmpty)
    }

    // MARK: - L'ancre traverse l'enveloppe

    func testCursorAnchorSurvivesTheCodexEnvelope() throws {
        let event = try XCTUnwrap(CodexHookEvent(envelope: envelope(
            enrich: ["tty": "ttys012", "terminalHint": "com.todesktop.230313mzl4w4u92",
                     "env": cursorEnvironment])))
        let anchor = try XCTUnwrap(event.anchor)
        XCTAssertEqual(anchor.cwd, "/Users/m/Desktop/Dynamic_Island")
        XCTAssertEqual(anchor.tty, "ttys012")
        XCTAssertEqual(anchor.bundleID, "com.todesktop.230313mzl4w4u92")
        // `entrypoint` est propre à Claude Code : jamais inventé pour Codex.
        XCTAssertNil(anchor.entrypoint)
    }

    /// LE POINT DE TOUTE LA MANŒUVRE : le résolveur doit rendre Cursor pour une
    /// session Codex exactement comme pour une session Claude. Si ce test tombe,
    /// la transparence demandée par Mehdi n'existe plus.
    func testResolverPicksCursorForACodexSession() throws {
        let event = try XCTUnwrap(CodexHookEvent(envelope: envelope(
            enrich: ["terminalHint": "com.todesktop.230313mzl4w4u92", "env": cursorEnvironment])))
        let anchor = try XCTUnwrap(event.anchor)
        guard case .vscodeFamily(let cli) = TerminalResolver.resolve(anchor) else {
            return XCTFail("Cursor non reconnu pour une session Codex")
        }
        XCTAssertEqual(cli, "cursor")
    }

    // MARK: - Ce qu'on n'invente pas

    /// Une ancre sans aucun moyen d'identifier le terminal n'est pas fabriquée :
    /// le bouton resterait mort, ce que la leçon du bouton ARRÊTER interdit.
    func testNoAnchorWithoutAnyTerminalEvidence() throws {
        let bare = try XCTUnwrap(CodexHookEvent(envelope: envelope(enrich: nil)))
        XCTAssertNil(bare.anchor)
        let emptyEnrich = try XCTUnwrap(CodexHookEvent(envelope: envelope(enrich: ["tty": "ttys1"])))
        XCTAssertNil(emptyEnrich.anchor, "un tty seul ne dit pas QUELLE app ouvrir")
    }

    func testNoAnchorWithoutCwd() throws {
        let event = try XCTUnwrap(CodexHookEvent(envelope: envelope(
            enrich: ["terminalHint": "com.todesktop.230313mzl4w4u92", "env": cursorEnvironment],
            cwd: nil)))
        XCTAssertNil(event.anchor, "sans dossier, `cursor -r` n'a rien à ouvrir")
    }

    // MARK: - Persistance dans la projection

    /// Tous les hooks ne portent pas le même environnement. Perdre l'ancre au
    /// premier événement pauvre éteindrait le bouton au milieu d'une session.
    func testAnchorIsKeptWhenALaterEventCarriesNone() throws {
        var sessions = CodexSessions()
        let rich = try XCTUnwrap(CodexHookEvent(envelope: envelope(
            enrich: ["terminalHint": "com.todesktop.230313mzl4w4u92", "env": cursorEnvironment])))
        sessions.apply(rich)
        XCTAssertNotNil(sessions.anchor(for: "codex:abc"))

        let poor = try XCTUnwrap(CodexHookEvent(envelope: envelope(enrich: nil, event: "PostToolUse")))
        sessions.apply(poor)
        XCTAssertNotNil(sessions.anchor(for: "codex:abc"), "l'ancre a été perdue en route")
    }

    func testAnchorDisappearsWithTheSession() throws {
        var sessions = CodexSessions()
        sessions.apply(try XCTUnwrap(CodexHookEvent(envelope: envelope(
            enrich: ["terminalHint": "com.todesktop.230313mzl4w4u92", "env": cursorEnvironment]))))
        sessions.apply(try XCTUnwrap(CodexHookEvent(envelope: envelope(enrich: nil, event: "SessionEnd"))))
        XCTAssertNil(sessions.anchor(for: "codex:abc"))
    }

    func testUnknownSessionHasNoAnchor() {
        XCTAssertNil(CodexSessions().anchor(for: "codex:jamais-vue"))
    }
}
