import Foundation

/// Décision pure : conserver l'exécuteur choisi ou basculer une dépense Atoll
/// vers l'autre abonnement sur une preuve fraîche d'épuisement.
///
/// Bilan, rangement des notes et recherche IA de plugins partagent ce choix.
/// Le gate décide ensuite si le job peut consommer le quota sélectionné.
///
/// ⚠️ CE QU'ELLE NE DÉCIDE PAS : elle ne remplace pas `LearningGate`. Elle
/// choisit le fournisseur ; le gate décide ensuite si la dépense vaut la peine,
/// alimenté par le quota DE CE FOURNISSEUR (`quotaFacts(of:)`). Les deux portes
/// sont franchies dans cet ordre, jamais l'inverse : choisir d'abord évite
/// d'évaluer un plafond de fenêtre sur un compte qu'on ne va pas débiter.
///
/// Invariants, dans l'esprit de `LearningGate` :
/// - **Fail-safe par défaut** : dans le doute, on garde le moteur choisi. Basculer
///   n'est jamais gratuit — c'est débiter un SECOND abonnement.
/// - **Une donnée absente n'est pas un quota épuisé.** C'est la règle la plus
///   contre-intuitive du fichier, et la plus importante : un quota Claude
///   INCONNU ne déclenche PAS la bascule. Sans mesure fraîche, « épuisé » est
///   une supposition, et une supposition ne doit pas dépenser l'autre compte.
///   Le pendant existe déjà côté quota Codex, où `CodexAccountClient` refuse de
///   rendre un faux 0 % sur erreur.
/// - **Un `resetsAt` passé rend la valeur muette**, des deux côtés — même piège
///   que `StatusLinePayload` (un cache d'avant la réinitialisation).
/// - **Pureté totale** : aucune horloge, aucun disque, aucun réseau. `now` et
///   tous les faits arrivent en paramètres.
public enum ProviderFailover {

    /// Réglages de la bascule. `enabled` est false par défaut : dépenser un
    /// second abonnement est un choix explicite de l'utilisateur.
    public struct Config: Equatable, Sendable {
        public let enabled: Bool
        /// Fraction du quota Claude au-delà de laquelle (INCLUS) on le tient
        /// pour épuisé. Volontairement distincte du seuil de `LearningGate` :
        /// celui-ci dit « pas assez de marge pour se permettre ça », celui-là
        /// dit « il n'y a plus rien ». Basculer au premier ferait payer Codex
        /// alors que Claude peut encore servir l'utilisateur.
        public let claudeExhaustedAt: Double
        /// Même seuil côté Codex : au-delà, il ne sert à rien de basculer.
        public let codexExhaustedAt: Double
        /// Âge maximal d'une mesure pour être jugée fiable, des deux côtés.
        public let freshnessSeconds: TimeInterval
        public let preferred: AgentProvider

        public init(
            enabled: Bool = false,
            claudeExhaustedAt: Double = 0.95,
            codexExhaustedAt: Double = 0.95,
            freshnessSeconds: TimeInterval = 600,
            preferred: AgentProvider = .claude
        ) {
            self.enabled = enabled
            self.claudeExhaustedAt = claudeExhaustedAt
            self.codexExhaustedAt = codexExhaustedAt
            self.freshnessSeconds = freshnessSeconds
            self.preferred = preferred
        }
    }

    /// Pourquoi ce fournisseur — journalisé tel quel dans le journal
    /// d'apprentissage. Comme pour `LearningGate`, la RAISON compte autant que
    /// la décision : « rien ne s'est lancé » sans motif est indiagnosticable,
    /// c'est la leçon de la Phase 12.
    public enum Reason: String, Equatable, Sendable {
        /// La bascule est désactivée dans les réglages.
        case failoverDisabled
        /// Quota Claude frais et sous le seuil : rien à faire.
        case claudeAvailable
        /// Quota Claude absent ou périmé — on NE bascule PAS (voir invariants).
        case claudeUnknown
        /// Claude épuisé, Codex frais et disponible : on bascule.
        case claudeExhausted
        /// Claude épuisé, mais quota Codex absent, périmé ou illisible.
        case codexUnknown
        /// Les deux abonnements sont au-dessus de leur seuil.
        case bothExhausted
        case codexSelected, codexAvailable, codexExhausted
    }

    public struct Decision: Equatable, Sendable {
        /// Le fournisseur à débiter, ou `nil` si aucun ne peut l'être.
        public let provider: AgentProvider?
        public let reason: Reason

        public init(provider: AgentProvider?, reason: Reason) {
            self.provider = provider
            self.reason = reason
        }
    }

