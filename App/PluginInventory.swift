import Foundation
import Observation
import OSLog
import AtollCore

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "plugins")

/// L'inventaire des plugins Claude Code (jalon 12c, « boucle fermée ») : ce qui
/// est installé, ce qui est activé, ce qui est cassé, ce que ça coûte en tokens
/// à chaque session — et les actions pour y remédier.
///
/// SEULE LA CLI A LE DROIT D'ÉCRIRE (contrainte n°1, corollaire de la règle 2 du
/// projet : `~/.claude/settings.json` est sacré). Atoll ne touche JAMAIS
/// directement à la clé `enabledPlugins` ni au cache `~/.claude/plugins/` : il
/// LIT (`plugin list --json`, `plugin details`) et DÉLÈGUE toute mutation à
/// `claude plugin install|enable|disable`. Deux raisons : la CLI connaît le
/// format exact de son propre état (qu'une MAJ peut faire évoluer sans nous
/// prévenir), et l'utilisateur a des entrées non-Atoll dans ce fichier qu'un
/// écrasement mal fichu détruirait.
///
/// AUCUNE ACTION AUTOMATIQUE (contrainte n°6) : `install`, `setEnabled` ne sont
/// appelés que par un geste EXPLICITE de l'utilisateur (⌘⏎ dans la fenêtre de
/// revue). Atoll diagnostique et propose ; il n'installe ni n'active jamais
/// quoi que ce soit de son propre chef, et surtout pas depuis l'îlot en un clic.
/// Idem pour `refresh(includeAvailable: true)` : cet appel TOUCHE LE RÉSEAU, il
/// ne doit partir que sur demande (bouton « voir le catalogue »), jamais dans un
/// `onAppear` ni dans une boucle de poll.
///
/// Fail-open de bout en bout (contrainte n°7) : toute erreur laisse l'app
/// parfaitement fonctionnelle. On renseigne `lastError`, on log, et c'est tout —
/// un catalogue de plugins injoignable ne doit rien empêcher.
@MainActor
@Observable
final class PluginInventory {
    static let shared = PluginInventory()

    // MARK: - État publié

    /// Dernier inventaire connu. nil = jamais lu avec succès (≠ « aucun plugin »,
    /// qui est un `PluginSnapshot` vide) — la nuance compte pour l'affichage.
    private(set) var snapshot: PluginSnapshot?
    /// Un `plugin list` est en vol (le bouton « Actualiser » se désactive).
    private(set) var isRefreshing = false
    /// Dernière erreur lisible par un humain, ou nil. Purement informatif.
    private(set) var lastError: String?
    /// Fraîcheur de `snapshot` — un inventaire de plugins vieillit vite dès que
    /// l'utilisateur bricole en parallèle dans son terminal.
    private(set) var lastRefreshedAt: Date?
    /// id de plugin → tokens « always-on » (ajoutés à CHAQUE session). Rempli À
    /// LA DEMANDE, un `claude plugin details` par plugin : c'est le chiffre qui
    /// justifie tout le panneau, mais il coûte un spawn, donc jamais en masse.
    private(set) var tokenCosts: [String: Int] = [:]
    /// Une action (enable/disable/install) est en cours sur CE plugin. La vue
    /// désactive ses boutons tant que ce n'est pas nil.
    private(set) var busyPluginID: String?

    // MARK: - Interne

    /// Chemin du binaire `claude`, résolu puis mis en cache (même stratégie que
    /// `FleetPoller` / `FleetLauncher`).
    @ObservationIgnored private var claudePath: String?
    /// La résolution COÛTEUSE (login shell, source le profil) a-t-elle déjà été
    /// tentée ? Sur échec, on ne la rejoue PAS à chaque clic.
    @ObservationIgnored private var triedLoginResolve = false
    /// Coûts en tokens dont le `details` est en vol : empêche un `onAppear`
    /// répété (une liste qui se re-rend) de spawner dix fois la même commande.
    @ObservationIgnored private var tokenCostInFlight: Set<String> = []

    // MARK: - Délais (contrainte n°2 : TOUT spawn est borné)
    //
    // Piège vécu en Phase 8 : un `claude` figé (daemon bloqué) gelait la boucle
    // de poll ET neutralisait le repli, parce que `readToEnd` ignore
    // l'annulation d'une Task. La seule parade est de TUER le process —
    // SIGTERM, puis SIGKILL une seconde plus tard s'il s'accroche.

