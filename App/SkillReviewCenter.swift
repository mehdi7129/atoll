import Foundation
import Observation
import OSLog
import AtollCore

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "learning")

/// Une ligne « skill appris » pour le pane Réglages : l'entrée du manifeste
/// enrichie de son usage (compté depuis l'index mémoire) et de drapeaux d'état.
struct InstalledSkillRow: Identifiable {
    let skill: InstalledSkill
    var usageCount: Int?
    var lastUsedAt: Date?
    var userModified: Bool
    var id: String { "\(skill.destination.rawValue):\(skill.slug)" }

    /// Suggestion d'archivage : installé depuis > 30 j et jamais/plus utilisé.
    var suggestedForArchive: Bool {
        // L'index n'atteste pas encore une couverture exhaustive de 30 jours.
        // Un zéro observé, ou Codex non instrumenté, ne prouve aucun abandon.
        false
    }
}

/// Centre de revue des skills appris (Phase 7c). Découvre les propositions en
/// quarantaine, applique les décisions (approuver/rejeter/archiver) via le
/// `LearnedSkillStore` (toute la sûreté disque vit là), et expose l'état à l'UI.
///
/// Distinct d'`InteractionCenter` (couplé aux hooks bloquants) : une revue de
/// skill n'a aucun helper à débloquer — les décisions sont de simples opérations
/// de fichiers, jamais un `server.reply`.
@MainActor
@Observable
final class SkillReviewCenter {
    static let shared = SkillReviewCenter()

    private func store(for provider: AgentProvider) -> LearnedSkillStore { LearnedSkillStore(destination: provider) }
    private(set) var approving: SkillProposal.ID?

    private(set) var proposals: [SkillProposal] = []
    private(set) var installed: [InstalledSkillRow] = []
    private(set) var reconcileNotes: [String] = []
    private(set) var lastError: String?

    var pendingCount: Int { proposals.count }

    /// Au lancement : réconcilie le manifeste avec le disque (orphelins,
    /// déplacements inachevés, éditions manuelles) puis découvre les propositions.
    func reconcileAndScan() {
        let reports = AgentProvider.allCases.map { store(for: $0).reconcile() }
        var notes: [String] = []
        for report in reports {
        if !report.removedFromManifest.isEmpty {
            notes.append("Retirés (supprimés à la main) : \(report.removedFromManifest.joined(separator: ", "))")
        }
        if !report.unmanaged.isEmpty {
            notes.append("Dossiers atoll-* non gérés : \(report.unmanaged.joined(separator: ", "))")
        }
        if !report.userModified.isEmpty {
            notes.append("Modifiés par vous : \(report.userModified.joined(separator: ", "))")
        }
        }
        reconcileNotes = notes
        refresh()
    }

    /// Recharge propositions + skills installés + stats d'usage.
    func refresh() {
        let problems = AgentProvider.allCases.compactMap { provider in
            store(for: provider).manifestProblem().map { "\(provider.label) : \($0)" }
        }
        if !problems.isEmpty { lastError = problems.joined(separator: "\n") }
        proposals = AgentProvider.allCases.flatMap { store(for: $0).discoverProposals() }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        similarByProposal = similarByProposal.filter { id, _ in proposals.contains { $0.id == id } }
        similarByProposal.merge(computeSimilarities(for: proposals.filter { $0.destination == .claude })) { _, new in new }
        let usage = loadUsage()
        installed = AgentProvider.allCases.flatMap { provider in
            let store = store(for: provider)
            let userModified = Set(store.reconcile().userModified)
            return store.installedSkills().map { skill in
            let stat = provider == .claude ? (usage[skill.dirName] ?? usage[skill.slug]) : nil
            return InstalledSkillRow(
                skill: skill,
                usageCount: stat?.count,
                lastUsedAt: stat?.lastUsed,
                userModified: userModified.contains(skill.slug)
            )
            }
        }
    }

