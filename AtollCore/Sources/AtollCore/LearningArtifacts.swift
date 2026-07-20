import Foundation

// Deux types publics co-localisés, délibérément : `LearningNoteFile` et
// `LearningSkillProposalFile` sont les deux facettes du même rendu PUR des
// artefacts d'apprentissage (Phase 7b) et partagent leurs aides privées
// (dates UTC déterministes, échappement YAML). Aucun accès disque ici :
// c'est l'app qui écrit les fichiers rendus — jamais le `claude -p` d'analyse.

/// Rendu du fichier d'une note mémoire (`memory/<date>-<slug>.md`) issue d'un
/// `RetrospectiveReport.Note`.
///
/// Invariants :
/// - le nom de fichier ne dérive QUE du slug (déjà validé kebab par
///   `RetrospectiveReport.parse` — ni `/` ni `.` possibles) et de la date du
///   jour en UTC : déterministe, aucune traversée de chemin possible ;
/// - toutes les dates sont rendues en UTC, quel que soit le fuseau machine
///   (rendu reproductible, testable) ; `created_at` en ISO-8601 ;
/// - front-matter YAML en tête (`slug`, `category`, `confidence`,
///   `source_session`, `project` si connu, `created_at`) puis le contenu ;
///   TOUTES les valeurs passent par l'échappement YAML défensif — même les
///   champs « déjà validés », au cas où une Note serait construite à la main ;
/// - le contenu rendu se termine par exactement un saut de ligne.
public enum LearningNoteFile {

    /// Rend `("2026-07-20-<slug>.md", contenu)` pour la note donnée.
    /// `project` nil ou vide → la ligne `project:` est simplement omise.
    public static func render(
        note: RetrospectiveReport.Note,
        sessionID: String,
        project: String?,
        date: Date
    ) -> (filename: String, contents: String) {
        let filename = "\(LearningRender.utcDayStamp(date))-\(note.slug).md"

        var frontMatter = [
            "slug: \(LearningRender.yamlScalar(note.slug))",
            "category: \(LearningRender.yamlScalar(note.category))",
            "confidence: \(LearningRender.yamlScalar(note.confidence))",
            "source_session: \(LearningRender.yamlScalar(sessionID))",
        ]
        if let project, !project.isEmpty {
            frontMatter.append("project: \(LearningRender.yamlScalar(project))")
        }
        frontMatter.append("created_at: \(LearningRender.iso8601(date))")

        let contents = "---\n"
            + frontMatter.joined(separator: "\n")
            + "\n---\n\n"
            + note.content
            + "\n"
        return (filename: filename, contents: contents)
    }

    /// Nom disponible le plus proche de `base` : `base.md` pris → `base-2.md`,
    /// `base-3.md`… Le suffixe s'insère AVANT l'extension (dernier point, sauf
    /// point initial de fichier caché) ; termine toujours (`existing` est fini).
    public static func deduplicatedFilename(_ base: String, existing: Set<String>) -> String {
        guard existing.contains(base) else { return base }

        let stem: Substring
        let ext: Substring
        if let dot = base.lastIndex(of: "."), dot != base.startIndex {
            stem = base[..<dot]
            ext = base[dot...]
        } else {
            stem = base[...]
            ext = ""
        }

        var counter = 2
        while true {
            let candidate = "\(stem)-\(counter)\(ext)"
            if !existing.contains(candidate) { return candidate }
            counter += 1
        }
    }
}

