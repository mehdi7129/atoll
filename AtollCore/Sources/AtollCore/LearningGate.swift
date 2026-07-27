import Foundation

/// Décision PURE : faut-il lancer une rétrospective pour cette session ?
///
/// Contexte (Phase 7b) : à la fin d'une session Claude Code substantielle, Atoll
/// lance `claude -p` STRICTEMENT read-only qui analyse le transcript et rend un
/// JSON (notes mémoire, propositions de skills) ; Atoll écrit lui-même les
/// fichiers. Une rétrospective consomme du quota → cette porte décide, à partir
/// de faits fournis par l'appelant, si le jeu en vaut la chandelle.
///
/// Invariants :
/// - **Fail-safe absolu** : tout fait manquant ou invalide ⇒ `.skip`, jamais
///   `.run`. Dans le doute, on ne dépense rien.
/// - **Ordre d'évaluation STRICT** : la première raison qui matche gagne, dans
///   l'ordre déclaré ci-dessous — les logs de skip restent lisibles et stables.
/// - **Pureté totale** : aucune horloge, aucun disque — `now` et tous les faits
///   arrivent en paramètres, la décision est rejouable à l'identique en test.
public enum LearningGate {

    /// Fenêtre glissante du plafond de runs — alignée sur la fenêtre 5 h du
    /// quota Anthropic (voir `QuotaSnapshot`).
    private static let runWindowSeconds: TimeInterval = 5 * 3_600

    /// Faits observés sur la session candidate. `userPromptCount` nil = session
    /// synthétique découverte par scan, sans hooks → le critère est ignoré
    /// (on ne peut pas compter ce qu'on n'a jamais reçu).
    public struct SessionFacts: Equatable, Sendable {
        public let sessionID: String
        public let durationSeconds: TimeInterval
        /// Taille du transcript JSONL sur disque ; nil = introuvable/illisible.
        public let transcriptSizeBytes: Int?
        /// Nombre de UserPromptSubmit reçus ; nil = session synthétique.
        public let userPromptCount: Int?
        /// true = le process claude vit encore (la session peut reprendre).
        public let isCurrentlyAlive: Bool

        public init(
            sessionID: String,
            durationSeconds: TimeInterval,
            transcriptSizeBytes: Int?,
            userPromptCount: Int?,
            isCurrentlyAlive: Bool
        ) {
            self.sessionID = sessionID
            self.durationSeconds = durationSeconds
            self.transcriptSizeBytes = transcriptSizeBytes
            self.userPromptCount = userPromptCount
            self.isCurrentlyAlive = isCurrentlyAlive
        }
    }

    /// Dernier quota 5 h connu (via statusline). Tout champ nil = donnée absente ;
    /// une donnée absente ou périmée interdit le run (fail-safe : on ne lance pas
    /// une dépense de quota à l'aveugle).
    public struct QuotaFacts: Equatable, Sendable {
        /// Fraction utilisée 0…1 de la fenêtre 5 h.
        public let usedFraction: Double?
        /// Instant où cette valeur a été reçue (fraîcheur).
        public let receivedAt: Date?
        /// Réinitialisation annoncée ; passée ⇒ la valeur ne veut plus rien dire
        /// (même piège que `StatusLinePayload` : cache d'avant le reset).
        public let resetsAt: Date?

        public init(usedFraction: Double?, receivedAt: Date?, resetsAt: Date?) {
            self.usedFraction = usedFraction
            self.receivedAt = receivedAt
            self.resetsAt = resetsAt
        }
    }

