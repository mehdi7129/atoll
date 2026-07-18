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

    /// Événements installés en Phase 2 — tous en fire-and-forget (`async`).
    /// `PermissionRequest` (bloquant) arrivera en Phase 3 avec l'UI de réponse.
    public static let managedEvents = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "PermissionDenied", "Notification", "Stop",
        "StopFailure", "SubagentStart", "SubagentStop", "PreCompact",
        "PostCompact", "SessionEnd",
    ]

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
            var entries = try strictEntries(hooks[event])
            entries.removeAll { isManagedEntry($0) }
            entries.append([
                "hooks": [
                    [
                        "type": "command",
                        "command": command,
                        "async": true,
                        "timeout": 10,
                    ] as [String: Any]
                ]
            ])
            hooks[event] = entries
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
            (hooks[event] as? [[String: Any]] ?? []).contains { isManagedEntry($0) }
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
