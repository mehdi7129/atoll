import Foundation

/// Retrait RÉVERSIBLE des hooks sonores que l'utilisateur a posés lui-même dans
/// `~/.claude/settings.json`, quand il confie les sons à Atoll.
///
/// EXCEPTION ENCADRÉE à la règle n° 2 du projet (« settings.json est sacré,
/// Atoll ne touche qu'à ses propres entrées ») : même régime que le parking
/// Rockstar — sur demande EXPLICITE, écrit à part AVANT toute modification,
/// restitué à la désactivation, à la désinstallation et par réconciliation au
/// lancement. Rien n'est jamais automatique.
///
/// Pourquoi c'est nécessaire : sans retrait, l'utilisateur entendrait DEUX sons
/// (le sien et celui d'Atoll) pour le même événement.
public enum SoundHookEditor {

    public enum EditorError: Error, Equatable {
        /// settings.json existe mais n'est pas un objet JSON valide.
        case unparseableSettings
    }

    /// Un hook sonore mis de côté, avec de quoi le remettre EXACTEMENT où il
    /// était (même événement, même matcher, même position).
    public struct ParkedHook: Codable, Equatable, Sendable {
        /// Nom de l'événement (`Stop`, `Notification`…).
        public let event: String
        /// `matcher` du groupe, éventuellement absent dans le fichier.
        public let matcher: String?
        /// Position du groupe dans le tableau de l'événement, pour restituer
        /// l'ordre d'origine (un son joué avant ou après les autres hooks n'a
        /// pas d'incidence, mais on rend le fichier tel qu'on l'a trouvé).
        public let index: Int
        /// Position du hook DANS son groupe (groupe mixte).
        public let hookIndex: Int
        /// Le GROUPE d'origine, re-sérialisé — renseigné SEULEMENT quand tous
        /// ses hooks étaient sonores, donc que le groupe entier disparaît. On le
        /// remet alors tel quel, avec les clés éventuelles que `ParkedHook` ne
        /// connaît pas (`description`, extensions futures du CLI) : sans lui,
        /// elles étaient perdues définitivement.
        public let groupJSON: String?
        /// Commande, extraite pour pouvoir la MONTRER à l'utilisateur avant
        /// qu'il décide.
        public let command: String
        /// Le hook complet, re-sérialisé — c'est lui qui fait foi à la
        /// restitution (on ne reconstruit pas un hook « équivalent », on
        /// remet l'objet d'origine avec ses `timeout`, `async`, etc.).
        public let hookJSON: String

        public init(event: String, matcher: String?, index: Int, hookIndex: Int = 0,
                    command: String, hookJSON: String, groupJSON: String? = nil) {
            self.event = event
            self.matcher = matcher
            self.index = index
            self.hookIndex = hookIndex
            self.command = command
            self.hookJSON = hookJSON
            self.groupJSON = groupJSON
        }

