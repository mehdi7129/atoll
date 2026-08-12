import Foundation
import AtollCore

/// Recall PROACTIF (Milestone B) : au hook `UserPromptSubmit`, le helper
/// cherche dans l'index mémoire les souvenirs liés au prompt et les renvoie au
/// CLI via `additionalContext` — Claude reçoit le contexte sans avoir eu
/// l'idée d'appeler le skill `atoll-recall`.
///
/// OPT-IN STRICT : rien ne se passe sans `~/.atoll/proactive-recall.json`
/// (`enabled: true`), écrit par l'app quand l'utilisateur bascule le réglage.
/// C'est aussi ce fichier qui décide, à l'installation, si le hook
/// UserPromptSubmit est bloquant (un hook `async` ne peut rien injecter).
///
/// FAIL-OPEN ABSOLU (règle n° 1 du projet) : ce code tourne DANS le chemin
/// critique d'une session Claude Code, hook bloquant, timeout 5 s côté CLI.
/// Toute anomalie — config absente, index absent, base verrouillée, requête
/// stérile — rend `nil` : le helper n'écrit rien, le CLI continue exactement
/// comme si la fonction n'existait pas. Aucune exception ne remonte, aucun
/// travail long : la recherche est bornée (pool SQL, `maxHits`, bloc capé).
///
/// SÛRETÉ DU CONTENU : ce qu'on injecte vient de transcripts passés, donnée
/// NON FIABLE. `ProactiveRecall.additionalContext` neutralise les balises de
/// rôle, borne chaque extrait et cadre le bloc comme des DONNÉES, jamais des
/// instructions.
enum ProactiveRecallHook {

    /// Rôles autorisés dans un contexte injecté d'OFFICE : l'intention de
    /// l'utilisateur, les conclusions du modèle, les résumés de compaction et
    /// les notes d'Atoll. Volontairement PAS `tool`/`tool_result` (sorties de
    /// commandes, de fichiers et de pages web : bruyantes, et le vecteur
    /// d'injection indirecte le plus probable) ni `thinking` (verbeux) ni
    /// `title` (déjà affiché en en-tête de chaque extrait). Le verbe
    /// `atoll-bridge recall`, lui, cherche dans TOUT : il est appelé
    /// explicitement, avec un humain ou un modèle qui a demandé.
    static let injectableRoles: Set<TranscriptLine.Role> = [
        .user, .assistant, .summary, .note,
    ]

