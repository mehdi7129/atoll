import Foundation

// Inventaire des notes mémoire — l'envers de `LearningArtifacts` : ce fichier
// RELIT ce que `LearningNoteFile.render` (et le curateur de `NotesCuration`)
// ont écrit dans `~/.atoll/learning/notes/`, pour alimenter le tableau de bord
// « ce qu'Atoll a appris » (Réglages › Apprentissage).
//
// Trois principes, non négociables :
// - LECTURE PURE : aucune écriture, aucun déplacement, aucune suppression, pas
//   même la création du dossier. Ces notes appartiennent à l'utilisateur —
//   l'inventaire ne fait que les décrire ;
// - racine INJECTÉE (`notesRoot`) : testable sans toucher au vrai `~/.atoll` ;
// - robustesse absolue : dossier absent, fichier illisible, non-UTF-8,
//   front-matter tronqué, clé inconnue… rien ne lève, rien ne plante. Un
//   dossier absent rend simplement `[]`, un fichier abîmé est ignoré en
//   silence — un tableau de bord ne doit jamais empêcher l'app de tourner.

/// Une note mémoire résumée pour l'affichage : ses métadonnées de front-matter
/// et le poids de son corps. Le contenu intégral n'est délibérément PAS chargé
/// (l'inventaire peut décrire des centaines de notes).
public struct LearningNoteSummary: Equatable, Sendable, Identifiable {
    /// Nom de fichier (`2026-07-20-git-hygiene.md`) — identifiant naturel : il
    /// est unique dans le dossier (cf. `LearningNoteFile.deduplicatedFilename`).
    public var id: String { fileName }

    public let fileName: String
    /// Libellé d'affichage : clé `title`, sinon `slug`, sinon nom de fichier
    /// sans extension. Jamais vide.
    public let title: String
    public let slug: String?
    public let category: String?
    /// Chemin du projet d'origine, BRUT (tel qu'écrit dans le front-matter) :
    /// c'est lui qui montre que la connaissance circule entre projets.
    public let project: String?
    /// `created_at` (notes de rétrospective) ou `curated_at` (notes curées).
    public let createdAt: Date?
    /// Nombre de caractères du CORPS, front-matter exclu et blancs de bord
    /// retirés : le rendu insère une ligne vide après le front-matter et un
    /// saut de ligne final, les compter ferait varier le total selon le rendu
    /// et non selon la connaissance écrite.
    public let characterCount: Int

    public init(
        fileName: String,
        title: String,
        slug: String?,
        category: String?,
        project: String?,
        createdAt: Date?,
        characterCount: Int
    ) {
        self.fileName = fileName
        self.title = title
        self.slug = slug
        self.category = category
        self.project = project
        self.createdAt = createdAt
        self.characterCount = characterCount
    }
}

/// Inventaire (lecture seule) du dossier des notes mémoire.
///
/// Format lu — celui écrit par `LearningNoteFile.render` et par le curateur :
/// un front-matter optionnel `---` … `---` de lignes `clé: valeur`, puis le
/// corps markdown. Le parsing est DÉFENSIF de bout en bout : le format n'est
/// pas un contrat verrouillé, il évolue (les notes curées portent `curated_at`
/// et une liste `sources:` que les notes de rétrospective n'ont pas).
public struct LearningInventory {

    /// Clés de front-matter reconnues ; toutes les autres (`confidence`,
    /// `source_session`, `sources`…) sont lues puis ignorées sans erreur.
    private enum Key {
        static let title = "title"
        static let slug = "slug"
        static let category = "category"
        static let project = "project"
        static let createdAt = "created_at"
        static let curatedAt = "curated_at"
    }

    public let notesRoot: URL

    /// Racine injectable pour les tests ; défaut = chemin réel.
    public init(notesRoot: URL = BridgePaths.learningNotesDirectory) {
        self.notesRoot = notesRoot
    }

    private var fm: FileManager { .default }

    // MARK: - Lecture

    /// Les notes du dossier (`*.md`, NON récursif), triées par date de création
    /// DÉCROISSANTE — les plus récentes d'abord, celles sans date à la fin —
    /// puis par nom de fichier croissant : ordre total, stable et déterministe
    /// (deux appels rendent la même liste, l'UI ne « saute » pas).
    ///
    /// Tout ce qui n'est pas lisible en UTF-8 (fichier binaire, permissions,
    /// sous-dossier nommé `*.md`) est ignoré en silence.
    public func notes() -> [LearningNoteSummary] {
        let entries = (try? fm.contentsOfDirectory(
            at: notesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return entries
            .filter { $0.pathExtension.lowercased() == "md" }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true }
            .compactMap(summary(of:))
            .sorted(by: Self.isOrderedBefore)
    }

    /// Répartition des notes par projet d'origine : `(chemin brut, nombre)`,
    /// trié par nombre décroissant puis par projet croissant. Les notes sans
    /// projet connu sont regroupées sous la clé VIDE `""` — l'appelant décide
    /// comment l'afficher (« projet inconnu », section à part…).
    public func projects() -> [(project: String, count: Int)] {
        var counts: [String: Int] = [:]
        for note in notes() {
            counts[note.project ?? "", default: 0] += 1
        }
        return counts
            .map { (project: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.project < $1.project : $0.count > $1.count }
    }

    /// Volume total de connaissance écrite (somme des corps), pour l'entête du
    /// tableau de bord.
    public func totalCharacterCount() -> Int {
        notes().reduce(0) { $0 + $1.characterCount }
    }

    // MARK: - Tri

    /// Date décroissante (sans date = en dernier), puis nom de fichier croissant.
    private static func isOrderedBefore(
        _ lhs: LearningNoteSummary,
        _ rhs: LearningNoteSummary
    ) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (left?, right?):
            if left != right { return left > right }
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case (nil, nil):
            break
        }
        return lhs.fileName < rhs.fileName
    }

