import Foundation

/// Qualité du recall (Milestone B) : dédoublonnage INTER-FICHIERS puis
/// reclassement pertinence + récence des résultats de `MemoryIndex.search`.
///
/// Pourquoi c'est nécessaire, mesuré sur la vraie base (2026-07-26, 28 019
/// messages / 82 fichiers) : **1 155 uuid de messages apparaissent dans au
/// moins deux fichiers JSONL**. C'est le comportement normal de Claude Code —
/// `--resume`, un fork ou une compaction recopient l'historique dans un
/// nouveau transcript en CONSERVANT l'uuid d'origine de chaque message. La
/// dédup d'ingestion (`(file_id, uuid, block_idx)`) ne les voit donc pas :
/// sans ce module, une recherche sur une session reprise remonte deux ou trois
/// fois le même extrait et gaspille les places du top N.
///
/// Deux étapes PURES (aucun SQLite ici — testable sans base) :
/// 1. `deduplicated` : un seul hit par `dedupKey`, celui de meilleur rang
///    (l'ordre d'entrée est supposé trié par pertinence, ce que garantit le
///    `ORDER BY bm25` du SQL) ;
/// 2. `reranked` : mélange pertinence et récence sur des scores NORMALISÉS
///    dans le pool — l'échelle brute de bm25 dépend de la requête et du
///    corpus, la normaliser rend le mélange stable d'une recherche à l'autre.
public enum MemoryRanking {

    /// Poids de la récence dans le score final (0 = pertinence pure, 1 =
    /// récence pure). 0.25 : la pertinence commande, la récence départage —
    /// un souvenir d'hier passe devant un souvenir d'il y a un an à
    /// pertinence comparable, jamais devant un résultat nettement meilleur.
    public static let defaultRecencyWeight = 0.25

    /// Au-delà de cet âge, tous les souvenirs sont « vieux » à égalité : la
    /// pénalité sature (sinon un souvenir de 2019 serait infiniment pénalisé
    /// par rapport à un de 2024, alors que les deux sont hors mémoire vive).
    public static let recencyCapDays = 365.0

    /// Un seul hit par `dedupKey`, le premier rencontré. L'appelant passe une
    /// liste DÉJÀ triée par pertinence : le premier d'un groupe est donc le
    /// meilleur. Un `dedupKey` vide (Hit construit à la main, hors SQL) est
    /// considéré comme unique — ne jamais fusionner sur une clé absente.
    public static func deduplicated(_ hits: [MemoryIndex.Hit]) -> [MemoryIndex.Hit] {
        var seen = Set<String>()
        var kept: [MemoryIndex.Hit] = []
        kept.reserveCapacity(hits.count)
        for hit in hits {
            if hit.dedupKey.isEmpty {
                kept.append(hit)
                continue
            }
            guard seen.insert(hit.dedupKey).inserted else { continue }
            kept.append(hit)
        }
        return kept
    }

    /// Ne garde que les hits dont la pertinence n'est pas ridicule face au
    /// meilleur du lot : `rank <= meilleurRank × ratio` (bm25 est négatif,
    /// donc « au moins `ratio` fois aussi pertinent que le meilleur »).
    ///
    /// Sert au recall PROACTIF, où l'on injecte sans qu'on l'ait demandé : si
    /// un seul souvenir répond vraiment à la question, en ajouter deux qui ne
    /// partagent qu'un mot commun ne fait que diluer le contexte. Le recall
    /// EXPLICITE (`atoll-bridge recall`) ne s'en sert pas : quand on cherche,
    /// on préfère voir les résultats faibles que rien du tout.
    ///
    /// Le meilleur hit survit toujours (le lot n'est jamais vidé), et un lot
    /// de rangs nuls ou positifs (base dégénérée) passe tel quel.
    /// Ratio par défaut CALIBRÉ SUR DU bm25 RÉEL en mode `.any` (revue) :
    /// l'amplitude y est pilotée par le NOMBRE de termes appariés, si bien
    /// qu'un seuil à 0,5 ne laissait passer qu'un seul extrait et rendait le
    /// réglage « souvenirs injectés » inerte. 0,3 ≈ « couvre au moins un tiers
    /// de ce que couvre le meilleur ».
    public static let defaultRelevanceRatio = 0.3

    public static func aboveRelevanceFloor(
        _ hits: [MemoryIndex.Hit],
        ratio: Double = defaultRelevanceRatio
    ) -> [MemoryIndex.Hit] {
        guard let best = hits.map(\.rank).min(), best < 0 else { return hits }
        let floor = best * min(max(ratio, 0), 1)
        return hits.filter { $0.rank <= floor }
    }

    /// Reclasse par score combiné croissant (plus petit = meilleur).
    ///
    /// - pertinence normalisée : `(rank − min) / (max − min)` sur le POOL reçu
    ///   → 0 pour le meilleur bm25, 1 pour le pire ; pool homogène (tous les
    ///   rangs égaux) → 0 pour tout le monde, la récence tranche seule ;
    /// - récence : `min(âge, 365 j) / 365 j` → 0 pour aujourd'hui, 1 au-delà
    ///   d'un an ; timestamp absent → 1 (traité comme ancien, jamais éliminé) ;
    ///   un horodatage DANS LE FUTUR (horloge machine faussée, transcript
    ///   bricolé) est ramené à 0, jamais négatif — sinon il gagnerait toujours.
    ///
    /// Tri STABLE : à score égal, l'ordre d'entrée (donc bm25) est conservé —
    /// deux recherches identiques rendent exactement le même classement.
    public static func reranked(
        _ hits: [MemoryIndex.Hit],
        now: Date,
        recencyWeight: Double = defaultRecencyWeight
    ) -> [MemoryIndex.Hit] {
        guard hits.count > 1 else { return hits }
        let weight = min(max(recencyWeight, 0), 1)

        let ranks = hits.map(\.rank)
        let minRank = ranks.min() ?? 0
        let maxRank = ranks.max() ?? 0
        let span = maxRank - minRank

        let scored = hits.enumerated().map { index, hit -> (index: Int, score: Double) in
            let relevance = span > 0 ? (hit.rank - minRank) / span : 0
            let ageDays = hit.timestamp
                .map { max(now.timeIntervalSince($0), 0) / 86_400 }
                .map { min($0, recencyCapDays) / recencyCapDays } ?? 1
            return (index, (1 - weight) * relevance + weight * ageDays)
        }

        // `sorted` n'est pas stable en Swift : on départage explicitement par
        // l'index d'entrée pour un classement reproductible.
        return scored
            .sorted { ($0.score, $0.index) < ($1.score, $1.index) }
            .map { hits[$0.index] }
    }
}
