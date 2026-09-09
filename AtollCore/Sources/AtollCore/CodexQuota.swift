import Foundation
import CoreFoundation

/// Subscription usage, NOT API billing or local token counts. Missing ≠ 0%.
public struct CodexQuota: Equatable, Sendable {
    public struct Window: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let usedFraction: Double
        public let resetsAt: Date?
        public func isCurrent(at now: Date) -> Bool { resetsAt.map { $0 > now } ?? true }
    }
    public struct Bucket: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let windows: [Window]
    }
    public let buckets: [Bucket]
    public let receivedAt: Date
    public func isFresh(at now: Date) -> Bool {
        now.timeIntervalSince(receivedAt) < 300 && now >= receivedAt
    }
    public var primaryBucket: Bucket? { buckets.first { $0.id == "codex" } ?? buckets.first }

    public init?(result: [String: Any], receivedAt: Date = Date()) {
        let map = result["rateLimitsByLimitId"] as? [String: Any]
        var raw = map ?? [:]
        if let fallback = result["rateLimits"] as? [String: Any] {
            let id = fallback["limitId"] as? String ?? "codex"
            if raw[id] == nil { raw[id] = fallback }
        }
        let buckets = raw.keys.sorted().compactMap { id -> Bucket? in
            guard let bucket = raw[id] as? [String: Any] else { return nil }
            let windows = ["primary", "secondary"].compactMap { key -> Window? in
                guard let window = bucket[key] as? [String: Any],
                      let percent = window["usedPercent"] as? NSNumber,
                      CFGetTypeID(percent) != CFBooleanGetTypeID(),
                      percent.doubleValue.isFinite, (0...100).contains(percent.doubleValue)
                else { return nil }
                let duration = window["windowDurationMins"] as? NSNumber
                let minutes = duration.flatMap { number -> Int? in
                    let value = number.doubleValue
                    guard CFGetTypeID(number) != CFBooleanGetTypeID(), value.isFinite,
                          value > 0, value < Double(Int.max), value.rounded() == value else { return nil }
                    return Int(value)
                }
                let label: String
                if let m = minutes, m > 0 {
                    if m % 1440 == 0 { label = "\(m / 1440)j" }
                    else if m % 60 == 0 { label = "\(m / 60)h" }
                    else { label = "\(m)min" }
                } else { label = key == "primary" ? "principale" : "secondaire" }
                let reset = (window["resetsAt"] as? NSNumber)?.doubleValue
                return Window(id: key, label: label, usedFraction: percent.doubleValue / 100,
                              resetsAt: reset.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil })
            }
            guard !windows.isEmpty else { return nil }
            return Bucket(id: id, label: bucket["limitName"] as? String ?? id, windows: windows)
        }
        guard !buckets.isEmpty else { return nil }
        self.buckets = buckets
        self.receivedAt = receivedAt
    }
}