    // MARK: - Parsing (100 % défensif)

    private func summary(of url: URL) -> LearningNoteSummary? {
        // Non-UTF-8 / illisible → nil, jamais d'exception qui remonte.
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Self.parse(fileName: url.lastPathComponent, contents: contents)
    }

    /// Résume un fichier déjà lu. Ne peut PAS échouer : au pire toutes les
    /// métadonnées sont nil et le titre retombe sur le nom de fichier.
    static func parse(fileName: String, contents: String) -> LearningNoteSummary {
        let (fields, body) = splitFrontMatter(contents)
        let slug = fields[Key.slug]
        // `created_at` prioritaire ; `curated_at` (notes curées) en second —
        // et en repli si `created_at` est présent mais indéchiffrable.
        let createdAt = fields[Key.createdAt].flatMap(date(from:))
            ?? fields[Key.curatedAt].flatMap(date(from:))

        return LearningNoteSummary(
            fileName: fileName,
            title: fields[Key.title] ?? slug ?? stem(of: fileName),
            slug: slug,
            category: fields[Key.category],
            project: fields[Key.project],
            createdAt: createdAt,
            characterCount: body.trimmingCharacters(in: .whitespacesAndNewlines).count
        )
    }

    /// Découpe `front-matter / corps`. Le front-matter n'est reconnu QUE si le
    /// fichier commence (blancs de tête tolérés) par une ligne réduite à `---`
    /// ET qu'une seconde ligne `---` la referme — même règle que
    /// `LearningRender.strippedLeadingFrontMatter`, qui l'écrit. Sinon : aucune
    /// métadonnée, et le corps est le fichier ENTIER (un `---` ouvrant sans
    /// fermant n'est pas un front-matter, c'est du markdown).
    ///
    /// Les valeurs ne sont retenues que non vides : une clé présente mais vide
    /// équivaut à une clé absente. Une clé répétée garde sa PREMIÈRE valeur.
    ///
    /// `internal` (et non privé) : `NotesCurationPlanner` s'en sert pour relire
    /// les métadonnées des notes SOURCES et les reporter dans la note
    /// consolidée — sans ça, une curation effaçait `project`/`category` et le
    /// tableau de bord par projet mourait au premier cycle (revue).
    static func splitFrontMatter(_ raw: String) -> (fields: [String: String], body: String) {
        let leading = raw.drop { $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t" }
        let lines = leading.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, isFence(first),
              let close = lines.dropFirst().firstIndex(where: isFence)
        else { return ([:], raw) }

        var fields: [String: String] = [:]
        for line in lines[(lines.startIndex + 1)..<close] {
            guard let (key, value) = keyValue(in: line) else { continue }
            if fields[key] == nil { fields[key] = value }
        }
        let body = lines[(close + 1)...].joined(separator: "\n")
        return (fields, body)
    }

    /// Ligne « fence » de front-matter : exactement `---` (blancs et `\r` d'un
    /// fichier à fins de ligne Windows tolérés).
    private static func isFence(_ line: Substring) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
    }

    /// `clé: valeur` d'une ligne de front-matter, ou nil si la ligne n'est pas
    /// une clé.
    ///
    /// Une clé vit en COLONNE 0 : toute ligne INDENTÉE est une valeur imbriquée
    /// (les items `  - fichier.md` de `sources:`) et ne doit JAMAIS être prise
    /// pour une clé — même quand l'item contient un `:` (`  - "titre: x"`).
    /// Une ligne commençant par `-` est de même un item de liste, pas une clé.
    private static func keyValue(in line: Substring) -> (key: String, value: String)? {
        guard let firstCharacter = line.first,
              firstCharacter != " ", firstCharacter != "\t", firstCharacter != "-",
              let colon = line.firstIndex(of: ":")
        else { return nil }

        let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }

        let rawValue = line[line.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = unquoted(rawValue)
        guard !value.isEmpty else { return nil }
        return (key, value)
    }

    /// Déquote un scalaire écrit par `LearningRender.yamlScalar` : guillemets
    /// doubles de bord retirés, `\"` et `\\` restitués. Une valeur non quotée
    /// est rendue telle quelle (déjà trimée par l'appelant).
    private static func unquoted(_ raw: String) -> String {
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
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
        // Antislash final orphelin (valeur mal formée) : conservé plutôt
        // qu'avalé — on ne réécrit jamais la note de l'utilisateur.
        if escaping { output.append("\\") }
        return output
    }

    /// ISO-8601, avec ET sans fraction de seconde (les deux formes existent
    /// dans la nature ; Atoll écrit la précision seconde).
    private static func date(from raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }

    /// Nom de fichier sans son extension (`2026-07-20-x.md` → `2026-07-20-x`).
    private static func stem(of fileName: String) -> String {
        URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    }
}
