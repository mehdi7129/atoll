import Foundation
import Observation
import AtollCore

/// État visible de l'upgrade. Un échec se retente sans réarmer les fonctions
/// retirées ; la création de skills attend le succès de cette porte d'entrée.
@MainActor
@Observable
final class EssentialMigration {
    static let shared = EssentialMigration()
    private var completedHome: URL?
    var isComplete: Bool {
        if CodexPreview.enabled { return true }
        return !isRunning && completedHome != nil && CodexPaths.configurationError == nil && completedHome == CodexPaths.homeURL
    }
    private(set) var isRunning = false
    private(set) var errorMessage: String?
    private(set) var warnings: [String] = []
    @ObservationIgnored private var active: Task<Bool, Never>?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    @discardableResult
    func run() async -> Bool {
        guard !CodexPreview.enabled else { return true }
        if let active { return await active.value }
        isRunning = true
        completedHome = nil
        errorMessage = nil
        warnings = []
        let task = Task { @MainActor in
            var migratedHome: URL?
            var homeError: String?
            do {
                // Une sélection Codex corrompue ne justifie aucun repli vers
                // un autre compte et ne suspend pas la restitution Claude.
                let home = try? CodexPaths.validatedHome()
                if home == nil { homeError = CodexPaths.configurationError ?? "Home Codex indisponible : vérifie la connexion avant de reprendre les skills." }
                let store = EssentialMigrationStore(home: BridgePaths.homeDirectory, codexHome: home)
                try await HookInstaller.beginEssentialMigration()
                defer { HookInstaller.endEssentialMigration() }

                // Aucun dictionnaire global de préférences, aucune donnée de
                // compte. Le choix du switch skills n'est jamais modifié.
                let defaults = self.defaults
                let keys = ["learningCurationWeekly", "learningProactiveRecall", "memoryIndexingEnabled",
                            "soundsEnabled", "autonomyLevel", "codexFailoverEnabled"]
                var previous: [String: Any] = [:]
                for key in keys { previous[key] = defaults.object(forKey: key) ?? NSNull() }
                let data = try JSONSerialization.data(withJSONObject: previous, options: [.sortedKeys])
                try await Task.detached(priority: .utility) { try store.preservePreferences(data) }.value
                for key in keys where key != "autonomyLevel" { defaults.set(false, forKey: key) }
                defaults.set("manual", forKey: "autonomyLevel")
                let report = try await Task.detached(priority: .utility) { try store.run() }.value
                guard home == nil || CodexPaths.homeURL == home else {
                    throw HookInstaller.InstallerError.helperFailed("Le home Codex a changé : relance la migration depuis la connexion courante.")
                }
                self.warnings = report.warnings
                migratedHome = home
            } catch {
                self.errorMessage = "Migration incomplète : \(error.localizedDescription)"
                return false
            }
            // Les pointeurs vers le bundle courant sont rafraîchis seulement
            // après la transaction disque, hors de sa section exclusive.
            do {
                try await HookInstaller.repairPassiveIfInstalled(includeCodex: migratedHome != nil)
                if let homeError { throw HookInstaller.InstallerError.helperFailed(homeError) }
                guard CodexPaths.homeURL == migratedHome else {
                    throw HookInstaller.InstallerError.helperFailed("Le home Codex a changé pendant la réparation : relance la migration.")
                }
                self.completedHome = migratedHome
                return true
            } catch {
                self.errorMessage = "Migration incomplète : \(error.localizedDescription)"
                return false
            }
        }
        active = task
        let result = await task.value
        active = nil
        isRunning = false
        return result
    }
}
