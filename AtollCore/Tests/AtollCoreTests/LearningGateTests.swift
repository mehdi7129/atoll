import XCTest
@testable import AtollCore

final class LearningGateTests: XCTestCase {

    /// Instant de référence fixe — aucune horloge réelle dans ces tests.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fixtures

    /// Session terminée et substantielle : passe TOUS les critères de session.
    private func session(
        id: String = "sess-abc",
        duration: TimeInterval = 1_800,
        transcriptBytes: Int? = 250_000,
        prompts: Int? = 8,
        alive: Bool = false
    ) -> LearningGate.SessionFacts {
        LearningGate.SessionFacts(
            sessionID: id,
            durationSeconds: duration,
            transcriptSizeBytes: transcriptBytes,
            userPromptCount: prompts,
            isCurrentlyAlive: alive
        )
    }

    /// Quota frais, sous le seuil, fenêtre 5 h non expirée.
    private var freshQuota: LearningGate.QuotaFacts {
        LearningGate.QuotaFacts(
            usedFraction: 0.35,
            receivedAt: now.addingTimeInterval(-60),
            resetsAt: now.addingTimeInterval(3_600)
        )
    }

    /// Config activée, tout le reste aux valeurs par défaut.
    private var enabledConfig: LearningGate.Config {
        LearningGate.Config(enabled: true)
    }

    /// Raccourci : décision avec les fixtures éligibles, surchargées au besoin.
    /// Sans surcharge, le verdict attendu est `.run`.
    private func decide(
        session: LearningGate.SessionFacts? = nil,
        quota: LearningGate.QuotaFacts? = nil,
        config: LearningGate.Config? = nil,
        history: LearningGate.History = LearningGate.History()
    ) -> LearningGate.Decision {
        LearningGate.decide(
            session: session ?? self.session(),
            quota: quota ?? freshQuota,
            config: config ?? enabledConfig,
            history: history,
            now: now
        )
    }

    // MARK: - Portail et cas nominal

    func testDisabledByDefaultSkips() {
        // Config() par défaut = désactivé : opt-in strict, même si tout le reste
        // est éligible.
        XCTAssertEqual(decide(config: LearningGate.Config()), .skip(.disabled))
    }

    func testRunsWhenAllConditionsMet() {
        XCTAssertEqual(decide(), .run)
    }

    // MARK: - Critères de session

    func testSkipsResumedSession() {
        XCTAssertEqual(decide(session: session(alive: true)), .skip(.sessionResumed))
    }

    func testSkipsShortSession() {
        XCTAssertEqual(decide(session: session(duration: 599)), .skip(.sessionTooShort))
        XCTAssertEqual(decide(session: session(duration: 600)), .run,
                       "durée exactement au seuil = assez longue (strictement <)")
    }

    func testSkipsMissingTranscript() {
        XCTAssertEqual(decide(session: session(transcriptBytes: nil)), .skip(.transcriptMissing))
    }

    func testSkipsSmallTranscript() {
        XCTAssertEqual(decide(session: session(transcriptBytes: 99_999)), .skip(.transcriptTooSmall))
        XCTAssertEqual(decide(session: session(transcriptBytes: 100_000)), .run,
                       "taille exactement au seuil = assez grosse")
    }

    func testSkipsTooFewUserPrompts() {
        XCTAssertEqual(decide(session: session(prompts: 2)), .skip(.tooFewUserPrompts))
        XCTAssertEqual(decide(session: session(prompts: 3)), .run,
                       "compte exactement au seuil = assez de prompts")
    }

    func testSyntheticSessionIgnoresPromptCriterion() {
        // Session synthétique (découverte par scan, sans hooks) : le compte de
        // prompts est inconnu → le critère est ignoré, pas bloquant.
        XCTAssertEqual(decide(session: session(prompts: nil)), .run)
    }

    // MARK: - Critères de quota (fail-safe : pas de donnée = pas de run)

    func testSkipsWithoutQuotaData() {
        let noFraction = LearningGate.QuotaFacts(usedFraction: nil, receivedAt: now, resetsAt: nil)
        XCTAssertEqual(decide(quota: noFraction), .skip(.quotaMissing))
        let noReception = LearningGate.QuotaFacts(usedFraction: 0.1, receivedAt: nil, resetsAt: nil)
        XCTAssertEqual(decide(quota: noReception), .skip(.quotaMissing))
    }

    func testSkipsStaleQuota() {
        let stale = LearningGate.QuotaFacts(
            usedFraction: 0.1,
            receivedAt: now.addingTimeInterval(-601),
            resetsAt: now.addingTimeInterval(3_600)
        )
        XCTAssertEqual(decide(quota: stale), .skip(.quotaStale))
        let atLimit = LearningGate.QuotaFacts(
            usedFraction: 0.1,
            receivedAt: now.addingTimeInterval(-600),
            resetsAt: nil
        )
        XCTAssertEqual(decide(quota: atLimit), .run,
                       "âge exactement à la limite = encore frais (strictement >)")
    }

