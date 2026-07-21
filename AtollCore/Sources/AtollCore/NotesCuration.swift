import Foundation

// Deux types publics co-localisés, délibérément (même précédent que
// LearningArtifacts.swift) : `NotesCurationOutput` (parsing défensif de la
// sortie du `claude -p` de curation) et `NotesCurationPlanner` (planificateur
// pur avec garde-fous) sont les deux moitiés de la même étape de curation des
// notes mémoire (Phase 7c) et partagent leurs aides privées (rendu YAML/UTC,
// mêmes conventions que `LearningRender`, privé dans LearningArtifacts.swift).
// Aucun accès disque ici : le service App qui lance `claude -p` et écrit les
// fichiers vient à part — ici, uniquement de la logique pure et testée.

/// Sortie de la curation des notes mémoire : un `claude -p --output-format
/// json` relit l'ensemble des notes accumulées et propose un jeu de notes
/// CONSOLIDÉES, plus les contradictions qu'il a repérées entre elles (jamais
/// résolues automatiquement — voir `NotesCurationPlanner`).
///
/// Schéma attendu du payload :
/// `{ notes: [{title, content, sources[]}], contradictions: [{summary, files[]}] }`
///
/// Parsing 100 % défensif de l'enveloppe `claude -p` (même forme que pour
/// `RetrospectiveReport`, vérifiée empiriquement, CLI 2.1.215) :
/// - `structured_output` (objet) est la source primaire ; à défaut, `result`
///   (string JSON, fences ```json``` strippées) ;
/// - enveloppe d'erreur (`is_error`, `subtype` explicite ≠ "success") ou JSON
///   inexploitable → nil, jamais d'exception ;
/// - item sans `title`/`content` (resp. `summary`) non vide → DROPPÉ en
///   silence, jamais d'échec global pour un item ; dans `sources`/`files`,
///   seules les strings non vides survivent (le reste est ignoré) ;
/// - un payload objet valide SANS clé `notes` rend simplement 0 note : c'est
///   le planificateur qui refuse une sortie vide, pas le parseur.
public struct NotesCurationOutput: Equatable, Sendable {

    /// Une note consolidée proposée. `sources` = noms des fichiers de notes
    /// d'origine que cette note résume/fusionne (provenance, purement
    /// indicative — jamais interprétée comme un chemin).
    public struct Note: Equatable, Sendable {
        public let title: String
        public let content: String
        public let sources: [String]

        public init(title: String, content: String, sources: [String]) {
            self.title = title
            self.content = content
            self.sources = sources
        }
    }

    /// Une contradiction repérée entre notes existantes. Jamais appliquée :
    /// seulement remontée à l'humain (voir `NotesCurationPlanner.plan`).
    public struct Contradiction: Equatable, Sendable {
        public let summary: String
        public let files: [String]

        public init(summary: String, files: [String]) {
            self.summary = summary
            self.files = files
        }
    }

    public let notes: [Note]
    public let contradictions: [Contradiction]

    public init(notes: [Note], contradictions: [Contradiction]) {
        self.notes = notes
        self.contradictions = contradictions
    }

    // MARK: - Parsing

    public static func parse(cliOutput: Data) -> NotesCurationOutput? {
        // (1) L'enveloppe doit être un objet JSON.
        guard let rootAny = try? JSONSerialization.jsonObject(with: cliOutput),
              let root = rootAny as? [String: Any] else { return nil }

        // (2) Enveloppe d'erreur du CLI. `subtype` absent n'est PAS une erreur
        // (le format peut évoluer) — seuls un mismatch explicite ou is_error comptent.
        let subtype = root["subtype"] as? String
        let isError = (root["is_error"] as? Bool) ?? false
        if isError || (subtype != nil && subtype != "success") { return nil }

        // (3) Payload structuré : structured_output (objet), sinon result (string JSON).
        guard let payload = structuredPayload(of: root) else { return nil }

        return NotesCurationOutput(
            notes: validatedNotes(payload["notes"]),
            contradictions: validatedContradictions(payload["contradictions"])
        )
    }