    /// `plugin list --json` : lecture 100 % locale (le cache sur disque).
    private static let listTimeout: TimeInterval = 8
    /// `plugin list --available --json` : VA SUR LE RÉSEAU (268 entrées de
    /// marketplaces) — c'est le cas dangereux, d'où le délai plus large.
    private static let availableTimeout: TimeInterval = 20
    /// `plugin details <nom>` : local, comme `list`.
    private static let detailsTimeout: TimeInterval = 8
    /// `plugin enable|disable` : local (réécriture de settings.json par la CLI),
    /// mais peut relire/valider le cache du plugin au passage.
    private static let toggleTimeout: TimeInterval = 30
    /// `plugin install` : clone/téléchargement depuis un marketplace — le seul
    /// qui a une vraie raison d'être long.
    private static let installTimeout: TimeInterval = 90

    // MARK: - Lecture

    /// Relit l'inventaire. `includeAvailable` ajoute le catalogue des
    /// marketplaces (`--available`).
    ///
    /// ⚠️ `includeAvailable: true` TOUCHE LE RÉSEAU : à n'appeler QUE sur un
    /// geste explicite de l'utilisateur, jamais automatiquement (ni au
    /// lancement, ni dans un `onAppear`, ni périodiquement).
    ///
    /// No-op si un refresh est déjà en vol.
    func refresh(includeAvailable: Bool = false) {
        // `refreshNow` pose sa propre garde de ré-entrance AVANT son premier
        // await : deux Task créées coup sur coup s'excluent correctement (elles
        // s'exécutent toutes deux sur le MainActor).
        Task { [weak self] in await self?.refreshNow(includeAvailable: includeAvailable) }
    }

    private func refreshNow(includeAvailable: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true // AVANT le premier await (sinon la garde ne garde rien)
        defer { isRefreshing = false }

        guard let claude = await resolveClaudePath() else {
            lastError = "Binaire claude introuvable."
            return
        }
        var arguments = ["plugin", "list", "--json"]
        if includeAvailable { arguments.insert("--available", at: 2) }

        let outcome = await Self.run(
            arguments: arguments,
            claude: claude,
            timeout: includeAvailable ? Self.availableTimeout : Self.listTimeout
        )
        guard outcome.status == 0 else {
            lastError = Self.failureMessage(outcome, verb: "Lecture des plugins")
            log.error("plugin list a échoué : \(outcome.diagnostic, privacy: .public)")
            return
        }
        guard let fresh = Self.decodeTolerant(outcome.output) else {
            lastError = "Sortie de `claude plugin list` inexploitable."
            log.error("plugin list : décodage impossible (\(outcome.output.count) octets)")
            return
        }

        // `plugin list --json` (sans `--available`) rend un TABLEAU NU : son
        // décodage a donc un catalogue vide. On CONSERVE le catalogue déjà
        // chargé — sinon un simple rafraîchissement local viderait l'écran de
        // découverte et pousserait à re-taper le réseau pour rien.
        let merged = PluginSnapshot(
            installed: fresh.installed,
            available: includeAvailable ? fresh.available : (snapshot?.available ?? [])
        )
        lastError = nil
        // Horodaté seulement sur SUCCÈS : `lastRefreshedAt` qualifie la
        // fraîcheur de `snapshot`, pas celle de la dernière tentative. Le poser
        // après un échec ferait passer un inventaire périmé pour tout neuf.
        lastRefreshedAt = Date()
        // No-op si rien n'a changé : réassigner une valeur identique
        // réveillerait toutes les vues observatrices pour rien (leçon du
        // FleetPoller, qui poll en boucle).
        if merged != snapshot { snapshot = merged }
        log.info("inventaire : \(merged.installed.count) installés, \(merged.enabledCount) activés, \(merged.broken.count) cassés, \(merged.available.count) disponibles")
    }

