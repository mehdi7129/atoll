import Foundation
import Observation
import OSLog
import AtollCore

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "learning")

/// Une ligne « skill appris » pour le pane Réglages : l'entrée du manifeste
/// enrichie de son usage (compté depuis l'index mémoire) et de drapeaux d'état.
struct InstalledSkillRow: Identifiable {
    let skill: InstalledSkill
    var usageCount: Int
    var lastUsedAt: Date?
    var userModified: Bool
    var id: String { skill.slug }

    /// Suggestion d'archivage : installé depuis > 30 j et jamais/plus utilisé.
    var suggestedForArchive: Bool {
        let old = Date().timeIntervalSince(skill.installedAt) > 30 * 86400
        let idle = lastUsedAt.map { Date().timeIntervalSince($0) > 30 * 86400 } ?? true
        return old && idle
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

    private let store = LearnedSkillStore()

    private(set) var proposals: [SkillProposal] = []
    private(set) var installed: [InstalledSkillRow] = []
    private(set) var reconcileNotes: [String] = []
    private(set) var lastError: String?

    var pendingCount: Int { proposals.count }

    /// Au lancement : réconcilie le manifeste avec le disque (orphelins,
    /// déplacements inachevés, éditions manuelles) puis découvre les propositions.
    func reconcileAndScan() {
        let report = store.reconcile()
        var notes: [String] = []
        if !report.removedFromManifest.isEmpty {
            notes.append("Retirés (supprimés à la main) : \(report.removedFromManifest.joined(separator: ", "))")
        }
        if !report.unmanaged.isEmpty {
            notes.append("Dossiers atoll-* non gérés : \(report.unmanaged.joined(separator: ", "))")
        }
        if !report.userModified.isEmpty {
            notes.append("Modifiés par vous : \(report.userModified.joined(separator: ", "))")
        }
        reconcileNotes = notes
        refresh()
    }

    /// Recharge propositions + skills installés + stats d'usage.
    func refresh() {
        proposals = store.discoverProposals()
        similarByProposal = computeSimilarities(for: proposals)
        let userModified = Set(store.reconcile().userModified)
        let usage = loadUsage()
        installed = store.installedSkills().map { skill in
            let stat = usage[skill.dirName] ?? usage[skill.slug]
            return InstalledSkillRow(
                skill: skill,
                usageCount: stat?.count ?? 0,
                lastUsedAt: stat?.lastUsed,
                userModified: userModified.contains(skill.slug)
            )
        }
    }

    func approve(_ id: SkillProposal.ID, force: Bool = false) {
        guard let proposal = proposals.first(where: { $0.id == id }) else { return }
        do {
            let entry = try store.approve(proposal, force: force)
            log.info("skill approuvé : \(entry.dirName, privacy: .public)")
            lastError = nil
        } catch {
            log.error("approbation \(proposal.slug, privacy: .public) : \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
        refresh()
    }

    func reject(_ id: SkillProposal.ID) {
        guard let proposal = proposals.first(where: { $0.id == id }) else { return }
        do {
            try store.reject(proposal)
            log.info("skill rejeté : \(proposal.slug, privacy: .public)")
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func archiveInstalled(slug: String) {
        do {
            try store.archiveInstalled(slug: slug)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Un skill installé a-t-il été édité à la main ? (protège l'approbation
    /// d'une mise à jour : on confirmera avant d'écraser.)
    func isUpdateOfModifiedSkill(_ proposal: SkillProposal) -> Bool {
        installed.first { $0.skill.slug == proposal.slug }?.userModified ?? false
    }

    /// Ce slug est-il DÉJÀ installé ? Approuver le remplacera — et l'étiquette
    /// de la revue doit le dire même si l'utilisateur n'a pas édité le skill à
    /// la main (audit : elle affichait « (nouveau) », alors que le calcul
    /// d'antériorité exclut justement le jumeau en comptant sur cette mention).
    func isUpdateOfInstalledSkill(_ proposal: SkillProposal) -> Bool {
        installed.contains { $0.skill.slug == proposal.slug }
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
        entry.isAvailable ? entry.id : "\(entry.id) [désactivé]"
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
