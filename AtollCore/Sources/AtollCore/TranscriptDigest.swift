import Foundation

/// Condensé d'un transcript JSONL, extrait EN SWIFT pour être injecté DANS le prompt
/// de la rétrospective — le modèle n'a alors plus besoin du moindre outil de lecture.
///
/// POURQUOI (mesuré le 2026-07-27, jalon 12a de `docs/ROADMAP-12-boucle-fermee.md`) :
/// la rétrospective faisait lire au modèle un JSONL de 9 à 47 Mo avec Read/Grep sous un
/// budget de 1,50 $ — il n'en voyait que ~8 %, et le tirage de ces 8 % était arbitraire.
/// Ici Atoll lit TOUT (c'est gratuit), ne garde que ce qui porte du savoir durable, et
/// rend un texte déterministe borné (~150 000 caractères) qui tient dans un prompt.
///
/// Logique 100 % pure, AUCUN accès disque : l'appelant lit le fichier, le découpe avec
/// `TranscriptLineSplitter` et le parse avec `TranscriptLineParser`, puis passe les
/// lignes ici. Même contrat défensif que le parseur : jamais de crash, jamais
/// d'exception, une entrée illisible est simplement absente.
///
/// ## Ce qu'on garde, par ordre de valeur
/// 1. `.user` — l'INTENTION. C'est la matière première d'un skill : ce que l'humain
///    voulait, dans ses mots.
/// 2. `.summary` — les résumés de compaction sont déjà distillés par le modèle,
///    rapport valeur/caractère imbattable.
/// 3. `.assistant` — les conclusions (« voilà ce que j'ai fait, voilà pourquoi »).
/// 4. `.toolResult` PORTANT UNE ERREUR — c'est là que vivent les pièges, donc la moitié
///    de ce qu'une rétrospective doit apprendre.
/// 5. `.tool` SUIVI D'UN SUCCÈS — la commande exacte qui a MARCHÉ, matière d'une
///    procédure rejouable.
///
/// ## Ce qu'on jette
/// - `.thinking` : verbeux (cap 4 000 par fragment côté parseur) et redondant avec les
///   conclusions ; à budget égal, dix conclusions valent mieux qu'un raisonnement.
/// - `.title`, `.note` : métadonnées d'Atoll, aucune valeur d'analyse (et une `.note`
///   est un texte QU'ATOLL A ÉCRIT — le réinjecter ferait tourner le modèle en rond).
/// - Tout `.toolResult` sans marqueur d'erreur : le succès se lit sur l'invocation, pas
///   sur ses 400 Ko de sortie.
public enum TranscriptDigest {

    // MARK: - Types

    /// Une unité retenue : un fragment de transcript jugé porteur de savoir, déjà borné
    /// à `entryCharacterCap` caractères. Le `timestamp` est celui de la LIGNE d'origine
    /// (le format ne date pas les fragments individuellement) ; `nil` si illisible.
    public struct Entry: Equatable, Sendable {
        public let role: TranscriptLine.Role
        public let text: String
        public let timestamp: Date?
        /// `is_error` du transcript pour un `.toolResult` (nil = absent) —
        /// propagé depuis le fragment, c'est l'autorité sur l'échec.
        public let isError: Bool?
        /// Identifiant d'invocation (`toolUseID` du fragment) : relie une
        /// commande à SON résultat, même quand plusieurs outils partent en
        /// parallèle. nil = absent du transcript, on retombe sur la position.
        public let toolUseID: String?

        public init(role: TranscriptLine.Role, text: String, timestamp: Date?,
                    isError: Bool? = nil, toolUseID: String? = nil) {
            self.role = role
            self.text = text
            self.timestamp = timestamp
            self.isError = isError
            self.toolUseID = toolUseID
        }
    }