    /// ORDRE STRICT — la première règle qui matche gagne. Les cas sont écrits
    /// dans l'ordre de coût croissant pour l'utilisateur.
    public static func choose(
        claude: LearningGate.QuotaFacts,
        codex: CodexQuota?,
        config: Config,
        now: Date = Date()
    ) -> Decision {
        // 1. Bascule désactivée : comportement historique, à l'identique.
        guard config.enabled else {
            return Decision(provider: config.preferred,
                            reason: config.preferred == .codex ? .codexSelected : .failoverDisabled)
        }

        if config.preferred == .codex {
            guard let codex, codex.isFresh(at: now), let used = worstUsedFraction(codex, now: now) else {
                return Decision(provider: .codex, reason: .codexUnknown)
            }
            guard used >= config.codexExhaustedAt else { return Decision(provider: .codex, reason: .codexAvailable) }
            guard let other = usableFraction(claude, freshness: config.freshnessSeconds, now: now) else {
                return Decision(provider: nil, reason: .claudeUnknown)
            }
            return Decision(provider: other < config.claudeExhaustedAt ? .claude : nil,
                            reason: other < config.claudeExhaustedAt ? .codexExhausted : .bothExhausted)
        }

        // 2. Quota Claude inutilisable comme PREUVE d'épuisement. On reste sur
        //    Claude : c'est `LearningGate` qui décidera de dépenser ou non à
        //    l'aveugle (`unknownQuotaMaxPerWindow`), avec sa propre prudence.
        guard let claudeUsed = usableFraction(claude, freshness: config.freshnessSeconds, now: now) else {
            return Decision(provider: .claude, reason: .claudeUnknown)
        }

        // 3. Il reste du quota Claude : on n'ouvre pas le second abonnement.
        guard claudeUsed >= config.claudeExhaustedAt else {
            return Decision(provider: .claude, reason: .claudeAvailable)
        }

        // 4. Claude est à sec. Codex peut-il prendre le relais ?
        guard let codex, codex.isFresh(at: now),
              let codexUsed = worstUsedFraction(codex, now: now) else {
            return Decision(provider: nil, reason: .codexUnknown)
        }
        guard codexUsed < config.codexExhaustedAt else {
            return Decision(provider: nil, reason: .bothExhausted)
        }
        return Decision(provider: .codex, reason: .claudeExhausted)
    }

    /// Fraction Claude exploitable, ou `nil` si la mesure manque, a vieilli, ou
    /// décrit une fenêtre DÉJÀ réinitialisée.
    private static func usableFraction(
        _ facts: LearningGate.QuotaFacts, freshness: TimeInterval, now: Date
    ) -> Double? {
        guard let used = facts.usedFraction, used.isFinite,
              let receivedAt = facts.receivedAt,
              now >= receivedAt, now.timeIntervalSince(receivedAt) <= freshness
        else { return nil }
        // `resetsAt` passé : la fenêtre a tourné, la valeur ne décrit plus rien
        // (même raisonnement que le rejet d'un quota périmé côté statusline).
        if let resetsAt = facts.resetsAt, resetsAt <= now { return nil }
        return min(max(used, 0), 1)
    }

    /// La fenêtre Codex la PLUS contraignante parmi celles encore en cours.
    ///
    /// Une seule catégorie applicable, complète et fraîche. Une fenêtre basse
    /// restante après le reset d'une autre ne prouve jamais la disponibilité.
    public static func worstUsedFraction(_ quota: CodexQuota, now: Date = Date()) -> Double? {
        quotaFacts(of: quota, now: now).usable(at: now, freshness: 300)
    }

    /// Projette un quota Codex dans les faits que `LearningGate` sait lire, pour
    /// que le gate arbitre une dépense Codex avec EXACTEMENT ses règles (seuil,
    /// fraîcheur, plafond de fenêtre). Rien à dupliquer, rien à faire diverger.
    ///
    /// `resetsAt` : la fin de fenêtre la plus PROCHE parmi celles en cours —
    /// c'est elle qui rendra la mesure caduque en premier.
    public static func quotaFacts(of quota: CodexQuota?, now: Date = Date()) -> LearningGate.QuotaFacts {
        guard let quota, quota.receivedAt <= now else {
            return LearningGate.QuotaFacts(usedFraction: nil, receivedAt: quota?.receivedAt, resetsAt: nil,
                                          unknownReason: "quota Codex absent ou date invalide")
        }
        // model/list ne relie pas ses modèles aux limitId. Avec plusieurs
        // catégories, on ne sait pas laquelle paie CE job : ne pas les fusionner.
        guard quota.buckets.count == 1, let bucket = quota.buckets.first, bucket.id == "codex" else {
            return LearningGate.QuotaFacts(usedFraction: nil, receivedAt: quota.receivedAt, resetsAt: nil,
                                          unknownReason: "portée du quota non établie pour le modèle")
        }
        let current = bucket.windows.filter { $0.isCurrent(at: now) }
        let complete = quota.isFresh(at: now) && current.count == bucket.windows.count
        // Une mesure ancienne ou partielle n'établit pas la disponibilité,
        // mais une fenêtre haute dont le reset est encore futur reste un
        // minorant. Le conserver permet au budget de refuser sans failover.
        let candidates = complete ? current : current.filter { $0.resetsAt != nil }
        guard let limiting = candidates.max(by: { $0.usedFraction < $1.usedFraction }) else {
            return LearningGate.QuotaFacts(usedFraction: nil, receivedAt: quota.receivedAt, resetsAt: nil,
                                          unknownReason: "fenêtres réinitialisées ou reset inconnu")
        }
        let nextReset = complete ? current.compactMap(\.resetsAt).min() : limiting.resetsAt
        return LearningGate.QuotaFacts(
            usedFraction: limiting.usedFraction, receivedAt: quota.receivedAt, resetsAt: nextReset,
            bucket: bucket.id, window: limiting.id,
            unknownReason: complete ? nil : "quota Codex ancien ou partiel : minorant seulement"
        )
    }
}