    private static func structuredPayload(of root: [String: Any]) -> [String: Any]? {
        if let structured = root["structured_output"] as? [String: Any] {
            return structured
        }
        guard let result = root["result"] as? String else { return nil }
        let stripped = strippedCodeFences(result)
        guard !stripped.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(stripped.utf8)),
              let payload = object as? [String: Any] else { return nil }
        return payload
    }

    /// Retire une paire de fences Markdown (```json … ```) autour du texte.
    private static func strippedCodeFences(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("```") else { return body }
        guard let firstNewline = body.firstIndex(of: "\n") else { return "" }
        body = String(body[body.index(after: firstNewline)...])
        if body.hasSuffix("```") {
            body = String(body.dropLast(3))
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Revalidation

    private static func validatedNotes(_ value: Any?) -> [Note] {
        var notes: [Note] = []
        for entry in (value as? [Any]) ?? [] {
            guard let dict = entry as? [String: Any],
                  let title = trimmedNonEmpty(dict["title"]),
                  let content = trimmedNonEmpty(dict["content"]) else { continue }
            notes.append(Note(
                title: title,
                content: content,
                sources: validatedStrings(dict["sources"])
            ))
        }
        return notes
    }

    private static func validatedContradictions(_ value: Any?) -> [Contradiction] {
        var contradictions: [Contradiction] = []
        for entry in (value as? [Any]) ?? [] {
            guard let dict = entry as? [String: Any],
                  let summary = trimmedNonEmpty(dict["summary"]) else { continue }
            contradictions.append(Contradiction(
                summary: summary,
                files: validatedStrings(dict["files"])
            ))
        }
        return contradictions
    }

    /// La valeur si c'est une string non vide après trim, sinon nil.
    private static func trimmedNonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Seules les strings non vides (après trim) du tableau survivent ;
    /// tout autre type (nombre, objet…) est ignoré sans échec.
    private static func validatedStrings(_ value: Any?) -> [String] {
        ((value as? [Any]) ?? []).compactMap { trimmedNonEmpty($0) }
    }
}

/// Planificateur PUR de la curation : transforme une `NotesCurationOutput` en
/// plan d'écriture (fichiers de notes rendus + avertissements) — ou REFUSE.
/// C'est le service App qui, sur un `.success`, remplace les anciens fichiers
/// par `newNotes` ; sur un `.failure`, il ne touche à RIEN.
///
/// Garde-fous (le modèle peut halluciner ou tout perdre — on ne remplace
/// jamais la mémoire existante sur une sortie suspecte) :
/// - 0 note proposée alors que des notes existent → `.emptyOutputFromNonEmptyInput` ;
/// - volume des contenus proposés < 50 % du volume existant (strictement ;
///   à exactement 50 % on passe) → `.excessiveShrink(ratio:)` — volumes
///   comptés en caractères sur les contenus BRUTS (fichiers existants tels
///   quels côté ancien, `content` des notes côté neuf : le front-matter des
///   fichiers existants gonfle l'ancien volume et pousse donc vers le refus,
///   le sens sûr) ;
/// - les contradictions ne sont JAMAIS résolues automatiquement : chacune
///   devient un avertissement `⚠ contradiction : <summary>` que l'UI affiche,
///   et n'influence NI les notes rendues NI le refus.
///
/// Rendu déterministe (mêmes entrées + même `now` → mêmes octets) :
/// `NN-<slug-du-titre>.md` (index 1-based sur 2 chiffres — pas de collision
/// possible même à titres identiques —, slug ASCII kebab dérivé du titre,
/// « note » si vide), front-matter minimal dans le style de `LearningNoteFile`
/// (`title` échappé YAML, `curated_at` ISO-8601 UTC, `sources` si non vide),
/// contenu terminé par exactement un saut de ligne.
public enum NotesCurationPlanner {

    /// Un fichier de note prêt à écrire. Struct nommé (plutôt qu'un tuple)
    /// pour que `Plan` reste Equatable.
    public struct RenderedNote: Equatable, Sendable {
        public let fileName: String
        public let content: String

        public init(fileName: String, content: String) {
            self.fileName = fileName
            self.content = content
        }
    }

    /// Le plan accepté : les fichiers à écrire et les avertissements à montrer.
    public struct Plan: Equatable, Sendable {
        public let newNotes: [RenderedNote]
        public let warnings: [String]

        public init(newNotes: [RenderedNote], warnings: [String]) {
            self.newNotes = newNotes
            self.warnings = warnings
        }
    }

    /// Raisons de refus — dans les deux cas, rien ne doit être écrit.
    public enum CurationRefusal: Error, Equatable, Sendable {
        /// Le modèle ne propose AUCUNE note alors qu'il en existe : appliquer
        /// reviendrait à effacer toute la mémoire.
        case emptyOutputFromNonEmptyInput
        /// Le volume proposé est < 50 % de l'existant (`ratio` = neuf/ancien) :
        /// un rétrécissement massif est suspect.
        case excessiveShrink(ratio: Double)
    }

    /// Seuil de rétrécissement : refus si `ratio` est STRICTEMENT inférieur.
    private static let shrinkThreshold = 0.5

    public static func plan(
        existing: [(name: String, content: String)],
        output: NotesCurationOutput,
        now: Date
    ) -> Result<Plan, CurationRefusal> {
        // (1) Sortie vide sur entrée non vide : jamais d'effacement total —
        // testé sur la LISTE (même des fichiers vides méritent le refus).
        if output.notes.isEmpty && !existing.isEmpty {
            return .failure(.emptyOutputFromNonEmptyInput)
        }

        // (2) Rétrécissement massif suspect. `existingVolume == 0` (aucun
        // fichier, ou que des fichiers vides) → ratio indéfini, garde inerte.
        let existingVolume = existing.reduce(0) { $0 + $1.content.count }
        let newVolume = output.notes.reduce(0) { $0 + $1.content.count }
        if existingVolume > 0 {
            let ratio = Double(newVolume) / Double(existingVolume)
            if ratio < shrinkThreshold {
                return .failure(.excessiveShrink(ratio: ratio))
            }
        }

        // (3) Rendu des notes ; les contradictions deviennent des
        // avertissements, dans l'ordre de la sortie, et rien d'autre.
        let rendered = output.notes.enumerated().map { index, note in
            RenderedNote(
                fileName: fileName(index: index, title: note.title),
                content: renderedContents(of: note, now: now)
            )
        }
        let warnings = output.contradictions.map { "⚠ contradiction : \($0.summary)" }
        return .success(Plan(newNotes: rendered, warnings: warnings))
    }

    // MARK: - Rendu

    /// `01-mon-titre.md` — index 1-based sur 2 chiffres (l'ordre du modèle est
    /// préservé et lisible dans un `ls`), slug dérivé du titre.
    private static func fileName(index: Int, title: String) -> String {
        String(format: "%02d-", index + 1) + slug(fromTitle: title) + ".md"
    }

    /// Slug ASCII kebab sûr pour nommer un fichier : diacritiques pliés
    /// (« Pièges » → "pieges"), tout ce qui n'est pas [a-z0-9] devient
    /// séparateur, runs fusionnés, ≤ 60 caractères (sans tiret pendant),
    /// « note » si plus rien ne survit. Aucune traversée de chemin possible :
    /// `/` et `.` ne peuvent pas apparaître.
    private static func slug(fromTitle title: String) -> String {
        let folded = title
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var parts: [String] = []
        var current = ""
        for character in folded {
            if character.isASCII, character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                parts.append(current)
                current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        var joined = parts.joined(separator: "-")
        guard !joined.isEmpty else { return "note" }
        if joined.count > 60 {
            joined = String(joined.prefix(60))
            while joined.hasSuffix("-") { joined.removeLast() }
        }
        return joined
    }

    /// Front-matter minimal (title, curated_at, sources si non vide) puis le
    /// contenu, terminé par exactement un saut de ligne — style LearningNoteFile.
    private static func renderedContents(of note: NotesCurationOutput.Note, now: Date) -> String {
        var frontMatter = [
            "title: \(CurationRender.yamlScalar(note.title))",
            "curated_at: \(CurationRender.iso8601(now))",
        ]
        if !note.sources.isEmpty {
            frontMatter.append("sources:")
            frontMatter.append(contentsOf: note.sources.map {
                "  - \(CurationRender.yamlScalar($0))"
            })
        }

        var output = "---\n" + frontMatter.joined(separator: "\n") + "\n---\n"
        // `parse` garantit un contenu non vide, mais une Note construite à la
        // main peut être vide → front-matter seul, jamais de corps fantôme.
        let body = note.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            output += "\n" + body + "\n"
        }
        return output
    }
}

// MARK: - Aides de rendu

/// Miroir local des aides de `LearningRender` (privé dans
/// LearningArtifacts.swift — non partageable sans l'exposer) : dates figées en
/// UTC (déterminisme testable, le fuseau machine ne transparaît jamais) et
/// échappement YAML défensif identique.
private enum CurationRender {

    /// `2026-07-20T12:00:00Z` — ISO-8601 UTC, précision seconde.
    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Rend une valeur sûre pour `clé: valeur` en YAML : sauts de ligne → un
    /// espace (une valeur multi-ligne ne peut pas injecter de clé), puis
    /// guillemets doubles (avec échappement `\` et `"`) si la valeur contient
    /// `:`, `#`, `"` ou `\`, commence par un indicateur YAML, ou a des blancs
    /// de bord. Une valeur anodine reste en clair (lisible) ; sur-quoter est
    /// sans danger, sous-quoter ne l'est pas — le doute quote.
    static func yamlScalar(_ raw: String) -> String {
        let flattened = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        // Actifs PARTOUT dans un scalaire plain (`: `, ` #`, échappement) —
        // sur-approximés à « présent quelque part » pour rester simple et sûr.
        let activeAnywhere: Set<Character> = [":", "#", "\"", "\\"]
        // Indicateurs YAML actifs seulement en TÊTE de scalaire.
        let activePrefix: Set<Character> = [
            "-", "?", ",", "[", "]", "{", "}", "&", "*",
            "!", "|", ">", "'", "%", "@", "`",
        ]
        let needsQuoting = flattened.isEmpty
            || flattened.hasPrefix(" ") || flattened.hasSuffix(" ")
            || flattened.first.map { activePrefix.contains($0) } == true
            || flattened.contains { activeAnywhere.contains($0) }
        guard needsQuoting else { return flattened }

        let escaped = flattened
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
