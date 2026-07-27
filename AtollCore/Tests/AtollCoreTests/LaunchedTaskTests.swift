import XCTest
@testable import AtollCore

final class LaunchedTaskTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func task(_ text: String = "ranger les imports",
                      cwd: String = "/Users/m/Projet",
                      offset: TimeInterval = 0,
                      sessionID: String? = nil) -> LaunchedTask {
        LaunchedTask(task: text, cwd: cwd, launchedAt: now.addingTimeInterval(offset),
                     sessionID: sessionID)
    }

    // MARK: - Correspondance d'identifiants

    func testMatchesExactSessionID() {
        let uuid = "3dac7149-1e2f-4c00-9a00-2b7c9d1e5f60"
        XCTAssertTrue(task(sessionID: uuid).matchesSessionID(uuid))
    }

    /// LE cas qui justifie tout : `claude --bg` n'imprime parfois que le préfixe
    /// (cf. FleetLaunchTests), alors que les hooks portent l'UUID complet. Une
    /// comparaison par égalité ne notifierait JAMAIS dans ce cas.
    func testMatchesTruncatedIDAgainstFullUUID() {
        let short = "a8558220"
        let full = "a8558220-1e2f-4c00-9a00-2b7c9d1e5f60"
        XCTAssertTrue(task(sessionID: short).matchesSessionID(full))
        XCTAssertTrue(task(sessionID: full).matchesSessionID(short))
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertTrue(task(sessionID: "A8558220").matchesSessionID("a8558220-1e2f-4c00-9a00-2b7c9d1e5f60"))
    }

    /// Plancher de 8 caractères : en dessous, un préfixe commun n'est plus une
    /// preuve d'identité.
    func testShortPrefixesDoNotMatch() {
        XCTAssertFalse(task(sessionID: "a855").matchesSessionID("a8558220-1e2f-4c00-9a00-2b7c9d1e5f60"))
        XCTAssertFalse(LaunchedTask.sessionIDsMatch("", ""))
    }

    func testDifferentIDsDoNotMatch() {
        XCTAssertFalse(task(sessionID: "a8558220").matchesSessionID("b8558220-1e2f-4c00-9a00-2b7c9d1e5f60"))
    }

    func testTaskWithoutSessionIDMatchesNothing() {
        XCTAssertFalse(task().matchesSessionID("a8558220-1e2f-4c00-9a00-2b7c9d1e5f60"))
    }

    // MARK: - Terminaison

    func testCompleteMarksAndReturnsTaskOnce() {
        var log = LaunchedTaskLog()
        log.register(task(sessionID: "a8558220"))
        let full = "a8558220-1e2f-4c00-9a00-2b7c9d1e5f60"

        let first = log.complete(sessionID: full, at: now, summary: "c'est fait")
        XCTAssertEqual(first?.summary, "c'est fait")
        XCTAssertTrue(log.tasks[0].notified)

        // Deuxième signal de fin (disparition de la flotte après le hook Stop) :
        // aucune deuxième notification.
        XCTAssertNil(log.complete(sessionID: full, at: now, summary: "encore"))
        XCTAssertEqual(log.tasks[0].summary, "c'est fait")
    }

    func testCompleteIgnoresUnknownSession() {
        var log = LaunchedTaskLog()
        log.register(task(sessionID: "a8558220"))
        XCTAssertNil(log.complete(sessionID: "ffffffff-1e2f-4c00-9a00-2b7c9d1e5f60",
                                  at: now, summary: nil))
        XCTAssertFalse(log.tasks[0].notified)
    }

    func testPendingAndUnacknowledged() {
        var log = LaunchedTaskLog()
        log.register(task("A", sessionID: "aaaaaaaa"))
        log.register(task("B", sessionID: "bbbbbbbb"))
        XCTAssertEqual(log.pending.count, 2)

        log.complete(sessionID: "aaaaaaaa", at: now, summary: "fini")
        XCTAssertEqual(log.pending.map(\.task), ["B"])
        XCTAssertEqual(log.unacknowledged.map(\.task), ["A"])

        log.acknowledge(id: log.tasks[0].id)
        XCTAssertTrue(log.unacknowledged.isEmpty)
    }

    func testUnacknowledgedIsMostRecentFirst() {
        var log = LaunchedTaskLog()
        log.register(task("A", sessionID: "aaaaaaaa"))
        log.register(task("B", sessionID: "bbbbbbbb"))
        log.complete(sessionID: "aaaaaaaa", at: now, summary: nil)
        log.complete(sessionID: "bbbbbbbb", at: now.addingTimeInterval(60), summary: nil)
        XCTAssertEqual(log.unacknowledged.map(\.task), ["B", "A"])
    }

    // MARK: - Rattrapage par dossier + horodatage

    func testAdoptsSessionInSameDirectoryStartedAfterLaunch() {
        var log = LaunchedTaskLog()
        log.register(task(cwd: "/Users/m/Projet"))
        let index = log.adopt(sessionID: "a8558220-1e2f-4c00-9a00-2b7c9d1e5f60",
                              cwd: "/Users/m/Projet", startedAt: now.addingTimeInterval(3))
        XCTAssertEqual(index, 0)
        XCTAssertEqual(log.tasks[0].sessionID, "a8558220-1e2f-4c00-9a00-2b7c9d1e5f60")
    }

    func testAdoptionNormalizesPaths() {
        var log = LaunchedTaskLog()
        log.register(task(cwd: "/Users/m/Projet/"))
        XCTAssertEqual(log.adopt(sessionID: "a8558220-1e2f-4c00-9a00-2b7c9d1e5f60",
                                 cwd: "/Users/m/Projet/./", startedAt: now.addingTimeInterval(1)), 0)
    }

    /// Une session démarrée AVANT le lancement ne peut pas être la nôtre —
    /// sinon on annoncerait la fin d'un travail qui n'a rien à voir.
    func testDoesNotAdoptSessionStartedBeforeLaunch() {
        var log = LaunchedTaskLog()
        log.register(task(cwd: "/Users/m/Projet"))
        XCTAssertNil(log.adopt(sessionID: "a8558220-1e2f-4c00-9a00-2b7c9d1e5f60",
                               cwd: "/Users/m/Projet", startedAt: now.addingTimeInterval(-60)))
        XCTAssertNil(log.tasks[0].sessionID)
    }

    func testDoesNotAdoptOutsideWindowOrOtherDirectory() {
        var log = LaunchedTaskLog()
        log.register(task(cwd: "/Users/m/Projet"))
        XCTAssertNil(log.adopt(sessionID: "a8558220-1e2f-4c00-9a00-2b7c9d1e5f60",
                               cwd: "/Users/m/Projet", startedAt: now.addingTimeInterval(9999)))
        XCTAssertNil(log.adopt(sessionID: "a8558220-1e2f-4c00-9a00-2b7c9d1e5f60",
                               cwd: "/Users/m/Autre", startedAt: now.addingTimeInterval(3)))
    }

    func testAdoptionPrefersOldestPendingTask() {
        var log = LaunchedTaskLog()
        log.register(task("vieille", cwd: "/Users/m/Projet", offset: 0))
        log.register(task("récente", cwd: "/Users/m/Projet", offset: 10))
        let index = log.adopt(sessionID: "a8558220-1e2f-4c00-9a00-2b7c9d1e5f60",
                              cwd: "/Users/m/Projet", startedAt: now.addingTimeInterval(12))
        XCTAssertEqual(log.tasks[index ?? 1].task, "vieille")
    }

    func testAdoptionSkipsAlreadyLinkedSession() {
        var log = LaunchedTaskLog()
        let full = "a8558220-1e2f-4c00-9a00-2b7c9d1e5f60"
        log.register(task("liée", cwd: "/Users/m/Projet", sessionID: "a8558220"))
        log.register(task("libre", cwd: "/Users/m/Projet", offset: 1))
        // Le préfixe désigne déjà la 1re tâche : ne pas la lier une 2e fois.
        XCTAssertNil(log.adopt(sessionID: full, cwd: "/Users/m/Projet",
                               startedAt: now.addingTimeInterval(2)))
        XCTAssertNil(log.tasks[1].sessionID)
    }

    func testAdoptionRejectsMissingData() {
        var log = LaunchedTaskLog()
        log.register(task(cwd: "/Users/m/Projet"))
        XCTAssertNil(log.adopt(sessionID: "", cwd: "/Users/m/Projet", startedAt: now))
        XCTAssertNil(log.adopt(sessionID: "a8558220", cwd: nil, startedAt: now))
        XCTAssertNil(log.adopt(sessionID: "a8558220", cwd: "/Users/m/Projet", startedAt: nil))
    }

    // MARK: - Purge

    func testPruneDropsOldCompletedButKeepsPending() {
        var log = LaunchedTaskLog()
        log.register(task("vieille terminée", sessionID: "aaaaaaaa"))
        log.register(task("toujours en cours", offset: -100_000, sessionID: "bbbbbbbb"))
        log.complete(sessionID: "aaaaaaaa", at: now, summary: nil)

        log.prune(now: now.addingTimeInterval(48 * 3600))
        XCTAssertEqual(log.tasks.map(\.task), ["toujours en cours"])
    }

    func testPruneKeepsRecentCompleted() {
        var log = LaunchedTaskLog()
        log.register(task(sessionID: "aaaaaaaa"))
        log.complete(sessionID: "aaaaaaaa", at: now, summary: nil)
        log.prune(now: now.addingTimeInterval(3600))
        XCTAssertEqual(log.tasks.count, 1)
    }

    func testCapDropsOldestCompletedFirst() {
        var log = LaunchedTaskLog()
        for index in 0..<LaunchedTaskLog.maxEntries {
            let id = String(format: "%08x", index)
            log.register(task("terminée \(index)", offset: TimeInterval(index), sessionID: id))
            log.complete(sessionID: id, at: now.addingTimeInterval(TimeInterval(index)), summary: nil)
        }
        log.register(task("la nouvelle", offset: 999))
        XCTAssertEqual(log.tasks.count, LaunchedTaskLog.maxEntries)
        XCTAssertEqual(log.tasks.last?.task, "la nouvelle")
        XCTAssertFalse(log.tasks.contains { $0.task == "terminée 0" })
    }

    /// Le plafond ne doit pas faire disparaître une tâche EN COURS tant qu'il
    /// reste des terminées à sacrifier.
    func testCapSparesPendingTasksWhileCompletedRemain() {
        var log = LaunchedTaskLog()
        log.register(task("en cours", offset: -1))
        for index in 0..<LaunchedTaskLog.maxEntries {
            let id = String(format: "%08x", index)
            log.register(task("terminée \(index)", offset: TimeInterval(index), sessionID: id))
            log.complete(sessionID: id, at: now.addingTimeInterval(TimeInterval(index)), summary: nil)
        }
        XCTAssertTrue(log.tasks.contains { $0.task == "en cours" })
        XCTAssertEqual(log.tasks.count, LaunchedTaskLog.maxEntries)
    }

    // MARK: - Persistance

    func testRoundTripsThroughJSON() throws {
        var log = LaunchedTaskLog()
        log.register(task(sessionID: "a8558220"))
        log.complete(sessionID: "a8558220", at: now, summary: "terminé")
        let data = try JSONEncoder().encode(log)
        XCTAssertEqual(try JSONDecoder().decode(LaunchedTaskLog.self, from: data), log)
    }

    // MARK: - Réconciliation avec la flotte

    /// LE cas que le journal persisté est censé couvrir : la tâche finit
    /// pendant qu'Atoll ne tourne pas. Sa session n'existe plus au redémarrage,
    /// donc ni le hook `Stop` ni `markEnded` ne la concernent.
    func testReconcileAnnouncesTaskSeenAliveThenGone() {
        var log = LaunchedTaskLog()
        log.register(task(offset: 0, sessionID: "aaaaaaaa"))
        log.adopt(sessionID: "aaaaaaaa-1e2f-4c00-9a00-2b7c9d1e5f60",
                  cwd: "/Users/m/Projet", startedAt: now.addingTimeInterval(2))
        XCTAssertTrue(log.tasks[0].seenAlive)

        let announce = log.reconcile(activeSessionIDs: [], now: now.addingTimeInterval(600))
        XCTAssertEqual(announce, [0])
    }

    /// Un lancement raté (session jamais apparue) ne doit surtout PAS produire
    /// « ta tâche est terminée ».
    func testReconcileClosesNeverSeenTaskSilently() {
        var log = LaunchedTaskLog()
        log.register(task(sessionID: "aaaaaaaa"))
        let announce = log.reconcile(activeSessionIDs: [], now: now.addingTimeInterval(600))
        XCTAssertTrue(announce.isEmpty)
        XCTAssertTrue(log.tasks[0].isComplete, "la tâche ne doit pas rester zombie")
        XCTAssertTrue(log.tasks[0].acknowledged)
    }

    /// Délai de grâce : la flotte doit avoir le temps de faire apparaître une
    /// session fraîchement lancée.
    func testReconcileRespectsGracePeriod() {
        var log = LaunchedTaskLog()
        log.register(task(sessionID: "aaaaaaaa"))
        XCTAssertTrue(log.reconcile(activeSessionIDs: [], now: now.addingTimeInterval(10)).isEmpty)
        XCTAssertFalse(log.tasks[0].isComplete)
    }

    func testReconcileMarksActiveTaskSeenAlive() {
        var log = LaunchedTaskLog()
        log.register(task(sessionID: "aaaaaaaa"))
        let announce = log.reconcile(
            activeSessionIDs: ["aaaaaaaa-1e2f-4c00-9a00-2b7c9d1e5f60"],
            now: now.addingTimeInterval(600))
        XCTAssertTrue(announce.isEmpty)
        XCTAssertTrue(log.tasks[0].seenAlive)
        XCTAssertFalse(log.tasks[0].isComplete)
    }

    // MARK: - Compatibilité du journal persisté

    /// Ajouter un champ à une structure persistée a déjà effacé l'historique
    /// d'apprentissage en Phase 12 : un journal écrit par une version
    /// antérieure DOIT rester lisible.
    func testDecodesLogWrittenByAnOlderVersion() throws {
        let legacy = """
        {"tasks":[{"id":"\(UUID().uuidString)","task":"ranger","cwd":"/Users/m/P",
          "launchedAt":760000000,"notified":false,"acknowledged":false}]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LaunchedTaskLog.self, from: legacy)
        XCTAssertEqual(decoded.tasks.count, 1)
        XCTAssertEqual(decoded.tasks[0].task, "ranger")
        XCTAssertFalse(decoded.tasks[0].seenAlive)
    }

    // MARK: - Bannière bornée dans le temps

    func testUnacknowledgedIgnoresTasksPastRetention() {
        var log = LaunchedTaskLog()
        log.register(task(sessionID: "aaaaaaaa"))
        log.complete(sessionID: "aaaaaaaa", at: now, summary: nil)
        XCTAssertEqual(log.unacknowledged(now: now.addingTimeInterval(3600)).count, 1)
        XCTAssertTrue(log.unacknowledged(now: now.addingTimeInterval(48 * 3600)).isEmpty)
    }

    func testProjectNameIsLastPathComponent() {
        XCTAssertEqual(task(cwd: "/Users/m/Dynamic_Island").projectName, "Dynamic_Island")
    }
}
