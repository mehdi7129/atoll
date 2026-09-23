import Foundation
import Observation
import OSLog
import AtollCore
import Darwin

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "curation")

/// Curation périodique des notes mémoire (Milestone B) : un `claude -p`
/// STRICTEMENT sans outils relit toutes les notes accumulées et propose un jeu
/// CONSOLIDÉ ; Atoll archive l'existant, vérifie l'archive, puis remplace.
///
/// Pourquoi c'est nécessaire : chaque rétrospective ajoute ses notes sans
/// jamais relire les précédentes — au bout de quelques dizaines de sessions la
/// mémoire se répète, se contredit et le recall remonte des redites.
///
/// Garde-fous, dans l'ordre où ils s'appliquent (chacun peut ANNULER le
/// cycle sans rien toucher) :
/// 1. opt-in explicite (réglage) et jamais deux runs à la fois (garde de
///    ré-entrance posée AVANT le premier `await` — piège vécu en Phase 9) ;
/// 2. moins de 2 notes → rien à consolider ;
/// 3. corpus au-dessus du budget de prompt → REFUS (jamais de troncature :
///    curer un sous-ensemble remplacerait TOUTE la mémoire par lui) ;
/// 4. quota 5 h au-dessus du seuil d'apprentissage → reporté ;
/// 5. sortie du modèle inexploitable, vide ou rétrécissant trop
///    (`NotesCurationPlanner`) → refus, l'existant reste intact ;
/// 6. archive incomplète (nombre de fichiers ou octets différents) → ABANDON
///    avant la moindre suppression.
///
/// Les contradictions repérées ne sont JAMAIS tranchées : elles remontent en
/// avertissements dans les Réglages.
@MainActor
@Observable
final class NotesCurationService {
    static let shared = NotesCurationService()

    enum Phase: Equatable { case idle, running }

    private(set) var phase: Phase = .idle
    /// Résumé lisible du dernier cycle (affiché dans les Réglages).
    private(set) var lastOutcome: String?
    private(set) var lastRunAt: Date?
    /// Contradictions signalées par le dernier cycle réussi — informatives.
    private(set) var warnings: [String] = []

    /// Branchement vers l'index mémoire : (anciens chemins oubliés, nouvelles
    /// notes indexées). Injecté par l'AppDelegate, comme `noteSink`.
    @ObservationIgnored var onNotesReplaced: (([String], [URL]) -> Void)?

    /// Dernier `claude -p` RÉELLEMENT lancé par la curation.
    ///
    /// `lastRunAt` ne convient pas pour borner la dépense : il est posé au
    /// simple ARMEMENT de l'option hebdomadaire, et avancé par des cycles qui
    /// n'ont rien lancé (corpus trop gros, moins de deux notes). Le seul créneau
    /// de la fenêtre de 5 h était donc consommé par un non-événement, et le clic
    /// explicite restait mort cinq heures — exactement ce que la tolérance
    /// devait débloquer (revue des corrections, 2026-07-27). En mémoire à
    /// dessein : après un redémarrage, on redonne sa chance à l'utilisateur.
    @ObservationIgnored private var lastSpendAt: Date?
    @ObservationIgnored private var process: Process?
    /// Cause exacte du dernier échec de sous-processus (affichée telle quelle).
    @ObservationIgnored private var spawnFailure: String?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?
    @ObservationIgnored private var cycleTask: Task<Void, Never>?
    @ObservationIgnored private var runGeneration = UUID()
    @ObservationIgnored private var processIdentity: ProcessIdentity?
    @ObservationIgnored private var activeExecution: AnalysisExecution?
    @ObservationIgnored private var activeLease: UUID?
    @ObservationIgnored private var activeManual = true
    @ObservationIgnored private var runLaunched = false
    @ObservationIgnored private var lastSuccessfulCorpus: CurationCorpusFingerprint?
    private(set) var retryAt: Date?

    private static let timeoutSeconds: TimeInterval = 600
    nonisolated private static let stdoutCapBytes = 4 * 1024 * 1024
    /// Cadence de la vérification « est-ce dû ? » quand l'automatique est actif.
    private static let schedulerTickSeconds: TimeInterval = 15 * 60

    private init() {
        let state = Self.loadState()
        lastRunAt = state.lastRunAt
        lastOutcome = state.lastOutcome
        warnings = state.warnings
        retryAt = state.retryAt
        lastSuccessfulCorpus = state.lastSuccessfulCorpus
    }

    // MARK: - Planification

    /// Démarre/arrête la boucle hebdomadaire selon le réglage (pattern
    /// `MemoryIndexer.syncWithSettings`). Idempotent.
    func syncWithSettings() {
        guard LearningSettings.shared.isCurationScheduled else {
            schedulerTask?.cancel()
            schedulerTask = nil
            if !activeManual, cycleTask != nil { cancel() }
            return
        }
        guard schedulerTask == nil else { return }
        // ARMER N'EST PAS LANCER (revue) : sans échéance connue, cocher la
        // case aurait déclenché sur-le-champ un `claude -p` qui réécrit toutes
        // les notes. La première échéance part de maintenant ; pour curer
        // tout de suite, il y a le bouton juste à côté.
        if lastRunAt == nil {
            lastRunAt = Date()
            persistState()
        }
        schedulerTask = Task { [weak self] in
            while !Task.isCancelled {
                // Premier tour immédiat : une curation due pendant qu'Atoll
                // était fermé se rattrape au lancement suivant.
                self?.runIfDue()
                try? await Task.sleep(for: .seconds(Self.schedulerTickSeconds))
            }
        }
    }

    /// Lance un cycle si l'échéance est passée (et si le réglage est actif).
    func runIfDue() {
        guard LearningSettings.shared.isCurationScheduled else { return }
        if let retryAt, retryAt > Date() { return }
        let interval = LearningSettings.curationIntervalDays * 86_400
        if let lastRunAt, Date().timeIntervalSince(lastRunAt) < interval { return }
        curateNow(manual: false)
    }

