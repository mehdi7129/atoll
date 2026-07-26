import Foundation
import Observation
import AtollCore

/// Réglages du mode apprentissage (rétrospectives de fin de session).
///
/// OPT-IN STRICT : OFF par défaut — contrairement à l'indexation mémoire
/// (passive, locale), la rétrospective consomme du quota de souscription.
/// Le toggle est aussi le kill-switch : OFF purge la file et SIGTERM le
/// processus en cours en moins d'une seconde.
@MainActor
@Observable
final class LearningSettings {
    static let shared = LearningSettings()

    static let enabledKey = "learningRetrospectiveEnabled"   // Bool, défaut false
    static let thresholdKey = "learningQuotaThreshold"       // Double, défaut 0.7
    static let modelKey = "learningRetrospectiveModel"       // String, défaut "sonnet"
    static let maxPerWindowKey = "learningMaxPerWindow"      // Int, défaut 2
    /// Curation périodique des notes (Milestone B) — Bool, défaut false : elle
    /// consomme du quota ET réécrit la mémoire, donc opt-in comme la rétrospective.
    static let curationScheduledKey = "learningCurationWeekly"
    /// Recall proactif (Milestone B) — Bool, défaut false : il rend le hook
    /// UserPromptSubmit BLOQUANT, donc jamais sans accord explicite.
    static let proactiveRecallKey = "learningProactiveRecall"
    /// Nombre de souvenirs injectés — Int, défaut 3 (clampé 1…5 par la config).
    static let proactiveRecallMaxHitsKey = "learningProactiveRecallMaxHits"
    /// Limiter les souvenirs au projet courant — Bool, défaut true.
    static let proactiveRecallProjectScopedKey = "learningProactiveRecallProjectScoped"

    /// Budget dollar par rétrospective (--max-budget-usd) : plafond dur côté CLI.
    static let budgetUSD = 1.50
    /// Intervalle de la curation automatique (jours).
    static let curationIntervalDays: TimeInterval = 7

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Seuil d'utilisation 5 h au-delà duquel on n'apprend pas (clampé — un
    /// réglage corrompu ne doit jamais désactiver le garde-fou).
    var quotaThreshold: Double {
        let raw = UserDefaults.standard.object(forKey: Self.thresholdKey) as? Double ?? 0.7
        return min(max(raw, 0.1), 0.95)
    }

    var model: String {
        UserDefaults.standard.string(forKey: Self.modelKey) ?? "sonnet"
    }

    var maxPerWindow: Int {
        let raw = UserDefaults.standard.object(forKey: Self.maxPerWindowKey) as? Int ?? 2
        return min(max(raw, 1), 10)
    }

    /// Config du gate assemblée depuis les réglages (le reste = défauts validés).
    var gateConfig: LearningGate.Config {
        LearningGate.Config(enabled: isEnabled,
                            quotaThreshold: quotaThreshold,
                            maxPerWindow: maxPerWindow)
    }

    /// La curation hebdomadaire est-elle armée ? (indépendante de la
    /// rétrospective : on peut vouloir consolider des notes déjà accumulées
    /// sans continuer d'en produire.)
    var isCurationScheduled: Bool {
        UserDefaults.standard.bool(forKey: Self.curationScheduledKey)
    }

    var isProactiveRecallEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.proactiveRecallKey)
    }

    /// Config du recall proactif telle qu'elle doit être sur disque
    /// (les bornes de `maxHits` sont appliquées par le type lui-même).
    var proactiveRecallConfig: ProactiveRecallConfig {
        let defaults = UserDefaults.standard
        return ProactiveRecallConfig(
            enabled: isProactiveRecallEnabled,
            maxHits: defaults.object(forKey: Self.proactiveRecallMaxHitsKey) as? Int
                ?? ProactiveRecallConfig.defaultMaxHits,
            projectScoped: defaults.object(forKey: Self.proactiveRecallProjectScopedKey) as? Bool
                ?? true
        )
    }

    /// Appelé au lancement et à CHAQUE bascule du toggle (pattern
    /// ModelQuotaPoller.syncWithSettings).
    func syncWithSettings() {
        if isEnabled {
            // Les répertoires n'existent qu'à l'activation (opt-in respecté).
            for url in [BridgePaths.learningNotesDirectory,
                        BridgePaths.learningProposedDirectory,
                        BridgePaths.learningArchiveDirectory] {
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        } else {
            RetrospectiveRunner.shared.disable()
        }
        NotesCurationService.shared.syncWithSettings()
    }

    /// Écrit `~/.atoll/proactive-recall.json` (source de vérité LUE PAR LE
    /// HELPER, y compris app fermée) puis réaligne les hooks : activer rend
    /// UserPromptSubmit bloquant, désactiver le remet en async. Appelé au
    /// lancement (réconciliation après un crash ou une édition manuelle) et à
    /// chaque changement de réglage.
    ///
    /// Renvoie un message d'erreur à afficher, nil si tout est en ordre.
    @discardableResult
    func syncProactiveRecall() -> String? {
        let config = proactiveRecallConfig
        do {
            // ~/.atoll en 0700 (revue) : ce dossier porte l'index mémoire de
            // TOUTES les sessions et la config lue par le helper à chaque
            // prompt. Sur une machine partagée, aucun autre compte n'a à le
            // lire ni à y écrire. Appliqué aussi à un dossier préexistant.
            let root = BridgePaths.proactiveRecallConfigURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: root.path)
            try config.encoded().write(to: BridgePaths.proactiveRecallConfigURL, options: .atomic)
        } catch {
            return "Réglage du recall proactif non enregistré : \(error.localizedDescription)"
        }
        // Sans hooks installés, il n'y a rien à réécrire (et surtout rien à
        // installer : Atoll ne touche settings.json que si l'utilisateur a
        // accepté les hooks).
        guard HookInstaller.isInstalled else { return nil }
        let settings = try? Data(contentsOf: BridgePaths.claudeSettingsURL)
        guard HookSettingsEditor.installedProactiveRecall(in: settings) != config.enabled else {
            return nil // déjà dans le bon mode
        }
        do {
            try HookInstaller.install() // idempotent : relit la config et réécrit le hook
            return nil
        } catch {
            return "Hooks non mis à jour pour le recall proactif : \(error.localizedDescription)"
        }
    }
}
