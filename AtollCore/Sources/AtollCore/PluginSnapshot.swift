import Foundation

// Décodage PUR de l'état des plugins Claude Code (jalon 12c, « boucle fermée »).
//
// CE QUE CE FICHIER EST : du parsing, rien d'autre. Aucun spawn de processus,
// aucune I/O, aucun accès disque — l'app fournit les octets, ce fichier rend des
// valeurs. Même contrat que `AgentsSnapshot` pour `claude agents --json`, et pour
// la même raison : ce sont les sorties d'une COMMANDE, pas d'une API versionnée.
//
// LES TROIS SOURCES, ET LE DEGRÉ DE CONFIANCE À LEUR ACCORDER :
//
// 1. `claude plugin list --json` — interface machine, FAIT AUTORITÉ sur l'état
//    installé/activé. Forme RÉELLE observée (CLI 2.1.220, 2026-07-27) : un
//    TABLEAU JSON nu de 31 entrées, clés `id`, `version`, `scope`, `enabled`,
//    `installPath`, `installedAt`, `lastUpdated`, et — seulement quand il y a
//    lieu — `mcpServers` (un OBJET nom → configuration) et `errors` (un tableau
//    de messages « Path not found: … »).
//    ⚠️ Il n'y a PAS de champ `name` dans cette liste : le nom se lit dans l'`id`
//    (`swift-lsp@claude-plugins-official` → nom `swift-lsp`, marketplace
//    `claude-plugins-official`).
//
// 2. `claude plugin list --available --json` — même commande, réponse de forme
//    DIFFÉRENTE : un OBJET `{ "installed": [...], "available": [...] }` (268
//    entrées disponibles). Champs d'`available[]` : `pluginId`, `name`,
//    `description`, `marketplaceName`, `version`, `source` (chaîne OU objet) et
//    `installCount` — présent sur ~85 % des entrées (227/268), c'est le signal
//    de popularité utilisé pour classer. Cet appel TOUCHE LE RÉSEAU : côté app,
//    watchdog obligatoire (même piège que le FleetPoller).
//    → `decode` accepte les DEUX formes ; un tableau nu est traité comme la
//      liste installée. Aucun appelant n'a à savoir laquelle il tient.
//
// 3. `claude plugin details <nom>` — sortie TEXTE destinée à un humain, donc la
//    moins stable des trois : alignement à l'espace, `~` d'approximation,
//    séparateurs de milliers. `PluginDetails` la parse de façon strictement
//    textuelle et rend nil/[:] plutôt que de deviner. Ne JAMAIS en faire une
//    dépendance dure : c'est un enrichissement (« ce que tes plugins te coûtent
//    à chaque session »), pas un état.
//
// RÈGLE ABSOLUE D'ÉCRITURE : Atoll n'écrit JAMAIS dans `~/.claude/settings.json`
// (clé `enabledPlugins`) ni dans le cache `~/.claude/plugins/`. Activer,
// désactiver, installer ou supprimer un plugin passe EXCLUSIVEMENT par la CLI
// (`claude plugin install|enable|disable`), sur action explicite de
// l'utilisateur. Seule la CLI a le droit de modifier l'état ; ce fichier, lui,
// ne sait que lire.
//
// Défensif de bout en bout : une entrée sans identité est ignorée en silence,
// un champ manquant devient nil/false, un type inattendu n'interrompt jamais le
// décodage des autres entrées. Un catalogue de plugins ne doit pas pouvoir
// empêcher Atoll de tourner.

// MARK: - Plugin installé