    /// Déclenchement explicite (bouton des Réglages) — ignore l'échéance mais
    /// PAS les autres garde-fous.
    func curateNow(manual: Bool = true) {
        guard phase == .idle, process == nil, cycleTask == nil else {
            log.info("curation déjà en cours — demande ignorée")
            return
        }
        // Jamais DEUX `claude -p` d'Atoll en même temps (revue) : la
        // rétrospective est déclenchée par un événement (fin de session), la
        // curation est périodique — c'est elle qui cède le pas.
        guard RetrospectiveRunner.shared.phase == .idle else {
            log.info("rétrospective en cours — curation reportée")
            lastOutcome = "reportée (une rétrospective tourne)"
            return
        }
        // Ré-entrance : la garde est posée AVANT le premier await (un
        // double-clic lançait deux `claude` en Phase 9).
        phase = .running
        activeManual = manual
        // L'annulation peut arriver avant le premier tour de la Task : elle
        // ne doit pas reprendre le drapeau de dépense du cycle précédent.
        runLaunched = false
        lastOutcome = nil
        let generation = UUID()
        runGeneration = generation
        cycleTask = Task {
            defer { cycleTask = nil }
            await run(manual: manual, generation: generation)
            if runGeneration != generation { phase = .idle; lastOutcome = "analyse annulée" }
        }
    }

    /// Kill-switch : arrêt immédiat avec escalade SIGTERM → SIGKILL.
    /// `phase` revient à `.idle` (revue) : sinon un `cancel()` sans processus
    /// en vol laissait le service bloqué en « running » pour toujours.
    func cancelIfCodex() {
        if activeExecution?.provider == .codex { cancel() }
    }

