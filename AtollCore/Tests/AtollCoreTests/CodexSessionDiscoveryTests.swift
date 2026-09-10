import XCTest
@testable import AtollCore

/// L'heuristique doit se tromper DANS LE BON SENS : manquer une session vaut
/// mieux qu'en annoncer une morte — c'est l'arbitrage qui a fait retirer le
/// badge « INPUT? » en Phase 14 et fusionner les sessions non confirmées dans
/// « EN COURS » en v0.16.1.
final class CodexSessionDiscoveryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func rollout(_ id: String, cwd: String, minutesAgo: Double = 5) -> CodexSessionDiscovery.Rollout {
        .init(path: "/r/rollout-\(id).jsonl", sessionID: id, cwd: cwd,
              modifiedAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    private func discover(_ processes: [CodexSessionDiscovery.RunningProcess],
                          _ rollouts: [CodexSessionDiscovery.Rollout],
                          known: Set<String> = []) -> [CodexSessionDiscovery.Discovered] {
        CodexSessionDiscovery.discover(processes: processes, rollouts: rollouts,
                                       known: known, now: now)
    }

    func testALiveProcessWithARecentRolloutIsDiscovered() throws {
        let found = discover([.init(pid: 5941, cwd: "/p/codex", startTime: 1_700_000_000, sessionID: "01a08577")],
                             [rollout("01a08577", cwd: "/p/codex")])
        let session = try XCTUnwrap(found.first)
        XCTAssertEqual(session.sessionID, "codex:01a08577")
        XCTAssertEqual(session.cwd, "/p/codex")
        XCTAssertEqual(session.transcriptPath, "/r/rollout-01a08577.jsonl")
    }

    /// LE POINT CENTRAL : un rollout survit à la fermeture de sa session. Sans
    /// l'exigence d'un processus vivant, l'îlot exhumerait des sessions mortes.
    func testARolloutWithoutAProcessIsNeverAnnouncedAlive() {
        XCTAssertTrue(discover([], [rollout("01a08577", cwd: "/p/codex")]).isEmpty)
    }

    /// …et l'inverse : un processus dont on ne trouve aucun rollout reste
    /// invisible. On ne sait rien de lui — pas même son identifiant.
    func testAProcessWithoutARolloutStaysInvisible() {
        XCTAssertTrue(discover([.init(pid: 1, cwd: "/p/vide")], []).isEmpty)
    }

    /// Les hooks font autorité : une session déjà connue n'est pas redécouverte,
    /// sinon l'îlot l'afficherait deux fois.
    func testAlreadyKnownSessionsAreNotDuplicated() {
        let found = discover([.init(pid: 1, cwd: "/p/codex")],
                             [rollout("01a08577", cwd: "/p/codex")],
                             known: ["codex:01a08577"])
        XCTAssertTrue(found.isEmpty)
    }

    /// Deux rollouts dans le même dossier : on garde le PLUS RÉCENT. En annoncer
    /// deux inventerait une session qui n'existe pas.
    func testTheNewestRolloutIsNotProofOfIdentity() throws {
        let found = discover([.init(pid: 1, cwd: "/p/codex")],
                             [rollout("vieux", cwd: "/p/codex", minutesAgo: 300),
                              rollout("recent", cwd: "/p/codex", minutesAgo: 2)])
        XCTAssertTrue(found.isEmpty)
    }

    /// Deux processus dans le MÊME dossier ne doivent pas produire deux fois la
    /// même session : ils sont indiscernables, on n'en montre qu'une.
    func testTwoUnidentifiedProcessesDoNotInheritAnOldSession() {
        let found = discover([.init(pid: 1, cwd: "/p/codex"), .init(pid: 2, cwd: "/p/codex")],
                             [rollout("01a08577", cwd: "/p/codex")])
        XCTAssertTrue(found.isEmpty)
    }

    func testDifferentDirectoriesAreIndependent() {
        let found = discover([.init(pid: 101, cwd: "/p/a", startTime: 1_700_000_000, sessionID: "aaa"), .init(pid: 102, cwd: "/p/b", startTime: 1_700_000_001, sessionID: "bbb")],
                             [rollout("aaa", cwd: "/p/a"), rollout("bbb", cwd: "/p/b")])
        XCTAssertEqual(Set(found.map(\.sessionID)), ["codex:aaa", "codex:bbb"])
    }

    /// Un rollout trop vieux n'est pas rattaché : une session tourne peut-être
    /// dans ce dossier aujourd'hui, mais rien ne dit que c'est celle-là.
    func testAnAncientRolloutIsNotAttachedToATodayProcess() {
        let found = discover([.init(pid: 1, cwd: "/p/codex")],
                             [rollout("vieux", cwd: "/p/codex", minutesAgo: 3 * 24 * 60)])
        XCTAssertTrue(found.isEmpty)
    }

    /// Un rollout daté du FUTUR (horloge reculée) est ignoré, pas extrapolé —
    /// même prudence que `ProviderFailover` sur les quotas.
    func testARolloutFromTheFutureIsIgnored() {
        let found = discover([.init(pid: 1, cwd: "/p/codex")],
                             [rollout("futur", cwd: "/p/codex", minutesAgo: -60)])
        XCTAssertTrue(found.isEmpty)
    }

    /// Les dossiers ne se ressemblent pas « à peu près » : l'appariement est
    /// exact, sinon un sous-dossier hériterait de la session de son parent.
    func testDirectoryMatchingIsExactNotPrefixed() {
        let found = discover([.init(pid: 1, cwd: "/p/codex/sous-dossier")],
                             [rollout("01a08577", cwd: "/p/codex")])
        XCTAssertTrue(found.isEmpty)
    }
}

/// L'adoption ne doit JAMAIS écraser ce que les hooks savent.
extension CodexSessionDiscoveryTests {
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
