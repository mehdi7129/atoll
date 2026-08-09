import Foundation

/// Édition chirurgicale du bloc `hooks` de `~/.claude/settings.json`.
///
/// Règles absolues (voir CLAUDE.md) :
/// - nos entrées sont identifiables par la présence de `atoll-bridge` dans la commande ;
/// - les hooks existants de l'utilisateur sont préservés à l'octet près (structure) ;
/// - un fichier non-JSON (JSONC, corrompu) fait échouer l'opération SANS écriture ;
/// - installation idempotente, désinstallation complète.
public enum HookSettingsEditor {
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
    public static let managedEvents: [ManagedEvent] = managedEvents(proactiveRecall: false)

    /// Jeu d'événements gérés pour un mode donné.
    ///
    /// `proactiveRecall` (Milestone B, OPT-IN, OFF par défaut) rend
    /// **UserPromptSubmit BLOQUANT** : un hook `async` est fire-and-forget, sa
    /// sortie n'est jamais lue — or c'est précisément par sa sortie
    /// (`additionalContext`) que le helper injecte les souvenirs liés au
    /// prompt. Timeout court (5 s) : la recherche locale se compte en
    /// millisecondes, et le helper sort en silence à la moindre anicroche
    /// (fail-open). Réglage OFF ⇒ on retombe sur `async: true`, zéro latence
    /// ajoutée au CLI — c'est le comportement historique.
    public static func managedEvents(proactiveRecall: Bool) -> [ManagedEvent] {
        [
            ManagedEvent("SessionStart"),
            proactiveRecall
                ? ManagedEvent("UserPromptSubmit", async: false, timeout: 5)
                : ManagedEvent("UserPromptSubmit"),
            ManagedEvent("PreToolUse"), ManagedEvent("PostToolUse"),
            ManagedEvent("PostToolUseFailure"), ManagedEvent("PermissionDenied"),
            ManagedEvent("Notification"), ManagedEvent("Stop"),
            ManagedEvent("StopFailure"), ManagedEvent("SubagentStart"),
            ManagedEvent("SubagentStop"), ManagedEvent("PreCompact"),
            ManagedEvent("PostCompact"), ManagedEvent("SessionEnd"),
            ManagedEvent("PermissionRequest", async: false, timeout: 86_400, matcher: "*"),
        ]
    }

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
    /// `proactiveRecall` : voir `managedEvents(proactiveRecall:)` — passer le
    /// mode voulu, l'installation est idempotente et remplace nos entrées.
    public static func install(into data: Data?, command: String,
                               proactiveRecall: Bool = false) throws -> Data {
        var settings = try parse(data)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        for event in managedEvents(proactiveRecall: proactiveRecall) {
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
    /// Insensible au MODE : la liste des événements est la même avec ou sans
    /// recall proactif (seul le caractère bloquant d'UserPromptSubmit change).
    public static func isInstalled(in data: Data?) -> Bool {
        guard let settings = try? parse(data),
              let hooks = settings["hooks"] as? [String: Any] else { return false }
        return managedEvents.allSatisfy { event in
            (hooks[event.name] as? [[String: Any]] ?? []).contains { isManagedEntry($0) }
        }
    }

    /// Le hook UserPromptSubmit installé est-il en mode recall proactif,
    /// c'est-à-dire BLOQUANT (`async` absent ou faux) ? Sert à détecter qu'une
    /// installation existante ne correspond plus au réglage et doit être
    /// réécrite. Hooks absents / structure inattendue → false (le mode par
    /// défaut, sans latence : le doute ne rend jamais un hook bloquant).
    public static func installedProactiveRecall(in data: Data?) -> Bool {
        guard let settings = try? parse(data),
              let hooks = settings["hooks"] as? [String: Any],
              let entries = hooks["UserPromptSubmit"] as? [[String: Any]] else { return false }
        for entry in entries {
            guard let inner = entry["hooks"] as? [[String: Any]] else { continue }
            for hook in inner where isManagedHook(hook) {
                if (hook["async"] as? Bool) != true { return true }
            }
        }
        return false
    }

    // MARK: - Interne

    /// `nil` = fichier ABSENT : on part d'un objet vide, c'est une création
    /// délibérée. Un `Data` PRÉSENT mais vide (ou uniquement blanc) est tout
    /// autre chose : un `settings.json` de 0 octet est un fichier CORROMPU —
    /// une troncature attrapée en vol (trois écrivains se partagent ce fichier :
    /// l'utilisateur, le CLI, nous). Les confondre était destructeur : `parse`
    /// rendait `[:]`, et l'écriture qui suit reposait un fichier ne contenant
    /// QUE nos hooks — statusLine, `permissions` (allow ET deny), `env`, `model`
    /// et les hooks tiers disparaissaient en silence. On refuse, comme pour tout
    /// JSON illisible : aucune écriture.
    ///
    /// L'asymétrie qui rendait le défaut invisible en relecture mérite d'être
    /// nommée : *corrompu* → refus propre, *absent* → création délibérée,
    /// *zéro octet* → écriture destructrice silencieuse. Trois branches, dont
    /// une seule était fausse.
    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard !isBlank(data) else { throw EditorError.unparseableSettings }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw EditorError.unparseableSettings
        }
        return dict
    }

    /// Vide, ou uniquement des espaces/retours : dans les deux cas il n'y a
    /// aucun JSON à préserver, et rien ne prouve qu'il n'y en avait pas avant.
    public static func isBlank(_ data: Data) -> Bool {
        String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
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
