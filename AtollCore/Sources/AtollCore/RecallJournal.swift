import Foundation

/// Journal du recall PROACTIF — l'instrument qui doit permettre de décider si
/// cette fonction mérite d'exister.
///
/// POURQUOI. Mesuré le 2026-08-09 : le skill `atoll-recall` n'a **jamais** été
/// invoqué en 22 jours, pendant que le canal automatique injectait ~200 fois.
/// Le seul canal de mémoire vivant est donc celui dont personne ne sait s'il
/// sert. Aujourd'hui la question ne peut pas être tranchée : il faut relire
/// 831 Mo de transcripts à la main pour produire le moindre chiffre.
///
/// CE QU'ON ENREGISTRE, ET POURQUOI CE N'EST PAS QUE LES SUCCÈS. Un journal qui
/// ne compte que les injections rendrait un nombre ININTERPRÉTABLE : « 300
/// injections » ne dit pas si le silence des autres prompts vient d'un gate trop
/// strict, d'une base sans réponse ou d'un plancher de pertinence trop haut.
/// C'est la leçon du journal de la rétrospective (`AttemptRecord`), qui a
/// diagnostiqué la Phase 12 justement parce qu'il portait les REFUS : 39
/// `sessionTooShort`, 10 `tooFewUserPrompts`, 5 runs. On enregistre donc **un
/// passage sur deux issues** : injecté, ou refusé avec sa raison exacte.
///
/// CE QU'ON N'ENREGISTRE PAS. Ni le prompt, ni le contenu des souvenirs : ce
/// serait recopier la base à côté de la base, et grossir une trace que personne
/// ne relit. On garde des MÉTADONNÉES et les identifiants de lignes (`rows`),
/// qui suffisent à remonter au contenu depuis `memory.db` le jour de l'analyse.
/// Zéro télémétrie : le fichier ne quitte jamais la machine (règle n° 4).
public enum RecallJournal {

    /// Issue d'un passage du hook. Les valeurs brutes sont écrites telles quelles
    /// dans le fichier : elles doivent rester lisibles à l'œil nu.
    public enum Outcome: String, Codable, Equatable, CaseIterable, Sendable {
        /// Un bloc de souvenirs est parti vers le CLI.
        case injected
        // — Refus du gate, AVANT toute recherche (aucun coût) —
        /// Moins de 12 caractères.
        case promptTooShort
        /// Commande `/…` ou `!…` : l'utilisateur pilote, il ne demande rien.
        case promptIsCommand
        /// Le prompt EST une enveloppe machine (`<task-notification>`…).
        case promptIsMachineEnvelope
        /// Moins de 2 mots-clés significatifs.
        case tooFewKeywords
        // — Refus APRÈS recherche (la base a été interrogée) —
        /// Index absent, verrouillé, illisible.
        case indexUnavailable
        /// La recherche a échoué (SQL, base corrompue).
        case searchFailed
        /// La recherche n'a rien rendu du tout.
        case noHits
        /// Des résultats, mais aucun au-dessus du plancher de pertinence.
        case noneAboveFloor
        /// Des résultats retenus, mais le bloc rendu était vide (extraits
        /// entièrement caviardés ou blancs).
        case emptyBlock

        /// La recherche a-t-elle réellement eu lieu ? Sépare « le gate a dit
        /// non » (gratuit, et réglable) de « la mémoire n'a rien à dire »
        /// (le vrai signal sur la valeur de la base).
        public var searched: Bool {
            switch self {
            case .promptTooShort, .promptIsCommand, .promptIsMachineEnvelope, .tooFewKeywords:
                return false
            default:
                return true
            }
        }
    }