    /// Le JSON à écrire tel quel sur stdout, ou nil s'il n'y a rien à injecter.
    ///
    /// `payload` = le JSON du hook (`prompt`, `cwd`, `session_id`…). La forme
    /// de sortie est celle documentée pour UserPromptSubmit :
    /// `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit",
    ///   "additionalContext":"…"},"suppressOutput":true}`.
    /// `suppressOutput` évite d'afficher le bloc dans le transcript verbeux du
    /// terminal : le contexte est pour le modèle, pas pour l'écran.
    static func contextJSON(payload: [String: Any]) -> (json: Data, count: Int)? {
        guard let config = loadConfig(), config.enabled else { return nil }
        guard let prompt = payload["prompt"] as? String else { return nil }

        // INSTRUMENTATION. Chaque passage laisse une ligne, injecté OU refusé
        // avec sa raison : sans les refus, le total des injections ne dit pas si
        // le silence vient du gate, de la base ou du plancher de pertinence.
        // Voir `RecallJournal`. Fail-open comme le reste : si le journal ne peut
        // pas s'écrire, on continue sans lui.
        let started = Date()
        let session = (payload["session_id"] as? String).map { String($0.prefix(8)) }
        let project = (payload["cwd"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: Self.projectRoot(of: $0)).lastPathComponent }
        func journal(_ outcome: RecallJournal.Outcome, keywords: Int? = nil, pool: Int? = nil,
                     kept: Int? = nil, injected: Int? = nil, coverage: [Int]? = nil,
                     blockChars: Int? = nil, keys: [String]? = nil) {
            appendJournal(RecallJournal.Entry(
                at: started, outcome: outcome, session: session, project: project,
                keywords: keywords, pool: pool, kept: kept, injected: injected,
                coverage: coverage, blockChars: blockChars,
                elapsedMs: Int(Date().timeIntervalSince(started) * 1000), keys: keys))
        }

        let query: String
        let keywordCount: Int
        switch ProactiveRecall.decide(prompt: prompt) {
        case .eligible(let resolved, let count):
            query = resolved
            keywordCount = count
        case .promptTooShort:
            journal(.promptTooShort); return nil
        case .promptIsCommand:
            journal(.promptIsCommand); return nil
        case .promptIsMachineEnvelope:
            journal(.promptIsMachineEnvelope); return nil
        case .tooFewKeywords(let count):
            journal(.tooFewKeywords, keywords: count); return nil
        }

        // Portée projet : la RACINE du dépôt qui contient le cwd, pas le cwd
        // brut (revue) — lancer `claude` depuis ~/Desktop faisait matcher tous
        // les projets qui vivent dessous, et un préfixe nu fait matcher les
        // dossiers frères (`proj` attrapait `proj-client`). `MemoryIndex`
        // applique une frontière de chemin ; ici on remonte au `.git`.
        let projectPrefix: String? = config.projectScoped
            ? (payload["cwd"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
                .map(Self.projectRoot(of:))
            : nil

        guard let index = openIndex() else {
            journal(.indexUnavailable, keywords: keywordCount); return nil
        }
        defer { index.close() }

        // `now` fourni → classement pertinence + récence : dans un contexte
        // injecté d'office, un souvenir périmé coûte plus cher qu'ailleurs.
        // La session COURANTE est exclue : le prompt qu'on vient d'envoyer est
        // déjà dans son transcript et s'auto-remonterait en tête de résultats
        // (constaté en vrai au premier essai de bout en bout).
        guard let hits = try? index.search(rawQuery: query,
                                           limit: config.maxHits,
                                           projectPrefix: projectPrefix,
                                           now: Date(),
                                           excludingSessionID: payload["session_id"] as? String,
                                           // Mots-clés extraits d'une phrase :
                                           // OR obligatoire, le AND ne trouve rien.
                                           mode: .any,
                                           roles: Self.injectableRoles)
        else {
            journal(.searchFailed, keywords: keywordCount); return nil
        }
        guard !hits.isEmpty else {
            journal(.noHits, keywords: keywordCount, pool: 0); return nil
        }
        // Plancher de pertinence : mieux vaut UN souvenir juste que trois dont
        // deux ne partagent qu'un mot avec le prompt.
        // Puis tri par COUVERTURE — combien des mots du prompt l'extrait
        // contient VRAIMENT. En mode `.any`, bm25 classe surtout par rareté des
        // termes : un extrait qui n'apparie qu'un mot rare passait devant un
        // extrait qui en apparie quatre. MESURÉ sur les 739 extraits réellement
        // injectés : 32 % n'appariaient qu'UN terme, 43 % deux. Le tri ne change
        // PAS l'ensemble retenu (le plancher a déjà filtré, et il porte sur
        // `rank`, pas sur l'ordre) : il change lesquels survivent au cap
        // `maxHits`. `byCoverage` préserve l'ordre d'entrée à couverture égale,
        // donc le classement pertinence+récence garde le dernier mot.
        let terms = MemoryIndex.queryTerms(query)
        let significant = MemoryRanking.byCoverage(
            MemoryRanking.aboveRelevanceFloor(hits), terms: terms)
        guard !significant.isEmpty else {
            journal(.noneAboveFloor, keywords: keywordCount, pool: hits.count, kept: 0)
            return nil
        }
        // `injectedBlock` rend le texte ET les extraits qu'il contient vraiment :
        // c'est la seule façon de journaliser ce qui est PARTI plutôt que ce
        // qu'on espérait envoyer (voir `ProactiveRecall.InjectedBlock`).
        guard let block = ProactiveRecall.injectedBlock(hits: significant,
                                                        maxHits: config.maxHits,
                                                        now: Date())
        else {
            journal(.emptyBlock, keywords: keywordCount, pool: hits.count, kept: significant.count)
            return nil
        }
        let context = block.text

        let object: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "UserPromptSubmit",
                "additionalContext": context,
            ],
            "suppressOutput": true,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: object) else {
            journal(.emptyBlock, keywords: keywordCount, pool: hits.count, kept: significant.count)
            return nil
        }
        // CE QUI EST RÉELLEMENT PARTI — pas ce qu'on espérait envoyer.
        // `prefix(maxHits)` ne suffisait pas : la construction du bloc écarte
        // aussi les extraits vides après nettoyage ET ceux qui ne tiennent pas
        // sous le cap de caractères. À 5 extraits pleins, elle en emporte 4 —
        // et l'en-tête du bloc annonçait donc « 4 » au modèle pendant que le
        // journal en enregistrait 5, couvertures et `keys` comprises.
        let sent = block.hits
        journal(.injected,
                keywords: keywordCount, pool: hits.count, kept: significant.count,
                injected: sent.count,
                coverage: sent.map { MemoryRanking.coverage(of: $0, terms: terms) },
                blockChars: context.count,
                keys: sent.map(\.dedupKey))
        // Le NOMBRE d'extraits remonte à l'îlot avec l'événement : c'est la
        // seule façon pour l'utilisateur de savoir que sa session a reçu de la
        // mémoire (le bloc lui-même est masqué du terminal). Même compte que le
        // journal et que l'en-tête du bloc : il n'y a plus qu'une source.
        return (json: json, count: sent.count)
    }

