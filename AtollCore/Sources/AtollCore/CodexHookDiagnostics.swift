import Foundation

/// Interprétation de hooks/list, distincte de la présence sur disque.
public struct CodexHookDiagnostics: Equatable, Sendable {
    public let managedCount: Int
    public let disabledCount: Int
    public let untrustedCount: Int
    public let obsoleteCount: Int
    public let errorCount: Int

    public init?(data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = root["data"] as? [[String: Any]], !entries.isEmpty else { return nil }
        let hooks = entries.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .filter { $0["command"] as? String == CodexHookSettingsEditor.command }
        managedCount = hooks.count
        disabledCount = hooks.filter { $0["enabled"] as? Bool != true }.count
        untrustedCount = hooks.filter { !["trusted", "managed"].contains($0["trustStatus"] as? String ?? "") }.count
        obsoleteCount = hooks.filter { hook in
            guard let name = hook["eventName"] as? String,
                  let kind = CodexHookEvent.Kind.allCases.first(where: {
                      $0.rawValue.prefix(1).lowercased() + $0.rawValue.dropFirst() == name
                  }) else { return true }
            let synchronous = CodexHookSettingsEditor.synchronousEvents.contains(kind)
            return (hook["async"] as? Bool ?? false) == synchronous
                || hook["timeoutSec"] as? Int != (kind == .permissionRequest ? 600 : 3)
                || (kind == .permissionRequest && hook["statusMessage"] as? String
                    != CodexHookSettingsEditor.permissionStatusMessage)
        }.count
        errorCount = entries.reduce(0) { $0 + ($1["errors"] as? [[String: Any]] ?? []).count }
    }

    public var summary: String {
        if errorCount > 0 { return "\(errorCount) erreur(s) de configuration — ouvre /hooks dans ce projet" }
        if managedCount == 0 { return "aucun hook Atoll reconnu par Codex pour ce dossier" }
        if disabledCount > 0 { return "\(disabledCount) hook(s) désactivé(s) — ouvre /hooks" }
        if obsoleteCount > 0 || managedCount < CodexHookEvent.Kind.allCases.count {
            return "définitions Atoll incomplètes ou obsolètes — réparer l'installation"
        }
        if untrustedCount > 0 { return "\(untrustedCount) hook(s) à approuver — ouvre /hooks" }
        return "\(managedCount) hooks actifs et approuvés · attente d'événements de la TUI"
    }
}