/// Un plugin présent dans le cache local, tel que le rapporte `plugin list --json`.
public struct InstalledPlugin: Equatable, Sendable, Identifiable {
    /// Identifiant complet et unique : `<nom>@<marketplace>` (ex.
    /// `swift-lsp@claude-plugins-official`). C'est ce que la CLI attend.
    public let id: String
    /// Nom court, sans le marketplace. Dérivé de l'`id` (la liste n'expose pas
    /// de champ `name`), sauf si un jour le JSON en fournit un.
    public let name: String
    /// Provenance, lue après le dernier `@` de l'`id` ; nil si l'id n'en a pas.
    /// Deux plugins de MÊME nom et de marketplaces différents = doublon (cas
    /// réel, cf. `duplicateNames`).
    public let marketplace: String?
    /// Tel quel — `"unknown"` est une valeur RÉELLE émise par la CLI et n'est
    /// donc pas transformée en nil : ne rien inventer.
    public let version: String?
    /// `user` / `project` / `local`. Chaîne brute : le vocabulaire appartient à
    /// la CLI, Atoll ne le referme pas dans un enum qu'une MAJ rendrait faux.
    public let scope: String?
    /// Installé n'est PAS activé : chez l'utilisateur, 31 installés / 4 activés.
    public let isEnabled: Bool
    public let installPath: String?
    /// La CLI a signalé des composants déclarés mais introuvables (clé `errors`,
    /// messages « Path not found: … »). Un plugin ACTIVÉ peut être cassé —
    /// c'est exactement ce que le panneau doit pouvoir dire.
    public let hasLoadError: Bool
    /// Noms des serveurs MCP que ce plugin démarre (clés de `mcpServers`, triées
    /// pour un ordre déterministe). Vide = le plugin ne lance aucun serveur.
    public let mcpServerNames: [String]

    public init(
        id: String,
        name: String,
        marketplace: String?,
        version: String?,
        scope: String?,
        isEnabled: Bool,
        installPath: String?,
        hasLoadError: Bool,
        mcpServerNames: [String]
    ) {
        self.id = id
        self.name = name
        self.marketplace = marketplace
        self.version = version
        self.scope = scope
        self.isEnabled = isEnabled
        self.installPath = installPath
        self.hasLoadError = hasLoadError
        self.mcpServerNames = mcpServerNames
    }
}

// MARK: - Plugin disponible

/// Une entrée du catalogue des marketplaces (`plugin list --available --json`).
public struct AvailablePlugin: Equatable, Sendable, Identifiable {
    /// `pluginId` : `<nom>@<marketplace>`, l'argument d'un futur
    /// `claude plugin install`.
    public let id: String
    public let name: String
    public let description: String?
    /// `marketplaceName`, ou à défaut la part de l'`id` après le dernier `@`.
    public let marketplace: String?
    public let version: String?
    /// Nombre d'installations rapporté par le marketplace — ABSENT sur ~15 %
    /// des entrées. nil ≠ 0 : « inconnu » se classe en dernier, il ne se
    /// transforme jamais en « impopulaire ».
    public let installCount: Int?

    public init(
        id: String,
        name: String,
        description: String?,
        marketplace: String?,
        version: String?,
        installCount: Int?
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.marketplace = marketplace
        self.version = version
        self.installCount = installCount
    }
}

// MARK: - Instantané

/// L'état des plugins à un instant donné : ce qui est installé, ce qui est
/// disponible, et les anomalies qu'on peut en déduire sans rien exécuter.
public struct PluginSnapshot: Equatable, Sendable {
    public let installed: [InstalledPlugin]
    public let available: [AvailablePlugin]

    public init(installed: [InstalledPlugin] = [], available: [AvailablePlugin] = []) {
        self.installed = installed
        self.available = available
    }

    /// Instantané sans rien dedans (aucune clé exploitable dans le JSON).
    public static let empty = PluginSnapshot()

    // MARK: Diagnostic

    /// Combien de plugins sont réellement ACTIFS (le reste ne coûte rien mais
    /// ne sert à rien non plus).
    public var enabledCount: Int {
        installed.lazy.filter(\.isEnabled).count
    }

    /// Installés mais jamais activés — ordre de la liste d'origine préservé.
    public var installedButDisabled: [InstalledPlugin] {
        installed.filter { !$0.isEnabled }
    }

    /// Plugins dont la CLI signale des fichiers déclarés manquants, ACTIVÉS OU
    /// NON : un plugin cassé mais activé est le cas le plus grave, un plugin
    /// cassé et inactif reste une anomalie à montrer.
    public var broken: [InstalledPlugin] {
        installed.filter(\.hasLoadError)
    }

    /// Noms installés depuis DEUX provenances différentes (triés, sans doublon).
    /// Cas réel chez l'utilisateur : `feature-dev` existe à la fois sur
    /// `claude-code-plugins` et `claude-plugins-official`.
    ///
    /// Une entrée sans marketplace compte comme une provenance à part entière :
    /// « le même nom vient de deux endroits » reste vrai et mérite d'être dit.
    public var duplicateNames: [String] {
        var marketplacesByName: [String: Set<String>] = [:]
        for plugin in installed {
            marketplacesByName[plugin.name, default: []].insert(plugin.marketplace ?? "")
        }
        return marketplacesByName
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
    }

