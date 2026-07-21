import Foundation

/// Erreurs du magasin de skills appris. Co-localisée avec `LearnedSkillStore`
/// (elle n'a pas de sens sans lui) mais top-level : les sites d'appel écrivent
/// `catch let error as LearnedSkillError` sans préfixe redondant.
public enum LearnedSkillError: LocalizedError, Equatable {
    case invalidSlug(String)
    case collisionWithUnmanagedDirectory(String)
    case manifestUnreadable
    case userModifiedWithoutForce(String)
    case illegalTransition

    public var errorDescription: String? {
        switch self {
        case .invalidSlug(let slug):
            return "Slug de skill invalide : « \(slug) »."
        case .collisionWithUnmanagedDirectory(let dirName):
            return "Le dossier « \(dirName) » existe déjà dans ~/.claude/skills et n'est pas géré par Atoll — rien n'a été touché."
        case .manifestUnreadable:
            return "Manifeste des skills installés illisible — aucune suppression effectuée."
        case .userModifiedWithoutForce(let slug):
            return "Le skill « \(slug) » a été modifié à la main — relancer avec force pour l'écraser (l'existant sera archivé)."
        case .illegalTransition:
            return "Transition d'état de proposition interdite."
        }
    }
}

/// Magasin des skills appris (Phase 7c) : revue des propositions en quarantaine
/// (`learningRoot/proposed/`), activation dans `skillsRoot` (~/.claude/skills)
/// et désinstallation intégrale — avec `learningRoot/installed.json` pour
/// manifeste (cf. `InstalledSkillsManifest`).
///
/// Invariants ABSOLUS :
/// - `skillsRoot` contient des skills TIERS : Atoll ne touche QUE les dossiers
///   `atoll-<slug>` listés dans SON manifeste (double verrou : préfixe géré ET
///   entrée du manifeste). Les dossiers étrangers ne sont jamais énumérés pour
///   suppression, jamais modifiés ;
/// - manifeste présent mais illisible → FAIL-CLOSED : `manifestUnreadable`,
///   ZÉRO suppression (absent = simplement rien d'installé) ;
/// - rien n'est jamais détruit sans copie préalable dans
///   `learningRoot/archive/` (approved/, rejected/, uninstalled/) ;
/// - écritures ATOMIQUES : le `SKILL.md` est monté dans un dossier temporaire
///   de `skillsRoot` puis posé d'un seul `moveItem` (même volume) ; le
///   manifeste s'écrit en `.atomic` ;
/// - flux d'approbation ordonné pour rester récupérable par `reconcile()`
///   après un crash à n'importe quelle étape : skill posé → manifeste →
///   meta.json → déplacement de la proposition en archive ;
/// - horodatage des dossiers d'archive dérivé de `now()` injecté, format
///   `yyyyMMdd-HHmmss` UTC — déterministe et testable ; collision de nom →
///   suffixe `-2`, `-3`… (jamais d'écrasement d'archive).
public struct LearnedSkillStore {

    /// Bilan de `reconcile()` — informatif, l'appelant décide quoi afficher.
    public struct ReconcileReport: Equatable, Sendable {
        /// Slugs retirés du manifeste (leur dossier a disparu du disque).
        public let removedFromManifest: [String]
        /// Noms de dossiers `atoll-*` présents mais hors manifeste — signalés,
        /// JAMAIS touchés (triés pour un rapport déterministe).
        public let unmanaged: [String]
        /// Slugs dont le `SKILL.md` sur disque diffère du hash du manifeste.
        public let userModified: [String]

        public init(removedFromManifest: [String], unmanaged: [String], userModified: [String]) {
            self.removedFromManifest = removedFromManifest
            self.unmanaged = unmanaged
            self.userModified = userModified
        }
    }

    /// Bilan de `uninstallAll()`.
    public struct UninstallReport: Equatable, Sendable {
        /// Slugs dont le dossier a été supprimé de `skillsRoot`.
        public let removed: [String]
        /// Slugs modifiés par l'utilisateur, copiés en archive AVANT suppression.
        public let archived: [String]

        public init(removed: [String], archived: [String]) {
            self.removed = removed
            self.archived = archived
        }
    }

    /// Dossiers d'infrastructure d'Atoll dans ~/.claude/skills : posés hors du
    /// manifeste des skills appris (par le bridge), donc jamais « non gérés »
    /// et jamais candidats à la désinstallation par ce store.
    private static let infrastructureDirNames: Set<String> = ["atoll-recall"]