    /// Le condensé et de quoi le juger : l'appelant journalise ces chiffres (jalon 12a
    /// « journal d'apprentissage ») pour savoir, après coup, ce que le modèle a vraiment vu.
    public struct Result: Equatable, Sendable {
        /// Le condensé rendu, prêt à être injecté tel quel dans un prompt.
        public let text: String
        /// Nombre de lignes reçues (déjà filtrées par le parseur en amont).
        public let linesRead: Int
        /// Nombre d'entrées présentes dans `text`, après élagage.
        public let entriesKept: Int
        /// `true` dès qu'au moins une entrée a été ÉLAGUÉE faute de budget. Le cap par
        /// entrée, lui, est une normalisation systématique et n'est PAS signalé ici :
        /// ce drapeau répond à « ai-je perdu des entrées entières ? », la seule question
        /// qui doit faire réagir l'appelant (baisser le nombre de sessions, monter le budget).
        public let truncated: Bool
        /// `text.count` — mesuré sur le rendu final, jamais estimé.
        public let characterCount: Int

        public init(text: String, linesRead: Int, entriesKept: Int,
                    truncated: Bool, characterCount: Int) {
            self.text = text
            self.linesRead = linesRead
            self.entriesKept = entriesKept
            self.truncated = truncated
            self.characterCount = characterCount
        }
    }

    // MARK: - Constantes

    /// ~150 000 caractères ≈ 40 000 tokens : large pour une analyse complète, petit
    /// devant la fenêtre de contexte, et sans commune mesure avec les 9 à 47 Mo du
    /// fichier brut.
    public static let defaultCharacterBudget = 150_000

    /// Chaque entrée est bornée INDIVIDUELLEMENT : une sortie d'outil de 400 Ko ne doit
    /// pas manger le budget entier et faire disparaître cent autres entrées. Les
    /// marqueurs d'erreur, eux, sont cherchés sur le texte ENTIER avant troncature — on
    /// ne veut pas rater un piège parce qu'il arrive tard dans la sortie.
    public static let entryCharacterCap = 2_000

    /// Marqueur de troncature (4 caractères). Le texte tronqué fait exactement
    /// `entryCharacterCap` caractères, marqueur compris.
    static let entryTruncationMarker = " […]"

    /// Combien d'entrées après une invocation d'outil on cherche son résultat. Entre un
    /// `tool_use` et son `tool_result` s'intercalent souvent un texte d'assistant, un
    /// bloc `thinking` ou une seconde invocation (appels parallèles) — 3 couvre les cas
    /// observés sans risquer d'attraper le résultat d'un outil bien plus loin.
    static let toolLookahead = 3

    /// Séparateur entre deux blocs rendus.
    static let blockSeparator = "\n\n"

    /// Marqueurs d'échec cherchés dans un `.toolResult`, en minuscules (comparaison
    /// insensible à la casse). Volontairement LARGES : un faux positif ne coûte que du
    /// budget, un faux négatif fait perdre le piège que la rétrospective devait apprendre.
    static let errorMarkers = [
        "error", "failed", "erreur", "échec", "not found", "no such file",
        "exception", "traceback", "permission denied", "command not found", "exit code",
    ]

    // MARK: - API