    /// Une ligne du journal. Tous les champs de mesure sont optionnels : un
    /// refus du gate n'a ni pool, ni couverture, et écrire des zéros les rendrait
    /// indiscernables d'une recherche qui a vraiment rendu zéro.
    public struct Entry: Codable, Equatable, Sendable {
        public let at: Date
        public let outcome: Outcome
        /// Préfixe de session (8 caractères) : assez pour recouper avec
        /// `~/.claude/projects/` et les dossiers de jobs, jamais un identifiant
        /// complet dans un fichier qu'on relira à l'œil.
        public let session: String?
        /// NOM du projet, pas son chemin : le journal n'a pas à porter
        /// l'arborescence du disque.
        public let project: String?
        /// Mots-clés extraits du prompt (pas le prompt).
        public let keywords: Int?
        /// Résultats bruts rendus par la recherche.
        public let pool: Int?
        /// Résultats au-dessus du plancher de pertinence.
        public let kept: Int?
        /// Extraits réellement présents dans le bloc injecté.
        public let injected: Int?
        /// Pour chaque extrait injecté, combien de mots-clés du prompt il
        /// contient VRAIMENT. LE chiffre qui compte : mesuré sur les 739
        /// extraits déjà injectés, 32 % n'en appariaient qu'un et 43 % deux.
        public let coverage: [Int]?
        /// Taille du bloc en caractères — le coût en jetons, à la louche.
        public let blockChars: Int?
        /// Durée totale du passage. Le hook est BLOQUANT (timeout 5 s) : si ce
        /// chiffre dérive, la fonction coûte du temps de frappe à l'utilisateur.
        public let elapsedMs: Int?
        /// Clés de dédoublonnage des extraits injectés (`uuid` du message, ou
        /// `row:<id>` à défaut) : la seule prise qui permettra, le jour de
        /// l'analyse, de remonter au contenu exact dans `memory.db` et de le
        /// confronter à la réponse qui a suivi dans le transcript.
        public let keys: [String]?

        public init(at: Date, outcome: Outcome, session: String? = nil, project: String? = nil,
                    keywords: Int? = nil, pool: Int? = nil, kept: Int? = nil,
                    injected: Int? = nil, coverage: [Int]? = nil, blockChars: Int? = nil,
                    elapsedMs: Int? = nil, keys: [String]? = nil) {
            self.at = at
            self.outcome = outcome
            self.session = session
            self.project = project
            self.keywords = keywords
            self.pool = pool
            self.kept = kept
            self.injected = injected
            self.coverage = coverage
            self.blockChars = blockChars
            self.elapsedMs = elapsedMs
            self.keys = keys
        }
    }

    /// Au-delà, on compacte en ne gardant que la seconde moitié. Un mois d'usage
    /// intensif tient très largement dessous (≈ 3 000 lignes de ~200 octets), le
    /// plafond n'est donc pas une politique de rétention : c'est un garde-fou
    /// contre l'emballement — la base de télémétrie à 956 Mo d'un projet voisin
    /// rappelle ce que coûte un journal sans plafond.
    public static let maxBytes = 4 * 1024 * 1024

    // MARK: - Écriture

    public static func encode(_ entry: Entry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // Clés triées : deux lignes voisines se comparent à l'œil.
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(entry)
        data.append(0x0A)
        return data
    }