    /// Charge le coût « always-on » d'un plugin (tokens ajoutés à CHAQUE
    /// session) via `claude plugin details`.
    ///
    /// Sortie TEXTE destinée à un humain — la source la moins stable des trois
    /// (alignement à l'espace, `~` d'approximation, séparateurs de milliers) :
    /// parsing strictement défensif côté `PluginDetails`, et ÉCHEC = RIEN. On ne
    /// renseigne pas `lastError` : un chiffre d'enrichissement manquant n'est
    /// pas une panne, il ne mérite pas un bandeau rouge.
    func loadTokenCost(for pluginID: String) {
        // Déjà connu, ou déjà en vol : la vue peut appeler ceci à chaque rendu
        // de ligne sans déclencher une pluie de spawns.
        guard tokenCosts[pluginID] == nil, !tokenCostInFlight.contains(pluginID) else { return }
        tokenCostInFlight.insert(pluginID)
        Task { [weak self] in await self?.loadTokenCostNow(pluginID) }
    }

    private func loadTokenCostNow(_ pluginID: String) async {
        defer { tokenCostInFlight.remove(pluginID) }
        guard let claude = await resolveClaudePath() else { return }

        // VÉRIFIÉ (CLI 2.1.220) : `details` accepte l'id COMPLET
        // (`security-pro@claude-code-templates`) COMME le nom court. On envoie
        // l'id complet d'abord, parce que le nom court est AMBIGU dès que deux
        // marketplaces fournissent le même nom (6 doublons réels ici) : la CLI
        // en choisit un, et on afficherait le coût du mauvais plugin. Repli sur
        // le nom court si un CLI plus ancien refusait la forme complète.
        let shortName = Self.splitIdentifier(pluginID).name
        var candidates = [pluginID]
        if shortName != pluginID { candidates.append(shortName) }

        for candidate in candidates {
            let outcome = await Self.run(
                arguments: ["plugin", "details", candidate],
                claude: claude,
                timeout: Self.detailsTimeout
            )
            guard outcome.status == 0 else { continue }
            let text = String(decoding: outcome.output, as: UTF8.self)
            guard let tokens = PluginDetails.alwaysOnTokens(from: text) else { continue }
            tokenCosts[pluginID] = tokens
            log.info("coût always-on de \(pluginID, privacy: .public) : \(tokens) tokens")
            return
        }
        // Rien trouvé : silence radio, la vue affiche « — ».
        log.debug("coût always-on indisponible pour \(pluginID, privacy: .public)")
    }

    // MARK: - Actions (JAMAIS automatiques)

    /// Active ou désactive un plugin via `claude plugin enable|disable`.
    /// Renvoie un message d'erreur, ou nil si tout s'est bien passé.
    ///
    /// APPEL SUR GESTE EXPLICITE UNIQUEMENT. Aucune heuristique d'Atoll ne doit
    /// appeler cette méthode : désactiver un plugin change ce que le CLI charge
    /// dans CHAQUE session de l'utilisateur, c'est sa décision, pas la nôtre.
    @discardableResult
    func setEnabled(_ enabled: Bool, pluginID: String) async -> String? {
        await perform(
            arguments: ["plugin", enabled ? "enable" : "disable", pluginID],
            pluginID: pluginID,
            timeout: Self.toggleTimeout,
            verb: enabled ? "Activation" : "Désactivation"
        )
    }

    /// Installe un plugin via `claude plugin install <id>`.
    /// Renvoie un message d'erreur, ou nil si tout s'est bien passé.
    ///
    /// APPEL SUR GESTE EXPLICITE UNIQUEMENT (⌘⏎ dans la fenêtre de revue, après
    /// avoir vu ce que le plugin exécute, son coût en tokens et sa popularité).
    @discardableResult
    func install(pluginID: String) async -> String? {
        await perform(
            arguments: ["plugin", "install", pluginID],
            pluginID: pluginID,
            timeout: Self.installTimeout,
            verb: "Installation"
        )
    }