    // MARK: Décodage

    /// Décode la sortie de `plugin list --json` (tableau nu) OU de
    /// `plugin list --available --json` (objet `installed`/`available`).
    ///
    /// Rend nil UNIQUEMENT si les octets ne sont pas un conteneur JSON (texte
    /// libre, message d'erreur de la CLI, scalaire) — c'est-à-dire quand il n'y
    /// a rien à lire du tout. Sinon on rend TOUJOURS ce qu'on a pu lire : clés
    /// absentes → instantané vide, entrée sans `id` exploitable → ignorée en
    /// silence, jamais d'échec global. Une seule entrée d'un format futur ne
    /// doit pas faire perdre les 267 autres.
    public static func decode(_ data: Data) -> PluginSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        // Forme réelle de `plugin list --json` : un tableau nu = la liste installée.
        if let array = root as? [Any] {
            return PluginSnapshot(installed: decodeInstalled(array), available: [])
        }

        guard let object = root as? [String: Any] else { return nil }
        return PluginSnapshot(
            installed: decodeInstalled(object["installed"] as? [Any] ?? []),
            available: decodeAvailable(object["available"] as? [Any] ?? [])
        )
    }

    private static func decodeInstalled(_ entries: [Any]) -> [InstalledPlugin] {
        entries.compactMap { raw in
            guard let entry = raw as? [String: Any],
                  let id = firstString(entry, "id", "pluginId")
            else { return nil }

            let (derivedName, derivedMarketplace) = splitIdentifier(id)
            return InstalledPlugin(
                id: id,
                name: nonEmptyString(entry["name"]) ?? derivedName,
                marketplace: nonEmptyString(entry["marketplaceName"]) ?? derivedMarketplace,
                version: nonEmptyString(entry["version"]),
                scope: nonEmptyString(entry["scope"]),
                isEnabled: boolean(entry["enabled"]),
                installPath: nonEmptyString(entry["installPath"]),
                hasLoadError: hasLoadError(entry),
                mcpServerNames: mcpServerNames(entry["mcpServers"])
            )
        }
    }

    private static func decodeAvailable(_ entries: [Any]) -> [AvailablePlugin] {
        entries.compactMap { raw in
            guard let entry = raw as? [String: Any],
                  let id = firstString(entry, "pluginId", "id")
            else { return nil }

            let (derivedName, derivedMarketplace) = splitIdentifier(id)
            return AvailablePlugin(
                id: id,
                name: nonEmptyString(entry["name"]) ?? derivedName,
                description: nonEmptyString(entry["description"]),
                marketplace: nonEmptyString(entry["marketplaceName"]) ?? derivedMarketplace,
                version: nonEmptyString(entry["version"]),
                installCount: integer(entry["installCount"])
            )
        }
    }

    // MARK: Classement et rendu

    /// Le catalogue disponible classé par POPULARITÉ décroissante, `limit`
    /// entrées au plus.
    ///
    /// Ordre TOTAL (le tri de Swift n'est pas stable : sans départage complet,
    /// deux appels pourraient rendre deux ordres) : `installCount` décroissant,
    /// les inconnus (nil) en dernier, puis nom croissant, puis `id` croissant.
    public func availableRanked(limit: Int) -> [AvailablePlugin] {
        guard limit > 0 else { return [] }
        return Array(available.sorted(by: Self.isMorePopular).prefix(limit))
    }

    /// Le catalogue rendu pour un prompt de recherche d'antériorité (jalon 12b :
    /// « existe-t-il déjà un plugin qui fait ça ? »), une entrée par ligne :
    ///
    ///     - <id> (<N> installations) : <description>
    ///
    /// Le compteur d'installations disparaît s'il est inconnu, la description si
    /// elle est absente. Chaque description est mise à plat (retours à la ligne
    /// et blancs multiples réduits à une espace — une entrée = une ligne, quoi
    /// qu'écrive le marketplace) et capée à 200 caractères.
    ///
    /// DOUBLE plafond : `limit` entrées ET `promptCharacterCap` caractères. La
    /// coupe se fait toujours sur une frontière de ligne — jamais une entrée
    /// tronquée en plein milieu, qui donnerait un id incomplet au modèle.
    /// La troncature est ANNONCÉE au modèle. Sans marqueur, il concluait
    /// « aucun plugin ne correspond » — réponse que le prompt lui présente
    /// explicitement comme correcte — à partir d'un catalogue amputé de plus de
    /// la moitié (120 lignes sur 268 mesurées), pendant que l'interface promet
    /// à l'utilisateur une comparaison au catalogue entier. Le jumeau
    /// `SkillCatalog.summaryForPrompt` pose déjà ce marqueur (audit du
    /// 2026-07-27).
    public func summaryForPrompt(limit: Int = 120) -> String {
        promptCatalog(limit: limit).text
    }

    /// Le catalogue tel qu'il part dans le prompt, ET les identifiants qu'il
    /// contient RÉELLEMENT.
    ///
    /// `PluginSearchResult.parse(cliOutput:knownIDs:)` documente que `knownIDs`
    /// est « les identifiants du catalogue réellement fourni au modèle » — la
    /// garde qui empêche une hallucination de devenir une commande
    /// d'installation. L'appelant passait pourtant TOUS les `available` :
    /// mesuré, 268 identifiants validés pour ~120 montrés, soit près de 150
    /// acceptés sans avoir jamais été sous les yeux du modèle. Exactement le cas
    /// que cette garde existe pour couvrir.
    ///
    /// Les redériver côté appelant (`availableRanked(limit:)`) ne suffisait pas :
    /// c'est le plafond de 30 000 caractères, pas la limite d'entrées, qui coupe
    /// le plus souvent. Une seule fonction décide donc de ce qui est montré, et
    /// c'est elle qui dit ce qu'elle a montré.
    public func promptCatalog(limit: Int = 120) -> (text: String, shownIDs: Set<String>) {
        // Deux passes : on rend d'abord tel quel ; s'il manque des entrées, on
        // recommence en RÉSERVANT la place du marqueur. Il compte donc DANS le
        // plafond, il ne s'y ajoute pas — sinon le rendu dépasserait le budget
        // qu'il est justement censé faire respecter.
        let entries = render(limit: limit, reserve: 0)
        guard available.count > entries.count else {
            return (entries.map(\.line).joined(separator: "\n"), Set(entries.compactMap(\.id)))
        }
        let bounded = render(limit: limit, reserve: Self.truncationMarkerReserve)
        let hidden = available.count - bounded.count
        let text = (bounded.map(\.line) + [Self.truncationMarker(hidden: hidden)])
            .joined(separator: "\n")
        return (text, Set(bounded.compactMap(\.id)))
    }

    private func render(limit: Int, reserve: Int) -> [(id: String?, line: String)] {
        var rendered: [(id: String?, line: String)] = []
        var total = 0
        for plugin in availableRanked(limit: limit) {
            let line = Self.promptLine(for: plugin)
            let cost = line.count + (rendered.isEmpty ? 0 : 1) // le "\n" de jointure
            if total + cost > Self.promptCharacterCap - reserve { break }
            total += cost
            // Un identifiant plus long que `promptIdentifierCap` est TRONQUÉ
            // dans la ligne : le modèle ne peut alors pas le citer exactement,
            // et il ne doit pas figurer parmi ceux qu'on dit lui avoir montrés.
            // L'invariant tenu est donc strict : tout `shownID` apparaît
            // verbatim dans le texte.
            rendered.append((line.contains(plugin.id) ? plugin.id : nil, line))
        }
        return rendered
    }

    /// Marqueur de troncature, en français comme le reste des consignes.
    static func truncationMarker(hidden: Int) -> String {
        "… (\(hidden) autre(s) entrée(s) du catalogue non listée(s) ici : "
        + "si rien ci-dessus ne convient, dis-le sans affirmer qu'aucun plugin n'existe)"
    }

    /// Majorant de la longueur du marqueur (le nombre masqué tient largement).
    static let truncationMarkerReserve = 160

    /// Plafond dur du rendu de `summaryForPrompt` (caractères).
    public static let promptCharacterCap = 30_000
    /// Plafond d'une description dans ce rendu (caractères, ellipse comprise).
    public static let promptDescriptionCap = 200

    /// Plafond d'un identifiant dans ce rendu. Généreux — les vrais font 20 à
    /// 45 caractères — mais BORNÉ : c'est du texte venu d'un marketplace tiers.
    public static let promptIdentifierCap = 120

    static func promptLine(for plugin: AvailablePlugin) -> String {
        // L'identifiant est APLATI et BORNÉ comme la description, alors qu'il
        // partait verbatim. `nonEmptyString` ne coupe que les blancs de BORD :
        // un `pluginId` contenant un retour à la ligne survivait intact et
        // cassait l'invariant « une entrée = une ligne » sur lequel repose tout
        // le rendu — un identifiant pouvait fabriquer sa propre ligne, y compris
        // une fausse fin de catalogue. Le catalogue vient de marketplaces tiers
        // et part dans un prompt : il ne mérite pas plus de confiance que la
        // description, qui, elle, était déjà traitée.
        var line = "- " + flattened(plugin.id, cap: promptIdentifierCap)
        if let count = plugin.installCount, count >= 0 {
            line += count == 1 ? " (1 installation)" : " (\(count) installations)"
        }
        if let description = plugin.description.map({ flattened($0) }), !description.isEmpty {
            line += " : " + description
        }
        return line
    }

    /// Ordre total, cf. `availableRanked`.
    private static func isMorePopular(_ lhs: AvailablePlugin, _ rhs: AvailablePlugin) -> Bool {
        switch (lhs.installCount, rhs.installCount) {
        case let (left?, right?):
            if left != right { return left > right }
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case (nil, nil):
            break
        }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return lhs.id < rhs.id
    }

    /// Texte mis à plat (blancs de toute nature réduits à une espace) puis capé.
    private static func flattened(_ raw: String, cap: Int = promptDescriptionCap) -> String {
        let collapsed = raw
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard collapsed.count > cap else { return collapsed }
        return String(collapsed.prefix(cap - 1)) + "…"
    }

    // MARK: Lecture défensive des champs

    /// Chaîne non vide, ou nil. Absorbe `null` (NSNull) et les types inattendus.
    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Première clé qui porte une chaîne exploitable — le repli `id`/`pluginId`.
    ///
    /// À écrire ainsi, et PAS `entry["id"] ?? entry["pluginId"]` : sur un
    /// `[String: Any]`, un JSON `"id": null` devient `.some(NSNull())`, donc le
    /// `??` est satisfait et ne consulte JAMAIS la seconde clé. Le repli était
    /// neutralisé exactement dans le cas où il sert — une clé présente mais
    /// nulle — et l'entrée disparaissait en silence du `compactMap`.
    private static func firstString(_ entry: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = nonEmptyString(entry[key]) { return value }
        }
        return nil
    }

    /// Booléen tolérant : `true`, `1`, `"true"`, `"yes"`… Absent ou illisible
    /// → false (ne JAMAIS présumer un plugin actif : ce serait annoncer un coût
    /// en tokens que l'utilisateur ne paie pas).
    private static func boolean(_ raw: Any?) -> Bool {
        if let number = raw as? NSNumber { return number.boolValue }
        switch (raw as? String)?.lowercased() {
        case "true", "yes", "1": return true
        default: return false
        }
    }

    /// Entier tolérant (`installCount` peut arriver en nombre ou en chaîne).
    private static func integer(_ raw: Any?) -> Int? {
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// `<nom>@<marketplace>` → ses deux moitiés. Découpe sur le DERNIER `@` (un
    /// nom de marketplace n'en contient pas, un nom de plugin pourrait). Pas de
    /// `@`, ou une moitié vide → tout l'id sert de nom, marketplace nil.
    static func splitIdentifier(_ id: String) -> (name: String, marketplace: String?) {
        guard let at = id.lastIndex(of: "@") else { return (id, nil) }
        let name = String(id[id.startIndex..<at])
        let marketplace = String(id[id.index(after: at)...])
        guard !name.isEmpty, !marketplace.isEmpty else { return (id, nil) }
        return (name, marketplace)
    }

    /// La CLI émet un tableau de messages (`errors`) quand des composants
    /// déclarés sont introuvables. Les autres formes (chaîne, objet, clé
    /// `error` au singulier) sont acceptées par précaution — seule compte la
    /// réponse à « y a-t-il quelque chose de cassé ici ? ».
    private static func hasLoadError(_ entry: [String: Any]) -> Bool {
        for key in ["errors", "error", "loadErrors", "loadError"] {
            guard let raw = entry[key] else { continue }
            if let array = raw as? [Any], !array.isEmpty { return true }
            if let dictionary = raw as? [String: Any], !dictionary.isEmpty { return true }
            if nonEmptyString(raw) != nil { return true }
        }
        return false
    }

    /// `mcpServers` est en pratique un OBJET nom → configuration : on en garde
    /// les clés, TRIÉES (l'ordre d'un dictionnaire JSON n'est pas défini, et un
    /// instantané qui « bouge » tout seul relancerait des rendus pour rien).
    /// La forme tableau (chaînes, ou objets à clé `name`) est tolérée et garde
    /// son ordre, qui est alors une information de l'émetteur.
    private static func mcpServerNames(_ raw: Any?) -> [String] {
        if let dictionary = raw as? [String: Any] {
            return dictionary.keys.sorted()
        }
        if let array = raw as? [Any] {
            return array.compactMap { item in
                if let name = nonEmptyString(item) { return name }
                if let object = item as? [String: Any] { return nonEmptyString(object["name"]) }
                return nil
            }
        }
        return []
    }
}