    public static func decode(line: Data) -> Entry? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Entry.self, from: line)
    }

    /// Découpe un fichier en entrées, en tolérant tout : ligne vide, ligne
    /// tronquée par un crash en pleine écriture, format d'une version future.
    /// Une ligne illisible est SAUTÉE, jamais fatale — c'est un journal, pas un
    /// contrat.
    public static func entries(in data: Data) -> [Entry] {
        data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { decode(line: Data($0)) }
    }

    // MARK: - Lecture (le résumé qu'on lira dans un mois)

    public struct Summary: Equatable, Sendable {
        public var total = 0
        public var byOutcome: [Outcome: Int] = [:]
        /// Prompts pour lesquels la base a réellement été interrogée.
        public var searched = 0
        /// Extraits injectés, tous blocs confondus.
        public var injectedSnippets = 0
        /// Répartition des couvertures : combien d'extraits n'appariaient qu'un
        /// mot-clé, deux, trois… C'est CE tableau qui dit si la mémoire répond
        /// à la question posée ou si elle rime avec elle.
        public var coverageHistogram: [Int: Int] = [:]
        public var totalBlockChars = 0
        public var maxElapsedMs = 0
        public var medianElapsedMs = 0
        public var firstAt: Date?
        public var lastAt: Date?

        /// Part des passages qui ont abouti à une injection.
        public var injectionRate: Double {
            total > 0 ? Double(byOutcome[.injected] ?? 0) / Double(total) : 0
        }

        /// Part des extraits injectés qui n'appariaient qu'UN mot-clé du prompt.
        /// Au-dessus de ~30 %, la mémoire remplit surtout du contexte.
        public var thinMatchRate: Double {
            injectedSnippets > 0 ? Double(coverageHistogram[1] ?? 0) / Double(injectedSnippets) : 0
        }
    }

    public static func summarize(_ entries: [Entry]) -> Summary {
        var summary = Summary()
        var elapsed: [Int] = []
        for entry in entries {
            summary.total += 1
            summary.byOutcome[entry.outcome, default: 0] += 1
            if entry.outcome.searched { summary.searched += 1 }
            if let injected = entry.injected { summary.injectedSnippets += injected }
            for coverage in entry.coverage ?? [] {
                summary.coverageHistogram[coverage, default: 0] += 1
            }
            summary.totalBlockChars += entry.blockChars ?? 0
            if let ms = entry.elapsedMs {
                summary.maxElapsedMs = max(summary.maxElapsedMs, ms)
                // Médiane calculée sur les seuls passages qui ont INTERROGÉ la
                // base. Les refus du gate coûtent 0 ms et sont majoritaires :
                // les inclure écrasait la médiane à 0, et la ligne de latence
                // disparaissait du rapport — soit précisément l'information
                // qu'on veut lire dans un mois (est-ce que ça ralentit la
                // frappe ?).
                if entry.outcome.searched { elapsed.append(ms) }
            }
            if summary.firstAt == nil || entry.at < summary.firstAt! { summary.firstAt = entry.at }
            if summary.lastAt == nil || entry.at > summary.lastAt! { summary.lastAt = entry.at }
        }
        if !elapsed.isEmpty {
            // Médiane, pas moyenne : une seule ouverture de base à froid
            // (mesurée à 431 ms) déplacerait la moyenne et ferait croire à une
            // lenteur permanente.
            let sorted = elapsed.sorted()
            summary.medianElapsedMs = sorted[sorted.count / 2]
        }
        return summary
    }

    /// Rendu texte du résumé, en français, lisible dans un terminal.
    public static func report(_ summary: Summary) -> String {
        var lines: [String] = []
        lines.append("MÉMOIRE — recall proactif")
        if let first = summary.firstAt, let last = summary.lastAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let days = max(1, Int(last.timeIntervalSince(first) / 86_400) + 1)
            lines.append("période  : \(formatter.string(from: first)) → \(formatter.string(from: last)) (\(days) j)")
        }
        lines.append("passages : \(summary.total), dont \(summary.searched) ayant interrogé la base")
        let injected = summary.byOutcome[.injected] ?? 0
        lines.append(String(format: "injectés : %d (%.0f %% des passages)", injected, summary.injectionRate * 100))

        if summary.total > 0 {
            lines.append("")
            lines.append("issues :")
            for outcome in Outcome.allCases {
                let count = summary.byOutcome[outcome] ?? 0
                guard count > 0 else { continue }
                let share = Double(count) / Double(summary.total) * 100
                lines.append(String(format: "  %-24s %5d  %4.0f %%",
                                    (outcome.rawValue as NSString).utf8String!, count, share))
            }
        }

        if summary.injectedSnippets > 0 {
            lines.append("")
            lines.append("extraits injectés : \(summary.injectedSnippets)")
            lines.append("mots-clés du prompt réellement appariés par extrait :")
            for (coverage, count) in summary.coverageHistogram.sorted(by: { $0.key < $1.key }) {
                let share = Double(count) / Double(summary.injectedSnippets) * 100
                let bar = String(repeating: "█", count: max(0, Int(share / 4)))
                lines.append(String(format: "  %d mot(s) : %5d  %4.0f %% %@",
                                    coverage, count, share, bar))
            }
            lines.append(String(format: "appariement à UN seul mot : %.0f %% des extraits", summary.thinMatchRate * 100))
            lines.append("caractères injectés au total : \(summary.totalBlockChars)")
        }

        if summary.maxElapsedMs > 0 {
            lines.append("")
            lines.append("latence ajoutée au prompt : \(summary.medianElapsedMs) ms (médiane des "
                         + "passages ayant cherché), \(summary.maxElapsedMs) ms (pire)")
        }

        lines.append("")
        lines.append("Ce journal ne dit pas si un souvenir a SERVI — seulement s'il a été")
        lines.append("trouvé, et à quel point il collait à la question. Pour l'utilité réelle,")
        lines.append("croiser `keys` avec memory.db et la réponse qui a suivi dans le transcript.")
        return lines.joined(separator: "\n")
    }
}
