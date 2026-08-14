import XCTest
@testable import AtollCore

/// Dédup + reclassement du recall (Milestone B) — logique PURE, testée sans
/// aucune base : les Hit sont construits à la main.
final class MemoryRankingTests: XCTestCase {

    // MARK: - Fixtures

    private func hit(_ key: String,
                     rank: Double,
                     timestamp: Date? = nil,
                     session: String = "s") -> MemoryIndex.Hit {
        MemoryIndex.Hit(sessionID: session, projectPath: nil, projectDir: "dir",
                        title: nil, role: "user", timestamp: timestamp,
                        snippet: "extrait \(key)", rank: rank, dedupKey: key)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    // MARK: - Dédup

    func testDeduplicatedKeepsFirstOccurrence() {
        // L'entrée est triée par pertinence : le premier d'un groupe est le
        // meilleur, c'est LUI qui doit survivre.
        let hits = [hit("a", rank: -9, session: "meilleur"),
                    hit("b", rank: -5),
                    hit("a", rank: -1, session: "copie")]
        let deduped = MemoryRanking.deduplicated(hits)
        XCTAssertEqual(deduped.map(\.dedupKey), ["a", "b"])
        XCTAssertEqual(deduped.first?.sessionID, "meilleur")
    }

    func testDeduplicatedNeverMergesEmptyKeys() {
        // Clé vide = Hit construit hors SQL : aucune identité, donc aucune
        // fusion (sinon deux souvenirs distincts n'en feraient qu'un).
        let hits = [hit("", rank: -3), hit("", rank: -2), hit("k", rank: -1)]
        XCTAssertEqual(MemoryRanking.deduplicated(hits).count, 3)
    }

    func testDeduplicatedPreservesOrderAndHandlesEmptyInput() {
        XCTAssertTrue(MemoryRanking.deduplicated([]).isEmpty)
        let hits = [hit("x", rank: -4), hit("y", rank: -3), hit("z", rank: -2)]
        XCTAssertEqual(MemoryRanking.deduplicated(hits).map(\.dedupKey), ["x", "y", "z"])
    }

    // MARK: - Plancher de pertinence

    func testRelevanceFloorDropsWeakHits() {
        // Meilleur = -10 ; le seuil à 0.5 garde tout ce qui est ≤ -5.
        let hits = [hit("fort", rank: -10), hit("moyen", rank: -6), hit("faible", rank: -1)]
        XCTAssertEqual(MemoryRanking.aboveRelevanceFloor(hits).map(\.dedupKey),
                       ["fort", "moyen"])
    }

    func testRelevanceFloorAlwaysKeepsBest() {
        // Un seul hit, ou des hits tous faibles : on ne rend jamais [].
        XCTAssertEqual(MemoryRanking.aboveRelevanceFloor([hit("seul", rank: -0.2)]).count, 1)
        XCTAssertEqual(MemoryRanking.aboveRelevanceFloor(
            [hit("a", rank: -0.4), hit("b", rank: -0.39)]).count, 2)
        XCTAssertTrue(MemoryRanking.aboveRelevanceFloor([]).isEmpty)
    }

    func testRelevanceFloorIsInertOnDegenerateRanks() {
        // Rangs nuls ou positifs (jamais vu en pratique, mais bm25 est libre) :
        // le filtre ne doit rien couper au hasard.
        let hits = [hit("a", rank: 0), hit("b", rank: 3)]
        XCTAssertEqual(MemoryRanking.aboveRelevanceFloor(hits).count, 2)
    }

    func testRelevanceFloorClampsRatio() {
        let hits = [hit("fort", rank: -10), hit("faible", rank: -1)]
        // ratio 0 → seuil 0 : tout ce qui est ≤ 0 passe (aucun filtrage).
        XCTAssertEqual(MemoryRanking.aboveRelevanceFloor(hits, ratio: -5).count, 2)
        // ratio 1 → seuil = meilleur rang : seul le meilleur survit.
        XCTAssertEqual(MemoryRanking.aboveRelevanceFloor(hits, ratio: 9).map(\.dedupKey),
                       ["fort"])
    }

    // MARK: - Reclassement

    func testRerankedPrefersRecentAtEqualRelevance() {
        // Pertinence identique → la récence tranche seule.
        let hits = [hit("vieux", rank: -5, timestamp: daysAgo(300)),
                    hit("frais", rank: -5, timestamp: daysAgo(1))]
        XCTAssertEqual(MemoryRanking.reranked(hits, now: now).map(\.dedupKey),
                       ["frais", "vieux"])
    }

    func testRerankedKeepsClearlyBetterRelevanceAhead() {
        // Écart de pertinence net : la récence ne doit PAS renverser le
        // classement (poids 0.25 — la pertinence commande).
        let hits = [hit("pertinent", rank: -20, timestamp: daysAgo(300)),
                    hit("faible", rank: -1, timestamp: daysAgo(0))]
        XCTAssertEqual(MemoryRanking.reranked(hits, now: now).first?.dedupKey, "pertinent")
    }

    func testRerankedFullRecencyWeightIgnoresRelevance() {
        // Poids 1 = récence pure : le meilleur bm25 passe derrière s'il est
        // plus vieux (garde-fou : le paramètre agit vraiment).
        let hits = [hit("pertinent", rank: -20, timestamp: daysAgo(300)),
                    hit("faible", rank: -1, timestamp: daysAgo(1))]
        XCTAssertEqual(
            MemoryRanking.reranked(hits, now: now, recencyWeight: 1).first?.dedupKey,
            "faible"
        )
    }

    func testRerankedTreatsMissingTimestampAsOldButKeepsIt() {
        let hits = [hit("sansDate", rank: -5, timestamp: nil),
                    hit("daté", rank: -5, timestamp: daysAgo(2))]
        let ranked = MemoryRanking.reranked(hits, now: now)
        XCTAssertEqual(ranked.map(\.dedupKey), ["daté", "sansDate"])
        XCTAssertEqual(ranked.count, 2) // jamais éliminé
    }

    func testRerankedSaturatesBeyondOneYear() {
        // Deux souvenirs très anciens : la pénalité sature, l'ordre bm25
        // reprend la main (stabilité du tri).
        let hits = [hit("a", rank: -6, timestamp: daysAgo(400)),
                    hit("b", rank: -5, timestamp: daysAgo(4000))]
        XCTAssertEqual(MemoryRanking.reranked(hits, now: now).map(\.dedupKey), ["a", "b"])
    }

    func testRerankedIgnoresFutureTimestamps() {
        // Horloge faussée / transcript bricolé : un âge négatif est ramené à
        // 0 — le hit ne gagne rien de plus qu'un souvenir d'aujourd'hui, et
        // à pertinence égale l'ordre d'entrée est conservé (tri stable).
        let hits = [hit("aujourdhui", rank: -5, timestamp: now),
                    hit("futur", rank: -5, timestamp: now.addingTimeInterval(90 * 86_400))]
        XCTAssertEqual(MemoryRanking.reranked(hits, now: now).map(\.dedupKey),
                       ["aujourdhui", "futur"])
    }

    func testRerankedIsStableAndTotalOrder() {
        // Tous identiques : l'ordre d'entrée survit intégralement.
        let hits = (0..<5).map { hit("k\($0)", rank: -3, timestamp: daysAgo(10)) }
        XCTAssertEqual(MemoryRanking.reranked(hits, now: now).map(\.dedupKey),
                       hits.map(\.dedupKey))
    }

    func testRerankedHandlesTrivialInputs() {
        XCTAssertTrue(MemoryRanking.reranked([], now: now).isEmpty)
        let single = [hit("seul", rank: -2, timestamp: nil)]
        XCTAssertEqual(MemoryRanking.reranked(single, now: now).map(\.dedupKey), ["seul"])
    }

    func testRerankedClampsWeightOutOfRange() {
        // Un poids aberrant (réglage corrompu) ne doit ni inverser le sens ni
        // faire diverger le score : il est clampé sur [0, 1].
        let hits = [hit("vieux", rank: -5, timestamp: daysAgo(300)),
                    hit("frais", rank: -5, timestamp: daysAgo(1))]
        XCTAssertEqual(
            MemoryRanking.reranked(hits, now: now, recencyWeight: -3).map(\.dedupKey),
            ["vieux", "frais"] // poids 0 → ordre d'entrée (pertinence pure)
        )
        XCTAssertEqual(
            MemoryRanking.reranked(hits, now: now, recencyWeight: 42).map(\.dedupKey),
            ["frais", "vieux"] // poids 1 → récence pure
        )
    }

    // MARK: - Couverture : ce que FTS5 a VRAIMENT apparié (2026-08-14)

    private func hit(snippet: String) -> MemoryIndex.Hit {
        MemoryIndex.Hit(sessionID: "s", projectPath: nil, projectDir: "d", title: nil,
                        role: "assistant", timestamp: nil, snippet: snippet, rank: -1)
    }

    /// Seuls les segments encadrés par FTS5 comptent.
    ///
    /// Le défaut : un `contains` sur le snippet entier faisait compter un terme
    /// présent dans le CONTEXTE, sans qu'il ait apparié. Or c'est ce chiffre qui
    /// doit trancher l'utilité de la mémoire proactive.
    func testCouvertureNeCompteQueLesSegmentsMarquesParFTS5() {
        let h = hit(snippet: "… «recall» \"notch geometrie\" dans l'«index» …")
        XCTAssertEqual(MemoryRanking.coverage(of: h, terms: ["recall", "index"]), 2)
        // « notch » et « geometrie » sont dans le snippet mais N'ONT PAS apparié.
        XCTAssertEqual(MemoryRanking.coverage(of: h, terms: ["notch"]), 0)
        XCTAssertEqual(MemoryRanking.coverage(of: h, terms: ["recall", "notch", "geometrie"]), 1)
    }

    /// Le cas qui gonflait le plus : la sous-chaîne. FTS5 tokenise — il apparie
    /// « recalled » comme un mot entier, jamais comme contenant « recall ».
    func testUneSousChaineDansLeContexteNeComptePas() {
        let h = hit(snippet: "il a «reconstruit» le cache, puis recalled les sessions")
        XCTAssertEqual(MemoryRanking.coverage(of: h, terms: ["recall"]), 0,
                       "« recalled » dans le contexte n'apparie pas « recall »")
        XCTAssertEqual(MemoryRanking.coverage(of: h, terms: ["reconstruit"]), 1)
    }

    /// Insensible à la casse et aux diacritiques, comme l'index.
    func testCouvertureIgnoreCasseEtAccents() {
        let h = hit(snippet: "dans l'«Mémoire» du projet")
        XCTAssertEqual(MemoryRanking.coverage(of: h, terms: ["memoire"]), 1)
    }

    /// Un snippet sans aucun marqueur ne peut rien couvrir — et ne plante pas.
    func testSnippetSansMarqueurCouvreZero() {
        XCTAssertEqual(MemoryRanking.coverage(of: hit(snippet: "aucun marqueur ici"),
                                              terms: ["marqueur"]), 0)
        // Marqueur ouvrant sans fermant (snippet tronqué à 14 tokens) : ignoré.
        XCTAssertEqual(MemoryRanking.coverage(of: hit(snippet: "coupé au «mil"),
                                              terms: ["mil"]), 0)
    }

    /// Le tri par couverture suit la nouvelle mesure.
    func testByCoverageClasseSurLesSegmentsMarques() {
        let faible = hit(snippet: "«un» seul terme, mais deux autres en clair : index recall")
        let fort = hit(snippet: "«index» et «recall» tous deux appariés")
        let classés = MemoryRanking.byCoverage([faible, fort], terms: ["index", "recall"])
        XCTAssertEqual(classés.first?.snippet, fort.snippet,
                       "celui qui a VRAIMENT apparié deux termes passe devant")
    }
}