// MARK: - `claude plugin details <nom>` (sortie humaine)

/// Extraction de chiffres dans la sortie TEXTE de `claude plugin details`.
///
/// Format observé (CLI 2.1.220) :
///
///     example-skills
///       Collection of example skills demonstrating…
///       Source: example-skills@anthropic-agent-skills
///
///     Component inventory
///       Skills (12)  algorithmic-art, brand-guidelines, …
///       Agents (0)
///       Hooks (4)  SessionStart, …  (harness-only — no model context cost)
///       MCP servers (0)
///       LSP servers (1)  sourcekit-lsp  (out-of-process tooling; …)
///
///     Projected token cost
///       Always-on:   ~1,221 tok   added to every session
///
/// C'est de l'AFFICHAGE : alignement à l'espace, `~` d'approximation,
/// séparateurs de milliers. Ça changera. Tout est donc lu au caractère, sans
/// expression régulière compilée à la volée ni conversion qui puisse lever :
/// au pire on rend nil / un dictionnaire vide, et l'app se passe du chiffre.
public enum PluginDetails {

    /// Le coût « toujours chargé » d'un plugin, en tokens ajoutés à CHAQUE
    /// session — l'argument produit central du panneau.
    ///
    /// Tolère `~`/`≈`, les espaces multiples, `tok` comme `tokens`, et les
    /// séparateurs de milliers (`,`, `'`, espace fine ou insécable). Le nombre
    /// doit être sur la MÊME ligne que l'étiquette (sinon on récupérerait un
    /// chiffre d'une section suivante). Étiquette absente, ou présente sans
    /// nombre → nil, jamais 0 : « inconnu » et « gratuit » ne se confondent pas.
    public static func alwaysOnTokens(from text: String) -> Int? {
        // Plusieurs occurrences possibles (l'en-tête du tableau par composant
        // contient « always-on » sans chiffre) : on prend la première qui porte
        // réellement un nombre.
        for marker in ["Always-on", "Always on"] {
            var searchStart = text.startIndex
            while let found = text.range(
                of: marker,
                options: [.caseInsensitive],
                range: searchStart..<text.endIndex
            ) {
                if let value = number(inLineAfter: found.upperBound, of: text) { return value }
                searchStart = found.upperBound
            }
        }
        return nil
    }