    /// Construit le condensé. Ordre des opérations : sélection → cap par entrée → rendu
    /// des blocs → élagage par priorité si ça dépasse → assemblage.
    ///
    /// Robustesse : `lines` vide donne un `Result` vide (`entriesKept == 0`) et NON
    /// tronqué ; un `budget` ≤ 0 rend un texte vide marqué `truncated` (budget
    /// inexploitable = tout a été sacrifié, par convention).
    public static func make(lines: [TranscriptLine],
                            budget: Int = defaultCharacterBudget) -> Result {
        let linesRead = lines.count

        guard budget > 0 else {
            return Result(text: "", linesRead: linesRead, entriesKept: 0,
                          truncated: true, characterCount: 0)
        }

        let selected = entries(from: lines)
        guard !selected.isEmpty else {
            return Result(text: "", linesRead: linesRead, entriesKept: 0,
                          truncated: false, characterCount: 0)
        }

        let formatter = timeFormatter()
        let blocks = selected.map { render($0, formatter: formatter) }

        // Élagage. On raisonne sur des longueurs (pas de re-concaténation à chaque
        // retrait) : total = somme des blocs gardés + 2 caractères de séparateur par
        // jointure. L'estimation est un MAJORANT du `count` final (deux blocs ne
        // fusionnent jamais de grappe de graphèmes à travers "\n\n"), donc élaguer
        // dessus ne peut pas dépasser le budget.
        var keep = [Bool](repeating: true, count: blocks.count)
        var keptCount = blocks.count
        var sum = blocks.reduce(0) { $0 + $1.count }
        var pruned = false

        func estimatedTotal() -> Int {
            keptCount > 0 ? sum + blockSeparator.count * (keptCount - 1) : 0
        }

        // PARTS RÉSERVÉES PAR RÔLE (revue) — sans elles, la promesse faite au
        // modèle (« commands that succeeded ») était FAUSSE sur les sessions
        // qui comptent : mesuré sur un transcript de 45 Mo, 1 382 invocations
        // d'outils réussies étaient sélectionnées et **zéro** survivait, les
        // fragments `.assistant` (2 000 caractères chacun) ayant mangé tout le
        // budget avant que l'ordre de sacrifice ne s'applique. Or une commande
        // qui a marché EST la matière d'une procédure rejouable.
        //
        // On protège donc une part du budget pour les rôles qui portent le
        // savoir procédural, avant l'élagage global : tant qu'un rôle n'a pas
        // dépassé sa part, ses entrées ne sont pas sacrifiables.
        var protectedBudget: [TranscriptLine.Role: Int] = [:]
        for (role, share) in reservedShares {
            protectedBudget[role] = Int(Double(budget) * share)
        }

        // `sacrificeOrder` couvre TOUTES les entrées : la boucle se termine toujours,
        // au pire sur un condensé vide. Deux passes : d'abord en épargnant les
        // parts réservées, puis — s'il le faut encore — sans épargne.
        for pass in 0..<2 {
            for index in sacrificeOrder(for: selected) {
                guard estimatedTotal() > budget else { break }
                guard keep[index] else { continue }
                let role = selected[index].role
                if pass == 0, let reserve = protectedBudget[role] {
                    // Ce qui est GARDÉ pour ce rôle, recalculé à la volée.
                    let kept = selected.indices
                        .filter { keep[$0] && selected[$0].role == role }
                        .reduce(0) { $0 + blocks[$1].count }
                    if kept <= reserve { continue } // dans sa part : épargné
                }
                keep[index] = false
                keptCount -= 1
                sum -= blocks[index].count
                pruned = true
            }
            if estimatedTotal() <= budget { break }
        }

        let text = blocks.indices
            .filter { keep[$0] }
            .map { blocks[$0] }
            .joined(separator: blockSeparator)

        return Result(text: text, linesRead: linesRead, entriesKept: keptCount,
                      truncated: pruned, characterCount: text.count)
    }

    /// Étape de SÉLECTION seule : aplatit les lignes en fragments, applique les règles
    /// de valeur et borne chaque entrée. Sans budget ni rendu — exposé pour les tests et
    /// pour un appelant qui voudrait rendre autrement (affichage, autre prompt).
    public static func entries(from lines: [TranscriptLine]) -> [Entry] {
        // 1. Aplatissement. L'appariement outil ↔ résultat se fait par
        //    IDENTIFIANT (`tool_use_id`) quand le transcript le porte, et
        //    seulement à défaut par la position — cette dernière se trompe dès
        //    que deux outils partent en parallèle.
        var flat: [Entry] = []
        flat.reserveCapacity(lines.reduce(0) { $0 + $1.fragments.count })
        for line in lines {
            for fragment in line.fragments where !fragment.text.isEmpty {
                flat.append(Entry(role: fragment.role, text: fragment.text,
                                  timestamp: line.timestamp, isError: fragment.isError,
                                  toolUseID: fragment.toolUseID))
            }
        }
        // Index des résultats par identifiant d'invocation.
        var resultsByID: [String: Entry] = [:]
        for entry in flat where entry.role == .toolResult {
            if let id = entry.toolUseID, resultsByID[id] == nil { resultsByID[id] = entry }
        }

        // 2. Sélection.
        var kept: [Entry] = []
        kept.reserveCapacity(flat.count / 2)
        for (index, entry) in flat.enumerated() {
            let isKept: Bool
            switch entry.role {
            case .user, .summary, .assistant:
                isKept = true
            case .toolResult:
                isKept = isFailure(entry)
            case .tool:
                isKept = succeeded(toolAt: index, in: flat, resultsByID: resultsByID)
            case .thinking, .title, .note:
                isKept = false
            }
            guard isKept else { continue }
            kept.append(Entry(role: entry.role, text: capped(entry.text),
                              timestamp: entry.timestamp, isError: entry.isError))
        }
        return kept
    }

