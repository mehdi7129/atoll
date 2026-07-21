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
