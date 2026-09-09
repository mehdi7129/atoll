import Foundation
import Observation
import AtollCore
import os

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "codex-permission")

/// Cartes d'autorisation **Codex** en attente d'une décision de l'utilisateur.
///
/// ⚠️ STRICTEMENT SÉPARÉ D'`InteractionCenter`. Ce n'est pas de la duplication
/// gratuite : `InteractionCenter` porte l'auto-approbation Rockstar, qui suspend
/// les règles `permissions.deny` que l'utilisateur a écrites pour CLAUDE. Faire
/// passer une demande Codex par là lui appliquerait une politique pensée pour un
/// autre CLI, sur des règles qui ne le concernent pas. Codex l'a posé comme
/// condition en relisant son propre contrat, et la PR d'origine avait déjà bâti
/// toute son isolation là-dessus.
///
/// CE LOT EST UN RELAIS MANUEL, ET RIEN D'AUTRE : pas d'auto-approbation, pas de
/// « toujours autoriser ». Le contrat du hook ne promet qu'une décision pour la
/// demande courante — il ne permet pas de modifier durablement la politique de
/// Codex, et prétendre le contraire serait mentir à l'utilisateur.
@MainActor
@Observable
final class CodexInteractionCenter {
    static let shared = CodexInteractionCenter()

    /// Une demande en attente. Plusieurs peuvent coexister pour une MÊME
    /// session : deux outils peuvent demander en parallèle, et les fusionner
    /// répondrait à l'une par la décision de l'autre.
    struct Pending: Identifiable, Equatable {
        let id: String            // requestID, lié au fd côté serveur
        let sessionID: String
        let projectName: String
        let tool: String
        let receivedAt: Date
        /// PID du helper bloqué. C'est la SEULE preuve fiable qu'il attend
        /// encore : l'EOF ne vaut rien ici, le helper faisant un half-close
        /// normal après son envoi (mesuré le 2026-09-09).
        let helperPid: pid_t
    }

    private(set) var pending: [Pending] = []

    /// Le serveur du socket Codex, pour répondre sur le bon descripteur.
    @ObservationIgnored weak var server: BridgeServer?

    /// La plus ancienne demande en attente — celle que l'îlot montre.
    var current: Pending? { pending.first }

    func register(event: CodexHookEvent, requestID: String, helperPid: pid_t) {
        let card = Pending(
            id: requestID,
            sessionID: event.sessionID,
            projectName: event.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex",
            tool: event.tool ?? "Codex",
            receivedAt: Date(),
            helperPid: helperPid)
        pending.append(card)
        log.info("carte Codex \(requestID, privacy: .public) — \(card.tool, privacy: .public)")
    }

    /// Décision de l'utilisateur. Le helper la revalide de son côté : cette
    /// double barrière est voulue, c'est lui qui parle à Codex.
    func decide(_ requestID: String, _ decision: CodexPermissionDecision) {
        guard let index = pending.firstIndex(where: { $0.id == requestID }) else { return }
        pending.remove(at: index)
        guard let payload = decision.hookOutput() else {
            // Encodage impossible : on rend la main plutôt que d'envoyer
            // n'importe quoi — un octet mal formé REFUSERAIT l'action.
            handBack(requestID)
            return
        }
        server?.reply(requestID, decision: payload)
    }

    /// « Décider dans Codex » : retirer la carte, PUIS fermer sans répondre.
    ///
    /// L'ORDRE COMPTE. L'invite native de Codex n'apparaît que si aucun hook ne
    /// décide : tant que notre carte est là, elle est retenue. Fermer d'abord
    /// ferait surgir l'invite native pendant que la carte d'Atoll est encore
    /// affichée — les deux interfaces concurrentes qu'on veut éviter.
    func handBack(_ requestID: String) {
        pending.removeAll { $0.id == requestID }
        server?.cancelPending(requestID)
        log.info("carte Codex \(requestID, privacy: .public) rendue à Codex")
    }

    /// Une session qui se termine emporte ses demandes : le helper est mort
    /// avec elle, répondre sur ces descripteurs n'atteindrait personne.
    func cancelAll(forSession sessionID: String) {
        for card in pending where card.sessionID == sessionID {
            server?.cancelPending(card.id)
        }
        pending.removeAll { $0.sessionID == sessionID }
    }

    /// Retire les cartes dont le helper est MORT.
    ///
    /// Sans cela, tuer une session Codex sans qu'elle émette `SessionEnd`
    /// (terminal fermé d'un coup, `SIGKILL`) laissait une CARTE FANTÔME
    /// jusqu'au timeout de 600 s : plus personne n'attendait, et un clic
    /// envoyait une décision dans le vide. Trouvé en mesurant la matrice de
    /// fautes, pas en relisant.
    ///
    /// `kill(pid, 0)` ne tue rien : il teste l'existence du processus.
    func dropCardsOfDeadHelpers() {
        let dead = pending.filter { $0.helperPid > 0 && kill($0.helperPid, 0) != 0 }
        for card in dead {
            log.info("helper \(card.helperPid) disparu — carte \(card.id, privacy: .public) retirée")
            handBack(card.id)
        }
    }

    /// Filet de nettoyage sur `PostToolUse`, et RIEN DE PLUS.
    ///
    /// `PermissionRequest` ne porte pas de `tool_use_id` : le nom d'outil ne
    /// distingue pas deux demandes simultanées identiques. On ne referme donc
    /// que s'il n'y a AUCUNE ambiguïté — un seul candidat pour cette session et
    /// cet outil. Sinon on ne touche à rien : une carte de trop se ferme au
    /// clic, une carte fermée à tort perd une décision de l'utilisateur.
    func noteToolFinished(sessionID: String, tool: String?) {
        guard let tool else { return }
        let candidates = pending.filter { $0.sessionID == sessionID && $0.tool == tool }
        guard candidates.count == 1, let card = candidates.first else { return }
        handBack(card.id)
    }
}