    // MARK: - Règles de sélection

    /// Un `.toolResult` a-t-il ÉCHOUÉ ? `is_error` du transcript fait autorité ;
    /// l'heuristique par mot-clé n'est qu'un REPLI quand le champ est absent.
    ///
    /// POURQUOI (mesuré en revue) : chercher « error » dans la sortie classait
    /// en échec la lecture RÉUSSIE de tout fichier source contenant ce mot —
    /// 73 « erreurs » détectées sur un transcript qui n'en portait que 13
    /// selon `is_error`, soit 5× trop. Double dégât : ces succès étaient
    /// présentés au modèle comme des pièges, ET l'invocation correspondante
    /// disparaissait des « commandes qui ont marché ». À l'inverse, le texte
    /// arrive déjà tronqué à 1 500 caractères : un build qui échoue après une
    /// longue sortie passait pour un succès.
    static func isFailure(_ fragment: TranscriptLine.Fragment) -> Bool {
        if let isError = fragment.isError { return isError }
        return hasErrorMarker(fragment.text)
    }

    /// Même règle pour une entrée déjà sélectionnée.
    static func isFailure(_ entry: Entry) -> Bool {
        if let isError = entry.isError { return isError }
        return hasErrorMarker(entry.text)
    }

    /// Repli historique : trace d'échec dans le texte. Insensible à la casse ;
    /// `lowercased()` gère aussi « Échec » → « échec ».
    static func hasErrorMarker(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return errorMarkers.contains { lowered.contains($0) }
    }

    /// Une invocation d'outil n'est gardée que si elle a MARCHÉ : on regarde les
    /// `toolLookahead` entrées suivantes et c'est le PREMIER `.toolResult` rencontré qui
    /// décide. Pourquoi le premier et pas « un quelconque » : dans
    /// `tool, erreur, tool, succès`, se contenter d'un succès dans la fenêtre ferait
    /// passer le premier outil pour réussi alors qu'il a échoué. Aucun résultat dans la
    /// fenêtre (session coupée, appel jamais résolu) → on ne garde pas : on ne peut rien
    /// affirmer, et une commande dont on ignore l'issue n'est pas une procédure.
    static func succeeded(toolAt index: Int, in flat: [Entry],
                          resultsByID: [String: Entry] = [:]) -> Bool {
        // Appariement par IDENTITÉ dès que le transcript le permet. Le repli
        // positionnel ci-dessous jugeait les invocations 2..N d'un lot parallèle
        // sur le résultat de la PREMIÈRE, et écartait la première elle-même
        // quand quatre outils partaient ensemble (audit du 2026-07-27).
        if let id = flat[index].toolUseID {
            guard let result = resultsByID[id] else { return false }
            return !isFailure(result)
        }
        let upperBound = min(index + toolLookahead, flat.count - 1)
        guard upperBound > index else { return false }
        for next in (index + 1)...upperBound where flat[next].role == .toolResult {
            return !isFailure(flat[next])
        }
        return false
    }

    /// Borne une entrée à `entryCharacterCap`, marqueur compris.
    static func capped(_ text: String) -> String {
        guard text.count > entryCharacterCap else { return text }
        let keep = entryCharacterCap - entryTruncationMarker.count
        return String(text.prefix(keep)) + entryTruncationMarker
    }

    // MARK: - Élagage par priorité

