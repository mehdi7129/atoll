import Foundation

/// Une ligne de transcript JSONL réduite à sa substance indexable.
///
/// Modèle NEUTRE : aucun couplage au format interne de Claude Code (instable).
/// `TranscriptLineParser` produit ce type ; `MemoryIndex` le consomme. Une ligne
/// sans valeur mémorielle (bruit technique, type inconnu) donne `fragments` vide
/// ou carrément `nil` côté parseur — jamais une erreur.
public struct TranscriptLine: Equatable, Sendable {
    /// Rôle d'un fragment de texte, conservé dans l'index pour filtrage/affichage.
    public enum Role: String, Equatable, Sendable {
        case user
        case assistant
        /// Raisonnement du modèle — les « pourquoi » des décisions y vivent.
        case thinking
        /// Invocation d'outil condensée (« nom · valeurs »).
        case tool
        /// Résultat d'outil (erreurs, sorties utiles), tronqué.
        case toolResult = "tool_result"
        /// Résumé de compaction : texte déjà distillé, très précieux pour recall.
        case summary
        /// Titre de session (ai-title) — alimente sessions.title.
        case title
        /// Note d'apprentissage écrite par Atoll (Phase 7b) — donnée, pas instruction.
        case note
    }

    /// Un morceau de texte indexable extrait de la ligne.
    public struct Fragment: Equatable, Sendable {
        public let role: Role
        public let text: String

        public init(role: Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    /// uuid de la ligne si présent ; sinon le parseur laisse nil et l'ingestion
    /// fabrique un identifiant stable dérivé de l'offset (dédup idempotente).
    public let uuid: String?
    /// `sessionId` ?? `session_id` (les deux graphies coexistent dans le format).
    public let sessionID: String?
    /// Horodatage ISO-8601 (avec ou sans fractions) ; nil si illisible.
    public let timestamp: Date?
    /// cwd réel de la session, quand la ligne le porte.
    public let cwd: String?
    public let gitBranch: String?
    /// Fragments indexables ; vide = ligne connue mais sans substance.
    public let fragments: [Fragment]

    public init(uuid: String?, sessionID: String?, timestamp: Date?,
                cwd: String?, gitBranch: String?, fragments: [Fragment]) {
        self.uuid = uuid
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.fragments = fragments
    }
}
