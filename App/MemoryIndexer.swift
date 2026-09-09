import Foundation
import Observation
import OSLog
import AtollCore

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "memory")

/// Indexation mémoire : tous les transcripts de ~/.claude/projects sont versés
/// dans l'index FTS5 (~/.atoll/memory.db), interrogeable par les sessions Claude
/// via `atoll-bridge recall`.
///
/// Façade MainActor observable (stats pour les Réglages) + worker actor qui
/// possède la connexion SQLite : le MainActor n'est JAMAIS bloqué, tout le
/// travail tourne en priorité .utility. Le TranscriptTailer est volontairement
/// ignoré ici : il saute les gros deltas (> 1 Mo) et plafonne ses watches —
/// l'indexeur lit lui-même, avec offsets persistants et sans perte.
@MainActor
@Observable
final class MemoryIndexer {
    static let shared = MemoryIndexer()
    /// Clé ABSENTE des defaults = activé (opt-out) : l'indexation est locale,
    /// passive et ne consomme aucun quota. (La rétrospective, elle, est opt-in.)
    static let enabledKey = "memoryIndexingEnabled"

    private(set) var stats: MemoryIndex.Stats?
    private(set) var isIndexing = false

    @ObservationIgnored private let worker = MemoryIndexWorker()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var nudgeDrain: Task<Void, Never>?
    @ObservationIgnored private var pendingNudges: Set<String> = []

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Démarre/arrête la boucle selon le réglage. Appelé au lancement et à
    /// chaque bascule du toggle (pattern ModelQuotaPoller.syncWithSettings).
    func syncWithSettings() {
        if isEnabled {
            startScanLoop()
        } else {
            scanTask?.cancel()
            scanTask = nil
            nudgeDrain?.cancel()
            nudgeDrain = nil
            pendingNudges.removeAll()
            isIndexing = false
            Task { await worker.closeIndex() }
        }
    }