    /// Ordre de SACRIFICE (le premier part le premier). On n'ampute JAMAIS la fin du
    /// condensé par troncature aveugle : la fin d'une session est souvent le plus
    /// instructif (le bug enfin compris, la commande enfin bonne). On enlève donc par
    /// valeur croissante.
    ///
    /// `.tool` d'abord (une commande réussie sans son contexte vaut peu), puis
    /// `.assistant` (verbeux, souvent redondant avec la demande), puis les `.toolResult`
    /// d'erreur, puis `.summary` (déjà distillé, très dense) et enfin `.user` —
    /// l'intention, qu'on ne touche qu'en tout dernier recours. Les rôles jamais
    /// sélectionnés reçoivent le rang 0 par sûreté (si la sélection évoluait, ils
    /// partiraient en premier plutôt que de manger le budget des `.user`).
    static func sacrificeRank(_ role: TranscriptLine.Role) -> Int {
        switch role {
        case .tool: return 1
        case .assistant: return 2
        case .toolResult: return 3
        case .summary: return 4
        case .user: return 5
        case .thinking, .title, .note: return 0
        }
    }

    /// Part du budget garantie à chaque rôle porteur de savoir PROCÉDURAL,
    /// à l'abri de l'élagage tant qu'elle n'est pas dépassée.
    ///
    /// Calibré sur les mesures réelles : un transcript de 45 Mo produit ~1 380
    /// invocations d'outils et ~500 conclusions d'assistant ; sans réserve, les
    /// secondes évincent intégralement les premières. 25 % du budget suffisent
    /// à faire entrer plusieurs dizaines de commandes réussies, et 15 % pour
    /// les erreurs — l'autre moitié du savoir (« ce qui a raté et comment on
    /// s'en est sorti »). Les `.user` n'ont pas besoin de réserve : ils sont
    /// déjà les derniers sacrifiés.
    static let reservedShares: [TranscriptLine.Role: Double] = [
        .tool: 0.25,
        .toolResult: 0.15,
    ]

    /// Indices de `entries` dans l'ordre où il faut les sacrifier.
    static func sacrificeOrder(for entries: [Entry]) -> [Int] {
        var buckets: [Int: [Int]] = [:]
        for (index, entry) in entries.enumerated() {
            buckets[sacrificeRank(entry.role), default: []].append(index)
        }
        return buckets.keys.sorted().flatMap { middleOut(buckets[$0] ?? []) }
    }

    /// Ordonne des indices « du milieu vers les bords » : au sein d'une catégorie on
    /// sacrifie le MILIEU de la session d'abord et on garde le DÉBUT (qui pose le
    /// contexte : le projet, la demande initiale) et la FIN (qui conclut). Tri
    /// totalement ordonné (distance au centre, puis rang) → déterministe même si
    /// `sorted` n'est pas stable.
    static func middleOut(_ indices: [Int]) -> [Int] {
        guard indices.count > 2 else { return indices }
        let center = Double(indices.count - 1) / 2
        return indices.indices.sorted { left, right in
            let distanceLeft = abs(Double(left) - center)
            let distanceRight = abs(Double(right) - center)
            if distanceLeft != distanceRight { return distanceLeft < distanceRight }
            return left < right
        }.map { indices[$0] }
    }

    // MARK: - Rendu

    /// Un bloc par entrée, blocs séparés par une ligne vide :
    ///
    ///     [user 14:32] Corrige le bug du quota figé
    ///
    ///     [tool 14:33] Bash · git status
    ///
    ///     [tool_result 14:33] error: pathspec 'main' did not match
    ///
    /// Le préfixe donne le rôle (`user`, `assistant`, `summary`, `tool`, `tool_result` —
    /// la graphie de `TranscriptLine.Role`, sans interprétation) et l'heure LOCALE si
    /// elle est connue, omise sinon (`[user] …`). Deux invariants utiles au prompt qui
    /// consommera ce texte, à énoncer côté prompt car ils ne se lisent pas dans le rendu :
    /// tout `tool` présent a RÉUSSI, tout `tool_result` présent porte une ERREUR.
    static func render(_ entry: Entry, formatter: DateFormatter) -> String {
        guard let timestamp = entry.timestamp else {
            return "[\(entry.role.rawValue)] \(entry.text)"
        }
        return "[\(entry.role.rawValue) \(formatter.string(from: timestamp))] \(entry.text)"
    }

    /// Heure locale « HH:mm » : celle où la session s'est déroulée, la seule qui parle à
    /// l'utilisateur quand il relit une note. `en_US_POSIX` pour que le format ne dépende
    /// pas des réglages régionaux (un calendrier non grégorien ne doit pas déplacer l'heure).
    static func timeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }
}
