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
        /// ⚠️ UN PID SEUL N'EST PAS UNE IDENTITÉ DE PROCESSUS. Réutilisé avant
        /// le passage du timer, `kill(pid, 0)` validerait un processus
        /// ÉTRANGER et la carte survivrait à son helper. Le couple
        /// `(pid, startTime)` est l'identité ; le projet composait déjà ce
        /// couple ailleurs. Constat de Codex en revue.
        let helperStartTime: Double?
        /// Tour auquel la demande appartient. Une interruption ne clôt qu'un
        /// TOUR, pas la session : sans lui, annuler sur `Interrupt` emporterait
        /// les demandes d'un tour qui n'a pas été interrompu.
        let turnID: String?
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
            helperPid: helperPid,
            helperStartTime: helperPid > 0 ? ProcessInspector.startTime(of: helperPid) : nil,
            turnID: event.turnID)
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

    /// Retire les cartes dont plus personne n'attend la réponse.
    ///
    /// Sans cela, tuer une session Codex sans qu'elle émette `SessionEnd`
    /// (terminal fermé d'un coup, `SIGKILL`) laissait une CARTE FANTÔME
    /// jusqu'au timeout de 600 s : plus personne n'attendait, et un clic
    /// envoyait une décision dans le vide. Trouvé en mesurant la matrice de
    /// fautes, pas en relisant.
    ///
    /// LE JUGEMENT LUI-MÊME VIT DANS `CodexCardReaper`, testé : ses trois
    /// branches — pid inconnu, PID recyclé, filet absolu — ont chacune été un
    /// défaut réel, et aucune n'était vérifiable tant qu'elles étaient écrites
    /// ici, contre `kill(2)`. Cette méthode ne fait plus que fournir la sonde.
    func dropCardsOfDeadHelpers(now: Date = Date()) {
        let cards = pending.map {
            CodexCardReaper.Card(id: $0.id, helperPid: $0.helperPid,
                                 helperStartTime: $0.helperStartTime,
                                 receivedAt: $0.receivedAt)
        }
        let expired = CodexCardReaper.expired(cards, now: now) { pid in
            // `isAlive` ne tue rien et distingue ESRCH (disparu) d'EPERM
            // (existe, autre compte) — la nuance qui évite de retirer une carte
            // vivante.
            .init(isAlive: ProcessInspector.isAlive(pid),
                  startTime: ProcessInspector.startTime(of: pid))
        }
        for id in expired {
            log.info("plus personne n'attend — carte \(id, privacy: .public) retirée")
            handBack(id)
        }
    }

    /// Toutes les cartes d'un TOUR interrompu — l'utilisateur a coupé, plus
    /// personne n'attend la réponse à une demande de ce tour.
    ///
    /// `SessionEnd` avait son nettoyage (`cancelAll(forSession:)`), pas
    /// l'interruption : une carte pouvait survivre à un ⎋ jusqu'au passage du
    /// reaper ou à l'expiration de 600 s. Constat de Codex, revue du
    /// 2026-09-09.
    func cancelAll(forSession sessionID: String, turn: String) {
        for card in pending where card.sessionID == sessionID && card.turnID == turn {
            handBack(card.id)
        }
    }

    /// Cartes d'une session qui ne portent AUCUN tour, quand la clôture n'en
    /// nomme aucun non plus. C'est tout ce qu'on peut retirer sans deviner :
    /// une carte qui nomme son tour n'est pas prouvée close par un `Stop`
    /// anonyme.
    func cancelUnattributedCards(forSession sessionID: String) {
        for card in pending where card.sessionID == sessionID && card.turnID == nil {
            handBack(card.id)
        }
    }
}

// ⛔️ `noteToolFinished` A ÉTÉ RETIRÉ le 2026-09-09, et il faut dire pourquoi
// avant que quelqu'un le réintroduise.
//
// Ce filet fermait une carte quand `PostToolUse` arrivait et qu'il ne restait
// qu'UN candidat pour cette session et cet outil. Codex avait lui-même proposé
// la règle du candidat unique, puis l'a mesurée insuffisante : elle compte les
// candidats APRÈS le retrait des cartes déjà tranchées. Deux demandes
// identiques A et B attendent, l'utilisateur autorise A, la carte de A part ;
// le `PostToolUse` de A arrive alors que B est devenue l'unique candidate, et
// c'est B qu'on rendait au client — sa demande attendait toujours.
//
// Il n'est pas remplacé par une règle plus fine : il n'apportait AUCUNE
// garantie que les quatre autres autorités n'apportent déjà, chacune sur un
// fait constaté et non déduit — le clic (UUID), le retour explicite,
// `SessionEnd` / l'interruption, la mort du helper (`CodexCardReaper`) et
// l'expiration serveur (`onPendingExpired`). Un cinquième chemin qui devine
// ne pouvait que se tromper.
