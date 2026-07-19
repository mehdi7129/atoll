import Foundation

/// Événement décodé du flux `claude -p --output-format stream-json`.
/// Format vérifié dans docs/research/research-claude-integration.md (CLI 2.1.x).
/// Parsing DÉFENSIF : tout ce qui n'est pas reconnu devient `.other`.
public enum StreamEvent: Equatable, Sendable {
    /// system/init : la session démarre (id + modèle).
    case initialized(sessionID: String, model: String?)
    /// Fragment de texte de la réponse (content_block_delta / text_delta).
    case textDelta(String)
    /// Fragment de raisonnement (thinking_delta) — affiché en grisé si voulu.
    case thinkingDelta(String)
    /// Message assistant complet (fin d'un tour de contenu).
    case assistantText(String)
    /// Résultat final du tour (texte complet + coût éventuel).
    case result(text: String?, costUSD: Double?, isError: Bool)
    /// Changement de limite de débit (surface une alerte quota).
    case rateLimit(status: String?)
    /// Reconnu mais sans intérêt d'affichage (status, hook lifecycle…).
    case other(type: String)

    public init?(line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line),
              let dict = object as? [String: Any],
              let type = dict["type"] as? String else { return nil }
        self = StreamEvent.classify(type: type, dict: dict)
    }

    public init?(line: String) {
        guard let data = line.data(using: .utf8) else { return nil }
        self.init(line: data)
    }

    private static func classify(type: String, dict: [String: Any]) -> StreamEvent {
        switch type {
        case "system":
            if (dict["subtype"] as? String) == "init" {
                let sessionID = dict["session_id"] as? String ?? ""
                return .initialized(sessionID: sessionID, model: dict["model"] as? String)
            }
            return .other(type: "system/\(dict["subtype"] as? String ?? "?")")

        case "stream_event":
            return classifyStreamEvent(dict["event"] as? [String: Any])

        case "assistant":
            return .assistantText(extractText(fromMessage: dict["message"]))

        case "result":
            let cost = (dict["total_cost_usd"] as? NSNumber)?.doubleValue
            let isError = (dict["is_error"] as? Bool) ?? ((dict["subtype"] as? String) != "success")
            return .result(text: dict["result"] as? String, costUSD: cost, isError: isError)

        case "rate_limit_event":
            let info = dict["rate_limit_info"] as? [String: Any]
            return .rateLimit(status: info?["status"] as? String)

        default:
            return .other(type: type)
        }
    }

    /// Un stream_event enveloppe un événement SSE Anthropic brut.
    private static func classifyStreamEvent(_ event: [String: Any]?) -> StreamEvent {
        guard let event, let eventType = event["type"] as? String else {
            return .other(type: "stream_event")
        }
        if eventType == "content_block_delta", let delta = event["delta"] as? [String: Any] {
            switch delta["type"] as? String {
            case "text_delta":
                return .textDelta(delta["text"] as? String ?? "")
            case "thinking_delta":
                return .thinkingDelta(delta["thinking"] as? String ?? "")
            default:
                return .other(type: "delta")
            }
        }
        return .other(type: "sse/\(eventType)")
    }

    /// Concatène les blocs de texte d'un message API.
    private static func extractText(fromMessage message: Any?) -> String {
        guard let message = message as? [String: Any] else { return "" }
        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [[String: Any]] else { return "" }
        return blocks
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }
}
