import Foundation
import AtollCore

/// Façade de l'app vers le helper embarqué (une seule implémentation de
/// l'installation, dans atoll-bridge : voir Bridge/main.swift).
@MainActor
enum HookInstaller {
    static var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/atoll-bridge")
    }

    static var isInstalled: Bool {
        HookSettingsEditor.isInstalled(in: try? Data(contentsOf: BridgePaths.claudeSettingsURL))
    }

    enum InstallerError: LocalizedError {
        case helperMissing
        case helperFailed(String)

        var errorDescription: String? {
            switch self {
            case .helperMissing:
                return "Helper atoll-bridge introuvable dans le bundle."
            case .helperFailed(let message):
                return message.isEmpty ? "Le helper a échoué." : message
            }
        }
    }

    static func install() async throws {
        try await runHelper("install")
    }

    static func configureCodex(install: Bool) async throws {
        if let reason = CodexPaths.configurationError { throw InstallerError.helperFailed(reason) }
        try await runHelper(install ? "install-codex" : "uninstall-codex")
    }

    static func uninstall() async throws {
        // Rendre d'abord ses hooks sonores à l'utilisateur : une fois les hooks
        // Atoll retirés, l'app ne verrait plus passer les événements et plus
        // rien ne jouerait de son — ses `afplay` doivent reprendre du service.
        //
        // L'échec REMONTE (pas de `try?`) : c'est le dernier chemin de
        // restitution automatique. L'avaler laisserait l'utilisateur lire
        // « désinstallé » alors que ses hooks ne vivent plus que dans
        // `~/.atoll`, dossier qu'il supprimera naturellement ensuite.
        try await runHelper("uninstall", before: { try SoundCenter.shared.restoreUserSoundHooks() })
    }

    // MARK: - Rockstar : suspension des règles deny

    /// Les règles `permissions.deny` sont-elles actuellement parquées ?
    static var denyRulesParked: Bool {
        FileManager.default.fileExists(atPath: BridgePaths.rockstarParkedDenyURL.path)
    }

    /// Entrée en Rockstar : suspend les règles deny de l'utilisateur (elles
    /// s'exécutent dans Claude Code AVANT nos hooks — même en bypassPermissions,
    /// vérifié CLI 2.1.215 — les parquer est le seul moyen de tout autoriser).
    static func parkDenyRules() async throws {
        try await runHelper("rockstar-park")
    }

    /// Sortie de Rockstar : restaure les règles parquées.
    static func restoreDenyRules() async throws {
        try await runHelper("rockstar-restore")
    }

    /// Aligne le parking des règles deny sur le niveau d'autonomie. Appelé au
    /// changement de niveau, au lancement (récupération après crash : ne
    /// jamais laisser des règles parquées hors Rockstar, ni des règles actives
    /// en Rockstar) et après (dés)installation des hooks. Le parking exige
    /// Rockstar ET les hooks installés : sans hooks, Atoll ne pilote rien et
    /// n'a aucune légitimité à retirer les règles de l'utilisateur (sinon la
    /// réconciliation au lancement défait la restitution de la désinstallation).
    /// Renvoie un message d'erreur à afficher, nil si OK.
    @discardableResult
    static func syncDenyParking(level: AutonomyLevel) async -> String? {
        let request = UUID()
        parkingRequest = request
        await waitForPendingOperation()
        guard parkingRequest == request else { return nil }
        do {
            if level == .rockstar && isInstalled {
                // Idempotent : reparque aussi des règles (ré)apparues entre-temps.
                try await parkDenyRules()
            } else if denyRulesParked {
                try await restoreDenyRules()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// À chaque lancement : si les hooks sont installés, réexécute `install`
    /// (idempotent) pour réparer le wrapper si l'app a été déplacée.
    static func repairIfInstalled() async {
        await waitForPendingOperation()
        guard isInstalled else { return }
        try? await runHelper("install")
    }

    // Le MainActor sérialise la file, pas l'attente des processus. Une tâche
    // par demande absorbe les doubles clics consécutifs ; la file garde l’ordre.
    private static var pending: [String: (UUID, Task<Void, Error>)] = [:]
    private static var tail: Task<Void, Never>?
    private static var tailID: UUID?
    private static var unfinishedProcess: Process?
    private static var helperIsRunning = false
    private static var parkingRequest: UUID?

    /// Relire les états APRÈS les opérations déjà demandées. Une réparation
    /// différée ne doit pas réinstaller ce qu'une désinstallation vient de retirer.
    static func waitForPendingOperation() async {
        while let operation = tail {
            let id = tailID
            await operation.value
            if tailID == id { break }
        }
    }

    static func requireNoActiveHelper() throws {
        guard !helperIsRunning, unfinishedProcess?.isRunning != true else {
            throw InstallerError.helperFailed("Une mise à jour des hooks est en cours. Réessaie après sa fin.")
        }
    }

    static func runHelper(_ verb: String, executable: URL? = nil, timeout: TimeInterval = 20,
                          before: @escaping @MainActor () throws -> Void = {}) async throws {
        guard !CodexPreview.enabled else { return }
        let helper = executable ?? helperURL
        let home = CodexPaths.homeURL
        let key = verb + "\n" + helper.path + "\n" + home.path
        // Un verbe opposé intercalé représente une nouvelle intention :
        // install → uninstall → install doit conserver les trois opérations.
        if let (id, operation) = pending[key], tailID == id { return try await operation.value }
        let previous = tail
        let id = UUID()
        let operation = Task { @MainActor in
            if let previous { await previous.value }
            try Task.checkCancellation()
            // Une identité illisible peut interdire le kill. Ne jamais lancer
            // un second writer tant que cet enfant est encore vivant.
            guard unfinishedProcess?.isRunning != true else {
                throw InstallerError.helperFailed("Une opération précédente est encore en cours. Réessaie après sa fin.")
            }
            unfinishedProcess = nil
            guard CodexPaths.homeURL == home else {
                throw InstallerError.helperFailed("La configuration Codex a changé ; relance l’action depuis le réglage courant.")
            }
            guard FileManager.default.isExecutableFile(atPath: helper.path) else {
                throw InstallerError.helperMissing
            }
            try before() // restitution des sons DANS la même section sérialisée
            let process = Process()
            process.executableURL = helper
            process.arguments = [verb]
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = home.path
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            helperIsRunning = true
            defer { helperIsRunning = false }
            let result = try await BoundedProcessRunner.run(process, timeout: timeout,
                                                            stdoutCap: 64 * 1024, stderrCap: 8000)
            if process.isRunning { unfinishedProcess = process }
            guard result.succeeded else {
                let reason = result.timedOut || result.cancelled
                    ? "L’opération a été interrompue ; vérifie l’état affiché avant de réessayer."
                    : String(decoding: result.stderr, as: UTF8.self)
                throw InstallerError.helperFailed(reason)
            }
        }
        pending[key] = (id, operation)
        tailID = id
        tail = Task { _ = try? await operation.value }
        defer {
            if pending[key]?.0 == id { pending[key] = nil }
            if tailID == id { tail = nil; tailID = nil }
        }
        try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: { operation.cancel() }
    }
}
