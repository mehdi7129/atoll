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
        /// Pour un `.toolResult` : le champ `is_error` du transcript, quand il
        /// est présent. C'est l'AUTORITÉ pour savoir si un outil a échoué —
        /// bien plus fiable que de chercher « error » dans la sortie, qui
        /// classe en échec la lecture réussie d'un fichier contenant ce mot
        /// (mesuré : 5× trop de faux positifs). nil = information absente.
        public let isError: Bool?
        /// Identifiant d'invocation d'outil : `id` pour un `.tool`,
        /// `tool_use_id` pour le `.toolResult` correspondant.
        ///
        /// C'est LUI qui relie une commande à son résultat. Sans lui, le
        /// condensé appariait par POSITION : dès qu'un message assistant émet
        /// deux outils en parallèle — courant dans Claude Code —, les
        /// invocations 2..N héritaient du verdict de la première, et avec
        /// quatre outils la première était purement écartée. Le condensé
        /// affirme pourtant au modèle que tout `tool` présent a RÉUSSI
        /// (audit du 2026-07-27). nil = information absente du transcript.
        public let toolUseID: String?

        public init(role: Role, text: String, isError: Bool? = nil, toolUseID: String? = nil) {
            self.role = role
            self.text = text
            self.isError = isError
            self.toolUseID = toolUseID
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
