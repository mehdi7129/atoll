import Foundation

// Catalogue local — jalon 12b « Ne pas réinventer ».
//
// Avant de PROPOSER un skill (rétrospective, Phase 7b/7c), Atoll doit savoir ce
// que Claude Code sait DÉJÀ faire chez l'utilisateur. Ce fichier dresse cet
// inventaire unifié, en LECTURE PURE, à partir du disque uniquement : aucune
// écriture, aucun `Process`, aucun appel au CLI `claude` (la lecture de quelques
// centaines de front-matters est instantanée, et un spawn serait un risque
// fail-open supplémentaire pour rien).
//
// Mêmes principes que `LearningInventory` : racines INJECTÉES (testable sans
// toucher au vrai `~/.claude`), parsing DÉFENSIF de bout en bout, robustesse
// absolue — un dossier absent, illisible, un fichier binaire ou un front-matter
// tronqué rendent simplement MOINS d'entrées, jamais une erreur.
//
// ── LES QUATRE PIÈGES, vérifiés sur la machine de Mehdi (audit 2026-07-27) ──
//
// 1. LE NOM FAIT AUTORITÉ PAR LE DOSSIER, PAS PAR LE FRONT-MATTER.
//    `~/.claude/skills/workflow-apex-free/SKILL.md` déclare `name: apex` alors
//    que `~/.claude/skills/apex/` existe aussi : deux fichiers annoncent le même
//    nom. C'est le nom du DOSSIER qui décide de l'identifiant d'invocation —
//    le champ `name:` du front-matter est lu (pour rien d'autre que le débogage)
//    mais n'entre JAMAIS dans l'`id`. Sans cette règle, l'inventaire fusionnerait
//    deux skills distincts et déclarerait « existe déjà » à tort.
//
// 2. LES SLASH COMMANDS NE SONT PAS DES SKILLS — mais elles occupent le MÊME
//    espace de noms fonctionnel. `~/.claude/commands/<ns>/<cmd>.md` s'invoque
//    `ns:cmd`, `~/.claude/commands/<cmd>.md` s'invoque `cmd` (~60 `gsd:*` ici).
//    Proposer un skill qui refait `gsd:plan-phase` serait un doublon, même si
//    techniquement ce n'est pas « un skill ». Elles sont donc dans le catalogue,
//    avec un `kind` distinct.
//
// 3. PLUSIEURS VERSIONS DU MÊME PLUGIN COEXISTENT DANS LE CACHE.
//    `plugins/cache/<marketplace>/<plugin>/<version>/skills/<nom>/SKILL.md` :
//    `superpowers/6.1.1` ET `superpowers/6.2.0` sont présents côte à côte, et
//    `<version>` peut valoir littéralement `unknown`. On déduplique par
//    (plugin, nom de skill) en gardant la version la plus haute — comparaison
//    défensive : numérique par composants quand TOUS les composants des deux
//    versions sont des entiers, sinon lexicographique, et `unknown` perd
//    toujours (c'est un marqueur d'ignorance, pas une version).
//
// 4. INSTALLÉ ≠ ACTIVÉ. 31 plugins sont installés ici, 4 activés. L'activation
//    vit dans `~/.claude/settings.json` sous `enabledPlugins`, clé
//    `"<plugin>@<marketplace>"`. Un skill de plugin DÉSACTIVÉ n'est pas
//    invocable : il est marqué `isAvailable == false`, jamais retiré — il reste
//    une antériorité (« ça existe, il suffit de l'activer »).
//    DÉGRADATION SÛRE : si `settings.json` est absent, illisible, invalide ou
//    dépourvu de `enabledPlugins`, on considère TOUT comme disponible. Masquer
//    un skill par erreur ferait proposer un doublon ; l'inverse ne coûte rien.
//
// Ce que le catalogue n'indexe PAS, et pourquoi : les `SKILL.md` qui ne sont pas
// sous le `skills/` d'un plugin (p. ex. `<version>/cli-tool/components/skills/…`
// dans les plugins `claude-code-templates`) sont de la charge utile de dépôt que
// Claude Code ne charge pas — les lister les présenterait comme invocables.

