import XCTest
@testable import AtollCore

final class OAuthUsageTests: XCTestCase {

    /// Réponse réelle (capturée sur cette machine, anonymisée/abrégée).
    private let realResponse = Data("""
    {
      "five_hour": {"utilization": 46.0, "resets_at": "2026-07-19T21:10:00.233637+00:00"},
      "seven_day": {"utilization": 17.0, "resets_at": "2026-07-26T02:00:00.233659+00:00"},
      "seven_day_opus": null,
      "limits": [
        {"kind": "session", "group": "session", "percent": 46, "severity": "normal",
         "resets_at": "2026-07-19T21:09:59.753780+00:00", "scope": null, "is_active": true},
        {"kind": "weekly_all", "group": "weekly", "percent": 17, "severity": "normal",
         "resets_at": "2026-07-26T01:59:59.753802+00:00", "scope": null, "is_active": false},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 27, "severity": "normal",
         "resets_at": "2026-07-26T01:59:59.754069+00:00",
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": false}
      ]
    }
    """.utf8)

    func testParsesScopedModelLimit() throws {
        let usage = try XCTUnwrap(OAuthUsage(data: realResponse))
        XCTAssertEqual(usage.scopedLimits.count, 1)
        let fable = try XCTUnwrap(usage.scopedLimits.first)
        XCTAssertEqual(fable.label, "Fable")
        XCTAssertEqual(fable.usedFraction, 0.27, accuracy: 0.0001)
        XCTAssertNotNil(fable.resetsAt)
    }

    func testIgnoresUnscopedAndMalformedEntries() throws {
        let data = Data("""
        {"limits": [
          {"kind": "weekly_scoped", "percent": 30, "scope": null},
          {"kind": "weekly_scoped", "percent": "trente", "scope": {"model": {"display_name": "X"}}},
          {"kind": "weekly_scoped", "scope": {"model": {"display_name": "Y"}}},
          {"kind": "weekly_scoped", "percent": 12, "scope": {"model": {"id": "claude-opus-4-8"}}}
        ]}
        """.utf8)
        let usage = try XCTUnwrap(OAuthUsage(data: data))
        // Seule l'entrée avec un modèle identifiable et un percent numérique passe.
        XCTAssertEqual(usage.scopedLimits.count, 1)
        XCTAssertEqual(usage.scopedLimits[0].usedFraction, 0.12, accuracy: 0.0001)
        XCTAssertFalse(usage.scopedLimits[0].label.isEmpty)
    }

    func testGarbageAndMissingLimitsFailSoft() {
        XCTAssertNil(OAuthUsage(data: Data("pas du json".utf8)))
        XCTAssertNil(OAuthUsage(data: Data("{}".utf8)))
        let empty = OAuthUsage(data: Data(#"{"limits": []}"#.utf8))
        XCTAssertEqual(empty?.scopedLimits, [])
    }

    func testPercentClampedToSaneRange() throws {
        let data = Data("""
        {"limits": [{"kind": "weekly_scoped", "percent": 250,
                     "scope": {"model": {"display_name": "X"}}}]}
        """.utf8)
        let usage = try XCTUnwrap(OAuthUsage(data: data))
        XCTAssertEqual(usage.scopedLimits[0].usedFraction, 1.0)
    }

    func testParsesBothISO8601Forms() {
        XCTAssertNotNil(OAuthUsage.parseISO8601("2026-07-26T01:59:59.754069+00:00"))
        XCTAssertNotNil(OAuthUsage.parseISO8601("2026-07-26T01:59:59Z"))
        XCTAssertNil(OAuthUsage.parseISO8601("pas une date"))
    }
}
