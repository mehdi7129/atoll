import Foundation

/// Une proposition de skill en quarantaine (`~/.atoll/learning/proposed/<dir>/`),
/// décodée depuis son couple `meta.json` + `SKILL.md` écrit par la
/// rétrospective (Phase 7b, cf. `LearningSkillProposalFile`). Jamais active
/// tant qu'un humain ne l'a pas approuvée (Phase 7c, `LearnedSkillStore`).
///
/// Invariants :
/// - décodage 100 % DÉFENSIF : champ requis manquant, JSON illisible, date
///   imparsable ou statut INCONNU → nil, la proposition est ignorée (une
///   version future d'Atoll a pu introduire un état — on ignore plutôt que
///   de mal l'interpréter) ; jamais de crash ;
/// - le slug n'est PAS validé ici (seulement non vide) : la revue doit pouvoir
///   AFFICHER une proposition au slug douteux — c'est `approve` qui refuse
///   (`SkillSlug.validate`), pas le chargement ;
/// - les transitions d'état sont centralisées dans `canTransition` :
///   proposed → approved | rejected ; approved → archived ; rien d'autre.
public struct SkillProposal: Identifiable, Equatable, Sendable {

    /// Cycle de vie d'une proposition. `archived` = skill approuvé puis
    /// désinstallé (le dossier part en archive, rien n'est supprimé).
    public enum Status: String, Codable, CaseIterable, Equatable, Sendable {
        case proposed
        case approved
        case rejected
        case archived
    }

    public let slug: String
    public let title: String
    public let description: String
    public let rationale: String?
    public let sourceSession: String?
    public let sourceProject: String?
    public let createdAt: Date
    public let status: Status
    /// Dossier de la proposition sur disque (source du décodage).
    public let directoryURL: URL
    /// Contenu INTÉGRAL du `SKILL.md`, déjà rendu final par la 7b
    /// (front-matter Atoll compris) — c'est lui qui sera installé tel quel.
    public let skillMD: String

    /// Identité stable pour l'UI de revue : le nom du dossier sur disque.
    public var id: String { directoryURL.lastPathComponent }

    public init(
        slug: String,
        title: String,
        description: String,
        rationale: String?,
        sourceSession: String?,
        sourceProject: String?,
        createdAt: Date,
        status: Status,
        directoryURL: URL,
        skillMD: String
    ) {
        self.slug = slug
        self.title = title
        self.description = description
        self.rationale = rationale
        self.sourceSession = sourceSession
        self.sourceProject = sourceProject
        self.createdAt = createdAt
        self.status = status
        self.directoryURL = directoryURL
        self.skillMD = skillMD
    }

    /// Seules transitions légales : proposed → approved | rejected ;
    /// approved → archived. Tout le reste est false (y compris l'identité).
    public static func canTransition(from: Status, to: Status) -> Bool {
        switch (from, to) {
        case (.proposed, .approved), (.proposed, .rejected), (.approved, .archived):
            return true
        default:
            return false
        }
    }

    // MARK: - Décodage défensif de meta.json

    /// nil si le JSON est illisible, si un champ requis manque (`slug`,
    /// `title`, `description`, `created_at`, `status`), si la date ne se
    /// parse pas ou si le statut est inconnu. Les champs optionnels absents
    /// (`rationale`, `source_session`, `project`) deviennent simplement nil.
    public static func decode(metaJSON: Data, skillMD: String, directoryURL: URL) -> SkillProposal? {
        guard let meta = try? JSONDecoder().decode(Meta.self, from: metaJSON),
              !meta.slug.isEmpty,
              let status = Status(rawValue: meta.status),
              let createdAt = parseISO8601(meta.createdAt)
        else { return nil }

        return SkillProposal(
            slug: meta.slug,
            title: meta.title,
            description: meta.description,
            rationale: meta.rationale,
            sourceSession: meta.sourceSession,
            sourceProject: meta.project,
            createdAt: createdAt,
            status: status,
            directoryURL: directoryURL,
            skillMD: skillMD
        )
    }

    /// Miroir Codable strict du `meta.json` de la 7b (clés snake_case).
    /// La date reste String ici : parsée à part pour tolérer les deux
    /// variantes ISO-8601 (avec/sans fractions de seconde).
    private struct Meta: Codable {
        let slug: String
        let title: String
        let description: String
        let rationale: String?
        let sourceSession: String?
        let project: String?
        let createdAt: String
        let status: String

        enum CodingKeys: String, CodingKey {
            case slug, title, description, rationale, project, status
            case sourceSession = "source_session"
            case createdAt = "created_at"
        }
    }

    private static func parseISO8601(_ raw: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: raw) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw)
    }
}
