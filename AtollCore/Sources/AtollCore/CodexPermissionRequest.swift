import Foundation

/// Copie immuable de la demande exacte. Une demande trop grosse ou inconnue
/// revient au terminal ; une troncature ne doit jamais cacher ce qu'on autorise.
public struct CodexPermissionRequest: Equatable, Sendable {
    public static let maximumBytes = 128 * 1024
    public let toolName: String
    public let cwd: String
    public let summary: String
    public let details: String

    public init?(payload: [String: Any]) {
        guard let name = payload["tool_name"] as? String, !name.isEmpty,
              let cwd = payload["cwd"] as? String, cwd.hasPrefix("/"),
              let input = payload["tool_input"],
              input is [String: Any] || input is String,
              JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              data.count <= Self.maximumBytes, let text = String(data: data, encoding: .utf8) else { return nil }
        toolName = name
        self.cwd = cwd
        details = text
        let fields = input as? [String: Any]
        let value = ["command", "cmd", "file_path", "path", "description", "patch", "diff"]
            .compactMap { fields?[$0] as? String }.first ?? (input as? String)
        summary = String((value.map { "\(name)(\($0))" } ?? name).prefix(120))
    }
}