    // MARK: Lecture au caractère

    /// Premier entier trouvé entre `start` et la fin de SA ligne.
    private static func number(inLineAfter start: String.Index, of text: String) -> Int? {
        var index = start
        var digits = ""

        while index < text.endIndex {
            let character = text[index]
            if character.isNewline { break }

            if character.isNumber {
                digits.append(character)
                index = text.index(after: index)
                continue
            }
            if digits.isEmpty {
                // Avant le nombre : `:`, `~`, `≈`, espaces… tout est toléré.
                index = text.index(after: index)
                continue
            }
            // Après le premier chiffre : seul un séparateur de milliers SUIVI
            // d'un chiffre poursuit le nombre (« 1,221 » oui, « 688 tok » non).
            if isThousandsSeparator(character) {
                let next = text.index(after: index)
                if next < text.endIndex, text[next].isNumber {
                    index = next
                    continue
                }
            }
            break
        }

        guard !digits.isEmpty else { return nil }
        return Int(digits) // dépassement de capacité → nil, jamais de crash
    }

    private static func isThousandsSeparator(_ character: Character) -> Bool {
        // Virgule, apostrophe, et les espaces (fine, insécable, ordinaire).
        character == "," || character == "'" || character == "\u{2019}"
            || character == " " || character == "\u{00A0}"
            || character == "\u{202F}" || character == "\u{2009}"
    }

}