    public let learningRoot: URL
    public let skillsRoot: URL
    private let now: () -> Date

    /// Racines injectables pour les tests ; défauts = chemins réels.
    public init(
        learningRoot: URL = BridgePaths.learningDirectory,
        skillsRoot: URL = BridgePaths.claudeSkillsDirectory,
        now: @escaping () -> Date = Date.init
    ) {
        self.learningRoot = learningRoot
        self.skillsRoot = skillsRoot
        self.now = now
    }

    // MARK: - Chemins dérivés

    private var fm: FileManager { .default }

    private var proposedDirectory: URL {
        learningRoot.appendingPathComponent("proposed", isDirectory: true)
    }

    private var archiveDirectory: URL {
        learningRoot.appendingPathComponent("archive", isDirectory: true)
    }

    private var manifestURL: URL {
        learningRoot.appendingPathComponent("installed.json")
    }

    // MARK: - Découverte

    /// Propositions en quarantaine de statut `proposed`, triées par date de
    /// création (nom de dossier en départage — ordre stable). Tout dossier
    /// illisible (meta corrompu, statut inconnu, SKILL.md absent ou non-UTF-8)
    /// est ignoré en silence : la revue ne plante jamais sur un artefact abîmé.
    public func discoverProposals() -> [SkillProposal] {
        let entries = (try? fm.contentsOfDirectory(
            at: proposedDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .compactMap(loadProposal(in:))
            .filter { $0.status == .proposed }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    private func loadProposal(in directory: URL) -> SkillProposal? {
        guard let meta = try? Data(contentsOf: directory.appendingPathComponent("meta.json")),
              let skillMD = try? String(
                contentsOf: directory.appendingPathComponent("SKILL.md"),
                encoding: .utf8
              )
        else { return nil }
        return SkillProposal.decode(metaJSON: meta, skillMD: skillMD, directoryURL: directory)
    }

    // MARK: - Approbation

    /// Active une proposition dans `skillsRoot` (flux crash-safe, cf. doc du
    /// type). `force` n'a d'effet que sur une MISE À JOUR dont le `SKILL.md`
    /// sur disque a été modifié à la main — l'existant est alors archivé
    /// d'abord, jamais perdu.
    @discardableResult
    public func approve(_ proposal: SkillProposal, force: Bool = false) throws -> InstalledSkill {
        guard SkillProposal.canTransition(from: proposal.status, to: .approved) else {
            throw LearnedSkillError.illegalTransition
        }
        // (a) le slug ne devient un chemin qu'une fois validé.
        guard let slug = SkillSlug.validate(proposal.slug) else {
            throw LearnedSkillError.invalidSlug(proposal.slug)
        }
        let dirName = SkillSlug.dirName(for: slug)
        let target = skillsRoot.appendingPathComponent(dirName, isDirectory: true)
        var manifest = try readManifestOrThrow()
        let existingIndex = manifest.skills.firstIndex { $0.slug == slug }
        let stamp = timestamp()

        // (b) dossier déjà présent : mise à jour si géré, adoption si c'est
        // notre propre installation à moitié terminée (crash entre le move et
        // le manifeste), refus si c'est un dossier étranger.
        if fm.fileExists(atPath: target.path) {
            let diskMD = try? String(
                contentsOf: target.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            )
            if let index = existingIndex {
                // SKILL.md absent/illisible compte comme modifié (nil ≠ hash).
                if diskMD.map(InstalledSkillsManifest.sha256) != manifest.skills[index].skillSHA256,
                   !force {
                    throw LearnedSkillError.userModifiedWithoutForce(slug)
                }
                // Copie de l'ancien contenu AVANT écrasement — rien n'est perdu.
                if let diskMD {
                    let backupDir = uniqueArchiveURL(category: "uninstalled", slug: slug, stamp: stamp)
                    try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
                    try Data(diskMD.utf8).write(to: backupDir.appendingPathComponent("SKILL.md"))
                }
            } else if diskMD.map(InstalledSkillsManifest.sha256) == InstalledSkillsManifest.sha256(proposal.skillMD) {
                // Hors manifeste MAIS contenu identique à ce qu'on s'apprête à
                // poser : c'est une approbation interrompue (crash) qu'on REPREND
                // — on ne re-throw pas collision, on finit d'écrire le manifeste.
            } else {
                // Contenu différent = vrai dossier étranger : on n'y touche pas.
                throw LearnedSkillError.collisionWithUnmanagedDirectory(dirName)
            }
        }

        // (c) écriture ATOMIQUE : monté dans un dossier temporaire du même
        // volume, posé d'un seul move — jamais de skill à moitié écrit.
        try fm.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        let staging = skillsRoot.appendingPathComponent(
            ".\(dirName).tmp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) } // inerte après le move (chemin disparu)
        try Data(proposal.skillMD.utf8).write(to: staging.appendingPathComponent("SKILL.md"))
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target) // l'ancien contenu vient d'être archivé
        }
        try fm.moveItem(at: staging, to: target)

        // Destination d'archive calculée AVANT le manifeste pour que
        // `sourceArchivePath` la référence (informatif : si le move final
        // échouait, `reconcile()` terminerait vers un horodatage frais).
        let proposalArchive = uniqueArchiveURL(category: "approved", slug: slug, stamp: stamp)

        // (d) manifeste APRÈS le skill : un crash entre les deux laisse un
        // dossier posé sans entrée → « unmanaged » au reconcile, intouchable.
        let entry = InstalledSkill(
            slug: slug,
            dirName: dirName,
            installedAt: existingIndex.map { manifest.skills[$0].installedAt } ?? now(),
            updatedAt: existingIndex == nil ? nil : now(),
            skillSHA256: InstalledSkillsManifest.sha256(proposal.skillMD),
            sourceArchivePath: proposalArchive.path
        )
        if let index = existingIndex {
            manifest.skills[index] = entry
        } else {
            manifest.skills.append(entry)
        }
        try writeManifest(manifest)

        // (e) statut du meta d'abord, déplacement ENSUITE : un crash entre les
        // deux laisse `proposed/<slug>` avec un statut ≠ proposed, que
        // `reconcile()` sait terminer.
        rewriteMetaStatus(of: proposal.directoryURL, to: .approved)
        // Source disparue = déjà archivée par une autre instance/un reconcile
        // concurrent : le skill est bien installé (ci-dessus), on n'échoue pas
        // sur un déplacement devenu sans objet.
        if fm.fileExists(atPath: proposal.directoryURL.path) {
            try fm.createDirectory(
                at: proposalArchive.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fm.moveItem(at: proposal.directoryURL, to: proposalArchive)
        }
        return entry
    }

    // MARK: - Rejet

    /// Déplace la proposition vers `archive/rejected/<slug>-<ts>/` (statut du
    /// meta mis à jour au passage). RIEN n'est supprimé.
    public func reject(_ proposal: SkillProposal) throws {
        guard SkillProposal.canTransition(from: proposal.status, to: .rejected) else {
            throw LearnedSkillError.illegalTransition
        }
        rewriteMetaStatus(of: proposal.directoryURL, to: .rejected)
        // Slug invalide → repli sur le nom du dossier (déjà un composant de
        // chemin sûr) : un rejet doit toujours pouvoir aboutir.
        let component = SkillSlug.validate(proposal.slug) ?? proposal.directoryURL.lastPathComponent
        let destination = uniqueArchiveURL(category: "rejected", slug: component, stamp: timestamp())
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fm.moveItem(at: proposal.directoryURL, to: destination)
    }

    // MARK: - Désinstallation unitaire

    /// Retire un skill installé : copie du `SKILL.md` vers
    /// `archive/uninstalled/<slug>-<ts>/` AVANT de retirer le dossier, puis
    /// entrée retirée du manifeste. Slug hors manifeste → no-op (le dossier
    /// éventuel n'est pas géré par Atoll, on n'y touche pas).
    public func archiveInstalled(slug rawSlug: String) throws {
        guard let slug = SkillSlug.validate(rawSlug) else {
            throw LearnedSkillError.invalidSlug(rawSlug)
        }
        var manifest = try readManifestOrThrow()
        guard let index = manifest.skills.firstIndex(where: { $0.slug == slug }) else { return }
        let entry = manifest.skills[index]
        let target = skillsRoot.appendingPathComponent(entry.dirName, isDirectory: true)

        // Double verrou avant toute suppression : préfixe géré ET manifeste.
        if entry.dirName.hasPrefix(SkillSlug.managedPrefix), fm.fileExists(atPath: target.path) {
            if let skillMD = try? String(
                contentsOf: target.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            ) {
                let backupDir = uniqueArchiveURL(category: "uninstalled", slug: slug, stamp: timestamp())
                try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
                try Data(skillMD.utf8).write(to: backupDir.appendingPathComponent("SKILL.md"))
            }
            try fm.removeItem(at: target)
        }
        manifest.skills.remove(at: index)
        try writeManifest(manifest)
    }

    // MARK: - Lecture

    /// Entrées du manifeste ; absent OU illisible → [] (lecture seule, le
    /// fail-closed strict est réservé aux opérations destructrices).
    public func installedSkills() -> [InstalledSkill] {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = InstalledSkillsManifest.decode(data) else { return [] }
        return manifest.skills
    }

    // MARK: - Réconciliation

    /// Remet le disque et le manifeste d'accord après crash ou intervention
    /// manuelle. N'est JAMAIS destructif :
    /// - entrée du manifeste sans dossier → retirée (le dossier a été supprimé
    ///   à la main, acté) ;
    /// - dossier `atoll-*` hors manifeste → listé `unmanaged`, jamais touché ;
    /// - `SKILL.md` divergeant du hash → listé `userModified`, jamais touché ;
    /// - `proposed/<dir>` dont le meta n'est plus `proposed` (déplacement
    ///   inachevé, crash entre meta et move) → déplacement terminé vers
    ///   l'archive correspondante ;
    /// - manifeste illisible → traité comme vide SANS réécriture : tous les
    ///   dossiers `atoll-*` remontent `unmanaged`, rien n'est modifié.
    public func reconcile() -> ReconcileReport {
        var removedFromManifest: [String] = []
        var userModified: [String] = []
        var unmanaged: [String] = []

        let manifest = (try? Data(contentsOf: manifestURL))
            .flatMap(InstalledSkillsManifest.decode)

        if var manifest {
            var kept: [InstalledSkill] = []
            for entry in manifest.skills {
                let dir = skillsRoot.appendingPathComponent(entry.dirName, isDirectory: true)
                guard fm.fileExists(atPath: dir.path) else {
                    removedFromManifest.append(entry.slug)
                    continue
                }
                kept.append(entry)
                let diskMD = try? String(
                    contentsOf: dir.appendingPathComponent("SKILL.md"),
                    encoding: .utf8
                )
                if diskMD.map(InstalledSkillsManifest.sha256) != entry.skillSHA256 {
                    userModified.append(entry.slug)
                }
            }
            if !removedFromManifest.isEmpty {
                manifest.skills = kept
                try? writeManifest(manifest)
            }
        }

        // Dossiers atoll-* hors manifeste : signalés, jamais touchés.
        let managedDirNames = Set(installedSkills().map(\.dirName))
        let children = (try? fm.contentsOfDirectory(
            at: skillsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for child in children {
            let name = child.lastPathComponent
            guard name.hasPrefix(SkillSlug.managedPrefix),
                  // `atoll-recall` est le skill d'INFRASTRUCTURE d'Atoll (posé par
                  // le bridge, hors manifeste des skills appris) : légitime, jamais
                  // « non géré ».
                  !Self.infrastructureDirNames.contains(name),
                  (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  !managedDirNames.contains(name)
            else { continue }
            unmanaged.append(name)
        }
        unmanaged.sort()

        sweepStagingLeaks()
        finishIncompleteMoves()

        return ReconcileReport(
            removedFromManifest: removedFromManifest,
            unmanaged: unmanaged,
            userModified: userModified
        )
    }

    /// Retire les dossiers de staging orphelins (`.atoll-<slug>.tmp-<uuid>`)
    /// laissés dans `skillsRoot` par un crash pendant `approve()` — cachés
    /// (préfixe `.`) donc invisibles pour Claude Code, mais à ne pas accumuler.
    private func sweepStagingLeaks() {
        guard let children = try? fm.contentsOfDirectory(
            at: skillsRoot,
            includingPropertiesForKeys: nil
            // PAS de skipsHiddenFiles : les stagings SONT cachés.
        ) else { return }
        for child in children {
            let name = child.lastPathComponent
            if name.hasPrefix(".\(SkillSlug.managedPrefix)"), name.contains(".tmp-") {
                try? fm.removeItem(at: child)
            }
        }
    }

    /// Termine les déplacements interrompus : un dossier de `proposed/` dont
    /// le meta porte un statut décidé (≠ proposed) part vers l'archive
    /// correspondante. Meta illisible ou statut inconnu → laissé en place
    /// (quarantaine), jamais supprimé. Best-effort intégral.
    private func finishIncompleteMoves() {
        let entries = (try? fm.contentsOfDirectory(
            at: proposedDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for dir in entries {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let rawStatus = object["status"] as? String,
                  let status = SkillProposal.Status(rawValue: rawStatus),
                  status != .proposed
            else { continue }

            let category: String
            switch status {
            case .approved: category = "approved"
            case .rejected: category = "rejected"
            case .archived: category = "uninstalled"
            case .proposed: continue
            }
            let component = (object["slug"] as? String).flatMap(SkillSlug.validate)
                ?? dir.lastPathComponent
            let destination = uniqueArchiveURL(category: category, slug: component, stamp: timestamp())
            try? fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fm.moveItem(at: dir, to: destination)
        }
    }

    // MARK: - Désinstallation intégrale

    /// Retire TOUS les skills du manifeste, et EUX SEULS. Manifeste présent
    /// mais illisible → `manifestUnreadable`, ZÉRO suppression (fail-closed) ;
    /// absent → rien d'installé, no-op. Un `SKILL.md` modifié par l'utilisateur
    /// est copié vers `archive/uninstalled/` avant la suppression. Les dossiers
    /// étrangers ne sont JAMAIS énumérés — seule la liste du manifeste guide.
    @discardableResult
    public func uninstallAll() throws -> UninstallReport {
        guard fm.fileExists(atPath: manifestURL.path) else {
            return UninstallReport(removed: [], archived: [])
        }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = InstalledSkillsManifest.decode(data) else {
            throw LearnedSkillError.manifestUnreadable
        }

        var removed: [String] = []
        var archived: [String] = []
        let stamp = timestamp()

        for entry in manifest.skills {
            // Double verrou : préfixe géré ET entrée du manifeste.
            guard entry.dirName.hasPrefix(SkillSlug.managedPrefix) else { continue }
            let dir = skillsRoot.appendingPathComponent(entry.dirName, isDirectory: true)
            guard fm.fileExists(atPath: dir.path) else { continue }

            let diskMD = try? String(
                contentsOf: dir.appendingPathComponent("SKILL.md"),
                encoding: .utf8
            )
            if let diskMD, InstalledSkillsManifest.sha256(diskMD) != entry.skillSHA256 {
                let backupDir = uniqueArchiveURL(category: "uninstalled", slug: entry.slug, stamp: stamp)
                try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
                try Data(diskMD.utf8).write(to: backupDir.appendingPathComponent("SKILL.md"))
                archived.append(entry.slug)
            }
            try fm.removeItem(at: dir)
            removed.append(entry.slug)
        }

        try writeManifest(InstalledSkillsManifest())
        return UninstallReport(removed: removed, archived: archived)
    }

    // MARK: - Aides privées

    /// Manifeste absent = vide ; présent mais illisible = fail-closed.
    private func readManifestOrThrow() throws -> InstalledSkillsManifest {
        guard fm.fileExists(atPath: manifestURL.path) else {
            return InstalledSkillsManifest()
        }
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = InstalledSkillsManifest.decode(data) else {
            throw LearnedSkillError.manifestUnreadable
        }
        return manifest
    }

    private func writeManifest(_ manifest: InstalledSkillsManifest) throws {
        try fm.createDirectory(at: learningRoot, withIntermediateDirectories: true)
        try manifest.encoded().write(to: manifestURL, options: .atomic)
    }

    /// `archive/<category>/<slug>-<stamp>[-N]` — premier chemin libre, les
    /// archives ne s'écrasent jamais entre elles.
    private func uniqueArchiveURL(category: String, slug: String, stamp: String) -> URL {
        let parent = archiveDirectory.appendingPathComponent(category, isDirectory: true)
        let base = "\(slug)-\(stamp)"
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var counter = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base)-\(counter)", isDirectory: true)
            counter += 1
        }
        return candidate
    }

    /// Réécrit `status` (+ append à `history`) dans le meta.json du dossier.
    /// Best-effort : un meta illisible n'interrompt pas le flux — l'archive de
    /// destination reste la source de vérité de l'état.
    private func rewriteMetaStatus(of directory: URL, to status: SkillProposal.Status) {
        let metaURL = directory.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        object["status"] = status.rawValue
        var history = object["history"] as? [[String: Any]] ?? []
        history.append(["status": status.rawValue, "at": iso8601(now())])
        object["history"] = history
        guard let output = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? output.write(to: metaURL, options: .atomic)
    }

    /// `20260719-000000` — horodatage de dossier d'archive, UTC, dérivé de
    /// `now()` (déterministe en test, jamais le fuseau machine).
    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: now())
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
