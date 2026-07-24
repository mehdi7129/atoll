import XCTest
@testable import AtollCore

final class AgentsSnapshotTests: XCTestCase {

    // Sortie réaliste de `claude agents --json --all` (schéma vérifié 2.1.218) :
    // une interactive, une arrière-plan stoppée (pid + status nuls).
    private var realistic: Data {
        Data("""
        [
          { "pid": 32959, "cwd": "/Users/x/proj", "kind": "interactive",
            "startedAt": 1784881801217, "sessionId": "95424d8b-b6c7-422e-84a3-47859dbaa063",
            "name": "dynamic-island-38", "status": "idle" },
          { "pid": null, "cwd": "/Users/x/proj", "kind": "background",
            "sessionId": "3dac7149-1e2f-4c00-9a00-000000000000",
            "name": "compte", "status": null }
        ]
        """.utf8)
    }

    func testDecodesRealisticOutput() {
        let sessions = AgentsSnapshot.decode(realistic)
        XCTAssertEqual(sessions.count, 2)
        let first = sessions[0]
        XCTAssertEqual(first.sessionID, "95424d8b-b6c7-422e-84a3-47859dbaa063")
        XCTAssertEqual(first.pid, 32959)
        XCTAssertEqual(first.name, "dynamic-island-38")
        XCTAssertEqual(first.status, .idle)
        XCTAssertEqual(first.kind, .interactive)
        XCTAssertNotNil(first.startedAt)
    }

    func testToleratesNullPidAndStatus() {
        let stopped = AgentsSnapshot.decode(realistic)[1]
        XCTAssertNil(stopped.pid)
        XCTAssertEqual(stopped.status, .unknown) // null → unknown, ne force rien
        XCTAssertNil(stopped.startedAt)
    }

    func testStartedAtIsMillisecondsEpoch() {
        let first = AgentsSnapshot.decode(realistic)[0]
        // 1784881801217 ms → 2026, pas 1970.
        let year = Calendar(identifier: .gregorian).component(.year, from: first.startedAt!)
        XCTAssertEqual(year, 2026)
    }

    func testStatusVocabularyNormalized() {
        XCTAssertEqual(AgentSessionInfo.Status.parse("busy"), .busy)
        XCTAssertEqual(AgentSessionInfo.Status.parse("working"), .busy)
        XCTAssertEqual(AgentSessionInfo.Status.parse("idle"), .idle)
        XCTAssertEqual(AgentSessionInfo.Status.parse("needs_input"), .needsInput)
        XCTAssertEqual(AgentSessionInfo.Status.parse("completed"), .completed)
        XCTAssertEqual(AgentSessionInfo.Status.parse("failed"), .failed)
        XCTAssertEqual(AgentSessionInfo.Status.parse("stopped"), .stopped)
        XCTAssertEqual(AgentSessionInfo.Status.parse("martien"), .unknown)
        XCTAssertEqual(AgentSessionInfo.Status.parse(nil), .unknown)
        XCTAssertTrue(AgentSessionInfo.Status.completed.isTerminal)
        XCTAssertFalse(AgentSessionInfo.Status.busy.isTerminal)
    }

    func testIgnoresEntriesWithoutSessionID() {
        let data = Data(#"[ { "pid": 1, "status": "busy" }, { "sessionId": "ok-1", "status": "busy" } ]"#.utf8)
        let sessions = AgentsSnapshot.decode(data)
        XCTAssertEqual(sessions.map(\.sessionID), ["ok-1"])
    }

    func testMalformedOutputYieldsEmpty() {
        XCTAssertTrue(AgentsSnapshot.decode(Data("pas du json".utf8)).isEmpty)
        XCTAssertTrue(AgentsSnapshot.decode(Data("{}".utf8)).isEmpty)      // objet, pas tableau
        XCTAssertTrue(AgentsSnapshot.decode(Data("[]".utf8)).isEmpty)
    }

    func testAlternateKeyNames() {
        // Résilience si le CLI renomme sessionId → id / session_id (défensif).
        let data = Data(#"[ { "id": "alt-1", "status": "busy" } ]"#.utf8)
        XCTAssertEqual(AgentsSnapshot.decode(data).first?.sessionID, "alt-1")
    }

    // MARK: - Corrélation

    func testCorrelateBySessionID() {
        let info = AgentSessionInfo(sessionID: "s1", pid: 100, cwd: nil, name: nil,
                                    status: .busy, kind: .interactive, startedAt: nil)
        let existing = [FleetReconciler.Existing(id: "s1", pid: 999)]
        XCTAssertEqual(FleetReconciler.correlate(info, among: existing), .existing(id: "s1"))
    }

    func testCorrelateByPidWhenIdDiffers() {
        // Fork/compaction : l'id JSON diffère mais le pid reste stable → pas de doublon.
        let info = AgentSessionInfo(sessionID: "nouveau-id", pid: 100, cwd: nil, name: nil,
                                    status: .busy, kind: .background, startedAt: nil)
        let existing = [FleetReconciler.Existing(id: "ancien-id", pid: 100)]
        XCTAssertEqual(FleetReconciler.correlate(info, among: existing), .existing(id: "ancien-id"))
    }

    func testCorrelateNewWhenNoMatch() {
        let info = AgentSessionInfo(sessionID: "s2", pid: 200, cwd: nil, name: nil,
                                    status: .busy, kind: .interactive, startedAt: nil)
        let existing = [FleetReconciler.Existing(id: "s1", pid: 100)]
        XCTAssertEqual(FleetReconciler.correlate(info, among: existing), .new)
    }

    func testCorrelateIgnoresAbsentPid() {
        // pid nil des deux côtés ne doit pas faire matcher par erreur.
        let info = AgentSessionInfo(sessionID: "s2", pid: nil, cwd: nil, name: nil,
                                    status: .unknown, kind: .background, startedAt: nil)
        let existing = [FleetReconciler.Existing(id: "s1", pid: nil)]
        XCTAssertEqual(FleetReconciler.correlate(info, among: existing), .new)
    }
}
