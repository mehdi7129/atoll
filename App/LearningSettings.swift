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
    static let skillDestinationKey = "learningSkillDestination" // défaut : agent de la session source
    static let thresholdKey = "learningQuotaThreshold"       // Double, défaut 0.7
    static let modelKey = "learningRetrospectiveModel"       // String, défaut "sonnet"
    /// Modèle de la CURATION des notes — String, défaut "sonnet" (jugement
    /// éditorial : fusionner sans perdre d'information).
    static let curationModelKey = "learningCurationModel"
    /// Modèle des RECHERCHES (antériorité d'un skill, plugin pertinent) —
    /// String, défaut "haiku" : comparer un besoin à quelques centaines de
    /// descriptions courtes est exactement sa taille de tâche, et c'est
    /// l'analyse la plus fréquente.
    static let searchModelKey = "learningSearchModel"

    /// Modèles proposés dans les Réglages, du plus économe au plus capable.
    static let availableModels = ["haiku", "sonnet", "opus", "fable"]
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
        validModel(UserDefaults.standard.string(forKey: Self.modelKey), fallback: "sonnet")
    }

    /// Modèle de la curation des notes (défaut : le même que la rétrospective).
    var curationModel: String {
        validModel(UserDefaults.standard.string(forKey: Self.curationModelKey), fallback: model)
    }

    /// Modèle des recherches d'antériorité et de plugins (défaut : haiku).
    var searchModel: String {
        validModel(UserDefaults.standard.string(forKey: Self.searchModelKey), fallback: "haiku")
    }

    /// Un réglage corrompu (ou un alias retiré par une MAJ du CLI) ne doit pas
    /// faire échouer tous les runs avec « unknown model » : on retombe sur le
    /// défaut plutôt que de passer une valeur douteuse à `--model`.
    private func validModel(_ raw: String?, fallback: String) -> String {
        guard let raw, Self.availableModels.contains(raw) else { return fallback }
        return raw
    }

    var maxPerWindow: Int {
        let raw = UserDefaults.standard.object(forKey: Self.maxPerWindowKey) as? Int ?? 2
        return min(max(raw, 1), 10)
    }

    /// Config du gate assemblée depuis les réglages (le reste = défauts validés).
    var gateConfig: LearningGate.Config {
        LearningGate.Config(enabled: isEnabled,
                            quotaThreshold: quotaThreshold,
                            maxPerWindow: maxPerWindow,
                            unknownQuotaMaxPerWindow: allowUnknownQuota ? 1 : 0)
    }

    static let analysisProviderKey = "analysisProvider"
    static let codexModelKey = "analysisCodexModel"
    static let unknownQuotaKey = "analysisAllowUnknownQuota"
    var analysisProvider: AgentProvider {
        AgentProvider(rawValue: UserDefaults.standard.string(forKey: Self.analysisProviderKey) ?? "") ?? .claude
    }
    var codexModel: String { UserDefaults.standard.string(forKey: Self.codexModelKey) ?? "" }
    var allowUnknownQuota: Bool {
        UserDefaults.standard.object(forKey: Self.unknownQuotaKey) as? Bool ?? true
    }

    // MARK: - Bascule vers Codex

    static let failoverEnabledKey = "codexFailoverEnabled"
    static let failoverThresholdKey = "codexFailoverThreshold"

    /// OFF par défaut : dépenser un SECOND abonnement est un choix explicite.
    var isFailoverEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.failoverEnabledKey)
    }

    /// Fraction du quota Claude à partir de laquelle on le tient pour épuisé.
    ///
    /// VOLONTAIREMENT distincte de `quotaThreshold` (le seuil du gate, 70 % par
    /// défaut). Celui-ci dit « pas assez de marge pour me permettre ça », et
    /// c'est une politique de prudence sur le compte de l'utilisateur ; celui-là
    /// dit « il n'y a plus rien ». Basculer au premier ferait payer Codex alors
    /// que Claude peut encore servir Mehdi pour son propre travail.
    var failoverThreshold: Double {
        let raw = UserDefaults.standard.object(forKey: Self.failoverThresholdKey) as? Double ?? 0.95
        return min(max(raw, 0.50), 1.0)
    }

    var failoverConfig: ProviderFailover.Config {
        ProviderFailover.Config(enabled: isFailoverEnabled,
                                claudeExhaustedAt: failoverThreshold,
                                codexExhaustedAt: failoverThreshold,
                                preferred: analysisProvider)
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
