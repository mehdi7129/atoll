import Foundation
import CoreFoundation

/// Compteurs natifs uniquement : aucune estimation depuis les caractères ou le coût.
/// `inputTokens` conserve la sémantique du fournisseur : Codex inclut les lectures
/// du cache, Claude les expose séparément. Ne pas sommer ces champs en un total.
public struct AnalysisUsage: Codable, Equatable, Sendable {
    public enum Availability: String, Codable, Sendable { case unknown, partial, reported }
    public enum Source: String, Codable, Sendable { case claudeResult, codexTurnCompleted }
    public enum Limitation: String, Codable, Sendable {
        case notReported, truncatedOutput, missingFields, unfinishedTurn
    }

    public let availability: Availability
    public let source: Source?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cachedInputTokens: Int?
    public let cacheCreationInputTokens: Int?
    public let reasoningOutputTokens: Int?
    public let limitation: Limitation?

    public static let unknown = Self(availability: .unknown, source: nil,
        inputTokens: nil, outputTokens: nil, cachedInputTokens: nil,
        cacheCreationInputTokens: nil, reasoningOutputTokens: nil, limitation: .notReported)

    /// `codex exec --json` livre un snapshot dans `turn.completed.usage` ; Claude
    /// livre l'usage cumulé dans l'enveloppe `result`. On retient le DERNIER,
    /// jamais la somme avec les messages, `modelUsage` ou un ancien snapshot.
    /// Les lecteurs des trois runners gardent au plus 4 Mio et un témoin d'excès.
    public static func parse(stdout: Data, provider: AgentProvider,
                             cap: Int = 4 * 1024 * 1024) -> Self {
        guard cap >= 0, stdout.count <= cap else {
            return Self(availability: .unknown, source: nil, inputTokens: nil,
                outputTokens: nil, cachedInputTokens: nil, cacheCreationInputTokens: nil,
                reasoningOutputTokens: nil, limitation: .truncatedOutput)
        }
        if provider == .claude {
            // Le mode JSON peut être indenté et précédé du bruit du shell de login.
            if let start = stdout.firstIndex(of: UInt8(ascii: "{")),
               let object = object(Data(stdout[start...])), isClaudeResult(object) {
                return from(object["usage"] as? [String: Any], source: .claudeResult)
            }
        }
        var latest = unknown
        for line in stdout.split(separator: UInt8(ascii: "\n")) {
            guard let object = object(Data(line)) else {
                // Un JSON interrompu après un snapshot ne prouve pas que ce
                // snapshot couvre tout le run. Le bruit textuel reste toléré.
                if latest.availability != .unknown,
                   line.drop(while: { $0 == 32 || $0 == 9 || $0 == 13 }).first == UInt8(ascii: "{") {
                    latest = latest.limited(by: .truncatedOutput)
                }
                continue
            }
            if provider == .claude, isClaudeResult(object) {
                latest = from(object["usage"] as? [String: Any], source: .claudeResult)
            } else if provider == .codex {
                switch object["type"] as? String {
                case "turn.completed":
                    latest = from(object["usage"] as? [String: Any], source: .codexTurnCompleted)
                case "turn.started", "turn.failed", "error":
                    // Une consommation postérieure peut manquer après échec/annulation.
                    if latest.availability != .unknown {
                        latest = latest.limited(by: .unfinishedTurn)
                    }
                default: break
                }
            }
        }
        return latest
    }

    private func limited(by reason: Limitation) -> Self {
        Self(availability: .partial, source: source, inputTokens: inputTokens,
            outputTokens: outputTokens, cachedInputTokens: cachedInputTokens,
            cacheCreationInputTokens: cacheCreationInputTokens,
            reasoningOutputTokens: reasoningOutputTokens, limitation: reason)
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func isClaudeResult(_ object: [String: Any]) -> Bool {
        object["type"] as? String == "result"
            || (object["type"] == nil && object["structured_output"] is [String: Any])
    }

    private static func from(_ usage: [String: Any]?, source: Source) -> Self {
        guard let usage else { return unknown }
        let input = count(usage["input_tokens"])
        let output = count(usage["output_tokens"])
        let cached = count(usage[source == .claudeResult ? "cache_read_input_tokens" : "cached_input_tokens"])
        let creation = source == .claudeResult ? count(usage["cache_creation_input_tokens"]) : nil
        let reasoning = source == .codexTurnCompleted ? count(usage["reasoning_output_tokens"]) : nil
        guard [input, output, cached, creation, reasoning].contains(where: { $0 != nil }) else { return unknown }
        let complete = input != nil && output != nil && cached != nil
            && (source == .codexTurnCompleted || creation != nil)
        return Self(availability: complete ? .reported : .partial, source: source,
            inputTokens: input, outputTokens: output, cachedInputTokens: cached,
            cacheCreationInputTokens: creation, reasoningOutputTokens: reasoning,
            limitation: complete ? nil : .missingFields)
    }

    /// JSON booléen, fraction, entier négatif ou hors Int : mesure inconnue,
    /// jamais coercition silencieuse en 0, 1 ou entier tronqué.
    private static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(number.stringValue), integer >= 0 else { return nil }
        return integer
    }
}