    /// Le transcript d'une session vivante vient d'être complété (fin de tour) :
    /// indexation quasi temps réel, coalescée (débounce 2 s, pattern snapshot).
    func nudge(transcriptPath: String) {
        guard isEnabled else { return }
        pendingNudges.insert(transcriptPath)
        guard nudgeDrain == nil else { return }
        nudgeDrain = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            let paths = Array(self.pendingNudges)
            self.pendingNudges.removeAll()
            self.nudgeDrain = nil
            await self.worker.indexFiles(paths)
            await self.refreshStatsNow()
        }
    }

    /// Repart de zéro : détruit la base (donnée dérivée) et relance un scan
    /// complet. Utile si l'index semble incohérent ou après changement de schéma.
    func rebuild() {
        guard isEnabled else { return }
        scanTask?.cancel()
        scanTask = nil
        // Le drain de nudges aussi : sinon un indexFile en vol s'intercale
        // avec la destruction (acteur réentrant) et écrit dans le vide (revue).
        nudgeDrain?.cancel()
        nudgeDrain = nil
        pendingNudges.removeAll()
        isIndexing = true
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.worker.destroyDatabase()
            self.stats = nil
            self.isIndexing = false
            self.syncWithSettings()
        }
    }

    func refreshStats() {
        Task { [weak self] in await self?.refreshStatsNow() }
    }

    /// Note d'apprentissage (7b) écrite par Atoll → indexée comme DONNÉE
    /// (rôle `note`) : recall la retrouve, elle n'est jamais une instruction.
    func indexNote(url: URL, slug: String) {
        guard isEnabled else { return }
        Task(priority: .utility) { [weak self] in
            await self?.worker.indexNoteFile(url: url, slug: slug)
            await self?.refreshStatsNow()
        }
    }

    /// Curation (Milestone B) : les notes remplacées sont OUBLIÉES de l'index
    /// (pas seulement marquées absentes — une note consolidée ne doit plus
    /// jamais remonter dans un recall) et les nouvelles sont indexées.
    /// L'ordre compte : oublier d'abord, sinon une nouvelle note portant le
    /// même chemin qu'une ancienne serait effacée juste après son insertion.
    func replaceNotes(forgotten: [String], written: [URL]) {
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            // L'OUBLI a lieu même si l'indexation est coupée (revue) : sinon
            // les notes remplacées restaient dans une base que `recall` et le
            // recall proactif lisent DIRECTEMENT, sans consulter le réglage —
            // du contenu effacé du disque continuait d'être injecté. Le worker
            // ne touche pas à une base absente.
            await self.worker.forgetFilesIfDatabaseExists(forgotten)
            guard self.isEnabled else { return }
            for url in written {
                await self.worker.indexNoteFile(url: url, slug: MemoryIndexer.noteSlug(for: url))
            }
            await self.refreshStatsNow()
        }
    }

    /// « 2026-07-20-mon-slug.md » → « mon-slug » ; « 01-mon-titre.md »
    /// (note curée) → « 01-mon-titre ». Seul un préfixe de 11 caractères
    /// entièrement composé de chiffres et de tirets est retiré.
    /// `nonisolated` : appelée aussi depuis le worker (contexte non-MainActor).
    nonisolated static func noteSlug(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        // Motif STRICT `AAAA-MM-JJ-` (revue) : « 11 caractères de chiffres et
        // de tirets » amputait une note curée titrée « 2026 07 20 : bilan »
        // (fichier `01-2026-07-20-bilan.md` → slug « 20-bilan »).
        let prefix = stem.prefix(11)
        let isDateStamp = prefix.count == 11
            && prefix.enumerated().allSatisfy { index, character in
                (index == 4 || index == 7 || index == 10) ? character == "-" : character.isNumber
            }
        guard stem.count > 11, isDateStamp else { return stem }
        return String(stem.dropFirst(11))
    }

    private func startScanLoop() {
        guard scanTask == nil else { return }
        scanTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.isIndexing = true
                await self.worker.scanAll()
                self.isIndexing = false
                await self.refreshStatsNow()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func refreshStatsNow() async {
        stats = await worker.currentStats()
        if let stats {
            log.debug("stats: \(stats.sessionCount) sessions, \(stats.messageCount) messages, \(stats.databaseBytes) octets")
        } else {
            // Cas NORMAL quand l'indexation est coupée (aucune base) : ce n'est
            // pas une erreur, et le panneau affiche « — » plutôt que des zéros.
            log.debug("stats indisponibles (index absent ou fermé)")
        }
    }
}

