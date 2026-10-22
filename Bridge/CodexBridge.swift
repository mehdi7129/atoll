import Foundation
import AtollCore

enum CodexBridge {
    static var settingsURL: URL {
        CodexPaths.hooksURL
    }

    /// Marqueur posé par Atoll sur les `codex exec` qu'il lance LUI-MÊME
    /// (bilan de fin de session, rangement des notes quand le quota Claude est
    /// épuisé). Hérité par le hook, donc lisible ici.
    static let internalRunMarker = "ATOLL_RETROSPECTIVE"

    static func forward(socketPath: String = CodexPaths.socketPath) {
        guard isatty(0) == 0 else { return }
        // ⚠️ ATOLL NE DOIT PAS SE REGARDER TRAVAILLER. Le marqueur existait
        // depuis la Phase 7b et n'était lu QUE côté Claude (`reconcile()`) : un
        // `codex exec` lancé par Atoll déclenchait donc les hooks comme
        // n'importe quelle session, et l'îlot montrait à l'utilisateur une
        // session Codex qu'il n'avait pas ouverte. Le commentaire de
        // `RetrospectiveRunner` disait « filtré par reconcile() » — vrai pour
        // Claude, et personne n'avait posé la question pour Codex.
        //
        // On s'abstient AVANT de lire stdin : rien n'est envoyé, rien n'est
        // écrit sur stdout, exit 0. Une demande d'autorisation d'un run interne
        // retombe donc sur la politique par défaut de Codex, ce qui est le bon
        // comportement — il n'y a personne devant l'écran pour y répondre.
        guard ProcessInfo.processInfo.environment[internalRunMarker] == nil else { return }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard data.count <= 8_388_608,
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        // MÊME enrichissement que le chemin Claude, et pour la même raison :
        // sans lui, `terminalAnchor` ne connaît aucune session Codex et le
        // jump-back reste mort — alors que le mécanisme (`cursor -r <cwd>`) est
        // parfaitement agnostique au fournisseur. C'est ce qui rend le passage
        // de Claude Code à Codex transparent (demande de Mehdi, 2026-09-09).
        //
        // Toujours AUCUNE réponse, aucune décision : on enrichit ce qu'on
        // observe, on ne prend pas la main sur Codex.
        var enrich: [String: Any] = ["observedAt": Date().timeIntervalSince1970,
                                     "codexHome": CodexPaths.cliHomeURL.path]
        if let identity = ProcessInspector.findCodexTUIAncestor(from: getpid()) {
            enrich["sessionPid"] = identity.pid
            enrich["sessionStartTime"] = identity.startedAt
        }
        if let tty = ProcessInspector.tty(of: getpid()) { enrich["tty"] = tty }
        let environment = ProcessInfo.processInfo.environment
        if let hint = environment["__CFBundleIdentifier"] ?? environment["TERM_PROGRAM"] {
            enrich["terminalHint"] = hint
        }
        let subset = TerminalAnchor.capture(from: environment)
        if !subset.isEmpty { enrich["env"] = subset }

        var envelope: [String: Any] = ["v": 1, "provider": "codex", "payload": payload]
        if !enrich.isEmpty { envelope["enrich"] = enrich }
        guard CodexHookEvent(envelope: envelope) != nil,
              let encoded = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        // Même PermissionRequest ne fait qu'observer l'attente native.
        // Le serveur peut être ancien, muet ou envoyer une décision : on ne lit
        // jamais sa réponse et stdout reste vide.
        _ = sendToSocket(encoded, path: socketPath)
    }

    static func configure(install: Bool) -> Int32 {
        if let error = CodexPaths.configurationError {
            try? FileHandle.standardError.write(contentsOf: Data((error + "\n").utf8))
            return 1
        }
        var hooksApplied = false
        do {
            // argv[0] peut être un nom nu cherché dans PATH. Le noyau donne
            // l'image réellement exécutée, indépendante du dossier courant.
            guard let helperPath = ProcessInspector.executablePath(of: getpid()) else {
                throw CocoaError(.fileReadUnknown)
            }
            let helperURL = URL(fileURLWithPath: helperPath)
            try CodexHookInstallation.apply(settingsURL: settingsURL, binDirectory: BridgePaths.binDirectory,
                                            helperURL: helperURL, install: install)
            hooksApplied = true
            // Les skills appris restent installés à la déconnexion. Le recall
            // legacy est traité sélectivement par la migration, jamais réinstallé.
            return 0
        } catch {
            let phase = hooksApplied
                ? "Hooks Codex \(install ? "installés" : "retirés"), gestion des skills incomplète"
                : "\(install ? "Installation" : "Retrait") des hooks Codex échoué"
            let message = "\(phase) : \(error.localizedDescription)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            return 1
        }
    }
}
