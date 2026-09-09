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

    static func forward() {
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
        var enrich: [String: Any] = [:]
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
        // UN SEUL événement attend une réponse : la demande d'autorisation. Tout
        // le reste reste de l'observation pure — aucune réponse, aucune
        // décision, aucune écriture dans les règles de sûreté de Claude.
        let isPermissionRequest = (payload["hook_event_name"] as? String) == "PermissionRequest"
        let outcome = sendToSocket(
            encoded, path: CodexPaths.socketPath,
            awaitReply: isPermissionRequest,
            replyDeadline: isPermissionRequest ? CodexPermissionTiming.helperDeadlineSeconds : nil)

        // ⚠️ ON NE RELAIE JAMAIS LES OCTETS DE L'APP. On les DÉCODE, puis on
        // RÉ-ENCODE depuis notre propre allowlist. Ce n'est pas de la prudence
        // de style : renvoyer `updatedInput`, `updatedPermissions` ou
        // `interrupt` à Codex **refuse la requête** — un octet inattendu venant
        // d'une version future d'Atoll bloquerait le travail de l'utilisateur
        // au lieu de lui rendre la main.
        //
        // Toute forme non comprise ⇒ abstention ⇒ rien sur stdout ⇒ exit 0 ⇒
        // Codex affiche son invite native. C'est le SEUL chemin de secours, et
        // il doit être atteint par tous les incidents : app absente, socket
        // fermé, carte abandonnée, deadline, réponse partielle ou trop grosse.
        if isPermissionRequest,
           let decision = CodexPermissionDecision.decode(outcome.reply),
           let json = decision.hookOutput() {
            FileHandle.standardOutput.write(json)
        }

        // FILET SONORE — même discipline que le helper Claude, et pour la même
        // raison, qui a coûté la v0.15.1 : « prendre quelque chose à
        // l'utilisateur et mourir avec » viole l'esprit de la règle n° 1. Atoll
        // fermé, aucun son Codex ne partait, alors que Mehdi met ces sons
        // précisément pour être appelé sans surveiller un écran.
        //
        // On ne joue QUE si l'enveloppe n'a pas été remise : exactement un des
        // deux sonne, jamais les deux.
        if !outcome.reached, let name = payload["hook_event_name"] as? String {
            SoundPlayer.play(hookEvent: name, provider: .codex)
        }
    }

    static func configure(install: Bool) -> Int32 {
        do {
            try CodexHookInstallation.apply(settingsURL: settingsURL, binDirectory: BridgePaths.binDirectory,
                                            helperURL: URL(fileURLWithPath: CommandLine.arguments[0]), install: install)
            return 0
        } catch {
            let message = "Installation des hooks Codex échouée : \(error.localizedDescription)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
            return 1
        }
    }
}