    /// Tronc commun des mutations : garde de ré-entrance, spawn borné, relecture.
    private func perform(
        arguments: [String],
        pluginID: String,
        timeout: TimeInterval,
        verb: String
    ) async -> String? {
        // Garde de ré-entrance posée AVANT le premier await (piège vécu au
        // FleetLauncher : `isLaunching` posé après l'await laissait passer un
        // double-clic → deux `claude --bg`). Ici, deux `plugin enable`
        // concurrents réécriraient tous deux settings.json : mise à jour perdue.
        // La garde est GLOBALE (une seule mutation à la fois, tous plugins
        // confondus) — c'est voulu : on sérialise les écritures de la CLI.
        guard busyPluginID == nil else {
            log.debug("action ignorée sur \(pluginID, privacy: .public) : une autre est en cours")
            return nil
        }
        busyPluginID = pluginID
        defer { busyPluginID = nil }

        guard let claude = await resolveClaudePath() else {
            let message = "Binaire claude introuvable — \(verb.lowercased()) impossible."
            lastError = message
            return message
        }
        let outcome = await Self.run(arguments: arguments, claude: claude, timeout: timeout)
        guard outcome.status == 0 else {
            let message = Self.failureMessage(outcome, verb: verb)
            lastError = message
            log.error("\(verb, privacy: .public) de \(pluginID, privacy: .public) : \(outcome.diagnostic, privacy: .public)")
            return message
        }
        log.info("\(verb, privacy: .public) de \(pluginID, privacy: .public) : OK")
        lastError = nil
        // L'état a changé côté CLI → on RELIT. Jamais de mise à jour optimiste
        // locale : la CLI est l'autorité, et elle peut avoir fait autre chose
        // que ce qu'on croit (dépendance, marketplace, refus silencieux).
        // Sans réseau : `--available` reste une action explicite.
        await refreshNow(includeAvailable: false)
        return nil
    }

    // MARK: - Résolution du chemin de claude (identique au FleetPoller)