/// Une chose que Claude Code peut invoquer (ou pourrait, si on l'activait).
public struct CatalogEntry: Equatable, Sendable, Identifiable {

    /// Nature de l'entrée.
    ///
    /// L'ORDRE DE DÉCLARATION est porteur de sens : c'est à la fois l'ordre de
    /// tri du catalogue ET la priorité de déduplication quand deux sources
    /// revendiquent le même `id` (un skill utilisateur l'emporte sur une
    /// command, qui l'emporte sur un skill de plugin — du plus proche de
    /// l'utilisateur au plus lointain).
    public enum Kind: String, Equatable, Sendable, CaseIterable {
        case userSkill
        case command
        case pluginSkill

        /// Rang de tri / priorité de dédup (0 = le plus prioritaire).
        var priority: Int {
            switch self {
            case .userSkill: return 0
            case .command: return 1
            case .pluginSkill: return 2
            }
        }
    }

    /// L'IDENTIFIANT D'INVOCATION, tel qu'on l'écrirait pour s'en servir :
    /// `atoll-recall`, `gsd:plan-phase`, `superpowers:brainstorming`. Il vient
    /// TOUJOURS du chemin sur disque, jamais du front-matter (piège n° 1).
    public let id: String
    /// Dernier segment du nom : `plan-phase` pour `gsd:plan-phase`. Nom du
    /// DOSSIER (skills) ou du FICHIER sans `.md` (commands).
    public let name: String
    /// Première ligne du champ `description:` du front-matter, aplatie sur une
    /// seule ligne et capée à 300 caractères (élision `…` incluse). Vide si le
    /// fichier n'en déclare pas.
    public let description: String
    public let kind: Kind
    /// D'où ça vient, pour l'affichage : `"utilisateur"`, `"command"`, ou le
    /// nom du plugin.
    public let origin: String
    /// `false` uniquement quand le plugin qui porte l'entrée n'est pas activé
    /// (piège n° 4). Toujours `true` pour les skills utilisateur et les commands.
    public let isAvailable: Bool
    /// Le fichier lu (`SKILL.md` ou `<cmd>.md`) — pas son dossier : c'est lui
    /// qu'on ouvre pour vérifier ce que fait vraiment l'entrée.
    public let path: URL

    public init(
        id: String,
        name: String,
        description: String,
        kind: Kind,
        origin: String,
        isAvailable: Bool,
        path: URL
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.kind = kind
        self.origin = origin
        self.isAvailable = isAvailable
        self.path = path
    }
}

/// Inventaire (lecture seule) de tout ce que Claude Code peut déjà invoquer.
public struct SkillCatalog: Sendable {

    // MARK: - Constantes publiques

    /// `origin` des skills de `~/.claude/skills`.
    public static let userSkillOrigin = "utilisateur"
    /// `origin` des slash commands de `~/.claude/commands`.
    public static let commandOrigin = "command"
    /// Version littérale posée par Claude Code quand il l'ignore (piège n° 3).
    public static let unknownVersion = "unknown"
    /// Plafond DUR du rendu de `summaryForPrompt` : au-delà, on ne rend plus un
    /// catalogue mais un budget de contexte gaspillé.
    public static let maxSummaryCharacters = 40_000

    // MARK: - Constantes internes

    /// Longueur max d'une description, marqueur d'élision inclus.
    static let maxDescriptionCharacters = 300
    /// Profondeur max explorée sous `commands/` et sous `<version>/skills/`.
    /// Les hiérarchies réelles font 1 à 2 niveaux ; la borne existe pour qu'un
    /// dossier pathologique (ou un lien) ne puisse pas faire durer un scan.
    private static let maxScanDepth = 6
    /// Octets lus en tête de chaque fichier : le front-matter vit au début, et
    /// un `SKILL.md` de 40 Mo ne doit pas coûter une lecture complète.
    private static let headByteCap = 64 * 1024
    /// Dossiers jamais explorés (bruit de dépôt, jamais des skills).
    private static let skippedDirectories: Set<String> = ["node_modules", "__pycache__"]

    // MARK: - Racines (injectables)

    public let skillsRoot: URL
    public let commandsRoot: URL
    public let pluginsCacheRoot: URL
    public let settingsURL: URL

