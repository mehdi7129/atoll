import XCTest
@testable import AtollCore

/// Les faits sont construits par le VRAI décodeur (`CodexQuota.init?(result:)`),
/// pas par un initialiseur de test : une bascule qui marcherait sur un modèle
/// fabriqué mais pas sur le JSON réel de l'app-server ne prouverait rien.
final class ProviderFailoverTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func claudeFacts(used: Double?, age: TimeInterval = 60,
                             resetsIn: TimeInterval? = 3600) -> LearningGate.QuotaFacts {
        LearningGate.QuotaFacts(
            usedFraction: used,
            receivedAt: used == nil ? nil : now.addingTimeInterval(-age),
            resetsAt: resetsIn.map { now.addingTimeInterval($0) }
        )
    }

    private func codexQuota(primary: Double?, secondary: Double? = nil,
                            age: TimeInterval = 60,
                            resetsIn: TimeInterval = 3600) -> CodexQuota? {
        var bucket: [String: Any] = ["limitId": "codex", "limitName": "Codex"]
        if let primary {
            bucket["primary"] = ["usedPercent": primary * 100, "windowDurationMins": 300,
                                 "resetsAt": now.addingTimeInterval(resetsIn).timeIntervalSince1970]
        }
        if let secondary {
            bucket["secondary"] = ["usedPercent": secondary * 100, "windowDurationMins": 10080,
                                   "resetsAt": now.addingTimeInterval(resetsIn * 48).timeIntervalSince1970]
        }
        return CodexQuota(result: ["rateLimits": bucket], receivedAt: now.addingTimeInterval(-age))
    }

    private var on: ProviderFailover.Config { .init(enabled: true) }

    // MARK: - Comportement historique

    func testDisabledAlwaysStaysOnClaude() {
        // Même Claude à 100 % et Codex vide : sans opt-in, rien ne change.
        let decision = ProviderFailover.choose(
            claude: claudeFacts(used: 1.0), codex: codexQuota(primary: 0.0),
            config: .init(enabled: false), now: now)
        XCTAssertEqual(decision.provider, .claude)
        XCTAssertEqual(decision.reason, .failoverDisabled)
    }

    func testDefaultConfigIsOptOut() {
        XCTAssertFalse(ProviderFailover.Config().enabled)
    }

    // MARK: - Claude disponible

    func testClaudeUnderThresholdKeepsClaude() {
        let decision = ProviderFailover.choose(
            claude: claudeFacts(used: 0.50), codex: codexQuota(primary: 0.0),
            config: on, now: now)
        XCTAssertEqual(decision.provider, .claude)
        XCTAssertEqual(decision.reason, .claudeAvailable)
    }

    /// Le seuil est INCLUSIF : à la valeur exacte, Claude est tenu pour épuisé.
    func testThresholdIsInclusive() {
        let decision = ProviderFailover.choose(
            claude: claudeFacts(used: 0.95), codex: codexQuota(primary: 0.1),
            config: on, now: now)
        XCTAssertEqual(decision.provider, .codex)
    }

    // MARK: - L'invariant central : l'ignorance ne bascule pas

    func testUnknownClaudeQuotaDoesNotFailOver() {
        let decision = ProviderFailover.choose(
            claude: claudeFacts(used: nil), codex: codexQuota(primary: 0.0),
            config: on, now: now)
        XCTAssertEqual(decision.provider, .claude)
        XCTAssertEqual(decision.reason, .claudeUnknown)
    }

    func testStaleClaudeQuotaDoesNotFailOver() {
        let decision = ProviderFailover.choose(
            claude: claudeFacts(used: 1.0, age: 5_000), codex: codexQuota(primary: 0.0),
            config: on, now: now)
        XCTAssertEqual(decision.reason, .claudeUnknown)
    }

    /// Une mesure dont la fenêtre a DÉJÀ tourné ne prouve plus rien : c'est un
    /// cache d'avant la réinitialisation (même piège que `StatusLinePayload`).
    func testClaudeQuotaPastItsResetIsIgnored() {
        let decision = ProviderFailover.choose(
            claude: claudeFacts(used: 1.0, resetsIn: -60), codex: codexQuota(primary: 0.0),
            config: on, now: now)
        XCTAssertEqual(decision.reason, .claudeUnknown)
    }

    /// Une mesure datée du FUTUR (horloge reculée) est refusée, pas extrapolée.
    func testClaudeQuotaFromTheFutureIsIgnored() {
        let decision = ProviderFailover.choose(
            claude: claudeFacts(used: 1.0, age: -600), codex: codexQuota(primary: 0.0),
            config: on, now: now)
        XCTAssertEqual(decision.reason, .claudeUnknown)
    }

    // MARK: - Bascule

    func testExhaustedClaudeSwitchesToCodex() {
        let decision = ProviderFailover.choose(
            claude: claudeFacts(used: 0.99), codex: codexQuota(primary: 0.20),
            config: on, now: now)
        XCTAssertEqual(decision.provider, .codex)
        XCTAssertEqual(decision.reason, .claudeExhausted)
    }

    /// Basculer vers un compte dont on ne sait RIEN, c'est remplacer un échec
    /// connu par un échec inconnu : on ne lance rien.
    func testExhaustedClaudeWithoutCodexQuotaRunsNothing() {
        let decision = ProviderFailover.choose(
            claude: claudeFacts(used: 1.0), codex: nil, config: on, now: now)
        XCTAssertNil(decision.provider)
        XCTAssertEqual(decision.reason, .codexUnknown)
    }

    func testStaleCodexQuotaRunsNothing() {
        // `CodexQuota.isFresh` plafonne à 5 min : au-delà, la donnée est muette.
        let decision = ProviderFailover.choose(
            claude: claudeFacts(used: 1.0), codex: codexQuota(primary: 0.0, age: 600),
            config: on, now: now)
        XCTAssertEqual(decision.reason, .codexUnknown)
    }

    func testBothExhaustedRunsNothing() {
        let decision = ProviderFailover.choose(
            claude: claudeFacts(used: 1.0), codex: codexQuota(primary: 0.98),
            config: on, now: now)
        XCTAssertNil(decision.provider)
        XCTAssertEqual(decision.reason, .bothExhausted)
    }

    // MARK: - Plusieurs fenêtres Codex

    /// L'hebdomadaire pleine interdit le run même si l'horaire est vide : c'est
    /// elle qui bloquera au premier appel.
    func testWorstCodexWindowWins() {
        let decision = ProviderFailover.choose(
            claude: claudeFacts(used: 1.0), codex: codexQuota(primary: 0.02, secondary: 0.99),
            config: on, now: now)
        XCTAssertEqual(decision.reason, .bothExhausted)
    }

    func testWorstFractionIgnoresWindowsAlreadyReset() {
        // Fenêtre expirée à 99 % + fenêtre en cours à 10 % ⇒ seule la seconde compte.
        let bucket: [String: Any] = [
            "limitId": "codex",
            "primary": ["usedPercent": 99, "windowDurationMins": 300,
                        "resetsAt": now.addingTimeInterval(-60).timeIntervalSince1970],
            "secondary": ["usedPercent": 10, "windowDurationMins": 10080,
                          "resetsAt": now.addingTimeInterval(9_000).timeIntervalSince1970]
        ]
        guard let quota = CodexQuota(result: ["rateLimits": bucket], receivedAt: now)
        else { return XCTFail("quota indécodable") }
        XCTAssertEqual(ProviderFailover.worstUsedFraction(quota, now: now) ?? -1, 0.10, accuracy: 0.001)
    }

    /// CAS RÉEL, mesuré le 2026-09-06 à 23h31 sur le compte de Mehdi
    /// (`account/rateLimits/read`) : fenêtre de 300 min à **100 %**, fenêtre de
    /// 10 080 min à **16 %**. `codex exec` a bien répondu « You've hit your
    /// usage limit » et sorti en 1.
    ///
    /// C'est le contre-exemple qui justifie `max` plutôt que `min` : en prenant
    /// la fenêtre la moins chargée, Atoll aurait lu 16 %, lancé un run condamné,
    /// et brûlé un créneau de sa propre fenêtre pour un `failed(exit 1)`.
    func testRealWorldExhaustedCodexIsSeenAsExhausted() {
        let bucket: [String: Any] = [
            "limitId": "codex", "limitName": "Codex",
            "primary": ["usedPercent": 100, "windowDurationMins": 300,
                        "resetsAt": now.addingTimeInterval(3_300).timeIntervalSince1970],
            "secondary": ["usedPercent": 16, "windowDurationMins": 10_080,
                          "resetsAt": now.addingTimeInterval(590_000).timeIntervalSince1970]
        ]
        guard let quota = CodexQuota(result: ["rateLimits": bucket], receivedAt: now)
        else { return XCTFail("quota réel indécodable") }
        XCTAssertEqual(ProviderFailover.worstUsedFraction(quota, now: now) ?? -1, 1.0, accuracy: 0.001)

        let decision = ProviderFailover.choose(
            claude: claudeFacts(used: 1.0), codex: quota, config: on, now: now)
        XCTAssertNil(decision.provider)
        XCTAssertEqual(decision.reason, .bothExhausted)
    }

    // MARK: - Projection vers LearningGate

    func testQuotaFactsCarryWorstFractionAndNearestReset() {
        guard let quota = codexQuota(primary: 0.30, secondary: 0.80) else { return XCTFail("quota") }
        let facts = ProviderFailover.quotaFacts(of: quota, now: now)
        XCTAssertEqual(facts.usedFraction ?? -1, 0.80, accuracy: 0.001)
        XCTAssertEqual(facts.receivedAt, quota.receivedAt)
        // La plus PROCHE des deux réinitialisations : l'horaire, pas l'hebdo.
        XCTAssertEqual(facts.resetsAt, now.addingTimeInterval(3600))
    }

    /// Absence de quota ⇒ faits vides, JAMAIS un 0 % qui autoriserait tout.
    func testQuotaFactsOfNilAreEmptyNotZero() {
        let facts = ProviderFailover.quotaFacts(of: nil, now: now)
        XCTAssertNil(facts.usedFraction)
        XCTAssertNil(facts.receivedAt)
        XCTAssertNil(facts.resetsAt)
    }

    /// Ces faits doivent traverser `LearningGate` sans traitement de faveur :
    /// un quota Codex plein est refusé exactement comme un quota Claude plein.
    func testGateRefusesAFullCodexQuotaLikeAnyOther() {
        let facts = ProviderFailover.quotaFacts(of: codexQuota(primary: 0.90), now: now)
        let session = LearningGate.SessionFacts(
            sessionID: "s", durationSeconds: 3_600, transcriptSizeBytes: 500_000,
            userPromptCount: 12, isCurrentlyAlive: false)
        let decision = LearningGate.decide(
            session: session, quota: facts,
            config: .init(enabled: true, quotaThreshold: 0.70),
            history: .init(processed: [], runTimestamps: []), now: now)
        XCTAssertNotEqual(decision, .run)
    }
}