/// Rendu des fichiers d'une proposition de skill (`SKILL.md` + `meta.json`)
/// issue d'un `RetrospectiveReport.SkillProposal` — jamais écrite sur disque
/// sans validation humaine (UI 7c) : `status` naît toujours à « proposed ».
///
/// Invariants :
/// - le front-matter du `SKILL.md` est GÉNÉRÉ par Atoll (`name: atoll-<slug>`,
///   `description` échappée YAML), JAMAIS repris du modèle : tout front-matter
///   en tête du `skillMD` reçu (`--- … ---`, même enchaîné) est STRIPPÉ — un
///   `allowed-tools` hostile injecté via le transcript ne peut pas survivre.
///   Un `---` ouvrant sans fermant n'est PAS un front-matter (aucun parseur ne
///   le lirait comme tel) et reste dans le corps, inerte derrière le nôtre ;
/// - `meta.json` est sérialisé avec `sortedKeys` : octets déterministes,
///   comparables et re-décodables ; `project` nil → clé absente ;
/// - dates UTC, `created_at` ISO-8601, comme pour les notes.
public enum LearningSkillProposalFile {

    /// `SKILL.md` FINAL : front-matter Atoll + corps nettoyé, terminé par un
    /// saut de ligne. Un corps vide après strip rend le front-matter seul.
    public static func renderSkillMD(_ proposal: RetrospectiveReport.SkillProposal) -> String {
        let body = LearningRender.strippedLeadingFrontMatter(proposal.skillMD)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var output = """
        ---
        name: atoll-\(proposal.slug)
        description: \(LearningRender.yamlScalar(proposal.description))
        ---
        """
        if !body.isEmpty {
            output += "\n\n" + body
        }
        return output + "\n"
    }

    /// `meta.json` de la proposition, prêt à écrire :
    /// `{v: 1, slug, title, description, rationale, confidence, source_session,
    /// project (si connu), created_at, status: "proposed", flags}`.
    /// `flags` = raisons de suspicion venues de `RetrospectiveReport.flags`
    /// (vide = rien à signaler) — l'UI de revue les affiche telles quelles.
    public static func renderMeta(
        _ proposal: RetrospectiveReport.SkillProposal,
        sessionID: String,
        project: String?,
        date: Date,
        flags: [String]
    ) -> Data {
        var object: [String: Any] = [
            "v": 1,
            "slug": proposal.slug,
            "title": proposal.title,
            "description": proposal.description,
            "rationale": proposal.rationale,
            "confidence": proposal.confidence,
            "source_session": sessionID,
            "created_at": LearningRender.iso8601(date),
            "status": "proposed",
            "flags": flags,
        ]
        if let project, !project.isEmpty {
            object["project"] = project
        }
        // Types JSON purs uniquement : la sérialisation ne peut pas échouer —
        // Data vide en ultime recours pour garder une signature non-throwing.
        return (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data()
    }
}

// MARK: - Aides partagées

/// Aides de rendu communes aux deux types : formatage de dates figé en UTC
/// (déterminisme testable — le fuseau machine ne doit jamais transparaître)
/// et échappement YAML défensif.
private enum LearningRender {

    /// `2026-07-20` — date CIVILE en UTC (pas le fuseau machine : un test à
    /// 23 h 30 UTC rend le 20, même si Paris est déjà le 21).
    static func utcDayStamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// `2026-07-20T23:30:00Z` — ISO-8601 UTC, précision seconde.
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

    /// Retire TOUT front-matter en tête du markdown : blancs de tête ignorés,
    /// bloc `---` … `---` (fermant = ligne réduite à `---`) supprimé, et on
    /// recommence — des front-matters enchaînés tombent tous. Un `---` ouvrant
    /// sans fermant est conservé tel quel : ce n'est pas un front-matter.
    static func strippedLeadingFrontMatter(_ markdown: String) -> String {
        var body = markdown[...]
        while true {
            body = body.drop { $0 == "\n" || $0 == "\r" || $0 == " " || $0 == "\t" }
            var lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            guard let first = lines.first, isFence(first) else { return String(body) }
            guard let close = lines.dropFirst().firstIndex(where: isFence) else {
                return String(body)
            }
            lines.removeSubrange(...close)
            body = lines.joined(separator: "\n")[...]
        }
    }

    /// Une ligne « fence » de front-matter : exactement `---`, blancs tolérés.
    private static func isFence(_ line: Substring) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines) == "---"
    }
}