    /// Défauts = les vrais chemins de la machine. `BridgePaths` fournit ceux
    /// qu'il connaît déjà ; les deux autres sont dérivés du home.
    public init(
        skillsRoot: URL = BridgePaths.claudeSkillsDirectory,
        commandsRoot: URL = BridgePaths.homeDirectory
            .appendingPathComponent(".claude/commands", isDirectory: true),
        pluginsCacheRoot: URL = BridgePaths.homeDirectory
            .appendingPathComponent(".claude/plugins/cache", isDirectory: true),
        settingsURL: URL = BridgePaths.claudeSettingsURL
    ) {
        self.skillsRoot = skillsRoot
        self.commandsRoot = commandsRoot
        self.pluginsCacheRoot = pluginsCacheRoot
        self.settingsURL = settingsURL
    }

    // MARK: - Lecture

    /// Tout l'inventaire, trié par `kind` puis par `id` — ordre TOTAL et
    /// déterministe (deux appels rendent exactement la même liste).
    ///
    /// Déduplication : un `id` n'apparaît qu'une fois. En cas de collision entre
    /// sources, l'ordre de priorité de `Kind` tranche (utilisateur > command >
    /// plugin) ; entre deux versions d'un même plugin, la plus haute gagne.
    public func entries() -> [CatalogEntry] {
        let enabled = enabledPlugins()
        let all = userSkills() + commands() + pluginSkills(enabled: enabled)
        var seen = Set<String>()
        return all
            .sorted(by: Self.isOrderedBefore)
            .filter { seen.insert($0.id).inserted }
    }

    /// Nombre d'entrées par nature. Les trois natures sont TOUJOURS présentes
    /// (0 si aucune entrée) : l'appelant n'a pas à gérer la clé absente.
    public func counts() -> [CatalogEntry.Kind: Int] {
        var result = [CatalogEntry.Kind: Int]()
        for kind in CatalogEntry.Kind.allCases { result[kind] = 0 }
        for entry in entries() { result[entry.kind, default: 0] += 1 }
        return result
    }

    /// Le catalogue rendu pour être injecté dans le prompt de recherche
    /// d'antériorité : une ligne par entrée,
    /// `- <id> (<origine>)[ [désactivé]] : <description>`.
    ///
    /// Le total est capé DEUX FOIS : par nombre d'entrées (`limit`) et par
    /// `maxSummaryCharacters`. Quand ça coupe, une dernière ligne le DIT
    /// explicitement — sans elle, le modèle conclurait « rien d'équivalent »
    /// à partir d'une liste partielle, c'est-à-dire exactement l'erreur que ce
    /// jalon cherche à éviter. Sortie strictement déterministe.
    /// La capacité existante la plus proche d'un skill proposé, ou nil.
    ///
    /// DÉTECTION LOCALE ET DÉTERMINISTE, en complément de ce que le modèle
    /// déclare dans `similar_existing` : la garantie du jalon 12b (« aucune
    /// proposition ne duplique ce qui existe ») ne peut pas reposer sur le seul
    /// bon vouloir d'une analyse. Ici, aucun modèle, aucun réseau — juste des
    /// mots comparés.
    ///
    /// Similarité = proportion de mots significatifs partagés entre le texte
    /// proposé (slug + titre + description) et celui de l'entrée (id + nom +
    /// description), rapportée au plus petit des deux vocabulaires — un titre
    /// court ne doit pas être pénalisé face à une description bavarde. Le seuil
    /// est volontairement HAUT (0,5) : mieux vaut ne rien signaler que crier au
    /// doublon à chaque proposition, ce qui apprendrait à ignorer l'avertissement.
    public func closestMatch(slug: String, title: String, description: String,
                             threshold: Double = 0.5,
                             excluding excluded: Set<String> = []) -> CatalogEntry? {
        // DEUX comparaisons, on garde la meilleure (revue) :
        // 1. le texte complet (slug + titre + description) — marche quand les
        //    deux côtés parlent la même langue ;
        // 2. les IDENTIFIANTS seuls (slug proposé vs id de l'entrée) — le
        //    filet indispensable, parce que la rétrospective rédige en
        //    FRANÇAIS alors que 89 des 119 descriptions du catalogue sont en
        //    anglais : « Traiter les commentaires de PR » ne ressemblait pas à
        //    « Fetch PR review comments », alors que `pr-review-comments`
        //    ressemble beaucoup à `fix-pr-comments`. Sans ça, 5 des 6 vrais
        //    doublons de la machine passaient à travers (mesuré).
        let fullNeedle = Self.significantWords(from: "\(slug) \(title) \(description)")
        let idNeedle = Self.identifierWords(from: slug)
        guard fullNeedle.count >= 2 || idNeedle.count >= 1 else { return nil }

        var best: (entry: CatalogEntry, score: Double)?
        for entry in entries() where !excluded.contains(entry.id) {
            var score = 0.0
            let hay = Self.significantWords(
                from: "\(entry.id) \(entry.name) \(entry.description)")
            if !hay.isEmpty, fullNeedle.count >= 2 {
                let shared = fullNeedle.intersection(hay).count
                if shared > 0 {
                    score = Double(shared) / Double(min(fullNeedle.count, hay.count))
                }
            }
            let idHay = Self.identifierWords(from: entry.id)
            if !idHay.isEmpty, !idNeedle.isEmpty {
                let shared = idNeedle.intersection(idHay).count
                if shared > 0 {
                    score = max(score, Double(shared) / Double(min(idNeedle.count, idHay.count)))
                }
            }
            if score >= threshold, score > (best?.score ?? 0) {
                best = (entry, score)
            }
        }
        return best?.entry
    }

