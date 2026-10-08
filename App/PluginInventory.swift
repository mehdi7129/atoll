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
    /// LA DEMANDE, un `claude plugin details` par plugin, avec au plus deux
    /// lectures simultanées, y compris depuis le bouton collectif.
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
    private struct CostVersion: Equatable {
        let version: String?
        let marketplace: String?
        let scope: String?
        let path: String?
        init(_ plugin: InstalledPlugin) {
            version = plugin.version; marketplace = plugin.marketplace
            scope = plugin.scope; path = plugin.installPath
        }
    }
    private struct CostRequest {
        let id: String
        let version: CostVersion
        let token = UUID()
        let generation: UUID
    }
    @ObservationIgnored private var costQueue: [CostRequest] = []
    @ObservationIgnored private var activeCosts: [String: CostRequest] = [:]
    @ObservationIgnored private let detailConcurrencyLimit: Int
    @ObservationIgnored private var operationGeneration = UUID()

    /// Injection réservée aux recettes hors ligne ; aucun réglage produit ajouté.
    init(claudePath: String? = nil, detailConcurrencyLimit: Int = 2) {
        self.claudePath = claudePath
        self.detailConcurrencyLimit = max(1, min(2, detailConcurrencyLimit))
    }

    // MARK: - Délais (contrainte n°2 : TOUT spawn est borné)
    //
    // La deadline couvre résolution, processus et collecte. Les drains sont
    // non bloquants ; un descendant ne peut garder la lecture ouverte après
    // la sortie du parent. Les signaux passent par l'identité de l'enfant.

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

    private func refreshNow(includeAvailable: Bool, searchScope: UUID? = nil) async {
        guard !isRefreshing else { return }
        let generation = operationGeneration
        isRefreshing = true // AVANT le premier await (sinon la garde ne garde rien)
        defer { isRefreshing = false }
        let timeout = includeAvailable ? Self.availableTimeout : Self.listTimeout
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))

        guard let claude = await resolveClaudePath(deadline: deadline) else {
            lastError = "Binaire claude introuvable."
            return
        }
        guard generation == operationGeneration,
              searchScope == nil || searchScope == searchGeneration else { return }
        var arguments = ["plugin", "list", "--json"]
        if includeAvailable { arguments.insert("--available", at: 2) }

        let outcome = await Self.run(
            arguments: arguments,
            claude: claude,
            timeout: BoundedProcessRunner.remaining(until: deadline),
            scope: searchScope
        )
        guard generation == operationGeneration,
              searchScope == nil || searchScope == searchGeneration else { return }
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
        tokenCosts = tokenCosts.filter {
            let previous = costVersion(for: $0.key, in: snapshot)
            let current = costVersion(for: $0.key, in: merged)
            return current != nil && current == previous
        }
        costQueue.removeAll { costVersion(for: $0.id, in: merged) != $0.version }
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
        guard tokenCosts[pluginID] == nil, let version = costVersion(for: pluginID, in: snapshot),
              activeCosts[pluginID]?.version != version,
              !costQueue.contains(where: { $0.id == pluginID && $0.version == version }) else { return }
        costQueue.removeAll { $0.id == pluginID }
        costQueue.append(CostRequest(id: pluginID, version: version, generation: operationGeneration))
        startQueuedCosts()
    }

    private func costVersion(for id: String, in snapshot: PluginSnapshot?) -> CostVersion? {
        snapshot?.installed.first(where: { $0.id == id }).map(CostVersion.init)
    }

    private func isCurrent(_ request: CostRequest) -> Bool {
        request.generation == operationGeneration && costVersion(for: request.id, in: snapshot) == request.version
    }

    /// FIFO bornée ; un ancien résultat peut finir pendant qu'une nouvelle
    /// version attend, mais jamais deux lectures simultanées du même identifiant.
    private func startQueuedCosts() {
        while activeCosts.count < detailConcurrencyLimit,
              let index = costQueue.firstIndex(where: { activeCosts[$0.id] == nil }) {
            let request = costQueue.remove(at: index)
            guard isCurrent(request) else { continue }
            activeCosts[request.id] = request
            Task { [weak self] in await self?.loadTokenCostNow(request) }
        }
    }

    private func loadTokenCostNow(_ request: CostRequest) async {
        let pluginID = request.id
        // Deux essais au plus (id complet puis nom), avec une seule enveloppe
        // de temps incluant la résolution du binaire et la collecte des pipes.
        let deadline = ContinuousClock.now.advanced(by: .seconds(Self.detailsTimeout * 2))
        defer {
            if activeCosts[pluginID]?.token == request.token { activeCosts[pluginID] = nil }
            startQueuedCosts()
        }
        guard let claude = await resolveClaudePath(deadline: deadline) else { return }
        guard isCurrent(request), !Task.isCancelled else { return }

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
                timeout: min(Self.detailsTimeout, BoundedProcessRunner.remaining(until: deadline)),
                scope: request.token
            )
            guard isCurrent(request), !Task.isCancelled else { return }
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
        // lanceur de tâches, retiré depuis : un drapeau posé APRÈS l'await
        // laissait passer un double-clic → deux processus). Ici, deux `plugin enable`
        // concurrents réécriraient tous deux settings.json : mise à jour perdue.
        // La garde est GLOBALE (une seule mutation à la fois, tous plugins
        // confondus) — c'est voulu : on sérialise les écritures de la CLI.
        guard busyPluginID == nil else {
            log.debug("action ignorée sur \(pluginID, privacy: .public) : une autre est en cours")
            // Une action ignorée n'est PAS un succès : le dire (piège de la
            // Phase 9, « stop fire-and-forget qui ment sur son résultat »).
            return "Une autre action plugin est en cours."
        }
        busyPluginID = pluginID
        defer { busyPluginID = nil }
        let generation = operationGeneration
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))

        guard let claude = await resolveClaudePath(deadline: deadline) else {
            let message = "Binaire claude introuvable — \(verb.lowercased()) impossible."
            lastError = message
            return message
        }
        guard generation == operationGeneration, !Task.isCancelled else { return "Action annulée." }
        let outcome = await Self.run(arguments: arguments, claude: claude,
                                     timeout: BoundedProcessRunner.remaining(until: deadline))
        guard generation == operationGeneration, !Task.isCancelled else { return "Action annulée." }
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
        //
        // ATTENDRE d'abord un rafraîchissement en vol. `refreshNow` sort
        // immédiatement sur sa garde de ré-entrance : la relecture n'avait alors
        // PAS lieu, et le rafraîchissement concurrent — parti AVANT la mutation,
        // donc porteur de l'état d'AVANT — publiait ensuite son instantané en
        // posant `lastRefreshedAt = Date()`. Le panneau affichait un inventaire
        // périmé avec l'heure courante : précisément ce que cet horodatage a été
        // ajouté pour empêcher. Le motif d'attente existe déjà dans `search()`,
        // et pour la même raison.
        while isRefreshing {
            try? await Task.sleep(for: .milliseconds(300))
            guard generation == operationGeneration, !Task.isCancelled else { return "Action annulée." }
        }
        await refreshNow(includeAvailable: false)
        return nil
    }

    // MARK: - Résolution du chemin de claude (identique au FleetPoller)

    private func resolveClaudePath(deadline: ContinuousClock.Instant) async -> String? {
        if let claudePath { return claudePath }
        // Chemin usuel de l'installeur natif : vérif CHEAP (pas de shell),
        // retentée à chaque fois (claude peut apparaître après coup).
        let common = ("~/.local/bin/claude" as NSString).expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: common) { claudePath = common; return common }
        // Login shell : COÛTEUX (source le profil) → EXACTEMENT une fois.
        guard !triedLoginResolve else { return nil }
        triedLoginResolve = true
        let resolved = await { () async -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "command -v claude"]
            process.standardInput = FileHandle.nullDevice
            guard let result = try? await BoundedProcessRunner.run(process,
                timeout: min(10, BoundedProcessRunner.remaining(until: deadline)),
                stdoutCap: 16_384, stderrCap: 0), result.succeeded else { return nil }
            let path = String(decoding: result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (!path.isEmpty && FileManager.default.isExecutableFile(atPath: path)) ? path : nil
        }()
        claudePath = resolved
        return resolved
    }

    // MARK: - Recherche par besoin

    /// Résultat de la dernière recherche « quel plugin répond à ce besoin ? ».
    /// Vidé à chaque nouvelle recherche.
    private(set) var searchMatches: [PluginSearchResult.Match] = []
    private(set) var isSearching = false
    @ObservationIgnored private var searchGeneration = UUID()
    @ObservationIgnored private var activeSearchProvider: AgentProvider?

    /// Les commandes `claude plugin` en vol — pour les arrêter à la fermeture.
    ///
    /// Boîte à verrou plutôt que propriété d'instance : le spawn se fait dans
    /// une fonction `static`, hors du MainActor, et peut être concurrent d'un
    /// autre appel (une recherche pendant un « Actualiser »).
    final class InFlight: @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [(process: Process, identity: ProcessIdentity?, scope: UUID?)] = []

        func adopt(_ process: Process, identity: ProcessIdentity?, scope: UUID?) {
            lock.lock(); defer { lock.unlock() }
            processes.append((process, identity, scope))
        }

        func release(_ process: Process) {
            lock.lock(); defer { lock.unlock() }
            processes.removeAll { $0.process === process }
        }

        /// SIGTERM à tout ce qui tourne, puis SIGKILL une seconde plus tard aux
        /// survivants — et seulement si le pid vit ENCORE (ne jamais tirer sur
        /// un pid recyclé, même garde que les deux autres escalades du projet).
        func terminate(scope: UUID? = nil) {
            lock.lock()
            let identities = processes.filter {
                $0.process.isRunning && (scope == nil || $0.scope == scope)
            }.compactMap { $0.identity }
            lock.unlock()
            identities.forEach { ProcessInspector.signal(SIGTERM, to: $0) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                identities.forEach { ProcessInspector.signal(SIGKILL, to: $0) }
            }
        }
    }

    @ObservationIgnored static let inFlight = InFlight()

    /// Arrête les commandes en vol. Appelé par `applicationWillTerminate` : la
    /// recherche de plugins est un `claude -p` FACTURÉ, il ne doit pas survivre
    /// à l'app qui l'a lancé.
    func cancel() {
        operationGeneration = UUID()
        costQueue.removeAll()
        searchGeneration = UUID()
        Self.inFlight.terminate()
    }

    /// Le bouton Annuler ne concerne que la recherche et sa lecture éventuelle
    /// du catalogue. Une installation ou estimation indépendante continue.
    func cancelSearch() {
        let scope = searchGeneration
        searchGeneration = UUID()
        Self.inFlight.terminate(scope: scope)
    }

    func cancelIfCodex() {
        guard activeSearchProvider == .codex else { return }
        cancelSearch()
    }

    /// Compare un besoin exprimé en français au catalogue PUBLIC des plugins.
    ///
    /// Deux gardes qui comptent :
    /// - le catalogue est chargé d'abord (`--available`, réseau) — sans lui, il
    ///   n'y a rien à comparer ;
    /// - `PluginSearchResult.parse` DROPPE tout id absent du catalogue : une
    ///   hallucination du modèle ne doit jamais devenir une commande
    ///   d'installation. C'est la garde centrale de cette fonction.
    func search(need: String, useAI: Bool = false) async -> String? {
        let trimmed = need.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSearching else { return nil }
        let generation = UUID()
        searchGeneration = generation
        isSearching = true
        searchMatches = []
        var execution: AnalysisExecution?
        var lease: UUID?
        var resultLabel = "cancelled"
        defer {
            if let lease { AnalysisBudget.shared.finish(lease, outcome: resultLabel) }
            activeSearchProvider = nil
            isSearching = false
        }
        // L'exécuteur, son modèle et son home sont figés AVANT le catalogue async.
        if useAI {
            do {
                let plan = try AnalysisExecution.capture(kind: .pluginSearch)
                lease = try AnalysisBudget.shared.begin(plan, kind: .pluginSearch, destination: .claude)
                execution = plan
                activeSearchProvider = plan.provider
            } catch { return error.localizedDescription }
        }
        if snapshot?.available.isEmpty ?? true {
            while isRefreshing {
                try? await Task.sleep(for: .milliseconds(100))
                guard generation == searchGeneration, !Task.isCancelled else { return "Recherche annulée." }
            }
            if snapshot?.available.isEmpty ?? true {
                await refreshNow(includeAvailable: true, searchScope: generation)
            }
        }
        guard generation == searchGeneration, !Task.isCancelled else { return "Recherche annulée." }
        guard let snapshot, !snapshot.available.isEmpty else {
            resultLabel = "catalogueUnavailable"
            return "Catalogue des plugins Claude indisponible."
        }
        guard let execution, let lease else {
            let terms = Set(trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count >= 3 }.map(String.init))
            searchMatches = snapshot.available.compactMap { plugin -> (Int, PluginSearchResult.Match)? in
                let text = "\(plugin.id) \(plugin.description ?? "")"
                    .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                let score = terms.filter { text.contains($0) }.count
                guard score > 0 else { return nil }
                return (score, .init(pluginID: plugin.id, reason: "Correspondance locale dans le catalogue Claude.",
                                    confidence: "medium"))
            }.sorted { $0.0 == $1.0 ? $0.1.pluginID < $1.1.pluginID : $0.0 > $1.0 }
                .prefix(3).map { $0.1 }
            return searchMatches.isEmpty ? "Aucune correspondance locale. L'analyse IA reste facultative." : nil
        }
        let catalog = snapshot.promptCatalog()
        let prompt = PluginSearchPrompt.userPrompt(need: trimmed, catalog: catalog.text)
        let fullPrompt = CodexExecPlan.fullPrompt(system: PluginSearchPrompt.systemPrompt, user: prompt)
        AnalysisBudget.shared.updateMetrics(lease, promptCharacters: execution.provider == .codex
            ? fullPrompt.count : PluginSearchPrompt.systemPrompt.count + prompt.count)
        let launch: CodexRun.Launch?
        if execution.provider == .codex {
            launch = await CodexRun.prepare(schema: PluginSearchPrompt.jsonSchema,
                prompt: fullPrompt,
                label: "plugins", home: execution.home, model: execution.model,
                executableOverride: execution.executableOverride)
        } else {
            launch = await CodexRun.prepareClaude(arguments:
                PluginSearchPrompt.cliArguments(model: execution.model, budgetUSD: 0.30) + [prompt], label: "plugins")
        }
        guard let launch else {
            resultLabel = "preparationFailed"
            return CodexRun.lastFailure ?? "Préparation impossible."
        }
        defer { launch.cleanUp() }
        guard generation == searchGeneration, !Task.isCancelled else { return "Recherche annulée." }
        let outcome = await Self.run(arguments: [], claude: "", timeout: 120, launch: launch,
            scope: generation,
            beforeSpawn: {
                guard generation == self.searchGeneration && !Task.isCancelled,
                      AnalysisBudget.shared.mayLaunch(lease, context: execution) else { return false }
                do { try AnalysisBudget.shared.prepareToLaunch(lease); return true }
                catch { return false }
            }, onSpawn: { process in
                AnalysisBudget.shared.launched(lease)
            })
        AnalysisBudget.shared.recordUsage(lease, stdout: outcome.output)
        guard generation == searchGeneration, !Task.isCancelled else { return "Recherche annulée." }
        resultLabel = "exit(\(outcome.status))"
        guard outcome.status == 0 else { return "Recherche impossible : \(outcome.diagnostic)" }
        let result: PluginSearchResult?
        if let file = launch.outputFile, let data = BoundedProcessOutput.file(at: file, cap: 1_048_576) {
            result = PluginSearchResult.parse(codexOutput: data, knownIDs: catalog.shownIDs)
        } else if launch.outputFile == nil {
            result = Self.parseSearchTolerant(outcome.output, knownIDs: catalog.shownIDs)
        } else { result = nil }
        guard let result else { resultLabel = "invalidOutput"; return "Réponse inexploitable." }
        searchMatches = result.matches
        resultLabel = "success"
        return result.matches.isEmpty ? "Aucun plugin ne correspond." : nil
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
        timeout: TimeInterval,
        launch: CodexRun.Launch? = nil,
        scope: UUID? = nil,
        beforeSpawn: (() -> Bool)? = nil,
        onSpawn: ((Process) -> Void)? = nil
    ) async -> CommandOutcome {
        // Shell de LOGIN : un `claude` lancé directement depuis une app GUI est
        // muet (PATH/profil absents — piège vécu, documenté dans CLAUDE.md).
        // L'`unset` vient APRÈS le sourcing du profil pour garantir l'auth par
        // SOUSCRIPTION (une clé API dans l'env changerait le mode d'auth).
        // Tous les arguments sont échappés (FleetLaunch.shellQuote) : un id de
        // plugin vient d'un marketplace tiers, il n'a rien à faire non quoté
        // dans une ligne de commande.
        let shellCommand = launch?.shellCommand ?? ("unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; exec "
            + FleetLaunch.shellQuote(claude) + " "
            + arguments.map(FleetLaunch.shellQuote).joined(separator: " "))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", shellCommand]
        process.currentDirectoryURL = launch?.workspace
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

        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, timeout)))
        guard timeout > 0, !Task.isCancelled, beforeSpawn?() ?? true else {
            return CommandOutcome(status: -1, output: Data(), errorTail: "", killedByWatchdog: timeout <= 0)
        }
        let identity: ProcessIdentity?
        do { identity = try ProcessInspector.launchOwned(process) }
        catch {
            log.error("spawn impossible : claude plugin \(arguments.joined(separator: " "), privacy: .public)")
            return CommandOutcome(status: -1, output: Data(), errorTail: "", killedByWatchdog: false)
        }
        onSpawn?(process)
        let pid = process.processIdentifier
        SessionStore.shared.registerInternalPid(pid)
        Self.inFlight.adopt(process, identity: identity, scope: scope)
        defer {
            Self.inFlight.release(process)
            SessionStore.shared.unregisterInternalPid(pid)
        }
        let result = await BoundedProcessRunner.collect(process: process, stdout: stdout, stderr: stderr,
            identity: identity, deadline: deadline, stdoutCap: 4_194_304, stderrCap: 4000)
        return CommandOutcome(status: result.succeeded ? 0 : (result.status == 0 ? 1 : result.status ?? -1),
                              output: result.stdout, errorTail: lastMeaningfulLine(result.stderr),
                              killedByWatchdog: result.timedOut)
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

    /// Idem pour la sortie de la RECHERCHE (`claude -p`), qui subit le même
    /// bruit de shell de login.
    private static func parseSearchTolerant(_ data: Data,
                                            knownIDs: Set<String>) -> PluginSearchResult? {
        if let result = PluginSearchResult.parse(cliOutput: data, knownIDs: knownIDs) { return result }
        guard let start = data.firstIndex(of: UInt8(ascii: "{")), start != data.startIndex else {
            return nil
        }
        return PluginSearchResult.parse(cliOutput: Data(data[start...]), knownIDs: knownIDs)
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