    /// Réglages de la porte. `enabled` est false par défaut : la rétrospective
    /// est STRICTEMENT opt-in (elle consomme du quota utilisateur).
    public struct Config: Equatable, Sendable {
        public let enabled: Bool
        /// Au-delà de cette fraction de quota 5 h utilisée (inclus), on s'abstient.
        public let quotaThreshold: Double
        /// Nombre maximal de runs dans une fenêtre glissante de 5 h.
        public let maxPerWindow: Int
        /// Durée minimale d'une session « substantielle ».
        public let minDurationSeconds: TimeInterval
        /// Taille minimale du transcript — en dessous, rien à apprendre.
        public let minTranscriptBytes: Int
        /// Nombre minimal de prompts utilisateur (ignoré si inconnu).
        public let minUserPrompts: Int
        /// Âge maximal du quota pour qu'il soit jugé fiable.
        public let quotaFreshnessSeconds: TimeInterval
        /// Croissance du transcript (octets) qui justifie de RE-traiter une
        /// session déjà passée à la rétrospective.
        public let reprocessGrowthBytes: Int
        /// Nombre de runs autorisés par fenêtre de 5 h QUAND LE QUOTA EST
        /// INCONNU ou périmé (voir `decide`, étape 6). 0 rétablit l'ancien
        /// comportement (refus sec), 1 = le défaut : on accepte d'apprendre à
        /// l'aveugle une fois par fenêtre plutôt que jamais.
        public let unknownQuotaMaxPerWindow: Int

        public init(
            enabled: Bool = false,
            quotaThreshold: Double = 0.70,
            maxPerWindow: Int = 2,
            minDurationSeconds: TimeInterval = 600,
            minTranscriptBytes: Int = 100_000,
            minUserPrompts: Int = 3,
            quotaFreshnessSeconds: TimeInterval = 600,
            reprocessGrowthBytes: Int = 50_000,
            unknownQuotaMaxPerWindow: Int = 1
        ) {
            self.enabled = enabled
            self.quotaThreshold = quotaThreshold
            self.maxPerWindow = maxPerWindow
            self.minDurationSeconds = minDurationSeconds
            self.minTranscriptBytes = minTranscriptBytes
            self.minUserPrompts = minUserPrompts
            self.quotaFreshnessSeconds = quotaFreshnessSeconds
            self.reprocessGrowthBytes = reprocessGrowthBytes
            self.unknownQuotaMaxPerWindow = unknownQuotaMaxPerWindow
        }
    }

    /// Historique persisté par l'appelant : sessions déjà traitées et instants
    /// des runs passés (pour le plafond par fenêtre).
    public struct History: Equatable, Sendable {
        /// Trace d'une rétrospective aboutie — `transcriptBytes` est la taille
        /// du transcript AU MOMENT du traitement, base du critère de croissance.
        public struct Processed: Equatable, Sendable, Codable {
            public let sessionID: String
            public let transcriptBytes: Int
            public let completedAt: Date

            public init(sessionID: String, transcriptBytes: Int, completedAt: Date) {
                self.sessionID = sessionID
                self.transcriptBytes = transcriptBytes
                self.completedAt = completedAt
            }
        }

        public let processed: [Processed]
        public let runTimestamps: [Date]

        public init(processed: [Processed] = [], runTimestamps: [Date] = []) {
            self.processed = processed
            self.runTimestamps = runTimestamps
        }
    }

    public enum Decision: Equatable, Sendable {
        case run
        case skip(Reason)
    }

    /// Raisons de skip, déclarées DANS l'ordre d'évaluation. La rawValue sert
    /// telle quelle dans les logs.
    public enum Reason: String, Equatable, Sendable {
        case disabled
        case sessionResumed
        case sessionTooShort
        case transcriptMissing
        case transcriptTooSmall
        case tooFewUserPrompts
        case alreadyProcessed
        case quotaMissing
        case quotaStale
        case quotaAboveThreshold
        case windowCapReached
    }