    /// Mots d'un IDENTIFIANT (`fix-pr-comments`, `gsd:plan-phase`) : découpe
    /// sur les séparateurs d'identifiant, ≥ 2 caractères (« pr » compte !),
    /// mots trop courants écartés comme ailleurs.
    static func identifierWords(from identifier: String) -> Set<String> {
        let tokens = identifier.lowercased().split { !$0.isLetter && !$0.isNumber }
        return Set(tokens.map(String.init).filter {
            $0.count >= 2 && !genericWords.contains($0)
        })
    }

    /// Mots de ≥ 4 caractères, minuscules, sans diacritiques, hors mots-outils
    /// techniques trop courants (« skill », « claude », « atoll », « code »…)
    /// qui feraient se ressembler tout et n'importe quoi.
    static func significantWords(from text: String) -> Set<String> {
        let folded = text
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let tokens = folded.split { !$0.isLetter && !$0.isNumber }
        return Set(tokens.map(String.init).filter {
            $0.count >= 4 && !genericWords.contains($0)
        })
    }

    /// Mots présents dans presque toutes les descriptions de skills : les
    /// garder ferait matcher n'importe quoi avec n'importe quoi.
    static let genericWords: Set<String> = [
        "skill", "skills", "claude", "atoll", "code", "avec", "pour", "dans",
        "this", "that", "when", "with", "from", "your", "user", "using", "use",
        "utiliser", "quand", "faire", "session", "sessions", "projet", "project",
    ]

    public func summaryForPrompt(limit: Int = 400) -> String {
        let all = entries()
        let maximumCount = max(0, limit)
        var lines: [String] = []
        var used = 0
        var index = 0

        while index < all.count, lines.count < maximumCount {
            let line = Self.promptLine(for: all[index])
            let cost = line.count + (lines.isEmpty ? 0 : 1) // le "\n" de jointure
            if used + cost > Self.maxSummaryCharacters { break }
            lines.append(line)
            used += cost
            index += 1
        }
        guard index < all.count else { return lines.joined(separator: "\n") }

        // Tronqué : on reprend de la place à la fin jusqu'à ce que le marqueur
        // tienne dans le budget (il est court, la boucle ne tourne quasi jamais).
        var omitted = all.count - index
        while !lines.isEmpty,
              used + Self.truncationMarker(omitted).count + 1 > Self.maxSummaryCharacters {
            let removed = lines.removeLast()
            used -= removed.count + (lines.isEmpty ? 0 : 1)
            omitted += 1
        }
        lines.append(Self.truncationMarker(omitted))
        return lines.joined(separator: "\n")
    }

