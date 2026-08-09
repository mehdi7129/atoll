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
        guard let prompt = payload["prompt"] as? String,
              let query = ProactiveRecall.query(fromPrompt: prompt) else { return nil }

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

        guard let index = openIndex() else { return nil }
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
                                           roles: Self.injectableRoles),
              // Plancher de pertinence : mieux vaut UN souvenir juste que
              // trois dont deux ne partagent qu'un mot avec le prompt.
              // Puis tri par COUVERTURE — combien des mots du prompt l'extrait
              // contient VRAIMENT. En mode `.any`, bm25 classe surtout par
              // rareté des termes : un extrait qui n'apparie qu'un mot rare
              // passait devant un extrait qui en apparie quatre. MESURÉ sur les
              // 739 extraits réellement injectés : 32 % n'appariaient qu'UN
              // terme, 43 % deux. Le tri ne change PAS l'ensemble retenu (le
              // plancher a déjà filtré, et il porte sur `rank`, pas sur
              // l'ordre) : il change lesquels survivent au cap `maxHits`.
              // `byCoverage` préserve l'ordre d'entrée à couverture égale, donc
              // le classement pertinence+récence garde le dernier mot.
              case let significant = MemoryRanking.byCoverage(
                  MemoryRanking.aboveRelevanceFloor(hits),
                  terms: MemoryIndex.queryTerms(query)
              ),
              let context = ProactiveRecall.additionalContext(hits: significant,
                                                              maxHits: config.maxHits,
                                                              now: Date())
        else { return nil }

        let object: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "UserPromptSubmit",
                "additionalContext": context,
            ],
            "suppressOutput": true,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        // Le NOMBRE d'extraits remonte à l'îlot avec l'événement : c'est la
        // seule façon pour l'utilisateur de savoir que sa session a reçu de la
        // mémoire (le bloc lui-même est masqué du terminal).
        return (json: json, count: min(significant.count, config.maxHits))
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