    /// Fichier du journal. Sous `~/.atoll/`, jamais dans le dépôt : c'est une
    /// mesure locale, elle ne se versionne pas et ne quitte pas la machine.
    static var journalURL: URL {
        BridgePaths.homeDirectory.appendingPathComponent(".atoll", isDirectory: true).appendingPathComponent("recall-journal.jsonl")
    }

    /// Ajoute une ligne au journal. TOTALEMENT silencieux et fail-open : ce code
    /// tourne dans un hook BLOQUANT, aucune anomalie d'écriture ne doit retarder
    /// une frappe ni salir stdout (canal de réponse du CLI).
    ///
    /// `O_APPEND` : deux hooks concurrents écrivent chacun leur ligne sans se
    /// chevaucher — le noyau positionne à la fin à chaque `write`, et nos lignes
    /// font quelques centaines d'octets.
    static func appendJournal(_ entry: RecallJournal.Entry) {
        guard let data = try? RecallJournal.encode(entry) else { return }
        let path = journalURL.path
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: BridgePaths.homeDirectory.appendingPathComponent(".atoll", isDirectory: true), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: path) {
            fileManager.createFile(atPath: path, contents: nil)
        }
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if written == 0 { break }
                offset += written
            }
            return offset
        }
        compactIfNeeded()
    }

    /// Ne garde que la seconde moitié quand le fichier dépasse le plafond.
    /// La taille est lue par `stat` (aucune lecture du contenu) : sur un journal
    /// normal, ce chemin ne fait donc rien du tout.
    static func compactIfNeeded() {
        let path = journalURL.path
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int,
              size > RecallJournal.maxBytes,
              let data = try? Data(contentsOf: journalURL) else { return }
        // Couper à la première fin de ligne après la moitié : jamais au milieu
        // d'un objet JSON, sinon la première entrée survivante est illisible.
        let half = data.count / 2
        guard let cut = data[half...].firstIndex(of: 0x0A) else { return }
        try? data[(cut + 1)...].write(to: journalURL, options: .atomic)
    }

    /// Racine du dépôt contenant `path` : on remonte jusqu'au premier dossier
    /// portant un `.git`, sinon on rend le chemin tel quel. Borné à 40 niveaux
    /// (un chemin bricolé ne peut pas faire boucler le hook) et arrêté à la
    /// racine du système.
    ///
    /// Pourquoi : le cwd d'une session peut être un sous-dossier (le filtre
    /// raterait les souvenirs du reste du dépôt) ou un dossier parent comme
    /// `~/Desktop` (le filtre attraperait TOUS les projets qui vivent
    /// dessous — mesuré : 40 sessions de projets différents).
    static func projectRoot(of path: String) -> String {
        var url = URL(fileURLWithPath: path).standardized
        for _ in 0..<40 {
            let parent = url.deletingLastPathComponent()
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
            if parent.path == url.path { break } // racine atteinte
            url = parent
        }
        return URL(fileURLWithPath: path).standardized.path
    }

    /// Config du recall proactif ; absente, illisible ou appartenant à
    /// quelqu'un d'autre → nil (désactivé).
    static func loadConfig() -> ProactiveRecallConfig? {
        let url = BridgePaths.proactiveRecallConfigURL
        guard isOwnedByCurrentUser(url) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ProactiveRecallConfig.decode(data)
    }

    /// Index en LECTURE SEULE STRICTE — jamais de repli `readWrite` (revue) :
    /// cet init pose des pragmas, migre, et sur une version de schéma
    /// inattendue SUPPRIME la base (`recreateFromScratch`). Un hook du chemin
    /// critique du CLI n'a pas le droit d'effacer la mémoire de l'utilisateur,
    /// ni de créer une base vide en pleine reconstruction par l'app. Échec =
    /// pas de souvenirs, point.
    ///
    /// (Le repli existait pour « base WAL sans `-shm` » ; vérifié en revue :
    /// l'ouverture readOnly réussit dans ce cas, c'est la première requête qui
    /// échouerait — et elle est déjà en `try?`.)
    private static func openIndex() -> MemoryIndex? {
        let url = BridgePaths.memoryDatabaseURL
        guard isOwnedByCurrentUser(url) else { return nil }
        return try? MemoryIndex(url: url, mode: .readOnly)
    }

    /// Le fichier existe-t-il, appartient-il à l'utilisateur courant, et
    /// n'est-il inscriptible ni par le groupe ni par les autres ?
    ///
    /// Défense en profondeur sur machine partagée : ces fichiers pilotent ce
    /// qui est injecté dans TOUTES les sessions Claude de l'utilisateur. Un
    /// fichier posé ou modifiable par un autre compte est ignoré, jamais lu.
    private static func isOwnedByCurrentUser(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else { return false }
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            return false
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        return (permissions & 0o022) == 0
    }
}