    static func promptLine(for entry: CatalogEntry) -> String {
        let flag = entry.isAvailable ? "" : " [désactivé]"
        let description = entry.description.isEmpty ? "(sans description)" : entry.description
        return "- \(entry.id) (\(entry.origin))\(flag) : \(description)"
    }

    static func truncationMarker(_ omitted: Int) -> String {
        "… \(omitted) entrée(s) supplémentaire(s) non listée(s)"
    }

    /// `kind` puis `id` ; `path` en dernier ressort pour que l'ordre reste TOTAL
    /// même si deux fichiers produisent le même identifiant (la dédup qui suit
    /// garde alors toujours le même).
    private static func isOrderedBefore(_ lhs: CatalogEntry, _ rhs: CatalogEntry) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind.priority < rhs.kind.priority }
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        return lhs.path.path < rhs.path.path
    }

    // MARK: - Skills utilisateur

    /// `~/.claude/skills/<nom>/SKILL.md` → id `<nom>`.
    ///
    /// Un sous-dossier sans `SKILL.md` lisible n'est pas un skill : il est
    /// ignoré (c'est aussi ce qui écarte les dossiers de travail parasites).
    private func userSkills() -> [CatalogEntry] {
        Self.childDirectories(of: skillsRoot).compactMap { directory in
            let file = directory.appendingPathComponent("SKILL.md")
            guard let front = Self.frontMatter(of: file) else { return nil }
            // Le DOSSIER fait autorité (piège n° 1) ; `front.name` est délibérément
            // ignoré pour l'identité.
            let name = directory.lastPathComponent
            guard !name.isEmpty else { return nil }
            return CatalogEntry(
                id: name,
                name: name,
                description: front.description,
                kind: .userSkill,
                origin: Self.userSkillOrigin,
                isAvailable: true,
                path: file
            )
        }
    }

    // MARK: - Slash commands

    /// `~/.claude/commands/<ns>/<cmd>.md` → id `<ns>:<cmd>` ;
    /// `~/.claude/commands/<cmd>.md` → id `<cmd>`. Les niveaux plus profonds
    /// sont joints de la même façon (`a:b:cmd`), sans hypothèse sur le nombre
    /// de niveaux.
    private func commands() -> [CatalogEntry] {
        var found: [(url: URL, components: [String])] = []
        Self.collect(
            in: commandsRoot,
            prefix: [],
            depth: 1,
            isMatch: { $0.lowercased().hasSuffix(".md") },
            into: &found
        )

        return found.compactMap { hit in
            var components = hit.components
            guard let file = components.popLast() else { return nil }
            let name = String(file.dropLast(3)) // ".md"
            guard !name.isEmpty, components.allSatisfy({ !$0.isEmpty }) else { return nil }
            let identifier = (components + [name]).joined(separator: ":")
            let front = Self.frontMatter(of: hit.url)
            return CatalogEntry(
                id: identifier,
                name: name,
                description: front?.description ?? "",
                kind: .command,
                origin: Self.commandOrigin,
                isAvailable: true,
                path: hit.url
            )
        }
    }

    // MARK: - Skills de plugins

    /// `<cache>/<marketplace>/<plugin>/<version>/skills/**/<nom>/SKILL.md`
    /// → id `<plugin>:<nom>`.
    ///
    /// L'ancrage sur le `skills/` du plugin est délibéré : c'est le seul
    /// emplacement que Claude Code charge. Sous ce dossier, en revanche, on
    /// descend récursivement (certains plugins rangent leurs skills par
    /// catégorie) et le nom reste celui du dossier PARENT du `SKILL.md`.
    private func pluginSkills(enabled: [String: Bool]?) -> [CatalogEntry] {
        // Par id : la meilleure version vue, et « au moins une copie activée ».
        var best: [String: (entry: CatalogEntry, version: String)] = [:]
        var anyEnabled: [String: Bool] = [:]

        for marketplace in Self.childDirectories(of: pluginsCacheRoot) {
            for plugin in Self.childDirectories(of: marketplace) {
                let pluginName = plugin.lastPathComponent
                let settingsKey = "\(pluginName)@\(marketplace.lastPathComponent)"
                // Activation indéterminable → disponible (piège n° 4).
                let isEnabled = enabled.map { $0[settingsKey] == true } ?? true

                for version in Self.childDirectories(of: plugin) {
                    let versionName = version.lastPathComponent
                    var found: [(url: URL, components: [String])] = []
                    Self.collect(
                        in: version.appendingPathComponent("skills", isDirectory: true),
                        prefix: [],
                        depth: 1,
                        isMatch: { $0 == "SKILL.md" },
                        into: &found
                    )

                    for hit in found {
                        // Il faut au moins `<nom>/SKILL.md` : un SKILL.md posé à
                        // la racine de `skills/` n'a pas de nom de dossier.
                        guard hit.components.count >= 2 else { continue }
                        let name = hit.components[hit.components.count - 2]
                        guard !name.isEmpty, let front = Self.frontMatter(of: hit.url) else { continue }

                        let identifier = "\(pluginName):\(name)"
                        anyEnabled[identifier] = (anyEnabled[identifier] ?? false) || isEnabled

                        let candidate = CatalogEntry(
                            id: identifier,
                            name: name,
                            description: front.description,
                            kind: .pluginSkill,
                            origin: pluginName,
                            isAvailable: isEnabled,
                            path: hit.url
                        )
                        if let current = best[identifier] {
                            // Égalité de version → on garde le PREMIER vu
                            // (parcours trié = déterministe).
                            if Self.isVersion(current.version, lowerThan: versionName) {
                                best[identifier] = (candidate, versionName)
                            }
                        } else {
                            best[identifier] = (candidate, versionName)
                        }
                    }
                }
            }
        }

        // La version gagnante fixe la description et le chemin ; la
        // DISPONIBILITÉ, elle, répond à « Claude Code peut-il l'invoquer ? » —
        // vrai dès qu'UNE copie installée est activée (deux marketplaces
        // peuvent porter le même plugin avec des activations différentes).
        return best.map { identifier, winner in
            CatalogEntry(
                id: identifier,
                name: winner.entry.name,
                description: winner.entry.description,
                kind: .pluginSkill,
                origin: winner.entry.origin,
                isAvailable: anyEnabled[identifier] ?? winner.entry.isAvailable,
                path: winner.entry.path
            )
        }
    }

    /// Activation des plugins lue dans `settings.json`.
    ///
    /// `nil` = INDÉTERMINABLE (fichier absent, illisible, JSON invalide, ou clé
    /// `enabledPlugins` absente / mal typée) → l'appelant considère tout comme
    /// disponible. Un dictionnaire VIDE, lui, est une réponse : rien n'est activé.
    private func enabledPlugins() -> [String: Bool]? {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = object["enabledPlugins"] as? [String: Any]
        else { return nil }

        var result: [String: Bool] = [:]
        for (key, value) in raw {
            // Tout ce qui n'est pas un booléen exploitable vaut « pas activé ».
            if let flag = value as? Bool {
                result[key] = flag
            } else if let number = value as? NSNumber {
                result[key] = number.boolValue
            } else if let text = value as? String {
                result[key] = (text as NSString).boolValue
            }
        }
        return result
    }

    // MARK: - Comparaison de versions (piège n° 3)

    /// « `lhs` est une version PLUS BASSE que `rhs` » — donc `lhs` perd.
    ///
    /// Ordre : `unknown` (et la chaîne vide) perd contre tout le reste ;
    /// numérique par composants si les DEUX versions sont entièrement
    /// numériques (`6.1.1` < `6.2.0`, `1.2` < `1.2.1`) ; sinon lexicographique
    /// (versions non standard, hachages…). Jamais d'exception, jamais de crash
    /// sur un composant qui déborde `Int`.
    static func isVersion(_ lhs: String, lowerThan rhs: String) -> Bool {
        if lhs == rhs { return false }
        let leftUnknown = lhs.isEmpty || lhs == unknownVersion
        let rightUnknown = rhs.isEmpty || rhs == unknownVersion
        if leftUnknown != rightUnknown { return leftUnknown }
        if leftUnknown { return false } // deux inconnues : égalité, premier vu gagne

        if let left = numericComponents(lhs), let right = numericComponents(rhs) {
            for index in 0..<max(left.count, right.count) {
                let leftValue = index < left.count ? left[index] : 0
                let rightValue = index < right.count ? right[index] : 0
                if leftValue != rightValue { return leftValue < rightValue }
            }
            return false
        }
        return lhs < rhs
    }

    /// `[6, 2, 0]` pour `"6.2.0"` ; `nil` dès qu'un composant n'est pas un
    /// entier décimal (y compris débordement).
    private static func numericComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var result: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            result.append(value)
        }
        return result
    }

    // MARK: - Parcours du disque (100 % défensif)

    /// Sous-dossiers directs, triés par nom. Dossier absent ou illisible → `[]`.
    /// Les liens symboliques SONT suivis ici : la profondeur est fixe (racines,
    /// marketplaces, plugins, versions), donc aucun risque de cycle, et des
    /// skills réellement liés depuis un dépôt tiers doivent compter.
    private static func childDirectories(of directory: URL) -> [URL] {
        contents(of: directory).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    private static func contents(of directory: URL) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Descente récursive bornée. `components` = chemin RELATIF à la racine du
    /// parcours, dernier élément inclus (le nom du fichier).
    ///
    /// Les dossiers qui sont des LIENS SYMBOLIQUES ne sont pas suivis ici :
    /// c'est la seule protection simple contre un cycle de liens, et la
    /// profondeur seule ne suffirait pas à borner l'explosion combinatoire.
    private static func collect(
        in directory: URL,
        prefix: [String],
        depth: Int,
        isMatch: (String) -> Bool,
        into results: inout [(url: URL, components: [String])]
    ) {
        guard depth <= maxScanDepth else { return }
        for child in contents(of: directory) {
            let name = child.lastPathComponent
            guard !name.isEmpty, !name.hasPrefix(".") else { continue }
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true {
                guard values?.isSymbolicLink != true, !skippedDirectories.contains(name) else { continue }
                collect(in: child, prefix: prefix + [name], depth: depth + 1,
                        isMatch: isMatch, into: &results)
            } else if isMatch(name) {
                results.append((child, prefix + [name]))
            }
        }
    }

    // MARK: - Front-matter (parsing défensif)

    /// Ce qu'on retient du front-matter d'un `SKILL.md` / `<cmd>.md`.
    struct FrontMatter: Equatable {
        /// Champ `name:` déclaré. Lu pour le débogage UNIQUEMENT : il ment
        /// (piège n° 1) et n'entre jamais dans l'identité d'une entrée.
        let name: String?
        /// Description déjà aplatie et capée.
        let description: String
    }

    /// `nil` seulement quand le fichier est absent ou impossible à ouvrir —
    /// c'est le signal « ce dossier n'est pas un skill ». Un contenu binaire ou
    /// tronqué, lui, rend une `FrontMatter` vide, pas une erreur.
    static func frontMatter(of url: URL) -> FrontMatter? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headByteCap) else { return nil }
        // `String(decoding:as:)` ne peut pas échouer : un octet invalide (ou un
        // caractère coupé en deux par le plafond de lecture) devient U+FFFD.
        return parseFrontMatter(String(decoding: data, as: UTF8.self))
    }

    /// Ne peut PAS échouer : au pire, aucun champ n'est trouvé.
    ///
    /// Le front-matter n'est reconnu que s'il OUVRE le fichier (lignes vides de
    /// tête tolérées) et qu'une seconde ligne `---` le referme — un `---`
    /// ouvrant sans fermant n'est pas un front-matter, c'est du markdown.
    static func parseFrontMatter(_ raw: String) -> FrontMatter {
        let empty = FrontMatter(name: nil, description: "")
        // PIÈGE Swift : `"\r\n"` est UN SEUL `Character` — découper sur `"\n"`
        // ne coupe donc JAMAIS un fichier à fins de ligne Windows, et tout le
        // front-matter passerait pour une ligne unique. `isNewline` couvre LF,
        // CR, CRLF et les séparateurs Unicode d'un coup.
        let lines = raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)

        var start = lines.startIndex
        while start < lines.endIndex,
              lines[start].trimmingCharacters(in: .whitespaces).isEmpty {
            start += 1
        }
        guard start < lines.endIndex, isFence(lines[start]),
              let close = lines[(start + 1)...].firstIndex(where: isFence)
        else { return empty }

        let body = lines[(start + 1)..<close]
        return FrontMatter(
            name: value(of: "name", in: body),
            description: flattened(value(of: "description", in: body) ?? "")
        )
    }

    /// Ligne « fence » : exactement `---`, blancs tolérés.
    private static func isFence(_ line: Substring) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
    }

    /// Valeur d'une clé de front-matter — PREMIÈRE occurrence, PREMIÈRE ligne.
    ///
    /// Gère les deux formes vues dans la nature :
    /// - `description: du texte` (éventuellement entre guillemets) ;
    /// - scalaire de bloc YAML `description: |-` / `>-` suivi de lignes
    ///   indentées (le `claude-api` d'`anthropic-agent-skills` fait ça) — on
    ///   rend alors la première ligne de contenu, ce qui est exactement le
    ///   résumé utile : les suivantes sont des consignes de déclenchement.
    private static func value(of key: String, in lines: ArraySlice<Substring>) -> String? {
        var index = lines.startIndex
        while index < lines.endIndex {
            let line = lines[index]
            index += 1
            guard let pair = keyValue(in: line), pair.key == key else { continue }
            if !pair.value.isEmpty, !isBlockIndicator(pair.value) {
                return unquoted(pair.value)
            }
            // Bloc (ou valeur vide) : première ligne indentée non vide, avant
            // la clé suivante.
            var cursor = index
            while cursor < lines.endIndex {
                let candidate = lines[cursor]
                if keyValue(in: candidate) != nil { break }
                let trimmed = candidate.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { return unquoted(trimmed) }
                cursor += 1
            }
            return nil
        }
        return nil
    }

    /// `clé: valeur` d'une ligne, ou `nil` si ce n'en est pas une.
    ///
    /// Une clé vit en COLONNE 0 et ne contient que `[A-Za-z0-9_.-]` : toute
    /// ligne indentée est du contenu de bloc ou une valeur imbriquée, et une
    /// ligne de prose contenant un `:` n'est pas une clé.
    private static func keyValue(in line: Substring) -> (key: String, value: String)? {
        guard let first = line.first, first != " ", first != "\t", first != "-",
              let colon = line.firstIndex(of: ":")
        else { return nil }
        let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty,
              key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." })
        else { return nil }
        let value = String(line[line.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    /// Indicateur de scalaire de bloc YAML : `|`, `>`, `|-`, `>-`, `|+`, `>2`…
    private static func isBlockIndicator(_ value: String) -> Bool {
        guard let first = value.first, first == "|" || first == ">" else { return false }
        return value.dropFirst().allSatisfy { $0 == "-" || $0 == "+" || $0.isNumber }
    }

    /// Retire les guillemets de bord (simples ou doubles) et restitue `\"` /
    /// `\\`. Une valeur non quotée est rendue telle quelle.
    private static func unquoted(_ raw: String) -> String {
        guard raw.count >= 2, let quote = raw.first, quote == "\"" || quote == "'",
              raw.last == quote
        else { return raw }
        guard quote == "\"" else { return String(raw.dropFirst().dropLast()) }

        var output = ""
        var escaping = false
        for character in raw.dropFirst().dropLast() {
            if escaping {
                output.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                output.append(character)
            }
        }
        if escaping { output.append("\\") } // antislash orphelin : conservé
        return output
    }

    /// Aplatit sur une seule ligne (blancs successifs → une espace, caractères
    /// de contrôle retirés) et cape à `maxDescriptionCharacters`, élision `…`
    /// comprise — une description n'a pas à pouvoir gonfler un prompt.
    static func flattened(_ raw: String) -> String {
        var output = ""
        var pendingSpace = false
        for character in raw {
            if character.isWhitespace {
                pendingSpace = !output.isEmpty
                continue
            }
            if let ascii = character.asciiValue, ascii < 32 { continue }
            if pendingSpace {
                output.append(" ")
                pendingSpace = false
            }
            output.append(character)
        }
        guard output.count > maxDescriptionCharacters else { return output }
        return String(output.prefix(maxDescriptionCharacters - 1)) + "…"
    }
}