/// Possède la connexion SQLite (MemoryIndex est non-Sendable : confinement par
/// l'acteur). Sérialise naturellement scans complets et nudges concurrents.
private actor MemoryIndexWorker {
    private var index: MemoryIndex?
    /// Dernier stat vu par chemin : un fichier inchangé (inode/taille/mtime)
    /// est sauté sans toucher la base — le re-scan de 30 s coûte ~un stat/fichier.
    private var lastSeen: [String: (inode: UInt64, size: Int64, mtime: TimeInterval)] = [:]

    private static let chunkSize = 4 * 1024 * 1024
    private static let batchSize = 500

    func closeIndex() {
        index?.close()
        index = nil
        lastSeen.removeAll()
    }

    func destroyDatabase() {
        closeIndex()
        destroyFiles()
    }

    /// Statistiques — SANS jamais créer la base, pour la même raison que
    /// `forgetFilesIfDatabaseExists` : ouvrir l'index revient à fabriquer un
    /// fichier que l'utilisateur ne veut pas. Ouvrir les Réglages recréait
    /// `~/.atoll/memory.db` (schéma FTS5 complet) alors que l'indexation était
    /// coupée et la base supprimée à la main — ce que le texte du réglage
    /// invite pourtant à faire (audit du 2026-07-27).
    func currentStats() -> MemoryIndex.Stats? {
        guard FileManager.default.fileExists(atPath: BridgePaths.memoryDatabaseURL.path) else {
            return nil
        }
        guard let index = openIndexIfNeeded() else { return nil }
        return try? index.stats()
    }

    /// Découverte + différentiel : strictement ~/.claude/projects/<dir>/*.jsonl
    /// (profondeur 2 — jamais de récursion : les sidecars <uuid>/ et memory/
    /// sont exclus par construction).
    func scanAll() async {
        guard let index = openIndexIfNeeded() else { return }
        let fm = FileManager.default
        // ⚠️ DEUX SOURCES INDÉPENDANTES. Ce `guard` faisait un `return` sec :
        // sans `~/.claude/projects`, la passe entière s'arrêtait AVANT le scan
        // Codex — donc un utilisateur CODEX SEUL n'indexait rien du tout.
        // C'est précisément le cas d'usage de Mehdi (« utiliser l'un sans
        // l'autre ») et une violation directe de l'isolation. Trouvé par Codex
        // en revue. L'absence d'une source rend une liste vide POUR ELLE,
        // jamais l'annulation de l'autre.
        let claudeProjects = try? fm.contentsOfDirectory(
            at: BridgePaths.claudeProjectsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let projectDirs = claudeProjects ?? []

        // ⚠️ ON NE DÉCLARE DISPARU QUE CE QU'ON A RÉELLEMENT REGARDÉ.
        //
        // Le `return` sec ci-dessus protégeait, par accident, contre un second
        // défaut : un dossier MOMENTANÉMENT ILLISIBLE (volume réseau, iCloud
        // qui rapatrie, permissions en cours de changement) rend exactement la
        // même chose qu'un dossier absent — `nil`. Continuer avec une liste
        // vide ferait passer TOUTE la base par `markMissing` en fin de passe.
        // Les messages survivraient (c'est un drapeau, pas une suppression),
        // mais Atoll annoncerait disparu ce qu'il n'a pas pu lire.
        //
        // Le dépôt porte déjà cette leçon quinze lignes plus bas, pour les
        // notes : « un dossier momentanément illisible ne doit rien effacer ».
        // Chaque source n'autorise donc le ménage QUE sur son propre préfixe,
        // et seulement si son listage a réussi.
        var scannedPrefixes: [String] = []
        if claudeProjects != nil {
            scannedPrefixes.append(BridgePaths.claudeProjectsURL.path + "/")
        }

        var seenPaths = Set<String>()
        for dir in projectDirs {
            // fileExists(isDirectory:) suit les symlinks — un dossier-projet
            // déplacé sur un autre volume et lié ici reste indexé (revue :
            // isDirectoryKey renvoie false pour un lien, le dossier était sauté).
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            for file in entries where file.pathExtension == "jsonl" {
                if Task.isCancelled { return }
                seenPaths.insert(file.path)
                await indexFile(at: file, projectDir: dir.lastPathComponent, index: index)
            }
        }
        // ⚠️ LES CHEMINS CODEX DOIVENT ENTRER DANS `seenPaths`. Sans cela, la
        // fin de passe les traite tous comme DISPARUS : `markMissing` puis
        // retrait de `lastSeen`, et la passe suivante les réindexe pour les
        // remarquer manquants — une boucle d'écritures SQLite toutes les 30 s,
        // qui neutralise au passage tout le scan incrémental côté Codex.
        // Trouvé par Codex en revue ; les messages restaient cherchables, donc
        // la preuve « 714 indexés » ne le contredisait pas.
        let codex = await scanCodexRollouts(index: index)
        seenPaths.formUnion(codex.paths)
        if codex.listed {
            scannedPrefixes.append(BridgePaths.codexSessionsURL.path + "/")
        }

        // Notes d'apprentissage (7b) : re-scannées ici pour survivre à une
        // reconstruction de la base (revue : indexées seulement à l'écriture,
        // un rebuild les orphelinait de recall pour toujours).
        if let notes = try? fm.contentsOfDirectory(
            at: BridgePaths.learningNotesDirectory, includingPropertiesForKeys: nil) {
            scannedPrefixes.append(BridgePaths.learningNotesDirectory.path + "/")
            var seenNotes = Set<String>()
            for note in notes where note.pathExtension == "md" {
                if Task.isCancelled { return }
                seenPaths.insert(note.path)
                seenNotes.insert(note.path)
                indexNoteFile(url: note, slug: MemoryIndexer.noteSlug(for: note))
            }
            // Notes disparues du dossier (curation appliquée alors que
            // l'indexation était coupée, suppression manuelle) : OUBLIÉES, pas
            // marquées absentes. Une note remplacée qui continuerait de
            // remonter dans recall serait pire que pas de note du tout.
            // Ce ménage n'a lieu QUE si le dossier a pu être listé (un dossier
            // momentanément illisible ne doit rien effacer).
            let notesPrefix = BridgePaths.learningNotesDirectory.path + "/"
            if let tracked = try? index.trackedPaths(prefix: notesPrefix) {
                for path in tracked where !seenNotes.contains(path) {
                    try? index.forgetFile(path: path)
                    lastSeen[path] = nil
                }
            }
        }

        // Disparus depuis le dernier scan : marqués missing, lignes CONSERVÉES
        // (le purge 30 j de Claude Code ne doit pas amnésier Atoll). Bornée aux
        // sources effectivement listées — voir `scannedPrefixes`.
        for path in lastSeen.keys where !seenPaths.contains(path)
            && scannedPrefixes.contains(where: { path.hasPrefix($0) }) {
            try? index.markMissing(path: path)
            lastSeen[path] = nil
        }
    }

    /// Comme `forgetFiles`, mais SANS jamais créer la base : appelé quand
    /// l'indexation est désactivée, où ouvrir l'index reviendrait à fabriquer
    /// un fichier que l'utilisateur ne veut pas.
    func forgetFilesIfDatabaseExists(_ paths: [String]) {
        guard FileManager.default.fileExists(atPath: BridgePaths.memoryDatabaseURL.path) else {
            return
        }
        forgetFiles(paths)
    }

    /// Oubli d'artefacts dont Atoll est propriétaire (notes remplacées par une
    /// curation) : messages supprimés ET suivi retiré, best-effort par fichier.
    func forgetFiles(_ paths: [String]) {
        guard let index = openIndexIfNeeded() else { return }
        for path in paths {
            try? index.forgetFile(path: path)
            lastSeen[path] = nil
        }
    }

    func indexFiles(_ paths: [String]) async {
        guard let index = openIndexIfNeeded() else { return }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard url.pathExtension == "jsonl" else { continue }
            await indexFile(at: url, projectDir: url.deletingLastPathComponent().lastPathComponent,
                            index: index)
        }
    }

    /// Rollouts Codex — `~/.codex/sessions/<année>/<mois>/<jour>/*.jsonl`.
    ///
    /// POURQUOI : sans cela, une session Codex ne laisse AUCUNE trace en
    /// mémoire. Mehdi a tranché le 2026-09-09 — « quand j'utilise Codex ou
    /// Claude Code, Atoll doit fonctionner de la même manière » — et
    /// « se souvenir » est l'un des trois verbes de la vision du projet.
    ///
    /// L'arborescence est datée, donc RÉCURSIVE, contrairement au scan Claude
    /// qui est plat par construction. On la borne quand même : un dossier de
    /// sessions accumule des années, et `skipsHiddenFiles` évite les sidecars.
    /// Rend les chemins RENCONTRÉS — y compris ceux que le plafond de la passe
    /// n'a pas indexés : ils existent, et les déclarer disparus serait faux —
    /// et `listed` dit si le dossier a pu être PARCOURU. Sans ce second
    /// booléen, un `~/.codex/sessions` illisible serait indiscernable d'un
    /// dossier vide, et la fin de passe déclarerait tous les rollouts disparus.
    private func scanCodexRollouts(index: MemoryIndex) async -> (paths: Set<String>, listed: Bool) {
        let fm = FileManager.default
        let root = BridgePaths.codexSessionsURL
        var seen = Set<String>()
        guard fm.fileExists(atPath: root.path),
              let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                         options: [.skipsHiddenFiles])
        else { return (seen, false) }
        var scanned = 0
        for case let file as URL in walker {
            if Task.isCancelled { return (seen, true) }
            guard file.pathExtension == "jsonl" else { continue }
            // Compté comme VU quoi qu'il arrive : le fichier existe, et le
            // déclarer disparu serait faux.
            seen.insert(file.path)
            guard scanned < Self.codexRolloutCap else { continue }
            // ⚠️ LE PLAFOND NE COMPTE QUE LE TRAVAIL RÉEL. Il comptait AUSSI les
            // fichiers inchangés, qui ressortent pourtant d'`indexFile` en
            // quelques microsecondes grâce à `lastSeen` : les 400 premiers
            // consommaient donc toutes les places à chaque passe, et le 401e
            // n'était jamais indexé — pas « reporté », JAMAIS. L'énumérateur
            // repartant du début, la famine était permanente. Trouvé par Codex,
            // qui l'avait signalée dès sa première revue.
            // Le dossier du jour sert de « projet » : c'est ce qui apparaîtra
            // dans les statistiques, faute de notion de projet dans un rollout.
            let worked = await indexFile(
                at: file, projectDir: file.deletingLastPathComponent().lastPathComponent,
                index: index, provider: .codex)
            if worked { scanned += 1 }
        }
        return (seen, true)
    }

    /// Plafond de rollouts par passe. Le scan tourne toutes les 30 s : borner
    /// évite qu'un backfill initial monopolise le worker, sans rien perdre —
    /// la passe suivante reprend là où l'offset s'est arrêté.
    private static let codexRolloutCap = 400

    /// Indexe une note d'apprentissage (fichier .md complet, pas du JSONL) :
    /// une pseudo-session « atoll-note-<slug> » avec un unique fragment `note`.
    func indexNoteFile(url: URL, slug: String) {
        guard let index = openIndexIfNeeded(),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let inode = (attrs[.systemFileNumber] as? UInt64) ?? 0
        let size = (attrs[.size] as? Int64) ?? 0
        guard let state = try? index.openFile(path: url.path, inode: inode, size: size),
              state.offset < size else { return }
        let line = TranscriptLine(
            uuid: "note", sessionID: nil, timestamp: Date(), cwd: nil, gitBranch: nil,
            fragments: [.init(role: .title, text: "Note Atoll : \(slug)"),
                        .init(role: .note, text: text)]
        )
        try? index.ingest(lines: [(line, "note-0")], fileState: state,
                          sessionID: "atoll-note-\(slug)", projectDir: "atoll-notes",
                          newOffset: size)
    }

    // MARK: - Lecture incrémentale d'un fichier

    /// Rend `true` si la passe a RÉELLEMENT eu du travail à faire.
    ///
    /// ⚠️ CE BOOLÉEN EXISTE POUR LE PLAFOND DE ROLLOUTS CODEX, et il est rendu
    /// ICI plutôt que recalculé par l'appelant : le critère « inchangé » est
    /// celui de `lastSeen`, six lignes plus bas. Le dupliquer chez l'appelant
    /// poserait deux définitions de « inchangé » à deux endroits, promises à
    /// diverger — le motif même qui a produit un wrapper Codex corrigé dans le
    /// générateur et périmé sur le disque.
    @discardableResult
    private func indexFile(at url: URL, projectDir: String, index: MemoryIndex,
                           provider: AgentProvider = .claude) async -> Bool {
        let path = url.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        let inode = (attrs[.systemFileNumber] as? UInt64) ?? 0
        let size = (attrs[.size] as? Int64) ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if let cached = lastSeen[path], cached == (inode, size, mtime) { return false }

        // openFile purge et remet l'offset à 0 si le fichier a été remplacé
        // (inode) ou tronqué (size < offset stocké).
        guard let state = try? index.openFile(path: path, inode: inode, size: size) else { return false }
        guard state.offset < size, let handle = FileHandle(forReadingAtPath: path) else {
            lastSeen[path] = (inode, size, mtime)
            return true
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(state.offset))

        // Identifiant de session. Côté Codex le fichier s'appelle
        // `rollout-<horodatage>-<uuid>.jsonl` : on en extrait l'uuid et on le
        // préfixe `codex:`, EXACTEMENT comme `CodexSessions`. Sans ce préfixe
        // commun, l'exclusion de la session courante par le recall proactif ne
        // reconnaîtrait pas la session qui vient de poser la question.
        let sessionID = provider == .codex
            ? "codex:" + CodexRollout.sessionID(fromFileName: url.lastPathComponent)
            : url.deletingPathExtension().lastPathComponent
        var splitter = TranscriptLineSplitter(startOffset: state.offset)
        var batch: [(line: TranscriptLine, syntheticUUID: String)] = []
        var skillUses: [SkillInvocation] = [] // invocations de skills pour les stats (7c)

        // INVARIANT DE LA REVUE : un lot dont l'ingestion échoue n'est JAMAIS
        // jeté-puis-dépassé. Tout échec abandonne le fichier ENTIER sans poser
        // lastSeen : l'offset en base n'a pas avancé (transaction), le scan de
        // 30 s retentera — aucune ligne ne peut être perdue en silence.
        func flush() -> Bool {
            guard splitter.consumedOffset > state.offset || !batch.isEmpty else { return true }
            do {
                try index.ingest(lines: batch, fileState: state, sessionID: sessionID,
                                 projectDir: projectDir, newOffset: splitter.consumedOffset)
                batch.removeAll(keepingCapacity: true)
            } catch {
                log.error("ingest \(url.lastPathComponent, privacy: .public) : \(error.localizedDescription) — lot abandonné, retente au prochain scan")
                return false
            }
            // Usage des skills (7c) : enregistré AU RYTHME des lots (pas au flush
            // final) — sinon, si un lot ultérieur échoue, l'offset a déjà avancé
            // et l'usage des premiers lots serait perdu à jamais. Idempotent
            // (INSERT OR IGNORE par toolUseID), hors transaction, non critique.
            if !skillUses.isEmpty {
                try? index.recordSkillUsage(skillUses)
                skillUses.removeAll(keepingCapacity: true)
            }
            return true
        }

        while true {
            if Task.isCancelled { return true } // sans lastSeen : sera repris
            guard let chunk = try? handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
            for line in splitter.consume(chunk) {
                let parsed = provider == .codex
                    ? CodexTranscriptParser.parse(line.data)
                    : TranscriptLineParser.parse(line.data)
                if let parsed {
                    batch.append((parsed, "line-\(line.startOffset)"))
                }
                // Les invocations de skills sont un format Claude Code : les
                // chercher dans un rollout Codex ne rendrait jamais rien, et
                // fausserait les statistiques d'usage si le format collisionnait.
                if provider == .claude {
                    skillUses.append(contentsOf: SkillUsageParser.invocations(inLine: line.data))
                }
                if batch.count >= Self.batchSize, !flush() { return true }
            }
            await Task.yield() // backfill de centaines de Mo sans monopoliser un cœur
        }
        // La queue partielle (ligne incomplète en cours d'écriture) n'est JAMAIS
        // comptée dans l'offset : elle sera relue entière au prochain passage.
        // lastSeen n'est posé QUE si tout a réussi (sinon : retenté).
        if flush() {
            lastSeen[path] = (inode, size, mtime)
        }
        return true
    }

    // MARK: - Connexion

    private func openIndexIfNeeded() -> MemoryIndex? {
        if let index { return index }
        // ~/.atoll n'existe pas tant que les hooks n'ont jamais été installés :
        // sans cette création, l'indexation serait silencieusement morte (revue).
        try? FileManager.default.createDirectory(
            at: BridgePaths.memoryDatabaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        do {
            index = try MemoryIndex(url: BridgePaths.memoryDatabaseURL, mode: .readWrite)
        } catch {
            // Base illisible/corrompue : donnée MAJORITAIREMENT dérivée → on
            // repart de zéro. Mais pas tout à fait : les messages des
            // transcripts que Claude Code a purgés à 30 jours ne se
            // reconstruisent PLUS (c'est même la raison d'être de `markMissing`).
            // On met donc l'ancienne base DE CÔTÉ au lieu de la supprimer :
            // elle reste ouvrable à la main, et rien n'est perdu en silence.
            log.error("index mémoire illisible (\(error.localizedDescription)) — mise de côté et reconstruction")
            Self.setAsideDatabase()
            index = try? MemoryIndex(url: BridgePaths.memoryDatabaseURL, mode: .readWrite)
        }
        // Ménage rétroactif, une seule fois : le filtre d'ingestion ne l'est
        // pas (l'offset d'un transcript déjà lu ne recule jamais), donc sans
        // cette purge les notifications de tâches déjà indexées resteraient là
        // pour toujours et le correctif serait un mensonge.
        if let index, let removed = try? index.runHygieneIfNeeded(), removed > 0 {
            log.info("hygiène de l'index : \(removed, privacy: .public) notification(s) de tâche retirée(s)")
        }
        return index
    }

    private func destroyFiles() {
        let base = BridgePaths.memoryDatabaseURL.path
        // Les copies mises de côté partent AUSSI : « Reconstruire l'index » et la
        // désactivation doivent vraiment tout rendre (revue des corrections).
        // LES DEUX noms, depuis que `setAsideDatabase` en utilise un second —
        // en oublier un rendrait le nettoyage partiel, en silence.
        for suffix in ["", "-wal", "-shm",
                       ".illisible", ".illisible-wal", ".illisible-shm",
                       ".illisible-recent", ".illisible-recent-wal", ".illisible-recent-shm"] {
            try? FileManager.default.removeItem(atPath: base + suffix)
        }
    }

    /// Renomme la base au lieu de la supprimer : `memory.db.illisible`.
    ///
    /// Nom FIXE, sans horodatage : c'est un filet, pas un historique. Un nom
    /// daté empilait une copie de ~24 Mo par corruption — et, sur un échec
    /// d'ouverture PERSISTANT (disque plein), une nouvelle toutes les 30 s
    /// (revue des corrections, 2026-07-27).
    ///
    /// MAIS le nom fixe rendait le filet AUTODESTRUCTEUR, par ce même échec
    /// persistant : l'ouverture est retentée toutes les 30 s, et chaque passage
    /// commençait par supprimer la copie de sauvetage pour y mettre ce qui
    /// occupait alors `memory.db` — c'est-à-dire la base VIDE que la tentative
    /// précédente venait de créer. Deux passages suffisaient à remplacer les
    /// vraies données par du vide.
    ///
    /// DEUX noms fixes, donc, et pas un : `.illisible` garde la PREMIÈRE mise de
    /// côté — celle d'avant la panne, la seule qui contienne les messages des
    /// transcripts que Claude Code a purgés — et n'est plus jamais écrasée ;
    /// `.illisible-recent` reçoit les suivantes. Se contenter de sortir quand
    /// `.illisible` existe (première version de ce correctif, prise en défaut
    /// par la revue adversariale) désarmait le filet DÉFINITIVEMENT : après une
    /// première corruption réparée, une seconde laissait `memory.db` corrompu en
    /// place, la réouverture échouait sur le même fichier et l'indexation
    /// mourait en silence. Le compte de copies reste borné à deux.
    nonisolated static func setAsideDatabase() {
        let fm = FileManager.default
        let base = BridgePaths.memoryDatabaseURL.path
        let keepFirst = !fm.fileExists(atPath: base + ".illisible")
        let tag = keepFirst ? ".illisible" : ".illisible-recent"
        for suffix in ["", "-wal", "-shm"] {
            let source = base + suffix
            guard fm.fileExists(atPath: source) else { continue }
            let destination = "\(base)\(tag)\(suffix)"
            try? fm.removeItem(atPath: destination)
            // Un déplacement impossible ne se solde JAMAIS par une suppression :
            // l'ouverture continuera d'échouer et le journal le dira à chaque
            // passage — un échec bruyant vaut mieux qu'une perte muette. Les
            // messages des transcripts purgés à 30 jours ne se reconstruisent
            // pas, et « Reconstruire l'index » reste la sortie explicite.
            try? fm.moveItem(atPath: source, toPath: destination)
        }
    }
}
