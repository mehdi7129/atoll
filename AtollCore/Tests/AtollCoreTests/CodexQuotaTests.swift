import XCTest
@testable import AtollCore

final class CodexQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func window(_ percent: Any = 25, minutes: Any = 300, reset: Any = 1_800_001_000) -> [String: Any] {
        ["usedPercent": percent, "windowDurationMins": minutes, "resetsAt": reset]
    }
    func testDynamicWindowsAndReset() throws {
        let quota = try XCTUnwrap(CodexQuota(result: ["rateLimits": ["primary": window(), "secondary": window(75, minutes: 10080)]], receivedAt: now))
        XCTAssertEqual(quota.primaryBucket?.windows.map(\.label), ["5h", "7j"])
        XCTAssertEqual(quota.primaryBucket?.windows.first?.usedFraction, 0.25)
        XCTAssertTrue(quota.isFresh(at: now.addingTimeInterval(299)))
        XCTAssertFalse(quota.isFresh(at: now.addingTimeInterval(300)))
        XCTAssertFalse(try XCTUnwrap(quota.primaryBucket?.windows.first).isCurrent(at: now.addingTimeInterval(1000)))
    }
    func testMissingIsNotZeroAndValidZeroIsPreserved() throws {
        XCTAssertNil(CodexQuota(result: [:]))
        XCTAssertNil(CodexQuota(result: ["rateLimits": ["primary": NSNull(), "secondary": NSNull()]]))
        let zero = try XCTUnwrap(CodexQuota(result: ["rateLimits": ["primary": window(0, minutes: 15)]]))
        XCTAssertEqual(zero.primaryBucket?.windows.first?.usedFraction, 0)
        XCTAssertEqual(zero.primaryBucket?.windows.first?.label, "15min")
    }
    func testMultiBucketUsesCodexNotAlphabeticallyFirst() throws {
        let quota = try XCTUnwrap(CodexQuota(result: ["rateLimitsByLimitId": [
            "aaa_other": ["limitName": "Other", "primary": window(42, minutes: 60)],
            "codex": ["primary": window(12)]
        ]]))
        XCTAssertEqual(quota.buckets.count, 2)
        XCTAssertEqual(quota.primaryBucket?.id, "codex")
        XCTAssertEqual(quota.buckets.first?.label, "Other")
        XCTAssertEqual(quota.primaryBucket?.windows.first?.usedFraction, 0.12)
    }
    func testBadNumbersRejectedAndUnknownDurationNotInvented() throws {
        for invalid: Any in [-1, 101, true, "25", Double.nan, Double.infinity] {
            XCTAssertNil(CodexQuota(result: ["rateLimits": ["primary": window(invalid)]]))
        }
        let quota = try XCTUnwrap(CodexQuota(result: ["rateLimits": ["primary": window(50, minutes: NSNull(), reset: NSNull())]]))
        XCTAssertEqual(quota.primaryBucket?.windows.first?.label, "principale")
        XCTAssertNil(quota.primaryBucket?.windows.first?.resetsAt)
        let decimalDuration = try XCTUnwrap(CodexQuota(result: ["rateLimits": ["primary": window(25, minutes: 300.0)]]))
        XCTAssertEqual(decimalDuration.primaryBucket?.windows.first?.label, "5h")
    }
    func testFallbackDoesNotOverwriteMultiBucket() throws {
        let quota = try XCTUnwrap(CodexQuota(result: [
            "rateLimits": ["limitId": "codex", "primary": window(99)],
            "rateLimitsByLimitId": ["codex": ["primary": window(1)]]
        ]))
        XCTAssertEqual(quota.primaryBucket?.windows.first?.usedFraction, 0.01)
    }
}