    func approve(_ proposal: SkillProposal, force: Bool = false) {
        guard approving == nil else { return }
        guard proposals.contains(proposal) else {
            lastError = "La proposition a changé : relis-la avant de confirmer l'installation."
            return
        }
        let id = proposal.id
        let target: SkillDestination
        do { target = try self.target(for: proposal.destination) }
        catch { lastError = error.localizedDescription; return }
        approving = id
        Task {
            defer { approving = nil }
            do {
                let project = proposal.sourceProject.map { URL(fileURLWithPath: $0) }
                let entries = try await target.catalog(project: project)
                guard target == (try self.target(for: proposal.destination)),
                      proposals.contains(proposal) else { throw AnalysisExecution.Failure("La destination ou la proposition a changé : relis la proposition.") }
                let twin = target.store.skillsRoot.appendingPathComponent(SkillSlug.dirName(for: proposal.slug)).appendingPathComponent("SKILL.md").resolvingSymlinksInPath()
                let candidates = entries.filter { $0.path.resolvingSymlinksInPath() != twin }
                let match = SkillCatalog().closestMatch(slug: proposal.slug, title: proposal.title,
                    description: proposal.description, catalog: candidates)
                let label = match.map { self.label(for: $0) }
                if let label, similarByProposal[id] != label {
                    similarByProposal[id] = label
                    lastError = "Le catalogue contient « \(label) ». Relis cette antériorité avant de confirmer l'installation."
                    return
                }
                let entry = try target.store.approve(proposal, force: force)
                log.info("skill approuvé pour \(entry.destination.rawValue) : \(entry.dirName, privacy: .public)")
                lastError = nil
            } catch { lastError = error.localizedDescription }
            refresh()
        }
    }

    private func target(for provider: AgentProvider) throws -> SkillDestination {
        SkillDestination(provider: provider,
            home: provider == .codex ? try CodexPaths.validatedHome() : BridgePaths.homeDirectory.appendingPathComponent(".claude"),
            executableOverride: UserDefaults.standard.string(forKey: CodexExecutable.overrideKey) ?? "")
    }

