import Foundation

/// Rapport de rétrospective de fin de session : sortie de `claude -p
/// --output-format json --json-schema …` (analyse READ-ONLY du transcript,
/// lancée par Atoll à la fin d'une session substantielle), parsée puis
/// REVALIDÉE intégralement ici. Le schéma appliqué côté CLI ne vaut PAS
/// validation : le modèle peut halluciner, l'enveloppe peut changer — on ne
/// fait jamais confiance à cette sortie, et c'est Atoll (pas le CLI) qui écrit
/// les fichiers résultants.
///
/// Enveloppe VÉRIFIÉE empiriquement (V0, CLI 2.1.215) :
///
/// ```json
/// {
///   "type": "result", "subtype": "success", "is_error": false,
///   "structured_output": { …objet déjà validé par --json-schema… },
///   "result": "…le même objet en string, parfois entouré de fences ```json…",
///   "total_cost_usd": 0.042, "session_id": "…", "num_turns": 7, "usage": { … }
/// }
/// ```
///
/// `structured_output` est la source primaire ; à défaut, `result` (string) est
/// parsé en JSON après retrait des fences. Invariants garantis après `parse` :
///
/// - slugs conformes à `^[a-z0-9]+(-[a-z0-9]+)*$` et ≤ 60 caractères — Atoll
///   nomme des fichiers d'après eux, aucun path traversal possible ;
/// - `category` ∈ `Note.allowedCategories` (sinon « project-fact »),
///   `confidence` ∈ {low, medium, high} (sinon « low ») ;
/// - longueurs plafonnées (troncature silencieuse) : summary 500, content 1200,
///   title 80, description 300, skillMD 8000, rationale 500 ; ≤ 8 notes,
///   ≤ 2 skills (les premiers items valides gagnent) ;
/// - item invalide (slug KO, champ requis manquant/vide) DROPPÉ silencieusement,
///   jamais d'échec global pour un item ; slugs de notes dupliqués → le premier
///   gagne ;
/// - contenu suspect (motif de secret, blob base64 > 200 caractères, pipe vers
///   un shell, mention de `~/.claude/settings.json`) : une NOTE suspecte est
///   DROPPÉE (comptée nulle part) ; un SKILL suspect est CONSERVÉ mais signalé
///   dans `flags[slug]` avec ses raisons — "secret-pattern", "base64-blob",
///   "pipe-to-shell", "settings-json-mention" — que l'UI de revue (7c) affiche.
public struct RetrospectiveReport: Equatable, Sendable {

    /// Une note mémoire proposée, destinée aux fichiers `memory/*.md`.
    public struct Note: Equatable, Sendable {
        /// Catégories acceptées — ALIGNÉES sur l'enum du jsonSchema de
        /// RetrospectivePrompt (source unique) ; toute autre valeur retombe
        /// sur « project-fact ».
        public static let allowedCategories: Set<String> = [
            "project-fact", "user-preference", "pitfall", "decision"
        ]

        public let slug: String
        public let category: String
        public let content: String
        public let confidence: String

        public init(slug: String, category: String, content: String, confidence: String) {
            self.slug = slug
            self.category = category
            self.content = content
            self.confidence = confidence
        }
    }

    /// Une proposition de skill (`.claude/skills/<slug>/SKILL.md`) — jamais
    /// écrite sur disque sans validation humaine explicite (UI 7c).
    public struct SkillProposal: Equatable, Sendable {
        public let slug: String
        public let title: String
        public let description: String
        public let skillMD: String
        public let rationale: String
        public let confidence: String

        public init(slug: String, title: String, description: String,
                    skillMD: String, rationale: String, confidence: String) {
            self.slug = slug
            self.title = title
            self.description = description
            self.skillMD = skillMD
            self.rationale = rationale
            self.confidence = confidence
        }
    }

    public enum ParseError: Error, Equatable, Sendable {
        /// La sortie n'est pas un objet JSON (crash du CLI, sortie tronquée…).
        case notJSON
        /// Enveloppe d'erreur du CLI (`is_error` ou `subtype` ≠ "success") —
        /// message = subtype + fin du champ `result` pour le diagnostic.
        case errorEnvelope(String)
        /// Ni `structured_output` (objet) ni `result` (string JSON) exploitables.
        case noStructuredPayload
        /// Payload bien formé mais sans AUCUN contenu (résumé, notes, skills)
        /// et sans revendiquer `nothing_learned` — rapport inutilisable.
        case empty
    }

    public let sessionSummary: String
    public let nothingLearned: Bool
    public let notes: [Note]
    public let skills: [SkillProposal]
    /// `total_cost_usd` de l'enveloppe (coût de l'analyse elle-même), si présent.
    public let costUSD: Double?
    /// slug de skill CONSERVÉ → raisons de suspicion (voir doc du type).
    public let flags: [String: [String]]