    private func resolveClaudePath() async -> String? {
        if let claudePath { return claudePath }
        // Chemin usuel de l'installeur natif : vérif CHEAP (pas de shell),
        // retentée à chaque fois (claude peut apparaître après coup).
        let common = ("~/.local/bin/claude" as NSString).expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: common) { claudePath = common; return common }
        // Login shell : COÛTEUX (source le profil) → EXACTEMENT une fois.
        guard !triedLoginResolve else { return nil }
        triedLoginResolve = true
        let resolved = await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "command -v claude"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            Self.armWatchdog(process, seconds: 10)
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            process.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (process.terminationStatus == 0 && !path.isEmpty
                    && FileManager.default.isExecutableFile(atPath: path)) ? path : nil
        }.value
        claudePath = resolved
        return resolved
    }

    // MARK: - Spawn borné

    /// Ce qu'a rendu une commande `claude plugin …`.
    private struct CommandOutcome {
        /// 0 = succès. -1 = le spawn lui-même a échoué.
        let status: Int32
        let output: Data
        let errorTail: String
        /// Tué par le watchdog (mort sur signal) — cas à distinguer d'une vraie
        /// erreur de la CLI dans le message rendu à l'utilisateur.
        let killedByWatchdog: Bool

        var diagnostic: String {
            killedByWatchdog ? "délai dépassé" : "exit \(status) — \(errorTail)"
        }
    }

    /// Exécute `claude plugin …` et rend sa sortie. Toujours borné par un
    /// watchdog (contrainte n°2), toujours via un shell de LOGIN (contrainte
    /// n°4), toujours marqué comme process interne d'Atoll (contrainte n°5).
    private static func run(
        arguments: [String],
        claude: String,
        timeout: TimeInterval
    ) async -> CommandOutcome {
        // Shell de LOGIN : un `claude` lancé directement depuis une app GUI est
        // muet (PATH/profil absents — piège vécu, documenté dans CLAUDE.md).
        // L'`unset` vient APRÈS le sourcing du profil pour garantir l'auth par
        // SOUSCRIPTION (une clé API dans l'env changerait le mode d'auth).
        // Tous les arguments sont échappés (FleetLaunch.shellQuote) : un id de
        // plugin vient d'un marketplace tiers, il n'a rien à faire non quoté
        // dans une ligne de commande.
        let shellCommand = "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; exec "
            + FleetLaunch.shellQuote(claude) + " "
            + arguments.map(FleetLaunch.shellQuote).joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", shellCommand]
        // ATOLL_RETROSPECTIVE=1 : marque le process comme INTERNE. Sans ça,
        // `SessionStore.reconcile()` prendrait ce `claude` pour une session
        // utilisateur et l'afficherait dans l'îlot (le marqueur d'env couvre
        // aussi le cas d'un redémarrage d'Atoll pendant la commande, où le
        // registre de pids serait perdu).
        var environment = ProcessInfo.processInfo.environment
        environment["ATOLL_RETROSPECTIVE"] = "1"
        process.environment = environment
        // Aucune commande `plugin` n'a besoin d'un stdin : le fermer évite de se
        // faire attendre indéfiniment par un prompt interactif.
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        guard (try? process.run()) != nil else {
            log.error("spawn impossible : claude plugin \(arguments.joined(separator: " "), privacy: .public)")
            return CommandOutcome(status: -1, output: Data(), errorTail: "", killedByWatchdog: false)
        }
        let pid = process.processIdentifier
        SessionStore.shared.registerInternalPid(pid)
        armWatchdog(process, seconds: timeout)

        // Les DEUX pipes drainés EN PARALLÈLE (contrainte n°3). En série, un
        // stderr saturé (~64 Ko de tampon noyau) bloque l'écrivain pour
        // toujours : la commande ne se termine jamais, stdout ne se ferme
        // jamais, et on attend le watchdog pour rien. Lectures BLOQUANTES sur
        // des tâches détachées : `readabilityHandler` est inopérant en
        // LSUIElement (piège vécu).
        async let outData: Data = Task.detached(priority: .utility) {
            (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
        }.value
        async let errData: Data = Task.detached(priority: .utility) {
            (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
        }.value
        let output = await outData
        let errorData = await errData
        await Task.detached(priority: .utility) { process.waitUntilExit() }.value
        SessionStore.shared.unregisterInternalPid(pid)

        // Mort sur signal = le watchdog a frappé (SIGTERM/SIGKILL). Heuristique
        // assumée : aucune autre source ne signale ces process.
        let killed = process.terminationReason == .uncaughtSignal
        return CommandOutcome(
            status: process.terminationStatus,
            output: output,
            errorTail: lastMeaningfulLine(errorData),
            killedByWatchdog: killed
        )
    }

    /// Tue un process qui dépasse `seconds` : SIGTERM, puis SIGKILL une seconde
    /// plus tard s'il s'accroche. Le terminate ferme les pipes → `readToEnd`
    /// retourne et l'appelant reprend la main.
    nonisolated private static func armWatchdog(_ process: Process, seconds: TimeInterval) {
        let pid = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    // MARK: - Lecture défensive de la sortie

    /// Décode `plugin list --json`, en tolérant du bruit AVANT le JSON : un
    /// `.zprofile` bavard écrit sur stdout du shell de login (piège vécu avec la
    /// rétrospective). Deuxième essai depuis le premier `[` ou `{`.
    private static func decodeTolerant(_ data: Data) -> PluginSnapshot? {
        if let snapshot = PluginSnapshot.decode(data) { return snapshot }
        let openers: [UInt8] = [UInt8(ascii: "["), UInt8(ascii: "{")]
        guard let start = data.firstIndex(where: { openers.contains($0) }) else { return nil }
        guard start != data.startIndex else { return nil } // déjà tenté tel quel
        return PluginSnapshot.decode(Data(data[start...]))
    }

    /// `<nom>@<marketplace>` → ses deux moitiés, découpe sur le DERNIER `@`.
    ///
    /// Doublon assumé de `PluginSnapshot.splitIdentifier`, qui est INTERNE à
    /// AtollCore (et le reste : ce fichier n'a pas à faire évoluer l'API du
    /// package). Trois lignes, même règle, testée là-bas.
    private static func splitIdentifier(_ id: String) -> (name: String, marketplace: String?) {
        guard let at = id.lastIndex(of: "@") else { return (id, nil) }
        let name = String(id[id.startIndex..<at])
        let marketplace = String(id[id.index(after: at)...])
        guard !name.isEmpty, !marketplace.isEmpty else { return (id, nil) }
        return (name, marketplace)
    }

    /// Dernière ligne non vide d'un flux d'erreur, capée — de quoi dire à
    /// l'utilisateur ce qui a cloché sans lui déverser une trace entière.
    private static func lastMeaningfulLine(_ data: Data) -> String {
        let text = String(decoding: data.suffix(4000), as: UTF8.self)
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }

    /// Message d'échec lisible. La CLI écrit parfois ses erreurs sur STDOUT
    /// (vérifié : « Plugin "x" not found. » y arrive) → on regarde les deux.
    private static func failureMessage(_ outcome: CommandOutcome, verb: String) -> String {
        if outcome.killedByWatchdog { return "\(verb) : délai dépassé, commande interrompue." }
        if outcome.status == -1 { return "\(verb) : impossible de lancer claude." }
        if !outcome.errorTail.isEmpty { return "\(verb) : \(outcome.errorTail)" }
        let stdoutTail = lastMeaningfulLine(outcome.output)
        if !stdoutTail.isEmpty { return "\(verb) : \(stdoutTail)" }
        return "\(verb) : échec (code \(outcome.status))."
    }

    // MARK: - Debug

    #if DEBUG
    /// Injecte un inventaire factice complet — installés/activés, désactivés,
    /// cassés, doublons entre deux marketplaces, catalogue disponible — pour
    /// travailler l'UI et faire des captures d'écran SANS réseau et sans
    /// dépendre de l'état réel de la machine. N'écrit rien nulle part.
    func debugSeedSnapshot() {
        func installed(
            _ id: String,
            enabled: Bool = false,
            version: String? = "1.0.0",
            broken: Bool = false,
            mcp: [String] = []
        ) -> InstalledPlugin {
            let (name, marketplace) = Self.splitIdentifier(id)
            return InstalledPlugin(
                id: id,
                name: name,
                marketplace: marketplace,
                version: version,
                scope: "user",
                isEnabled: enabled,
                installPath: "/Users/demo/.claude/plugins/cache/\(marketplace ?? "local")/\(name)",
                hasLoadError: broken,
                mcpServerNames: mcp
            )
        }
        func available(_ id: String, _ description: String, installs: Int?) -> AvailablePlugin {
            let (name, marketplace) = Self.splitIdentifier(id)
            return AvailablePlugin(
                id: id,
                name: name,
                description: description,
                marketplace: marketplace,
                version: "1.0.0",
                installCount: installs
            )
        }

        let seeded = PluginSnapshot(
            installed: [
                installed("swift-lsp@claude-plugins-official", enabled: true),
                installed("clangd-lsp@claude-plugins-official", enabled: true),
                // Activé ET cassé : le cas le plus grave à montrer.
                installed("security-pro@claude-code-templates", enabled: true, broken: true),
                // Activé et démarrant des serveurs MCP (coût réel, invisible).
                installed("context7@claude-plugins-official", enabled: true, version: "unknown", mcp: ["context7"]),
                // Installé mais jamais activé (le gros du troupeau).
                installed("code-review@claude-plugins-official", version: "unknown"),
                installed("playwright@claude-plugins-official", version: "unknown", mcp: ["playwright"]),
                // Doublon : même nom, deux marketplaces.
                installed("feature-dev@claude-code-plugins"),
                installed("feature-dev@claude-plugins-official", version: "unknown"),
                // Désactivé et cassé.
                installed("legacy-tools@claude-code-templates", broken: true)
            ],
            available: [
                available("supabase-toolkit@claude-code-templates", "Complete Supabase workflow with specialized commands, data engineering agents, and MCP integrations", installs: 4213),
                available("docs-writer@claude-plugins-official", "Génère et maintient la documentation d'un dépôt", installs: 1890),
                available("perf-lab@claude-code-plugins", "Profilage et budget de performance", installs: 42),
                available("obscure-thing@random-marketplace", "Sans compteur d'installations : « inconnu » se classe en dernier", installs: nil)
            ]
        )
        snapshot = seeded
        // Coûts factices : de « gratuit » à « cher », et un plugin dont le coût
        // reste inconnu (absent du dictionnaire) pour tester l'affichage « — ».
        tokenCosts = [
            "swift-lsp@claude-plugins-official": 0,
            "clangd-lsp@claude-plugins-official": 0,
            "security-pro@claude-code-templates": 1221,
            "context7@claude-plugins-official": 233,
            "feature-dev@claude-code-plugins": 688
        ]
        lastRefreshedAt = Date()
        lastError = nil
        isRefreshing = false
        busyPluginID = nil
        log.debug("inventaire factice injecté (\(seeded.installed.count) installés)")
    }
    #endif
}
