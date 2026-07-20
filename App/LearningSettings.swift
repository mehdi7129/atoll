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

    /// Budget dollar par rétrospective (--max-budget-usd) : plafond dur côté CLI.
    static let budgetUSD = 1.50

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
    }
}
