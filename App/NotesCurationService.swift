import Foundation
import Observation
import OSLog
import AtollCore

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

    @ObservationIgnored private var process: Process?
    /// Cause exacte du dernier échec de sous-processus (affichée telle quelle).
    @ObservationIgnored private var spawnFailure: String?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var schedulerTask: Task<Void, Never>?

    private static let timeoutSeconds: TimeInterval = 600
    nonisolated private static let stdoutCapBytes = 4 * 1024 * 1024
    /// Cadence de la vérification « est-ce dû ? » quand l'automatique est actif.
    private static let schedulerTickSeconds: TimeInterval = 6 * 3600

    private init() {
        let state = Self.loadState()
        lastRunAt = state.lastRunAt
        lastOutcome = state.lastOutcome
        warnings = state.warnings
    }

    // MARK: - Planification

    /// Démarre/arrête la boucle hebdomadaire selon le réglage (pattern
    /// `MemoryIndexer.syncWithSettings`). Idempotent.
    func syncWithSettings() {
        guard LearningSettings.shared.isCurationScheduled else {
            schedulerTask?.cancel()
            schedulerTask = nil
            return
        }
        guard schedulerTask == nil else { return }
        // ARMER N'EST PAS LANCER (revue) : sans échéance connue, cocher la
        // case aurait déclenché sur-le-champ un `claude -p` qui réécrit toutes
        // les notes. La première échéance part de maintenant ; pour curer
        // tout de suite, il y a le bouton juste à côté.
        if lastRunAt == nil {
            lastRunAt = Date()
            Self.saveState(.init(lastRunAt: lastRunAt, lastOutcome: lastOutcome,
                                 warnings: warnings))
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
        let interval = LearningSettings.curationIntervalDays * 86_400
        if let lastRunAt, Date().timeIntervalSince(lastRunAt) < interval { return }
        curateNow(manual: false)
    }

    /// Déclenchement explicite (bouton des Réglages) — ignore l'échéance mais
    /// PAS les autres garde-fous.
    func curateNow(manual: Bool = true) {
        guard phase == .idle, process == nil else {
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
        Task { await run(manual: manual) }
    }

    /// Kill-switch : arrêt immédiat avec escalade SIGTERM → SIGKILL.
    /// `phase` revient à `.idle` (revue) : sinon un `cancel()` sans processus
    /// en vol laissait le service bloqué en « running » pour toujours.
    func cancel() {
        timeoutTask?.cancel()
        timeoutTask = nil
        terminateWithEscalation()
        if process == nil { phase = .idle }
    }

    private func terminateWithEscalation() {
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(5))
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    // MARK: - Cycle

    private func run(manual: Bool) async {
        Self.sweepStagingLeaks() // débris d'un run interrompu
        let notes = Self.readNotes()
        guard notes.count >= 2 else {
            finish(outcome: "rien à consolider (\(notes.count) note(s))", touched: false)
            return
        }
        guard NotesCurationPrompt.fitsBudget(notes: notes) else {
            // Refus ASSUMÉ : tronquer ferait remplacer toute la mémoire par la
            // consolidation d'un échantillon.
            let size = NotesCurationPrompt.corpusCharacterCount(notes: notes)
            log.error("corpus de notes trop volumineux (\(size) caractères) — curation refusée")
            finish(outcome: "corpus trop volumineux (\(size) caractères) — curation refusée",
                   touched: false)
            return
        }
        // QUOTA — mêmes exigences que la rétrospective (revue) : la version
        // précédente ne regardait le quota que s'il était CONNU, donc au
        // premier tour du planificateur (juste après le lancement, avant la
        // première statusline) elle partait sans aucun garde-fou.
        let store = SessionStore.shared
        let quota = LearningGate.QuotaFacts(
            usedFraction: store.realQuota?.fiveHour.usedFraction,
            receivedAt: store.rawQuotaReceivedAt,
            resetsAt: store.realQuota?.fiveHour.resetsAt
        )
        if let refusal = Self.quotaRefusal(quota, now: Date(), lastRunAt: lastRunAt) {
            log.info("curation reportée : \(refusal, privacy: .public)")
            phase = .idle
            lastOutcome = "reportée (\(refusal))"
            Self.saveState(.init(lastRunAt: lastRunAt, lastOutcome: lastOutcome,
                                 warnings: warnings))
            return
        }
        if let used = quota.usedFraction,
           used > LearningSettings.shared.quotaThreshold {
            let percent = Int(used * 100)
            log.info("quota 5 h à \(percent) % — curation reportée")
            // Reportée : `lastRunAt` n'est PAS avancé, la prochaine vérification
            // réessaiera (sinon un pic de quota sauterait toute la semaine).
            // L'issue est tout de même persistée, sinon les Réglages
            // afficheraient le passage PRÉCÉDENT après un redémarrage.
            phase = .idle
            lastOutcome = "reportée (quota 5 h à \(percent) %)"
            Self.saveState(.init(lastRunAt: lastRunAt, lastOutcome: lastOutcome,
                                 warnings: warnings))
            return
        }

        let arguments = NotesCurationPrompt.cliArguments(
            model: LearningSettings.shared.curationModel,
            budgetUSD: LearningSettings.budgetUSD
        ) + [NotesCurationPrompt.userPrompt(notes: notes)]

        guard let output = await spawnClaude(arguments: arguments) else {
            finish(outcome: spawnFailure ?? "échec du lancement de l'analyse", touched: false)
            return
        }

        // Un .zprofile bavard peut précéder le JSON (shell de login) : on
        // retente depuis la première accolade, comme la rétrospective.
        var parsed = NotesCurationOutput.parse(cliOutput: output)
        if parsed == nil, let brace = output.firstIndex(of: UInt8(ascii: "{")) {
            parsed = NotesCurationOutput.parse(cliOutput: Data(output[brace...]))
        }
        guard let curation = parsed else {
            log.error("curation : sortie inexploitable")
            finish(outcome: "sortie inexploitable — notes inchangées", touched: false)
            return
        }

        switch NotesCurationPlanner.plan(existing: notes, output: curation, now: Date()) {
        case .failure(let refusal):
            let reason: String
            switch refusal {
            case .emptyOutputFromNonEmptyInput:
                reason = "aucune note proposée — refus (rien n'a été touché)"
            case .excessiveShrink(let ratio):
                reason = "rétrécissement suspect (\(Int(ratio * 100)) % de l'existant) — refus"
            }
            log.error("curation refusée : \(reason, privacy: .public)")
            finish(outcome: reason, touched: false)
        case .success(let plan):
            apply(plan, previous: notes, manual: manual)
        }
    }

    /// Remplacement : archive VÉRIFIÉE, puis staging, puis bascule. À la
    /// moindre anomalie, on s'arrête AVANT toute suppression.
    private func apply(_ plan: NotesCurationPlanner.Plan,
                       previous: [(name: String, content: String)],
                       manual: Bool) {
        let fm = FileManager.default
        let notesDirectory = BridgePaths.learningNotesDirectory
        let stamp = Self.timestamp()
        let archive = BridgePaths.learningArchiveDirectory
            .appendingPathComponent("notes-\(stamp)", isDirectory: true)
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
            try fm.createDirectory(at: archive, withIntermediateDirectories: true)
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
            swapStarted = true
            for note in previous {
                try? fm.removeItem(at: notesDirectory.appendingPathComponent(note.name))
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
            let forgotten = previous.map { notesDirectory.appendingPathComponent($0.name).path }
            onNotesReplaced?(forgotten, written)

            warnings = plan.warnings
            let summary = "\(previous.count) note(s) → \(plan.newNotes.count)"
                + (plan.warnings.isEmpty ? "" : " · \(plan.warnings.count) contradiction(s)")
            log.info("curation appliquée : \(summary, privacy: .public) (archive : \(archive.lastPathComponent, privacy: .public))")
            Self.pruneArchives()
            finish(outcome: summary + (manual ? "" : " (auto)"), touched: true)
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
                             lastRunAt: Date?) -> String? {
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
        if let lastRunAt, now.timeIntervalSince(lastRunAt) < LearningGate.runWindowSeconds {
            return doubtful
        }
        return nil
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

        var errorDescription: String? {
            switch self {
            case .archiveIncomplete(let expected, let actual):
                return "archive incomplète (\(actual)/\(expected) fichiers) — rien n'a été remplacé"
            case .archiveTruncated(let name):
                return "archive tronquée pour « \(name) » — rien n'a été remplacé"
            }
        }
    }

    /// L'échéance avance dès qu'un cycle est allé au bout de son évaluation,
    /// qu'il ait remplacé quelque chose ou non : un corpus trop gros, une
    /// sortie inexploitable ou un `claude` introuvable ne doivent pas
    /// relancer un cycle toutes les 6 heures. Seuls les REPORTS (quota
    /// inconnu, périmé, trop consommé, rétrospective en cours) laissent
    /// `lastRunAt` en arrière — et ils sortent avant d'arriver ici.
    ///
    /// `touched` ne sert qu'à savoir si les avertissements affichés
    /// (contradictions) proviennent de ce cycle ou doivent être effacés.
    private func finish(outcome: String, touched: Bool) {
        let now = Date()
        lastRunAt = now
        lastOutcome = outcome
        if !touched { warnings = [] }
        phase = .idle
        Self.saveState(.init(lastRunAt: now, lastOutcome: outcome, warnings: warnings))
    }

    // MARK: - Sous-processus

    /// Spawn `claude -p` via un shell de LOGIN (sinon le process est muet
    /// depuis une app GUI — piège vécu), sortie bornée, lecture sur des tâches
    /// détachées (readabilityHandler est inopérant en LSUIElement).
    private func spawnClaude(arguments: [String]) async -> Data? {
        let shellCommand = "unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN; exec claude "
            + arguments.map(FleetLaunch.shellQuote).joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", shellCommand]
        var environment = ProcessInfo.processInfo.environment
        environment["ATOLL_RETROSPECTIVE"] = "1" // filtré par reconcile() : invisible dans l'îlot
        process.environment = environment
        process.currentDirectoryURL = BridgePaths.learningDirectory
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        spawnFailure = nil
        do {
            try process.run()
        } catch {
            log.error("spawn curation impossible : \(error.localizedDescription)")
            spawnFailure = "claude n'a pas pu être lancé (\(error.localizedDescription))"
            return nil
        }
        self.process = process
        let pid = process.processIdentifier
        SessionStore.shared.registerInternalPid(pid)
        log.info("curation lancée (pid \(pid))")

        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.timeoutSeconds))
            guard !Task.isCancelled else { return }
            log.error("curation (pid \(pid)) : timeout — SIGTERM")
            self?.process?.terminate()
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            kill(pid, SIGKILL)
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
            let data = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            return String(decoding: data.suffix(2000), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        let output = await outputTask
        let errorTail = await errorTask

        // Hors MainActor : `waitUntilExit` boucle en attendant le SIGCHLD.
        await Task.detached(priority: .utility) { process.waitUntilExit() }.value
        timeoutTask?.cancel()
        timeoutTask = nil
        SessionStore.shared.unregisterInternalPid(pid)
        self.process = nil

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

    private static func saveState(_ state: PersistedState) {
        try? FileManager.default.createDirectory(at: BridgePaths.learningDirectory,
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
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