        /// Décodage tolérant : un parking écrit par une version antérieure n'a
        /// ni `hookIndex` ni `groupJSON`. Le refuser rendrait le fichier
        /// illisible — donc les hooks de l'utilisateur irrécupérables.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            event = try container.decode(String.self, forKey: .event)
            matcher = try container.decodeIfPresent(String.self, forKey: .matcher)
            index = try container.decodeIfPresent(Int.self, forKey: .index) ?? 0
            hookIndex = try container.decodeIfPresent(Int.self, forKey: .hookIndex) ?? 0
            command = try container.decode(String.self, forKey: .command)
            hookJSON = try container.decode(String.self, forKey: .hookJSON)
            groupJSON = try container.decodeIfPresent(String.self, forKey: .groupJSON)
        }
    }

    /// Contenu de `~/.atoll/parked-sound-hooks.json`.
    public struct ParkedSoundHooks: Codable, Equatable, Sendable {
        public let hooks: [ParkedHook]
        public let parkedAt: Date

        public init(hooks: [ParkedHook], parkedAt: Date) {
            self.hooks = hooks
            self.parkedAt = parkedAt
        }
    }

    // MARK: - Détection

    /// Cette commande de hook joue-t-elle un son ?
    ///
    /// Volontairement conservateur : on ne parque QUE ce qu'on reconnaît sans
    /// ambiguïté. Un faux positif retirerait à l'utilisateur un hook qui fait
    /// autre chose — bien pire que de laisser un son en trop.
    ///
    /// Ne matche JAMAIS un hook Atoll (le helper ne joue aucun son).
    public static func isSoundCommand(_ command: String) -> Bool {
        guard !command.contains("atoll-bridge"), !command.contains("atoll-statusline")
        else { return false }

        // Commande COMPOSÉE (`&&`, `||`, `;`, `|`) : on n'y touche pas. La
        // granularité du parking est l'entrée de hook ENTIÈRE — parquer
        // `./on-stop.sh && afplay done.wav` arrêterait aussi `on-stop.sh`, et
        // l'utilisateur n'aurait aucune idée de pourquoi son script ne tourne
        // plus. Mieux vaut un son en trop qu'un traitement supprimé.
        for separator in ["&&", "||", ";", "|", "\n", "\r"] where command.contains(separator) {
            return false
        }
        // Le `&` isolé enchaîne lui aussi : `afplay done.wav & node notify.js`
        // faisait sauter le `node`. On tolère le seul cas légitime — un `&`
        // final qui met le son en tâche de fond.
        if let ampersand = command.range(of: "&"),
           !command[ampersand.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }

        // Le lecteur de son doit être LA COMMANDE, pas un mot qui traîne dans
        // un argument. Sans ça : `curl .../beep-api`, `node say-hello.js` ou
        // `bun transcribe.ts --keep /tmp/x.m4a` étaient tous parqués (mesuré).
        let tokens = command.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = tokens.first else { return false }
        let program = (String(first).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                       as NSString).lastPathComponent
        if program == "afplay" || program == "say" { return true }
        if program == "osascript",
           command.range(of: "\\bbeep\\b", options: .regularExpression) != nil { return true }
        // Cas restant : n'importe quel programme qui joue un son du système.
        if command.contains("/System/Library/Sounds") { return true }
        return false
    }

    /// Chemins de fichiers audio cités par une commande — de quoi proposer de
    /// les REPRENDRE comme sons Atoll (migration invisible à l'oreille).
    /// Les guillemets simples ou doubles éventuels sont retirés.
    public static func audioPaths(in command: String) -> [String] {
        let pattern = "(?:'([^']+)'|\"([^\"]+)\"|(\\S+))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(command.startIndex..., in: command)
        var paths: [String] = []
        for match in regex.matches(in: command, range: range) {
            for group in 1...3 {
                guard let sub = Range(match.range(at: group), in: command) else { continue }
                let token = expandingHome(String(command[sub]))
                let ext = URL(fileURLWithPath: token).pathExtension.lowercased()
                guard SoundImport.allowedExtensions.contains(ext) else { continue }
                if !paths.contains(token) { paths.append(token) }
            }
        }
        return paths
    }

    /// `~` et `$HOME` → chemin réel. Sans ça, un hook écrit
    /// `afplay "$HOME/.claude/song/finish.mp3"` (la convention d'Atoll lui-même)
    /// ne rendait aucun fichier : la migration se déclarait réussie et laissait
    /// l'utilisateur en silence complet.
    static func expandingHome(_ path: String) -> String {
        var expanded = path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for prefix in ["$HOME", "${HOME}"] where expanded.hasPrefix(prefix) {
            expanded = home + expanded.dropFirst(prefix.count)
        }
        return (expanded as NSString).expandingTildeInPath
    }

    /// Hooks sonores présents (lecture seule, pour les afficher avant décision).
    public static func soundHooks(in data: Data?) -> [ParkedHook] {
        guard let settings = try? parse(data),
              let hooks = settings["hooks"] as? [String: Any] else { return [] }
        var found: [ParkedHook] = []
        // Ordre stable : les événements par ordre alphabétique (un dictionnaire
        // JSON n'a pas d'ordre — sans tri, la liste montrée à l'utilisateur
        // changerait d'un affichage à l'autre).
        for event in hooks.keys.sorted() {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            for (index, group) in groups.enumerated() {
                guard let entries = group["hooks"] as? [[String: Any]] else { continue }
                let soundIndices = entries.indices.filter { position in
                    guard let command = entries[position]["command"] as? String else { return false }
                    return isSoundCommand(command)
                }
                guard !soundIndices.isEmpty else { continue }
                // Le groupe entier disparaît-il ? Si oui, on le conserve TEL
                // QUEL pour pouvoir le remettre avec ses clés inconnues.
                let wholeGroupGoes = soundIndices.count == entries.count
                let groupJSON = wholeGroupGoes ? serializeFragment(group) : nil
                for position in soundIndices {
                    guard let command = entries[position]["command"] as? String,
                          let json = serializeFragment(entries[position]) else { continue }
                    found.append(ParkedHook(event: event,
                                            matcher: group["matcher"] as? String,
                                            index: index,
                                            hookIndex: position,
                                            command: command,
                                            hookJSON: json,
                                            groupJSON: groupJSON))
                }
            }
        }
        return found
    }

    // MARK: - Parking / restitution

    /// Retire les hooks sonores. nil si rien à faire (aucune écriture).
    /// Un `hooks` d'un type inattendu → erreur SANS écriture.
    public static func park(in data: Data?) throws -> (updated: Data, parked: [ParkedHook])? {
        var settings = try parse(data)
        guard var hooks = try strictHooks(settings) else { return nil }
        let parked = soundHooks(in: data)
        guard !parked.isEmpty else { return nil }

        for event in hooks.keys.sorted() {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            // Indices des groupes que NOUS avons vidés — eux seuls seront
            // retirés. Une purge globale des groupes vides effaçait aussi des
            // groupes vides préexistants (`{"matcher":"garde-place","hooks":[]}`)
            // qu'Atoll n'avait pas parqués et ne saurait donc pas rendre.
            var emptiedByUs: Set<Int> = []
            for index in groups.indices {
                guard let entries = groups[index]["hooks"] as? [[String: Any]] else { continue }
                let kept = entries.filter { entry in
                    guard let command = entry["command"] as? String else { return true }
                    return !isSoundCommand(command)
                }
                guard kept.count != entries.count else { continue }
                if kept.isEmpty {
                    emptiedByUs.insert(index)
                } else {
                    groups[index]["hooks"] = kept
                }
            }
            groups = groups.enumerated()
                .filter { !emptiedByUs.contains($0.offset) }
                .map(\.element)
            // Un événement qui devient vide À CAUSE DE NOUS perd sa clé ; un
            // événement déjà vide avant nous n'est pas touché (on ne l'a pas
            // parqué, on ne saurait pas le rendre).
            if groups.isEmpty, !emptiedByUs.isEmpty {
                hooks[event] = nil
            } else {
                hooks[event] = groups
            }
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return (try serialize(settings), parked)
    }

    /// Remet les hooks parqués à leur place. Idempotent : un hook déjà présent
    /// (l'utilisateur l'a remis à la main entre-temps) n'est pas dupliqué.
    public static func restore(into data: Data?, parked: [ParkedHook]) throws -> Data {
        var settings = try parse(data)
        var hooks = try strictHooks(settings) ?? [:]

        // Tri STABLE par index (le tri de Swift ne l'est pas) : deux hooks
        // parqués au même index doivent revenir dans leur ordre d'origine.
        let ordered = parked.enumerated()
            .sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }
            .map(\.element)

        // Combien d'exemplaires de chaque hook parqué on a déjà traité : c'est
        // ce compteur qui permet de restituer DEUX entrées identiques (même
        // commande dans deux groupes) au lieu d'une seule.
        var handled: [String: Int] = [:]

        for hook in ordered {
            guard let entry = parseFragment(hook.hookJSON) else { continue }
            let key = "\(hook.event)\u{1}\(hook.hookJSON)"
            let alreadyHandled = handled[key] ?? 0
            handled[key] = alreadyHandled + 1

            // STRICT : l'événement existe mais n'a pas la forme attendue → on
            // REFUSE d'écrire. Le remplacer par nos seuls groupes effacerait
            // définitivement les hooks que l'utilisateur y a mis. (Le modèle
            // Rockstar échoue de la même façon plutôt que d'écraser.)
            if let existing = hooks[hook.event], !(existing is [[String: Any]]) {
                throw EditorError.unparseableSettings
            }
            var groups = (hooks[hook.event] as? [[String: Any]]) ?? []

            // Déjà présent ? Comparaison sur le hook COMPLET, pas sur la seule
            // commande : deux groupes peuvent porter la même commande avec des
            // matchers différents, et n'en restituer qu'un en perdait un.
            let occurrences = groups.reduce(0) { total, group in
                let entries = (group["hooks"] as? [[String: Any]]) ?? []
                return total + entries.filter { serializeFragment($0) == hook.hookJSON }.count
            }
            // Cet exemplaire-là est-il déjà en place ? (restitution rejouée, ou
            // hook remis à la main par l'utilisateur pendant le parking)
            if occurrences > alreadyHandled { continue }

            if let groupJSON = hook.groupJSON, let original = parseFragment(groupJSON) {
                // Le groupe entier avait disparu : on le remet TEL QUEL, avec
                // ses éventuelles clés qu'on ne connaît pas.
                let position = min(max(hook.index, 0), groups.count)
                groups.insert(original, at: position)
            } else if let target = groups.indices.first(where: {
                ($0 == hook.index) && (groups[$0]["matcher"] as? String) == hook.matcher
            }) ?? groups.indices.first(where: {
                (groups[$0]["matcher"] as? String) == hook.matcher
            }) {
                // Groupe MIXTE toujours là : le hook retourne DEDANS, à sa
                // place — et non dans un groupe jumeau créé à côté.
                var entries = (groups[target]["hooks"] as? [[String: Any]]) ?? []
                entries.insert(entry, at: min(max(hook.hookIndex, 0), entries.count))
                groups[target]["hooks"] = entries
            } else {
                var group: [String: Any] = ["hooks": [entry]]
                if let matcher = hook.matcher { group["matcher"] = matcher }
                groups.insert(group, at: min(max(hook.index, 0), groups.count))
            }
            hooks[hook.event] = groups
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        return try serialize(settings)
    }

    /// Fusionne un parking précédent avec un nouveau (parking rejoué après un
    /// crash) : les anciens d'abord, sans doublon.
    ///
    /// La clé porte sur l'ENTRÉE, pas sur la seule commande : deux hooks de même
    /// commande peuvent différer par leur matcher ou leurs options (`timeout`,
    /// `async`). Dédoublonner sur la commande jetait le second — retiré de
    /// settings.json, absent du parking, donc perdu définitivement (audit du
    /// 2026-07-27). L'index est exclu à dessein : un parking rejoué après un
    /// crash produit des entrées identiques, qui restent bien dédoublonnées.
    public static func mergeParked(previous: [ParkedHook], new: [ParkedHook]) -> [ParkedHook] {
        func key(_ hook: ParkedHook) -> String {
            "\(hook.event)\u{1}\(hook.matcher ?? "")\u{1}\(hook.hookJSON)"
        }
        let known = Set(previous.map(key))
        return previous + new.filter { !known.contains(key($0)) }
    }

    // MARK: - Encodage du fichier de parking

    public static func encodeParked(_ parked: ParkedSoundHooks) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(parked)
    }

    public static func decodeParked(_ data: Data) -> ParkedSoundHooks? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ParkedSoundHooks.self, from: data)
    }

    // MARK: - Interne

    /// nil = clé absente ; présente mais pas un objet → erreur, refus d'écrire.
    private static func strictHooks(_ settings: [String: Any]) throws -> [String: Any]? {
        guard let value = settings["hooks"] else { return nil }
        guard let hooks = value as? [String: Any] else { throw EditorError.unparseableSettings }
        return hooks
    }

    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            throw EditorError.unparseableSettings
        }
        return dict
    }

    private static func serialize(_ settings: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: settings,
                                   options: [.prettyPrinted, .sortedKeys])
    }

    private static func serializeFragment(_ fragment: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: fragment,
                                                     options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseFragment(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object as? [String: Any]
    }
}
