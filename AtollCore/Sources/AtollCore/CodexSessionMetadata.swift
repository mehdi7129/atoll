import Foundation
import CoreFoundation

/// Enrichissement facultatif du rollout, jamais utilisé comme preuve de vie.
/// Champs observés sur les rollouts CLI 0.153.4 ; lecture bornée tête + fin.
public struct CodexSessionMetadata: Sendable {
    public let branchAtStart: String?
    public let firstHumanPrompt: String?
    public let model: String?
    public let contextUsage: ContextTokenUsage?
    public var contextFraction: Double? { contextUsage?.fraction }
    public let contextAt: Date?

    public static func read(at url: URL, sessionID: String) -> Self? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let cap = 1_048_576
        guard let prefix = try? handle.read(upToCount: cap),
              let size = try? handle.seekToEnd() else { return nil }
        let head = prefix.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        guard let meta = head.first(where: { $0["type"] as? String == "session_meta" })?["payload"] as? [String: Any],
              let id = (meta["id"] as? String) ?? (meta["session_id"] as? String),
              sessionID == id || sessionID == "codex:" + id else { return nil }
        var tail = head
        if size > UInt64(cap) {
            do {
                try handle.seek(toOffset: size - UInt64(cap))
                guard let bytes = try handle.read(upToCount: cap) else { return nil }
                // Premier fragment potentiellement coupé ; un JSONL entier
                // n'est jamais reconstruit par concaténation approximative.
                tail = bytes.split(separator: 10).dropFirst().compactMap {
                    try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
                }
            } catch { return nil }
        }
        let first = head.lazy.compactMap { object -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return CodexTranscriptParser.parse(data)?.fragments.first(where: { $0.role == .user })?.text
        }.first.map { String($0.prefix(200)) }
        var model: String?, usage: ContextTokenUsage?, measuredAt: Date?
        for root in tail {
            guard let payload = root["payload"] as? [String: Any] else { continue }
            if root["type"] as? String == "turn_context", let value = payload["model"] as? String { model = value }
            if root["type"] as? String == "compacted" { usage = nil; measuredAt = nil }
            if root["type"] as? String == "event_msg", payload["type"] as? String == "token_count" {
                // Une mesure récente inconnue efface l'ancienne, elle n'est
                // ni zéro ni une preuve de consommation actuelle.
                usage = nil; measuredAt = nil
                if let info = payload["info"] as? [String: Any],
                   let last = info["last_token_usage"] as? [String: Any],
                   let used = Self.tokenCount(last["total_tokens"]),
                   let window = Self.tokenCount(info["model_context_window"]),
                   let current = ContextTokenUsage(usedTokens: used, windowTokens: window) {
                    usage = current
                    if let stamp = root["timestamp"] as? String {
                        let format = ISO8601DateFormatter()
                        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        measuredAt = format.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
                    }
                }
            }
        }
        return Self(branchAtStart: (meta["git"] as? [String: Any])?["branch"] as? String,
                    firstHumanPrompt: first, model: model, contextUsage: usage, contextAt: measuredAt)
    }

    private static func tokenCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int(exactly: number.doubleValue)
    }
}