    /// Décide si une rétrospective doit être lancée. Première raison qui matche
    /// dans l'ordre STRICT de `Reason` ; `.run` seulement si TOUT est vérifié.
    public static func decide(
        session: SessionFacts,
        quota: QuotaFacts,
        config: Config,
        history: History,
        now: Date
    ) -> Decision {
        // 1. Opt-in explicite — désactivé par défaut.
        guard config.enabled else { return .skip(.disabled) }

        // 2. Session encore vivante : elle peut reprendre, le transcript bouge.
        if session.isCurrentlyAlive { return .skip(.sessionResumed) }

        // 3. Substance minimale : durée, transcript présent et assez gros,
        //    assez de prompts (critère ignoré pour les sessions synthétiques).
        if session.durationSeconds < config.minDurationSeconds {
            return .skip(.sessionTooShort)
        }
        guard let transcriptBytes = session.transcriptSizeBytes else {
            return .skip(.transcriptMissing)
        }
        if transcriptBytes < config.minTranscriptBytes {
            return .skip(.transcriptTooSmall)
        }
        if let prompts = session.userPromptCount, prompts < config.minUserPrompts {
            return .skip(.tooFewUserPrompts)
        }

        // 4. Déjà traitée — SAUF si le transcript a grossi d'au moins
        //    reprocessGrowthBytes depuis le DERNIER passage (completedAt max).
        if let lastRun = history.processed
            .filter({ $0.sessionID == session.sessionID })
            .max(by: { $0.completedAt < $1.completedAt }),
            transcriptBytes < lastRun.transcriptBytes + config.reprocessGrowthBytes {
            return .skip(.alreadyProcessed)
        }

        // 5. Plafond de runs dans la fenêtre glissante de 5 h. Un timestamp
        //    futur (horloge remontée) compte comme récent — fail-safe.
        //    ÉVALUÉ AVANT LE QUOTA (v0.12.0) : c'est lui qui borne réellement la
        //    dépense, et le mode « quota inconnu » ci-dessous s'appuie dessus.
        let recentRuns = history.runTimestamps
            .filter { now.timeIntervalSince($0) < runWindowSeconds }
        if recentRuns.count >= config.maxPerWindow {
            return .skip(.windowCapReached)
        }

        // 6. Quota : présent (une fraction non finie = donnée corrompue, donc
        //    absente), frais, fenêtre non expirée, sous le seuil (seuil atteint
        //    exactement ⇒ skip).
        //
        // QUOTA INCONNU OU PÉRIMÉ (v0.12.0) : ce n'était plus un garde-fou, mais
        // LA cause du silence. Le quota n'arrive que par la statusline, donc
        // uniquement d'une session à TUI, et il ne vivait qu'en mémoire : après
        // chaque redémarrage d'Atoll — et pour toute session `claude --bg` —
        // toutes les fins de session partaient en `quotaMissing`. Mesuré : 1
        // seule rétrospective lancée en 7 jours, sur ~29 sessions.
        //
        // Compromis retenu : sans quota fiable, on autorise QUAND MÊME, mais au
        // plus `unknownQuotaMaxPerWindow` fois par fenêtre de 5 h (défaut 1).
        // La dépense reste bornée par ce plafond ET par `--max-budget-usd`.
        guard let usedFraction = quota.usedFraction, usedFraction.isFinite,
              let receivedAt = quota.receivedAt else {
            return recentRuns.count < config.unknownQuotaMaxPerWindow
                ? .run : .skip(.quotaMissing)
        }
        let windowExpired = quota.resetsAt.map { $0 < now } ?? false
        let isStale = now.timeIntervalSince(receivedAt) > config.quotaFreshnessSeconds
            || windowExpired
        if isStale {
            // Lecture vieille mais fenêtre 5 h EXPLICITEMENT toujours en cours
            // (`resets_at` connu et futur) : la fraction ne peut qu'avoir
            // AUGMENTÉ depuis, elle reste donc un minorant valable — si elle
            // dépasse déjà le seuil, c'est un vrai refus, pas une incertitude.
            // Sans `resets_at`, on ne sait même pas si c'est la même fenêtre :
            // on retombe sur la règle « inconnu ».
            // La fenêtre 5 h EST la borne : une lecture plus jeune que cela
            // décrit forcément la fenêtre en cours (ou une plus ancienne, donc
            // un usage encore plus élevé). Dans les deux cas la fraction est un
            // MINORANT — un `resets_at` connu et futur le confirme, mais son
            // absence n'y change rien (revue : sans cette branche, une lecture
            // à 99 % vieille de 2 h autorisait un run).
            let readingIsWithinWindow = quota.resetsAt.map { $0 > now }
                ?? (now.timeIntervalSince(receivedAt) < runWindowSeconds)
            if readingIsWithinWindow, usedFraction >= config.quotaThreshold {
                return .skip(.quotaAboveThreshold)
            }
            return recentRuns.count < config.unknownQuotaMaxPerWindow
                ? .run : .skip(.quotaStale)
        }
        if usedFraction >= config.quotaThreshold {
            return .skip(.quotaAboveThreshold)
        }

        return .run
    }
}