    func cancel() {
        runGeneration = UUID()
        if cycleTask != nil {
            // Persisté AVANT le signal, pas dans le retour asynchrone : la
            // fermeture d'Atoll n'attend pas ce retour. Une analyse déjà
            // lancée consomme son échéance ; une préparation attend 30 min.
            recordOutcome("analyse annulée", touched: false)
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        terminateWithEscalation()
        if process == nil { phase = .idle }
    }

    private func terminateWithEscalation() {
        guard let identity = processIdentity else { return }
        ProcessInspector.signal(SIGTERM, to: identity)
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(5))
            ProcessInspector.signal(SIGKILL, to: identity)
        }
    }

    // MARK: - Cycle

    private func run(manual: Bool, generation: UUID) async {
        guard runGeneration == generation, !Task.isCancelled else { return }
        runLaunched = false
        // Le checkpoint permet de distinguer une bascule interrompue d'un
        // changement externe. Un doute conserve toutes les pièces, avant le
        // réparateur historique et son balayage des stagings.
        do { try Self.recoverCheckpointSwap() }
        catch {
            finish(outcome: "reprise locale impossible : résultat sauvegardé illisible ou bascule interrompue ambiguë — aucune nouvelle analyse",
                   touched: false, preserveWarnings: true)
            return
        }
        Self.repairInterruptedSwap()
        Self.sweepStagingLeaks() // débris d'un run interrompu
        let notes = Self.readNotes()
        // Le résultat payé passe AVANT toute capture d'auth/modèle ou de quota.
        // Un cache illisible n'autorise pas à repayer silencieusement l'analyse.
        if await resumePending(notes: notes, manual: manual, generation: generation) { return }
        guard runGeneration == generation, !Task.isCancelled else { return }
        guard notes.count >= 2 else {
            finish(outcome: "rien à consolider (\(notes.count) note(s))", touched: false, retry: false)
            return
        }
        guard NotesCurationPrompt.fitsBudget(notes: notes) else {
            // Refus ASSUMÉ : tronquer ferait remplacer toute la mémoire par la
            // consolidation d'un échantillon.
            let size = NotesCurationPrompt.corpusCharacterCount(notes: notes)
            log.error("corpus de notes trop volumineux (\(size) caractères) — curation refusée")
            finish(outcome: "corpus trop volumineux (\(size) caractères) — curation refusée",
                   touched: false, retry: false)
            return
        }
        if !manual, lastSuccessfulCorpus == CurationCorpusFingerprint(notes: notes) {
            finish(outcome: "notes inchangées depuis le dernier rangement — analyse évitée",
                   touched: false, retry: false, preserveWarnings: true)
            return
        }
        let execution: AnalysisExecution
        let lease: UUID
        do {
            execution = try AnalysisExecution.capture(kind: .curation)
            lease = try AnalysisBudget.shared.begin(execution, kind: .curation)
        } catch {
            finish(outcome: error.localizedDescription, touched: false)
            return
        }
        activeExecution = execution
        activeLease = lease
        defer {
            AnalysisBudget.shared.finish(lease, outcome: lastOutcome ?? "cancelled")
            activeExecution = nil
            activeLease = nil
        }
        let provider = execution.provider
        let userPrompt = NotesCurationPrompt.userPrompt(notes: notes)
        AnalysisBudget.shared.updateMetrics(lease, promptCharacters: provider == .codex
            ? CodexExecPlan.fullPrompt(system: NotesCurationPrompt.systemPrompt, user: userPrompt).count
            : NotesCurationPrompt.systemPrompt.count + userPrompt.count)
        var parsed: NotesCurationOutput?
        switch provider {
        case .claude:
            let arguments = NotesCurationPrompt.cliArguments(
                model: execution.model,
                budgetUSD: LearningSettings.budgetUSD
            ) + [userPrompt]
            guard let launch = await CodexRun.prepareClaude(arguments: arguments, label: "curation") else {
                guard runGeneration == generation else { return }
                finish(outcome: CodexRun.lastFailure ?? "Analyse indisponible.", touched: false)
                return
            }
            defer { launch.cleanUp() }
            guard let output = await spawnShell(command: launch.shellCommand, generation: generation,
                                                workingDirectory: launch.workspace) else {
                guard runGeneration == generation else { return }
                finish(outcome: spawnFailure ?? "échec du lancement de l'analyse", touched: false)
                return
            }
            // Un .zprofile bavard peut précéder le JSON (shell de login) : on
            // retente depuis la première accolade, comme la rétrospective.
            parsed = NotesCurationOutput.parse(cliOutput: output)
            if parsed == nil, let brace = output.firstIndex(of: UInt8(ascii: "{")) {
                parsed = NotesCurationOutput.parse(cliOutput: Data(output[brace...]))
            }
        case .codex:
            // Codex ÉCRIT son rapport dans un fichier au lieu de l'imprimer :
            // stdout ne porte que son journal d'événements.
            guard let launch = await CodexRun.prepare(
                schema: NotesCurationPrompt.jsonSchema,
                prompt: CodexExecPlan.fullPrompt(system: NotesCurationPrompt.systemPrompt,
                                                 user: userPrompt),
                label: "curation", home: execution.home, model: execution.model,
                executableOverride: execution.executableOverride)
            else {
                guard runGeneration == generation else { return }
                finish(outcome: CodexRun.lastFailure ?? CodexExecutable.notFoundMessage, touched: false)
                return
            }
            defer { launch.cleanUp() }
            guard runGeneration == generation, !Task.isCancelled else { return }
            guard await spawnShell(command: launch.shellCommand, generation: generation, workingDirectory: launch.workspace) != nil else {
                guard runGeneration == generation else { return }
                finish(outcome: spawnFailure ?? "échec du lancement de l'analyse", touched: false)
                return
            }
            let data = launch.outputFile.flatMap { BoundedProcessOutput.file(at: $0, cap: Self.stdoutCapBytes) } ?? Data()
            parsed = NotesCurationOutput.parse(codexOutput: data)
        }
        guard runGeneration == generation, !Task.isCancelled else { return }
        guard let curation = parsed else {
            log.error("curation : sortie inexploitable")
            finish(outcome: "sortie inexploitable — notes inchangées", touched: false)
            return
        }

        await planAndApply(curation, previous: notes, manual: manual, generation: generation,
                           createdAt: Date(), leaseID: lease)
    }

    private static var checkpointStore: CurationCheckpointStore {
        CurationCheckpointStore(directory: BridgePaths.learningDirectory
            .appendingPathComponent("curation-pending", isDirectory: true))
    }

    /// `true` signifie qu'un résultat local a pris en charge ce cycle, même
    /// refusé. Une erreur locale ne doit jamais tomber dans un nouvel appel.
    private func resumePending(notes: [(name: String, content: String)], manual: Bool,
                               generation: UUID) async -> Bool {
        let checkpoint: CurationCheckpoint
        do {
            guard let saved = try Self.checkpointStore.load() else { return false }
            checkpoint = saved
        } catch {
            finish(outcome: "reprise locale impossible : résultat sauvegardé illisible — aucune nouvelle analyse",
                   touched: false, preserveWarnings: true)
            return true
        }
        guard runGeneration == generation, !Task.isCancelled else { return true }
        switch checkpoint.match(notes: notes) {
        case .changed:
            // Un ajout, retrait ou changement suffit à invalider l'ancienne
            // réponse. Le cycle normal décidera seul d'une nouvelle dépense.
            do { try Self.checkpointStore.remove(ifID: checkpoint.id) }
            catch {
                finish(outcome: "reprise locale impossible : ancien résultat non retiré", touched: false)
                return true
            }
            return false
        case .target:
            // Crash après bascule mais avant l'état : les octets attendus
            // sont déjà posés. Ne pas réarchiver ni réécrire les mêmes notes.
            warnings = checkpoint.output?.contradictions.map { "⚠ contradiction : \($0.summary)" } ?? []
            lastSuccessfulCorpus = CurationCorpusFingerprint(notes: notes)
            AnalysisBudget.shared.updateMetrics(checkpoint.leaseID, notesWritten: notes.count, skillsProposed: 0)
            onNotesReplaced?(checkpoint.sourceNames.map { BridgePaths.learningNotesDirectory.appendingPathComponent($0).path },
                             notes.map { BridgePaths.learningNotesDirectory.appendingPathComponent($0.name) })
            if finish(outcome: "rangement repris localement (\(notes.count) note(s))", touched: true) {
                clearCheckpoint(checkpoint)
            }
            return true
        case .source:
            guard let output = checkpoint.output else {
                finish(outcome: "reprise locale impossible : résultat sauvegardé inexploitable", touched: false)
                return true
            }
            await planAndApply(output, previous: notes, manual: manual, generation: generation,
                               createdAt: checkpoint.createdAt, leaseID: checkpoint.leaseID)
            return true
        }
    }

    /// Même planificateur et mêmes archives relues pour un retour CLI frais
    /// et une reprise. L'horodatage conservé rend les fichiers déterministes.
    private func planAndApply(_ curation: NotesCurationOutput,
                              previous: [(name: String, content: String)], manual: Bool,
                              generation: UUID, createdAt: Date, leaseID: UUID) async {
        let archives = await Task.detached(priority: .utility) {
            NoteProvenance.readArchives(at: BridgePaths.learningArchiveDirectory)
        }.value
        guard generation == runGeneration, !Task.isCancelled else { return }
        // Le modèle ET la lecture des archives suspendent le MainActor. Une
        // rétrospective ou l'utilisateur a pu changer le corpus entre-temps.
        guard CurationCorpusFingerprint(notes: Self.readNotes()) == CurationCorpusFingerprint(notes: previous) else {
            finish(outcome: "notes modifiées pendant l'analyse — résultat non appliqué", touched: false)
            return
        }
        switch NotesCurationPlanner.plan(existing: previous, output: curation, now: createdAt, archives: archives) {
        case .failure(let refusal):
            let reason: String
            switch refusal {
            case .untraceableSources:
                reason = "source de note absente ou inconnue — refus (notes conservées)"
            case .emptyOutputFromNonEmptyInput:
                reason = "aucune note proposée — refus (rien n'a été touché)"
            case .excessiveShrink(let ratio):
                reason = "rétrécissement suspect (\(Int(ratio * 100)) % de l'existant) — refus"
            }
            log.error("curation refusée : \(reason, privacy: .public)")
            finish(outcome: reason, touched: false)
        case .success(let plan):
            do {
                let checkpoint = try CurationCheckpoint(previous: previous, output: curation, plan: plan,
                                                       createdAt: createdAt, leaseID: leaseID)
                // Sauver AVANT l'archive/staging : si cette écriture échoue,
                // les notes restent intactes, sans prétendre avoir une reprise.
                try Self.checkpointStore.save(checkpoint)
                apply(plan, previous: previous, manual: manual, generation: generation, checkpoint: checkpoint)
            } catch {
                finish(outcome: "non appliquée : sauvegarde du résultat impossible (\(error.localizedDescription))",
                       touched: false)
            }
        }
    }

    private func clearCheckpoint(_ checkpoint: CurationCheckpoint) {
        do { try Self.checkpointStore.remove(ifID: checkpoint.id) }
        catch { log.error("résultat appliqué conservé pour reprise : \(error.localizedDescription)") }
    }

    /// Remplacement : archive VÉRIFIÉE, puis staging, puis bascule. À la
    /// moindre anomalie, on s'arrête AVANT toute suppression.
    private func apply(_ plan: NotesCurationPlanner.Plan,
                       previous: [(name: String, content: String)],
                       manual: Bool, generation: UUID, checkpoint: CurationCheckpoint) {
        guard runGeneration == generation, !Task.isCancelled else { return }
        guard checkpoint.sourceFingerprint == CurationCorpusFingerprint(notes: Self.readNotes()) else {
            finish(outcome: "notes modifiées avant remplacement — résultat non appliqué", touched: false)
            return
        }
        let fm = FileManager.default
        let notesDirectory = BridgePaths.learningNotesDirectory
        let stamp = Self.timestamp()
        let archive: URL
        do { archive = try Self.reserveArchive(stamp: stamp) }
        catch {
            finish(outcome: "non appliquée : \(error.localizedDescription)", touched: false)
            return
        }
        /// Passe à true à la première suppression : au-delà, un échec ne peut
        /// plus être annoncé comme inoffensif.
        var swapStarted = false
        /// Notes NEUVES déjà posées — déclarées hors du `do` pour que la
        /// restauration puisse les retirer (revue : une note neuve portant le
        /// nom d'une ancienne se faisait compter comme « restaurée »).
        var written: [URL] = []

        do {
            // (1) ARCHIVE d'abord — puis VÉRIFICATION avant de toucher à quoi
            // que ce soit : nombre de fichiers ET octets identiques.
            for note in previous {
                let source = notesDirectory.appendingPathComponent(note.name)
                let destination = archive.appendingPathComponent(note.name)
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination) // reprise d'un run interrompu
                }
                try fm.copyItem(at: source, to: destination)
            }
            let archived = (try? fm.contentsOfDirectory(atPath: archive.path)) ?? []
            guard archived.count == previous.count else {
                throw CurationError.archiveIncomplete(expected: previous.count,
                                                      actual: archived.count)
            }
            // Comparaison OCTET À OCTET source ↔ archive (revue) : comparer à
            // `content.utf8.count` échouait sur un simple BOM (que
            // `String(contentsOf:)` retire), ce qui bloquait la curation pour
            // toujours sans que rien ne l'explique.
            for note in previous {
                let source = try Data(contentsOf: notesDirectory.appendingPathComponent(note.name))
                let copy = try Data(contentsOf: archive.appendingPathComponent(note.name))
                guard source == copy else {
                    throw CurationError.archiveTruncated(note.name)
                }
            }

            // (2) STAGING : les nouvelles notes sont écrites À CÔTÉ, jamais
            // par-dessus l'existant — un échec ici laisse tout en place.
            let staging = BridgePaths.learningDirectory
                .appendingPathComponent(".notes-staging-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            for note in plan.newNotes {
                try note.content.write(to: staging.appendingPathComponent(note.fileName),
                                       atomically: true, encoding: .utf8)
            }

            // (3) BASCULE — le SEUL moment destructeur. `swapStarted` bascule
            // à true dès la première suppression : au-delà, une erreur ne peut
            // plus être annoncée comme « rien n'a bougé » (revue), elle
            // déclenche une RESTAURATION depuis l'archive qu'on vient de
            // vérifier. Les fichiers non-.md éventuels sont laissés.
            guard runGeneration == generation, !Task.isCancelled else { return }
            guard checkpoint.sourceFingerprint == CurationCorpusFingerprint(notes: Self.readNotes()) else {
                throw CurationError.corpusChanged
            }
            // Distinguer un arrêt AVANT la première suppression d'un swap
            // commencé : sans ce témoin, une suppression externe ultérieure
            // serait attribuée à tort au remplacement interrompu.
            try Data(checkpoint.id.uuidString.utf8).write(
                to: staging.appendingPathComponent(".swap-started"), options: .atomic)
            swapStarted = true
            // On ne retient que les suppressions RÉUSSIES : c'est cette liste
            // qui part à `forgetFile` en (4). Dérivée de `previous`, elle
            // faisait oublier de l'index une note dont la suppression avait
            // échoué — le fichier restait sur le disque, mais devenait
            // invisible au recall, donc perdu sans l'être.
            var deleted: [String] = []
            for note in previous {
                let url = notesDirectory.appendingPathComponent(note.name)
                do {
                    try fm.removeItem(at: url)
                    deleted.append(url.path)
                } catch {
                    log.error("note non supprimée, conservée dans l'index : \(note.name, privacy: .public)")
                }
            }
            for note in plan.newNotes {
                let destination = notesDirectory.appendingPathComponent(note.fileName)
                // Une collision ne peut venir QUE d'un fichier que `readNotes`
                // n'a pas su lire (donc jamais archivé) : on l'écarte au lieu
                // de le détruire — la curation ne détruit rien qu'elle n'ait
                // pu archiver (revue).
                if fm.fileExists(atPath: destination.path) {
                    let orphan = notesDirectory.appendingPathComponent(
                        "\(note.fileName).orphan-\(stamp)")
                    if (try? fm.moveItem(at: destination, to: orphan)) == nil {
                        try? fm.removeItem(at: destination) // dernier recours
                    } else {
                        log.error("fichier illisible écarté : \(note.fileName, privacy: .public).orphan-\(stamp, privacy: .public)")
                    }
                }
                try fm.moveItem(at: staging.appendingPathComponent(note.fileName), to: destination)
                written.append(destination)
            }

            // (4) INDEX : oublier les anciens fichiers (sinon recall continue
            // de remonter des notes qui n'existent plus) et indexer les neufs.
            onNotesReplaced?(deleted, written)

            warnings = plan.warnings
            let summary = "\(previous.count) note(s) → \(plan.newNotes.count)"
                + (plan.warnings.isEmpty ? "" : " · \(plan.warnings.count) contradiction(s)")
            log.info("curation appliquée : \(summary, privacy: .public) (archive : \(archive.lastPathComponent, privacy: .public))")
            Self.pruneArchives()
            // L'entrée a été remplacée : comparer au corpus AVANT le swap
            // relancerait le modèle sur ses propres sorties au prochain tick.
            lastSuccessfulCorpus = CurationCorpusFingerprint(notes: Self.readNotes())
            AnalysisBudget.shared.updateMetrics(checkpoint.leaseID, notesWritten: written.count, skillsProposed: 0)
            // Le résultat reste récupérable si l'état n'a pas pu être écrit.
            // Le prochain passage reconnaîtra alors l'empreinte cible.
            if finish(outcome: summary + (manual ? "" : " (auto)"), touched: true) {
                clearCheckpoint(checkpoint)
            }
        } catch {
            guard swapStarted else {
                log.error("curation non appliquée : \(error.localizedDescription) — notes inchangées")
                finish(outcome: "non appliquée : \(error.localizedDescription)", touched: false)
                return
            }
            // Échec APRÈS la première suppression : les notes d'origine sont
            // dans l'archive (vérifiée juste avant), on les remet en place —
            // après avoir retiré les notes NEUVES déjà posées, sinon on
            // laisserait un mélange des deux générations.
            for url in written { try? fm.removeItem(at: url) }
            let restored = restoreFromArchive(archive, into: notesDirectory, expected: previous)
            log.error("curation interrompue (\(error.localizedDescription)) — restauration : \(restored)/\(previous.count) note(s)")
            finish(outcome: restored == previous.count
                   ? "interrompue — notes restaurées depuis l'archive"
                   : "interrompue — \(restored)/\(previous.count) note(s) restaurées, le reste est dans \(archive.lastPathComponent)",
                   touched: false)
        }
    }

    /// `mkdir` réserve réellement le nom (createDirectory réussit aussi sur
    /// un dossier déjà présent). Les suffixes ordonnés gardent la dernière
    /// archive identifiable par repairInterruptedSwap et pruneArchives.
    static func reserveArchive(stamp: String) throws -> URL {
        let directory = BridgePaths.learningArchiveDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<10_000 {
            let suffix = index == 0 ? "" : String(format: "-%04d", index)
            let candidate = directory.appendingPathComponent("notes-\(stamp)\(suffix)", isDirectory: true)
            if mkdir(candidate.path, 0o700) == 0 { return candidate }
            let failure = errno
            guard failure == EEXIST else {
                throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Remet les notes archivées à leur place (best-effort, fichier par
    /// fichier) et rend le nombre effectivement restauré. L'appelant a déjà
    /// retiré les notes neuves : ici, un fichier encore présent est bien
    /// l'original (bascule qui n'était pas allée jusqu'à lui).
    private func restoreFromArchive(_ archive: URL, into notesDirectory: URL,
                                    expected: [(name: String, content: String)]) -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        var restored = 0
        for note in expected {
            let destination = notesDirectory.appendingPathComponent(note.name)
            if fm.fileExists(atPath: destination.path) { restored += 1; continue }
            if (try? fm.copyItem(at: archive.appendingPathComponent(note.name),
                                 to: destination)) != nil {
                restored += 1
            }
        }
        return restored
    }

    /// Ne garde que les `keep` archives de notes les plus récentes : une
    /// curation hebdomadaire en produit une par semaine, chacune contenant une
    /// copie complète du corpus. Les dossiers d'archive des SKILLS
    /// (`approved/`, `rejected/`, `uninstalled/`) ne sont jamais touchés :
    /// seuls les `notes-<stamp>` sont concernés.
    private static func pruneArchives(keep: Int = 12) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: BridgePaths.learningArchiveDirectory, includingPropertiesForKeys: nil
        ) else { return }
        // Le nom porte l'horodatage UTC `yyyyMMdd-HHmmss` : l'ordre
        // lexicographique EST l'ordre chronologique.
        let archives = children
            .filter { $0.lastPathComponent.hasPrefix("notes-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for stale in archives.dropFirst(keep) {
            try? fm.removeItem(at: stale)
        }
    }

    /// Le quota interdit-il de lancer maintenant ? nil = feu vert.
    ///
    /// Trois cas douteux, calqués sur `LearningGate` : quota INCONNU, lecture
    /// PÉRIMÉE (plus de 30 min : la fenêtre a pu tourner), fenêtre 5 h déjà
    /// EXPIRÉE (le chiffre ne veut plus rien dire).
    ///
    /// Ils ne sont PAS un refus sec. C'était exactement le défaut que la Phase
    /// 12 a diagnostiqué comme « LA cause du silence » côté rétrospective : la
    /// statusline n'existe qu'avec un TUI ouvert, donc après chaque
    /// redémarrage d'Atoll — ou une demi-heure sans session — la fonction
    /// était morte, y compris sur un clic explicite de l'utilisateur. On
    /// autorise donc UN passage par fenêtre de 5 h, comme
    /// `unknownQuotaMaxPerWindow` (audit du 2026-07-27).
    static func quotaRefusal(_ quota: LearningGate.QuotaFacts, now: Date,
                             lastSpendAt: Date?) -> String? {
        let doubtful: String?
        if quota.usedFraction == nil {
            doubtful = "quota 5 h inconnu"
        } else if let receivedAt = quota.receivedAt, now.timeIntervalSince(receivedAt) >= 1_800 {
            doubtful = "quota périmé"
        } else if quota.receivedAt == nil {
            doubtful = "quota sans horodatage"
        } else if let resetsAt = quota.resetsAt, resetsAt < now {
            doubtful = "fenêtre 5 h expirée"
        } else {
            doubtful = nil
        }
        guard let doubtful else { return nil }
        // Une seule tentative par fenêtre tant qu'on ne sait pas : le plafond
        // borne la dépense, exactement comme pour la rétrospective.
        if let lastSpendAt, now.timeIntervalSince(lastSpendAt) < LearningGate.runWindowSeconds {
            return doubtful
        }
        return nil
    }

    /// Une bascule payée peut laisser des sources ET des sorties dans notes/.
    /// Le simple comptage historique reconstruisait alors un corpus mixte et
    /// invalidait le résultat sauvegardé. Ici chaque fichier doit être prouvé.
    private static func recoverCheckpointSwap() throws {
        guard let checkpoint = try checkpointStore.load() else { return }
        let fm = FileManager.default
        let notesDirectory = BridgePaths.learningNotesDirectory
        func files(in directory: URL, strict: Bool, swapID: UUID? = nil) throws -> [String: Data] {
            let kind = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard kind.isDirectory == true, kind.isSymbolicLink == false else {
                throw CurationError.interruptedSwapUnproven
            }
            var result: [String: Data] = [:]
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let name = file.lastPathComponent
                let isMarker = name == ".swap-started" && swapID != nil
                guard isMarker || (!name.hasPrefix(".") && name.lowercased().hasSuffix(".md")) else {
                    if strict { throw CurationError.interruptedSwapUnproven }
                    continue
                }
                let kind = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard kind.isRegularFile == true, kind.isSymbolicLink == false,
                      let bytes = BoundedProcessOutput.file(at: file, cap: 2 * 1024 * 1024) else {
                    throw CurationError.interruptedSwapUnproven
                }
                if isMarker {
                    guard bytes == Data(swapID!.uuidString.utf8) else { throw CurationError.interruptedSwapUnproven }
                } else {
                    result[name] = bytes
                }
            }
            return result
        }
        func corpus(_ files: [String: Data]) throws -> [(name: String, content: String)] {
            try files.sorted { $0.key < $1.key }.map {
                guard let content = String(data: $0.value, encoding: .utf8) else {
                    throw CurationError.interruptedSwapUnproven
                }
                return (name: $0.key, content: content)
            }
        }
        let stagingDirectories = try fm.contentsOfDirectory(at: BridgePaths.learningDirectory,
                                                             includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".notes-staging-") }
        let staged = try stagingDirectories.map {
            ($0, try files(in: $0, strict: true, swapID: checkpoint.id),
             fm.fileExists(atPath: $0.appendingPathComponent(".swap-started").path))
        }
            .filter { !$0.1.isEmpty }
        guard !staged.isEmpty else {
            // Même vide, un staging ne justifie pas d'écarter un checkpoint
            // dont ni les sources ni la cible ne correspondent au disque.
            if !stagingDirectories.isEmpty,
               checkpoint.match(notes: try corpus(files(in: notesDirectory, strict: false))) == .changed {
                throw CurationError.interruptedSwapUnproven
            }
            return
        }
        guard staged.count == 1, let output = checkpoint.output else {
            throw CurationError.interruptedSwapUnproven
        }
        let (staging, pending, swapStarted) = staged[0]
        let archives = try fm.contentsOfDirectory(at: BridgePaths.learningArchiveDirectory,
                                                 includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("notes-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var source: [String: Data]?
        for archive in archives.prefix(32) {
            guard let candidate = try? files(in: archive, strict: true),
                  Set(candidate.keys) == Set(checkpoint.sourceNames),
                  let previous = try? corpus(candidate),
                  CurationCorpusFingerprint(notes: previous) == checkpoint.sourceFingerprint else { continue }
            source = candidate
            break
        }
        guard let source,
              case .success(let plan) = NotesCurationPlanner.plan(existing: try corpus(source), output: output,
                now: checkpoint.createdAt, archives: NoteProvenance.readArchives(at: BridgePaths.learningArchiveDirectory)),
              CurationCorpusFingerprint(notes: plan.newNotes.map { ($0.fileName, $0.content) }) == checkpoint.targetFingerprint else {
            throw CurationError.interruptedSwapUnproven
        }
        let target = Dictionary(uniqueKeysWithValues: plan.newNotes.map { ($0.fileName, Data($0.content.utf8)) })
        let present = try files(in: notesDirectory, strict: false)
        // Aucun fichier ajouté ou modifié n'est attribué au swap par son nom
        // seul. Même discipline pour le staging, qui est la copie de secours.
        guard pending.allSatisfy({ target[$0.key] == $0.value }),
              present.allSatisfy({ source[$0.key] == $0.value || target[$0.key] == $0.value }) else {
            throw CurationError.interruptedSwapUnproven
        }
        let intact = CurationCorpusFingerprint(notes: try corpus(present)) == checkpoint.sourceFingerprint
        guard intact || (swapStarted && target.allSatisfy({ pending[$0.key] == $0.value || present[$0.key] == $0.value })) else {
            throw CurationError.interruptedSwapUnproven
        }
        if !intact {
            // Remettre d'abord TOUTES les sorties dans le staging : un second
            // crash au milieu de la restauration garde les mêmes preuves.
            for (name, bytes) in target where pending[name] == nil {
                let path = notesDirectory.appendingPathComponent(name)
                guard try Data(contentsOf: path) == bytes else { throw CurationError.interruptedSwapUnproven }
                try fm.copyItem(at: path, to: staging.appendingPathComponent(name))
            }
            guard try files(in: staging, strict: true, swapID: checkpoint.id) == target else { throw CurationError.interruptedSwapUnproven }
            for (name, bytes) in source {
                let path = notesDirectory.appendingPathComponent(name)
                if fm.fileExists(atPath: path.path) {
                    let current = try Data(contentsOf: path)
                    if current == bytes { continue }
                    guard current == target[name] else { throw CurationError.interruptedSwapUnproven }
                    try fm.removeItem(at: path)
                }
                // Sans .atomic : création exclusive, jamais écraser une note
                // réapparue après notre lecture.
                try bytes.write(to: path, options: .withoutOverwriting)
            }
            for (name, bytes) in target where source[name] == nil {
                let path = notesDirectory.appendingPathComponent(name)
                guard fm.fileExists(atPath: path.path) else { continue }
                guard try Data(contentsOf: path) == bytes else { throw CurationError.interruptedSwapUnproven }
                try fm.removeItem(at: path)
            }
        }
        guard CurationCorpusFingerprint(notes: try corpus(files(in: notesDirectory, strict: false))) == checkpoint.sourceFingerprint,
              try files(in: staging, strict: true, swapID: checkpoint.id) == (intact ? pending : target) else {
            throw CurationError.interruptedSwapUnproven
        }
        try fm.removeItem(at: staging)
        log.info("bascule interrompue restaurée depuis les sources vérifiées — reprise locale du résultat")
    }

    /// Rattrapage d'une bascule interrompue par un ARRÊT BRUTAL (SIGKILL,
    /// panne) — l'équivalent de `LearnedSkillStore.finishIncompleteMoves`, qui
    /// manquait ici.
    ///
    /// `apply()` restaure depuis l'archive quand une erreur est LEVÉE, mais
    /// rien ne rattrapait un processus tué entre la boucle de suppression et la
    /// fin des déplacements : `notes/` restait vide ou partiel. Et le run
    /// suivant commençait par balayer le staging — qui contenait les notes
    /// neuves déjà écrites — sans le regarder : les DEUX générations
    /// disparaissaient, et l'utilisateur lisait « rien à consolider (0 note) ».
    ///
    /// Signature du crash : un staging traîne ET `notes/` contient MOINS de
    /// fichiers que la dernière archive. Un run avorté AVANT la bascule laisse
    /// aussi un staging, mais `notes/` y est intact — d'où la comparaison,
    /// plutôt que la seule présence du staging.
    ///
    /// On restaure l'état PRÉ-bascule depuis l'archive (vérifiée octet à octet
    /// avant la suppression) : c'est terminer l'annulation que le crash a
    /// interrompue. On ne « finit » PAS la bascule vers les notes neuves — ce
    /// serait acter un plan que rien n'a validé.
    private static func repairInterruptedSwap() {
        let fm = FileManager.default
        let notesDirectory = BridgePaths.learningNotesDirectory
        func markdown(in directory: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.hasSuffix(".md") }
        }
        // Le staging doit contenir des notes ENCORE À DÉPLACER. Un run réussi
        // vide le staging (chaque `moveItem` en sort un fichier) avant même que
        // le `defer` ne supprime le dossier : exiger un staging NON VIDE écarte
        // le cas où ce `defer` a échoué après une curation parfaitement normale.
        // Sans cette condition, une curation réussie qui réduit le corpus
        // (5 notes → 3, le cas NOMINAL) satisfaisait la comparaison de comptes
        // ci-dessous et faisait ressusciter les notes que l'utilisateur venait
        // justement de faire consolider.
        let staged = ((try? fm.contentsOfDirectory(at: BridgePaths.learningDirectory,
                                                   includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(".notes-staging-") }
            .filter { !markdown(in: $0).isEmpty }
        guard !staged.isEmpty else { return }
        // Le nom porte l'horodatage UTC : l'ordre lexicographique EST l'ordre
        // chronologique (même convention que `pruneArchives`).
        guard let archive = ((try? fm.contentsOfDirectory(at: BridgePaths.learningArchiveDirectory,
                                                          includingPropertiesForKeys: nil)) ?? [])
            .filter({ $0.lastPathComponent.hasPrefix("notes-") })
            .max(by: { $0.lastPathComponent < $1.lastPathComponent })
        else { return }

        let archived = markdown(in: archive)
        guard markdown(in: notesDirectory).count < archived.count else { return }

        try? fm.createDirectory(at: notesDirectory, withIntermediateDirectories: true)
        var restored = 0
        for name in archived {
            let destination = notesDirectory.appendingPathComponent(name)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            if (try? fm.copyItem(at: archive.appendingPathComponent(name), to: destination)) != nil {
                restored += 1
            }
        }
        log.error("bascule de notes interrompue détectée — \(restored, privacy: .public) note(s) restaurée(s) depuis \(archive.lastPathComponent, privacy: .public)")
    }

    /// Balaye les stagings orphelins (`.notes-staging-<uuid>`) laissés par un
    /// crash pendant l'étape (2) — cachés, donc invisibles, mais à ne pas
    /// accumuler. Même rôle que `LearnedSkillStore.sweepStagingLeaks`.
    private static func sweepStagingLeaks() {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: BridgePaths.learningDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for child in children where child.lastPathComponent.hasPrefix(".notes-staging-") {
            try? fm.removeItem(at: child)
        }
    }

    enum CurationError: LocalizedError {
        case archiveIncomplete(expected: Int, actual: Int)
        case archiveTruncated(String)
        case corpusChanged
        case interruptedSwapUnproven

        var errorDescription: String? {
            switch self {
            case .interruptedSwapUnproven:
                return "bascule interrompue non prouvée — fichiers conservés"
            case .corpusChanged:
                return "notes modifiées avant remplacement — résultat non appliqué"
            case .archiveIncomplete(let expected, let actual):
                return "archive incomplète (\(actual)/\(expected) fichiers) — rien n'a été remplacé"
            case .archiveTruncated(let name):
                return "archive tronquée pour « \(name) » — rien n'a été remplacé"
            }
        }
    }

    /// Un lancement ou un refus durable (rien à consolider, corpus trop gros)
    /// avance l'échéance normale. Un échec de préparation conserve l'échéance
    /// mais impose 30 minutes avant un nouvel essai. Les reports de quota ou
    /// d'analyse concurrente sortent avant d'arriver ici.
    ///
    /// `touched` ne sert qu'à savoir si les avertissements affichés
    /// (contradictions) proviennent de ce cycle ou doivent être effacés.
    @discardableResult
    private func finish(outcome: String, touched: Bool, retry: Bool = true,
                        preserveWarnings: Bool = false) -> Bool {
        let saved = recordOutcome(outcome, touched: touched, retry: retry, preserveWarnings: preserveWarnings)
        phase = .idle
        return saved
    }

    @discardableResult
    private func recordOutcome(_ outcome: String, touched: Bool, retry: Bool = true,
                               preserveWarnings: Bool = false) -> Bool {
        let now = Date()
        if runLaunched || touched || !retry {
            lastRunAt = now
            retryAt = nil
        } else {
            retryAt = now.addingTimeInterval(30 * 60)
        }
        lastOutcome = outcome
        if !touched, !preserveWarnings { warnings = [] }
        if !touched, let lease = activeLease {
            AnalysisBudget.shared.updateMetrics(lease, notesWritten: 0, skillsProposed: 0)
        }
        return persistState()
    }

    @discardableResult
    private func persistState() -> Bool {
        Self.saveState(.init(lastRunAt: lastRunAt, lastOutcome: lastOutcome,
                             warnings: warnings, retryAt: retryAt,
                             lastSuccessfulCorpus: lastSuccessfulCorpus))
    }

    // MARK: - Sous-processus

    /// Exécution proprement dite — identique quel que soit l'abonnement : même
    /// shell de login, même watchdog, même drainage parallèle des deux pipes,
    /// même comptabilisation de la dépense. Seule la COMMANDE change, et elle
    /// est construite par l'appelant.
    ///
    /// Rend le stdout du process, ou `nil` sur échec. Sur le chemin Codex ce
    /// stdout n'est qu'un journal d'événements — le rapport est dans le fichier
    /// de `--output-last-message` —, mais le non-`nil` reste le signal
    /// « le process est allé au bout avec exit 0 ».
    private func spawnShell(command shellCommand: String, generation: UUID, workingDirectory: URL?) async -> Data? {
        guard runGeneration == generation, !Task.isCancelled else { return nil }
        guard let lease = activeLease, let execution = activeExecution,
              AnalysisBudget.shared.mayLaunch(lease, context: execution) else {
            spawnFailure = "Quota périmé ou plafond interne atteint."
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", shellCommand]
        var environment = ProcessInfo.processInfo.environment
        environment["ATOLL_RETROSPECTIVE"] = "1" // filtré par reconcile() : invisible dans l'îlot
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        // NON NÉGOCIABLE sur le chemin Codex : `codex exec` lit stdin même
        // quand le prompt est en argument, et attend EOF — mesuré le
        // 2026-09-06 (« Reading additional input from stdin... »), soit dix
        // minutes de watchdog par run. Voir `CodexExecPlan`.
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        spawnFailure = nil
        // La dépense commence ICI, pas au cycle : c'est ce qui borne la
        // tolérance « quota inconnu ».
        do {
            try AnalysisBudget.shared.prepareToLaunch(lease)
            processIdentity = try ProcessInspector.launchOwned(process)
        } catch {
            log.error("spawn curation impossible : \(error.localizedDescription)")
            spawnFailure = "l'analyse n'a pas pu être lancée (\(error.localizedDescription))"
            return nil
        }
        lastSpendAt = Date()
        runLaunched = true
        AnalysisBudget.shared.launched(lease)
        self.process = process
        let identity = processIdentity
        let pid = process.processIdentifier
        SessionStore.shared.registerInternalPid(pid)
        log.info("curation lancée (pid \(pid))")

        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(Self.timeoutSeconds))
            guard !Task.isCancelled else { return }
            log.error("curation (pid \(pid)) : timeout — SIGTERM")
            if let identity { ProcessInspector.signal(SIGTERM, to: identity) }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if let identity { ProcessInspector.signal(SIGKILL, to: identity) }
        }

        // Les DEUX pipes sont drainés EN PARALLÈLE (revue) : les lire l'un
        // après l'autre laissait `claude` bloqué dans un `write` sur stderr
        // plein (~64 Ko) — stdout ne se fermait jamais, le lecteur n'atteignait
        // jamais EOF, et il fallait attendre le timeout de 10 minutes. Même
        // raison au-delà du cap : on continue de lire en JETANT, on ne cesse
        // jamais de vider le tuyau.
        async let outputTask: Data = Task.detached(priority: .utility) {
            var collected = Data()
            var overflowed = false
            let handle = stdout.fileHandleForReading
            while let chunk = try? handle.read(upToCount: 1 << 16), !chunk.isEmpty {
                if overflowed { continue }
                collected.append(chunk)
                if collected.count > Self.stdoutCapBytes { overflowed = true }
            }
            return collected
        }.value
        async let errorTask: String = Task.detached(priority: .utility) {
            let data = BoundedProcessOutput.drain(stderr.fileHandleForReading, cap: 2000, tail: true)
            return String(decoding: data.suffix(2000), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        let output = await outputTask
        let errorTail = await errorTask
        AnalysisBudget.shared.recordUsage(lease, stdout: output)

        // Hors MainActor : `waitUntilExit` boucle en attendant le SIGCHLD.
        await Task.detached(priority: .utility) { process.waitUntilExit() }.value
        timeoutTask?.cancel()
        timeoutTask = nil
        SessionStore.shared.unregisterInternalPid(pid)
        self.process = nil
        processIdentity = nil
        guard runGeneration == generation, !Task.isCancelled else { return nil }

        guard process.terminationStatus == 0 else {
            log.error("curation (pid \(pid)) : exit \(process.terminationStatus) — \(errorTail, privacy: .public)")
            // La CAUSE au lieu d'un « échec du lancement » générique : dépassement
            // de budget, timeout (SIGTERM = 143) et binaire introuvable
            // envoyaient exactement le même message, qui désignait le PATH.
            spawnFailure = "l'analyse a échoué (exit \(process.terminationStatus))"
                + (errorTail.isEmpty ? "" : " — \(errorTail.prefix(120))")
            return nil
        }
        return output
    }

    // MARK: - Lecture des notes

    /// Les notes existantes, triées par nom (ordre déterministe du corpus).
    /// Un fichier illisible est SAUTÉ : il ne partira donc pas à l'archive et
    /// ne sera pas supprimé — la curation ne peut pas détruire ce qu'elle n'a
    /// pas su lire.
    static func readNotes() -> [(name: String, content: String)] {
        let directory = BridgePaths.learningNotesDirectory
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            // Mêmes critères que `LearningInventory` (revue : trois listages
            // divergeaient) — fichiers cachés exclus, extension insensible à
            // la casse : ce qui est inventorié est ce qui est curé.
            .filter { !$0.hasPrefix(".") && $0.lowercased().hasSuffix(".md") }
            .sorted()
        return names.compactMap { name in
            guard let content = try? String(contentsOf: directory.appendingPathComponent(name),
                                            encoding: .utf8) else { return nil }
            return (name: name, content: content)
        }
    }

    // MARK: - État persistant

    private struct PersistedState: Codable {
        var lastRunAt: Date?
        var lastOutcome: String?
        var warnings: [String] = []
        var retryAt: Date? = nil
        // Optionnel : un état antérieur garde sa cadence et ses opt-ins. Ni
        // une migration, ni un changement de modèle ne rendent une date due.
        var lastSuccessfulCorpus: CurationCorpusFingerprint? = nil

        init(lastRunAt: Date? = nil, lastOutcome: String? = nil, warnings: [String] = [],
             retryAt: Date? = nil, lastSuccessfulCorpus: CurationCorpusFingerprint? = nil) {
            self.lastRunAt = lastRunAt
            self.lastOutcome = lastOutcome
            self.warnings = warnings
            self.retryAt = retryAt
            self.lastSuccessfulCorpus = lastSuccessfulCorpus
        }

        // Une empreinte illisible ne doit pas remettre à zéro une échéance
        // valide : cette donnée ajoutée n'autorise jamais une dépense.
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            lastRunAt = try values.decodeIfPresent(Date.self, forKey: .lastRunAt)
            lastOutcome = try values.decodeIfPresent(String.self, forKey: .lastOutcome)
            warnings = try values.decodeIfPresent([String].self, forKey: .warnings) ?? []
            retryAt = try values.decodeIfPresent(Date.self, forKey: .retryAt)
            lastSuccessfulCorpus = try? values.decodeIfPresent(CurationCorpusFingerprint.self,
                                                               forKey: .lastSuccessfulCorpus)
        }
    }

    private static var stateURL: URL {
        BridgePaths.learningDirectory.appendingPathComponent("curation.json")
    }

    private static func loadState() -> PersistedState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return PersistedState() }
        return state
    }

    private static func saveState(_ state: PersistedState) -> Bool {
        do {
            try FileManager.default.createDirectory(at: BridgePaths.learningDirectory,
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
            return true
        } catch {
            log.error("état de curation non sauvegardé : \(error.localizedDescription)")
            return false
        }
    }

    /// `20260726-013000` — UTC, comme les archives du LearnedSkillStore.
    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
