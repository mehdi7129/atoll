import Foundation

/// Édition chirurgicale du bloc `hooks` de `~/.claude/settings.json`.
///
/// Règles absolues (voir CLAUDE.md) :
/// - nos entrées sont identifiables par la présence de `atoll-bridge` dans la commande ;
/// - les hooks existants de l'utilisateur sont préservés à l'octet près (structure) ;
/// - un fichier non-JSON (JSONC, corrompu) fait échouer l'opération SANS écriture ;
/// - installation idempotente, désinstallation complète.
public enum HookSettingsEditor {
    public static let managedMarker = "atoll-bridge"

    public struct ManagedEvent: Sendable {
        public let name: String
        /// Fire-and-forget (n'ajoute aucune latence au CLI).
        public let async: Bool
        public let timeout: Int
        public let matcher: String?

        init(_ name: String, async: Bool = true, timeout: Int = 10, matcher: String? = nil) {
            self.name = name
            self.async = async
            self.timeout = timeout
            self.matcher = matcher
        }
    }

    /// Les événements d'état sont async (jamais de latence CLI) ; PermissionRequest
    /// est BLOQUANT (timeout 86400 = l'îlot peut répondre pendant 24 h — même
    /// valeur que Vibe Island/open-vibe-island) et fail-open : si l'app ne répond
    /// pas, le helper sort en silence et le prompt terminal reprend la main.
    public static let managedEvents: [ManagedEvent] = [
        ManagedEvent("SessionStart"), ManagedEvent("UserPromptSubmit"),
        ManagedEvent("PreToolUse"), ManagedEvent("PostToolUse"),
        ManagedEvent("PostToolUseFailure"), ManagedEvent("PermissionDenied"),
        ManagedEvent("Notification"), ManagedEvent("Stop"),
        ManagedEvent("StopFailure"), ManagedEvent("SubagentStart"),
        ManagedEvent("SubagentStop"), ManagedEvent("PreCompact"),
        ManagedEvent("PostCompact"), ManagedEvent("SessionEnd"),
        ManagedEvent("PermissionRequest", async: false, timeout: 86_400, matcher: "*"),
    ]

    public static var managedEventNames: [String] { managedEvents.map(\.name) }

    public enum EditorError: Error, Equatable {
        /// Le fichier existe mais n'est pas un objet JSON valide (JSONC ? corrompu ?).
        /// On refuse d'y toucher plutôt que de risquer de le corrompre.
        case unparseableSettings
    }

    // MARK: - API

    /// Installe (ou réinstalle) nos hooks. `data` = contenu actuel du fichier, nil si absent.
    /// Un événement géré dont la valeur a une structure inattendue fait ÉCHOUER
    /// l'opération (aucune écriture) plutôt que de perdre des hooks utilisateur.
    public static func install(into data: Data?, command: String) throws -> Data {
        var settings = try parse(data)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for event in managedEvents {
            var entries = try strictEntries(hooks[event.name])
            entries.removeAll { isManagedEntry($0) }
            var hook: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": event.timeout,
            ]
            if event.async { hook["async"] = true }
            var entry: [String: Any] = ["hooks": [hook]]
            if let matcher = event.matcher { entry["matcher"] = matcher }
            entries.append(entry)
            hooks[event.name] = entries
        }

        settings["hooks"] = hooks
        return try serialize(settings)
    }

    /// Retire toutes nos entrées. Les événements dont la valeur a une structure
    /// inattendue — ou qui ne contiennent aucun de nos hooks — sont laissés
    /// STRICTEMENT intacts.
    public static func uninstall(from data: Data?) throws -> Data {
        var settings = try parse(data)
        guard var hooks = settings["hooks"] as? [String: Any] else {
            return try serialize(settings)
        }

        for (event, value) in hooks {
            // Valeur non conforme (édition manuelle, format futur) → intouchée.
            guard let entries = value as? [[String: Any]],
                  entries.contains(where: { containsManagedHook($0) }) else { continue }

            let remaining = entries.compactMap { entry -> [String: Any]? in
                if isManagedEntry(entry) { return nil }
                // Entrée mixte : on retire seulement nos hooks, on garde le reste.
                var entry = entry
                if var inner = entry["hooks"] as? [[String: Any]] {
                    inner.removeAll { isManagedHook($0) }
                    if inner.isEmpty { return nil }
                    entry["hooks"] = inner
                }
                return entry
            }
            hooks[event] = remaining.isEmpty ? nil : remaining
        }

        if hooks.isEmpty {
            settings["hooks"] = nil
        } else {
            settings["hooks"] = hooks
        }
        return try serialize(settings)
    }

    /// Nos hooks sont-ils installés (tous les événements gérés couverts) ?
    public static func isInstalled(in data: Data?) -> Bool {
        guard let settings = try? parse(data),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        return managedEvents.allSatisfy { event in
            (hooks[event.name] as? [[String: Any]] ?? []).contains { isManagedEntry($0) }
        }
    }

    // MARK: - Interne

    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw EditorError.unparseableSettings
        }
        return dict
    }

    private static func serialize(_ settings: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// nil → [] (événement absent) ; présent mais mal formé → erreur, refus d'écrire.
    private static func strictEntries(_ value: Any?) throws -> [[String: Any]] {
        guard let value else { return [] }
        guard let entries = value as? [[String: Any]] else {
            throw EditorError.unparseableSettings
        }
        return entries
    }

    private static func containsManagedHook(_ entry: [String: Any]) -> Bool {
        (entry["hooks"] as? [[String: Any]])?.contains { isManagedHook($0) } == true
    }

    private static func isManagedEntry(_ entry: [String: Any]) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]], !inner.isEmpty else { return false }
        return inner.allSatisfy { isManagedHook($0) }
    }

    /// Marquage par le CHEMIN du wrapper — pas par la simple sous-chaîne
    /// « atoll-bridge », qu'une commande utilisateur pourrait contenir.
    private static func isManagedHook(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.contains(".atoll/bin/atoll-bridge") == true
    }
}