    func reject(_ id: SkillProposal.ID) {
        guard let proposal = proposals.first(where: { $0.id == id }) else { return }
        do {
            try store(for: proposal.destination).reject(proposal)
            log.info("skill rejeté : \(proposal.slug, privacy: .public)")
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func archiveInstalled(slug: String, destination: AgentProvider) {
        do {
            try store(for: destination).archiveInstalled(slug: slug)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Un skill installé a-t-il été édité à la main ? (protège l'approbation
    /// d'une mise à jour : on confirmera avant d'écraser.)
    func isUpdateOfModifiedSkill(_ proposal: SkillProposal) -> Bool {
        installed.first { $0.skill.slug == proposal.slug && $0.skill.destination == proposal.destination }?.userModified ?? false
    }

    /// Ce slug est-il DÉJÀ installé ? Approuver le remplacera — et l'étiquette
    /// de la revue doit le dire même si l'utilisateur n'a pas édité le skill à
    /// la main (audit : elle affichait « (nouveau) », alors que le calcul
    /// d'antériorité exclut justement le jumeau en comptant sur cette mention).
    func isUpdateOfInstalledSkill(_ proposal: SkillProposal) -> Bool {
        installed.contains { $0.skill.slug == proposal.slug && $0.skill.destination == proposal.destination }
    }

    /// Antériorités calculées UNE fois par `refresh()` (jamais dans le corps
    /// d'une vue : `SkillCatalog.entries()` ouvre ~260 fichiers, 75-145 ms —
    /// mesuré en revue —, et SwiftUI rappelle le corps à chaque flèche, chaque
    /// décision, chaque changement de thème).
    private(set) var similarByProposal: [SkillProposal.ID: String] = [:]

    /// Ce que l'utilisateur peut DÉJÀ invoquer et qui recoupe cette proposition.
    func similarCapability(for proposal: SkillProposal) -> String? {
        similarByProposal[proposal.id]
    }

    /// Calcule les antériorités du lot courant.
    ///
    /// Deux règles issues de la revue :
    /// - ce que le MODÈLE déclare n'est retenu que s'il existe vraiment dans le
    ///   catalogue. Un « none », « N/A » ou un id halluciné s'affichait sinon
    ///   comme une antériorité réelle ET court-circuitait la détection locale —
    ///   la garantie se désarmait toute seule ;
    /// - le skill JUMEAU (`atoll-<slug>`, l'installation précédente de cette
    ///   même proposition) est exclu : sinon toute mise à jour se signale comme
    ///   son propre doublon, et un avertissement systématique s'apprend à
    ///   ignorer. La fenêtre a déjà « (màj) » pour ce cas.
    private func computeSimilarities(for proposals: [SkillProposal]) -> [SkillProposal.ID: String] {
        guard !proposals.isEmpty else { return [:] }
        let catalog = SkillCatalog()
        let entries = catalog.entries()
        let known = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var result: [SkillProposal.ID: String] = [:]
        for proposal in proposals {
            let twin = SkillSlug.dirName(for: proposal.slug)
            if let declared = proposal.similarExisting?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !declared.isEmpty, declared != twin, let entry = known[declared] {
                result[proposal.id] = label(for: entry)
                continue
            }
            // `entries` est passé explicitement : sans lui, chaque proposition
            // relançait un scan complet du disque sur le MainActor.
            if let match = catalog.closestMatch(slug: proposal.slug,
                                                title: proposal.title,
                                                description: proposal.description,
                                                excluding: [twin],
                                                catalog: entries) {
                result[proposal.id] = label(for: match)
            }
        }
        return result
    }

    /// « gsd:plan-phase » ou « example-skills:pdf [désactivé] » — une capacité
    /// qu'on ne peut pas invoquer n'est pas un doublon au même titre.
    private func label(for entry: CatalogEntry) -> String {
        "\(entry.id) [\(entry.origin)\(entry.isAvailable ? "" : "; désactivé")]"
    }

    func requestReviewWindow() {
        NotificationCenter.default.post(name: .atollShowSkillReview, object: nil)
    }

    private func loadUsage() -> [String: MemoryIndex.SkillUsageStat] {
        guard let index = try? MemoryIndex(url: BridgePaths.memoryDatabaseURL, mode: .readOnly),
              let stats = try? index.skillUsage(prefix: SkillSlug.managedPrefix) else { return [:] }
        index.close()
        return Dictionary(uniqueKeysWithValues: stats.map { ($0.skill, $0) })
    }

    #if DEBUG
    /// Sème une proposition factice complète (vérification visuelle du flux).
    func debugSeedProposal() {
        let slug = "test-skill"
        let dir = BridgePaths.learningProposedDirectory
            .appendingPathComponent(slug, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta = """
        { "v": 1, "slug": "\(slug)", "title": "Vérification visuelle du notch",
          "description": "Étend l'îlot, capture l'écran et regarde l'image.",
          "rationale": "Refait à la main à chaque changement d'UI — trois sessions.",
          "source_session": "debug", "project": "/Users/x/Dynamic_Island",
          "created_at": "2026-07-21T00:00:00Z", "status": "proposed", "flags": [] }
        """
        let skillMD = """
        ---
        name: atoll-test-skill
        description: Vérification visuelle du notch
        ---
        # Vérification visuelle

        1. `notifyutil -p dev.mehdiguiard.atoll.debug.expand`
        2. `screencapture -x f.png`
        3. Rogner la bande supérieure et REGARDER l'image.
        """
        try? Data(meta.utf8).write(to: dir.appendingPathComponent("meta.json"))
        try? Data(skillMD.utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        refresh()
    }
    #endif
}