    public init(sessionSummary: String, nothingLearned: Bool, notes: [Note],
                skills: [SkillProposal], costUSD: Double?, flags: [String: [String]]) {
        self.sessionSummary = sessionSummary
        self.nothingLearned = nothingLearned
        self.notes = notes
        self.skills = skills
        self.costUSD = costUSD
        self.flags = flags
    }

    // MARK: - Parsing

    public static func parse(cliOutput: Data) -> Result<RetrospectiveReport, ParseError> {
        // (1) L'enveloppe doit être un objet JSON.
        guard let rootAny = try? JSONSerialization.jsonObject(with: cliOutput),
              let root = rootAny as? [String: Any] else {
            return .failure(.notJSON)
        }

        // (2) Enveloppe d'erreur du CLI. `subtype` absent n'est PAS une erreur
        // (le format peut évoluer) — seuls un mismatch explicite ou is_error comptent.
        let subtype = root["subtype"] as? String
        let isError = (root["is_error"] as? Bool) ?? false
        if isError || (subtype != nil && subtype != "success") {
            return .failure(.errorEnvelope(
                errorMessage(subtype: subtype, result: root["result"] as? String)
            ))
        }

        // (3) Payload structuré : structured_output (objet), sinon result (string JSON).
        guard let payload = structuredPayload(of: root) else {
            return .failure(.noStructuredPayload)
        }

        // (4) Revalidation Swift complète — indépendante du --json-schema du CLI.
        let summary = truncated(payload["session_summary"] as? String ?? "", to: Limit.sessionSummary)
        let nothingLearned = (payload["nothing_learned"] as? Bool) ?? false
        let notes = validatedNotes(payload["notes"])
        let (skills, flags) = validatedSkills(payload["skills"])
        let costUSD = (root["total_cost_usd"] as? NSNumber)?.doubleValue

        if summary.isEmpty && notes.isEmpty && skills.isEmpty && !nothingLearned {
            return .failure(.empty)
        }

        return .success(RetrospectiveReport(
            sessionSummary: summary,
            nothingLearned: nothingLearned,
            notes: notes,
            skills: skills,
            costUSD: costUSD,
            flags: flags
        ))
    }

    // MARK: - Extraction du payload