    func testSkipsExpiredResetsAt() {
        // Même piège que StatusLinePayload : un rate_limits mis en cache AVANT
        // la réinitialisation — resets_at passé ⇒ la valeur ne veut plus rien dire.
        let expired = LearningGate.QuotaFacts(
            usedFraction: 0.1,
            receivedAt: now.addingTimeInterval(-60),
            resetsAt: now.addingTimeInterval(-1)
        )
        XCTAssertEqual(decide(quota: expired), .skip(.quotaStale))
    }

    func testSkipsQuotaAtThreshold() {
        let atThreshold = LearningGate.QuotaFacts(usedFraction: 0.70, receivedAt: now, resetsAt: nil)
        XCTAssertEqual(decide(quota: atThreshold), .skip(.quotaAboveThreshold),
                       "0.70 exactement ⇒ skip (>= et non >)")
        let justBelow = LearningGate.QuotaFacts(usedFraction: 0.6999, receivedAt: now, resetsAt: nil)
        XCTAssertEqual(decide(quota: justBelow), .run)
    }

    // MARK: - Plafond par fenêtre

    func testSkipsWhenWindowCapReached() {
        // Deux runs dans les 5 dernières heures = plafond par défaut atteint.
        let capped = LearningGate.History(
            runTimestamps: [now.addingTimeInterval(-3_600), now.addingTimeInterval(-7_200)]
        )
        XCTAssertEqual(decide(history: capped), .skip(.windowCapReached))
        // Un run sorti de la fenêtre 5 h ne compte plus.
        let aged = LearningGate.History(
            runTimestamps: [now.addingTimeInterval(-6 * 3_600), now.addingTimeInterval(-3_600)]
        )
        XCTAssertEqual(decide(history: aged), .run)
    }

    // MARK: - Sessions déjà traitées et re-traitement

    func testSkipsAlreadyProcessed() {
        let history = LearningGate.History(
            processed: [.init(sessionID: "sess-abc", transcriptBytes: 250_000,
                              completedAt: now.addingTimeInterval(-3_600))]
        )
        XCTAssertEqual(decide(history: history), .skip(.alreadyProcessed))
        // Une AUTRE session traitée n'empêche rien.
        let other = LearningGate.History(
            processed: [.init(sessionID: "autre", transcriptBytes: 250_000,
                              completedAt: now.addingTimeInterval(-3_600))]
        )
        XCTAssertEqual(decide(history: other), .run)
    }

    func testReprocessesAfterTranscriptGrowth() {
        // Deux passages : la croissance se mesure contre le DERNIER (completedAt max),
        // pas contre le premier.
        let history = LearningGate.History(
            processed: [
                .init(sessionID: "sess-abc", transcriptBytes: 100_000,
                      completedAt: now.addingTimeInterval(-7_200)),
                .init(sessionID: "sess-abc", transcriptBytes: 200_000,
                      completedAt: now.addingTimeInterval(-3_600)),
            ]
        )
        // 200 000 + 50 000 = 250 000 : croissance tout juste suffisante (≥) → run.
        XCTAssertEqual(decide(session: session(transcriptBytes: 250_000), history: history), .run)
        // Un octet de moins → toujours considérée comme déjà traitée.
        XCTAssertEqual(decide(session: session(transcriptBytes: 249_999), history: history),
                       .skip(.alreadyProcessed))
    }

    // MARK: - Ordre strict des raisons

    func testSkipReasonPriorityOrder() {
        // Session cumulant tous les défauts : vivante, courte, sans transcript.
        let broken = session(duration: 10, transcriptBytes: nil, prompts: 0, alive: true)

        // disabled avant tout le reste.
        XCTAssertEqual(decide(session: broken, config: LearningGate.Config()), .skip(.disabled))
        // sessionResumed avant sessionTooShort.
        XCTAssertEqual(decide(session: broken), .skip(.sessionResumed))
        // sessionTooShort avant transcriptMissing.
        XCTAssertEqual(decide(session: session(duration: 10, transcriptBytes: nil, prompts: 0)),
                       .skip(.sessionTooShort))
        // transcriptMissing avant tooFewUserPrompts.
        XCTAssertEqual(decide(session: session(transcriptBytes: nil, prompts: 0)),
                       .skip(.transcriptMissing))
        // alreadyProcessed avant quotaMissing.
        let processed = LearningGate.History(
            processed: [.init(sessionID: "sess-abc", transcriptBytes: 250_000, completedAt: now)]
        )
        let noQuota = LearningGate.QuotaFacts(usedFraction: nil, receivedAt: nil, resetsAt: nil)
        XCTAssertEqual(decide(quota: noQuota, history: processed), .skip(.alreadyProcessed))
        // quotaStale avant quotaAboveThreshold.
        let staleAndHigh = LearningGate.QuotaFacts(
            usedFraction: 0.99,
            receivedAt: now.addingTimeInterval(-9_999),
            resetsAt: nil
        )
        XCTAssertEqual(decide(quota: staleAndHigh), .skip(.quotaStale))
        // quotaAboveThreshold avant windowCapReached.
        let high = LearningGate.QuotaFacts(usedFraction: 0.99, receivedAt: now, resetsAt: nil)
        let capped = LearningGate.History(runTimestamps: [now, now])
        XCTAssertEqual(decide(quota: high, history: capped), .skip(.quotaAboveThreshold))
    }
}