    private static func structuredPayload(of root: [String: Any]) -> [String: Any]? {
        if let structured = root["structured_output"] as? [String: Any] {
            return structured
        }
        guard let result = root["result"] as? String else { return nil }
        let stripped = strippedCodeFences(result)
        guard !stripped.isEmpty,
              let data = stripped.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
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

    private static func errorMessage(subtype: String?, result: String?) -> String {
        let label = subtype ?? "unknown"
        guard let result, !result.isEmpty else { return label }
        let tail = String(result.suffix(Limit.errorTail)).trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? label : "\(label) — \(tail)"
    }

    // MARK: - Revalidation

    private enum Limit {
        static let sessionSummary = 500
        static let content = 1200
        static let title = 80
        static let description = 300
        static let skillMD = 8000
        static let rationale = 500
        static let notes = 8
        static let skills = 2
        static let errorTail = 200
    }

    private static let allowedConfidences: Set<String> = ["low", "medium", "high"]

    private static func validatedNotes(_ value: Any?) -> [Note] {
        var notes: [Note] = []
        var seenSlugs = Set<String>()
        for entry in (value as? [Any]) ?? [] {
            guard notes.count < Limit.notes else { break }
            guard let dict = entry as? [String: Any],
                  let slug = validSlug(dict["slug"]),
                  let rawContent = dict["content"] as? String else { continue }
            let content = truncated(rawContent, to: Limit.content)
            guard !content.isEmpty else { continue }
            // Scan du contenu BRUT (un secret peut se trouver après le cap) ;
            // note suspecte droppée AVANT la déduplication — son slug reste
            // disponible pour une note saine.
            guard suspicionReasons(in: rawContent).isEmpty else { continue }
            guard seenSlugs.insert(slug).inserted else { continue } // premier gagne
            notes.append(Note(
                slug: slug,
                category: normalized(dict["category"], in: Note.allowedCategories,
                                     fallback: "project-fact"),
                content: content,
                confidence: normalized(dict["confidence"], in: allowedConfidences,
                                       fallback: "low")
            ))
        }
        return notes
    }

    private static func validatedSkills(_ value: Any?) -> ([SkillProposal], [String: [String]]) {
        var skills: [SkillProposal] = []
        var flags: [String: [String]] = [:]
        var seenSlugs = Set<String>()
        for entry in (value as? [Any]) ?? [] {
            guard skills.count < Limit.skills else { break }
            guard let dict = entry as? [String: Any],
                  let slug = validSlug(dict["slug"]),
                  let rawTitle = dict["title"] as? String,
                  let rawSkillMD = dict["skill_md"] as? String else { continue }
            let title = truncated(rawTitle, to: Limit.title)
            let skillMD = truncated(rawSkillMD, to: Limit.skillMD)
            guard !title.isEmpty, !skillMD.isEmpty,
                  seenSlugs.insert(slug).inserted else { continue }
            let rawDescription = dict["description"] as? String ?? ""
            let rawRationale = dict["rationale"] as? String ?? ""
            // Skill suspect : CONSERVÉ mais signalé — scan des champs BRUTS,
            // avant troncature, un secret pouvant se trouver après le cap.
            let reasons = suspicionReasons(
                in: [rawTitle, rawDescription, rawSkillMD, rawRationale].joined(separator: "\n")
            )
            if !reasons.isEmpty { flags[slug] = reasons }
            skills.append(SkillProposal(
                slug: slug,
                title: title,
                description: truncated(rawDescription, to: Limit.description),
                skillMD: skillMD,
                rationale: truncated(rawRationale, to: Limit.rationale),
                confidence: normalized(dict["confidence"], in: allowedConfidences,
                                       fallback: "low")
            ))
        }
        return (skills, flags)
    }

    /// Slug sûr pour nommer un fichier : minuscules/chiffres/tirets simples,
    /// ≤ 60 caractères. Ancres `\A`/`\z` et non `^`/`$` : le `$` ICU accepterait
    /// un saut de ligne final — tout path traversal (`../…`) est exclu.
    private static func validSlug(_ value: Any?) -> String? {
        guard let slug = value as? String, slug.count <= 60,
              slug.range(of: "\\A[a-z0-9]+(-[a-z0-9]+)*\\z",
                         options: .regularExpression) != nil
        else { return nil }
        return slug
    }

    private static func normalized(_ value: Any?, in allowed: Set<String>,
                                   fallback: String) -> String {
        guard let string = value as? String, allowed.contains(string) else { return fallback }
        return string
    }

    /// Trim des blancs aux extrémités puis troncature dure à `limit` caractères.
    private static func truncated(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit))
    }

    // MARK: - Détection de contenu suspect

    /// Motifs de secrets (regex ICU). Volontairement larges : mieux vaut
    /// dropper/flagger à tort qu'écrire un secret dans un fichier mémoire.
    private static let secretPatterns: [String] = [
        "sk-ant-",                  // clés API Anthropic
        "ghp_[A-Za-z0-9]{8,}",      // tokens GitHub
        "AKIA[0-9A-Z]{16}",         // access keys AWS
        "(?i)api[_-]?key\\s*[:=]",  // affectation de clé générique
        "BEGIN.*PRIVATE KEY"        // blocs PEM
    ]

    /// Raisons de suspicion trouvées dans `text` (stables, affichées par 7c) :
    /// "secret-pattern", "base64-blob", "pipe-to-shell", "settings-json-mention".
    private static func suspicionReasons(in text: String) -> [String] {
        var reasons: [String] = []
        if secretPatterns.contains(where: {
            text.range(of: $0, options: .regularExpression) != nil
        }) {
            reasons.append("secret-pattern")
        }
        // Blob base64 : seuil abaissé à 120 (revue : une clé sk-ant encodée
        // fait ~140 caractères ; l'ancien seuil de 200 la laissait passer).
        if text.range(of: "[A-Za-z0-9+/=]{121,}", options: .regularExpression) != nil {
            reasons.append("base64-blob")
        }
        // Exécution aveugle depuis le réseau — trois formes (revue : `| zsh`,
        // `bash <(curl …)` et `sh -c "$(curl …)"` passaient sous l'ancien motif) :
        // pipe vers n'importe quel *sh, substitution de processus, command subst.
        let pipeToShell = "(curl|wget)[^|\\n]*\\|\\s*\\w*sh\\b"
        let processSubst = "\\w*sh\\b[^\\n]*<\\(\\s*(curl|wget)"
        let commandSubst = "\\w*sh\\s+-c\\s+[\"']?\\$\\((curl|wget)"
        if [pipeToShell, processSubst, commandSubst].contains(where: {
            text.range(of: $0, options: .regularExpression) != nil
        }) {
            reasons.append("pipe-to-shell")
        }
        // Toute mention des fichiers de réglages sacrés — settings.json ET
        // settings.local.json (revue), quel que soit le préfixe de chemin.
        if text.contains(".claude/settings") {
            reasons.append("settings-json-mention")
        }
        return reasons
    }
}
