import AppKit
import Foundation
import Observation
import OSLog
import UserNotifications
import AtollCore

private let log = Logger(subsystem: "dev.mehdiguiard.atoll", category: "taskDone")

/// Prévient quand une tâche lancée depuis le notch (`claude --bg`) se termine.
///
/// Le trou que ça bouche : le cockpit ambiant (Phase 9) sait lancer une tâche et
/// l'arrêter, mais rien ne rendait la main — on lançait, on partait, et il fallait
/// penser à revenir regarder l'îlot.
///
/// PORTÉE VOLONTAIREMENT ÉTROITE : seules les tâches qu'Atoll a lancées lui-même
/// sont suivies. On ne se sert PAS du champ `kind` de `claude agents --json` pour
/// deviner qu'une session est « de fond » — `AgentSessionInfo.Kind` documente
/// qu'il n'est pas fiable (une session interactive a déjà été rapportée
/// `background`), et une notification sur une session que l'utilisateur regarde
/// serait pire que pas de notification du tout.
///
/// Deux signaux de fin, dans cet ordre de préférence :
/// 1. le hook `Stop` — porte `last_assistant_message`, donc un vrai résumé ;
/// 2. la disparition/terminaison côté flotte — filet de sûreté sans résumé
///    (hooks non installés, session tuée, Atoll redémarré en cours de route).
///
/// `LaunchedTaskLog.complete` étant idempotent, le second signal ne peut pas
/// produire une deuxième notification.
@MainActor
@Observable
final class TaskCompletionNotifier {
    static let shared = TaskCompletionNotifier()

    /// Réglage OPT-OUT (Mehdi a demandé la fonction : elle est active par
    /// défaut). Coupe la notification SYSTÈME ; la bannière du notch, elle,
    /// n'interrompt rien et reste.
    static let notifyKey = "notifyOnTaskCompletion"

    static var notificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: notifyKey) as? Bool ?? true
    }

    /// Clé de `userInfo` portant l'identifiant de session (clic → ouvrir).
    private static let sessionKey = "sessionID"
    private static let taskKey = "taskID"

    private(set) var tasks = LaunchedTaskLog()

    /// Autorisation demandée une seule fois par lancement d'app, et seulement
    /// quand elle devient pertinente (au premier lancement de tâche) — pas au
    /// démarrage d'Atoll pour une fonction que l'utilisateur n'a pas encore
    /// employée.
    @ObservationIgnored private var didRequestAuthorization = false
    /// `UNUserNotificationCenter.delegate` est une référence FAIBLE : sans cette
    /// propriété, le délégué serait libéré aussitôt posé et les clics sur les
    /// notifications ne feraient plus rien.
    @ObservationIgnored private var delegate: NotificationDelegate?

    /// Tâches terminées non encore écartées — ce que la bannière du notch montre.
    /// Bornée par la rétention : la purge n'a lieu qu'au démarrage, et une
    /// bannière éternelle masquerait celle des skills proposés.
    var unacknowledged: [LaunchedTask] { tasks.unacknowledged(now: Date()) }

    /// Ce que macOS répond quand on lui demande le droit de notifier.
    enum Authorization: Equatable {
        case unknown          // pas encore interrogé
        case notRequested     // jamais demandé à l'utilisateur
        case granted
        case denied           // l'utilisateur a refusé (Réglages système)
        case unavailable(String) // le système refuse l'enregistrement lui-même

        var explanation: String? {
            switch self {
            case .unknown, .granted: return nil
            case .notRequested:
                return "macOS n'a pas encore demandé l'autorisation. Elle sera demandée au premier lancement de tâche."
            case .denied:
                return "Les notifications sont refusées pour Atoll dans les Réglages système. L'îlot garde quand même une trace visible de chaque tâche terminée."
            case .unavailable(let reason):
                return "macOS refuse d'enregistrer Atoll pour les notifications (\(reason)). C'est le cas des builds de développement signés « adhoc » : une version signée Developer ID n'a pas ce problème."
            }
        }
    }

    private(set) var authorization: Authorization = .unknown

    /// Interroge macOS sur l'état d'autorisation. Appelé au démarrage et à
    /// l'ouverture des réglages : un échec doit être VISIBLE, pas seulement
    /// dans les logs (c'est ainsi qu'on a découvert le refus des builds adhoc).
    func refreshAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                switch status {
                case .authorized, .provisional, .ephemeral:
                    self.authorization = .granted
                case .denied:
                    self.authorization = .denied
                case .notDetermined:
                    self.authorization = .notRequested
                @unknown default:
                    self.authorization = .unknown
                }
                log.info("autorisation de notification : \(String(describing: self.authorization), privacy: .public)")
            }
        }
    }

    /// Demande l'autorisation à la demande de l'utilisateur (bouton des
    /// réglages). Renseigne `authorization` avec la vraie raison d'un échec.
    func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        didRequestAuthorization = true
        installDelegateIfNeeded()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor in
                if let error {
                    self.authorization = .unavailable(error.localizedDescription)
                    log.error("autorisation refusée : \(error.localizedDescription, privacy: .public)")
                } else {
                    self.authorization = granted ? .granted : .denied
                }
            }
        }
    }

    /// Ouvre le volet Notifications des Réglages système (seul endroit où un
    /// refus se défait).
    func openSystemNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Cycle de vie

    func start() {
        load()
        tasks.prune(now: Date())
        save()
        // Le délégué doit être posé tôt : c'est lui qui reçoit le clic sur une
        // notification, y compris celle qui réveille l'app.
        installDelegateIfNeeded()
        // Demander l'autorisation AU DÉMARRAGE quand la fonction est active :
        // c'est l'appel à `requestAuthorization` qui INSCRIT l'app auprès du
        // centre de notifications (vérifié : sans lui, Atoll n'apparaît même pas
        // dans Réglages système › Notifications et le statut lu reste
        // « refusé »). macOS ne pose la question qu'une fois.
        //
        // Une seule des deux voies, sinon leurs deux complétions écrivent
        // `authorization` en dernier-arrivé-gagne : la demande renseigne déjà
        // l'état, la lecture ne sert que si on ne demande rien.
        if Self.notificationsEnabled {
            requestAuthorizationIfNeeded()
        } else {
            refreshAuthorization()
        }
    }

    private func installDelegateIfNeeded() {
        guard delegate == nil, Bundle.main.bundleIdentifier != nil else { return }
        let delegate = NotificationDelegate()
        self.delegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
    }

    // MARK: - Lancement

    /// Enregistre une tâche lancée depuis le notch.
    /// `sessionID` peut être nil (sortie de `--bg` illisible) : la session sera
    /// rattachée plus tard par `adopt(fleetSession:)`.
    func register(task: String, cwd: String, sessionID: String?) {
        let entry = LaunchedTask(task: task, cwd: cwd, launchedAt: Date(), sessionID: sessionID)
        tasks.register(entry)
        save()
        log.info("tâche suivie — id \(sessionID ?? "inconnu", privacy: .public)")
        requestAuthorizationIfNeeded()
    }

    /// Rattachement de secours quand `claude --bg` n'a pas imprimé d'id lisible :
    /// une session de flotte qui apparaît dans le même dossier juste après le
    /// lancement est très probablement la nôtre (critères stricts côté cœur).
    func adopt(sessionID: String, cwd: String?, startedAt: Date?) {
        guard !tasks.pending.isEmpty else { return } // cas courant : rien à faire
        guard tasks.adopt(sessionID: sessionID, cwd: cwd, startedAt: startedAt) != nil else { return }
        log.info("session \(sessionID, privacy: .public) rattachée à une tâche lancée")
        save()
    }

    // MARK: - Fin

    /// Signal PRÉFÉRÉ : le hook `Stop` porte le dernier message de l'assistant.
    func handleTurnEnded(sessionID: String, lastAssistantMessage: String?) {
        guard let index = tasks.pendingIndex(forSessionID: sessionID) else { return }
        let summary = TaskCompletion.summarize(lastAssistantMessage: lastAssistantMessage,
                                               fallback: tasks.tasks[index].task)
        finish(at: index, summary: summary)
    }

    /// Réconciliation avec la flotte : clôt les tâches dont la session n'est
    /// plus listée. Sans elle, une tâche terminée pendant qu'Atoll était fermé
    /// n'était JAMAIS annoncée — le journal persisté ne servait à rien dans le
    /// seul cas où il devait servir.
    func reconcileWithFleet(activeSessionIDs: Set<String>) {
        let toAnnounce = tasks.reconcile(activeSessionIDs: activeSessionIDs, now: Date())
        guard !toAnnounce.isEmpty || tasks.pending.isEmpty == false else { return }
        for index in toAnnounce {
            let summary = TaskCompletion.summarize(lastAssistantMessage: nil,
                                                   fallback: tasks.tasks[index].task)
            if let finished = tasks.complete(at: index, date: Date(), summary: summary) {
                log.info("tâche close par réconciliation : \(finished.projectName, privacy: .public)")
                deliver(finished)
            }
        }
        save()
    }

    /// Filet de sûreté : la session a disparu ou s'est terminée côté flotte,
    /// sans qu'aucun hook `Stop` ne soit passé. Pas de résumé disponible → on
    /// rappelle la tâche demandée.
    func handleSessionGone(sessionID: String) {
        guard let index = tasks.pendingIndex(forSessionID: sessionID) else { return }
        let summary = TaskCompletion.summarize(lastAssistantMessage: nil,
                                               fallback: tasks.tasks[index].task)
        finish(at: index, summary: summary)
    }

    private func finish(at index: Int, summary: String) {
        guard let finished = tasks.complete(at: index, date: Date(), summary: summary) else { return }
        save()
        log.info("tâche terminée dans \(finished.projectName, privacy: .public)")
        deliver(finished)
    }

    // MARK: - Bannière du notch

    func acknowledge(_ task: LaunchedTask) {
        acknowledge(id: task.id)
    }

    func acknowledge(id: UUID) {
        tasks.acknowledge(id: id)
        save()
    }


    // MARK: - Notification système

    private func requestAuthorizationIfNeeded() {
        guard Self.notificationsEnabled, !didRequestAuthorization else { return }
        // Sans bundle (tests, outils), UNUserNotificationCenter.current() lève.
        guard Bundle.main.bundleIdentifier != nil else { return }
        requestAuthorization()
    }

    private func deliver(_ task: LaunchedTask) {
        guard Self.notificationsEnabled, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = TaskCompletion.notificationTitle(projectName: task.projectName)
        content.body = task.summary ?? task.task
        // Le son de la notification ferait DOUBLON avec celui d'Atoll (le hook
        // `Stop` déclenche déjà `taskCompleted` au même instant) — et il sort au
        // volume système, ce qui donnerait l'impression que le curseur de volume
        // ne sert à rien. Atoll d'abord ; le ding système seulement s'il n'y a
        // rien d'autre à entendre.
        let atollWillPlay = SoundCenter.shared.soundsEnabled
            && !SoundCenter.shared.choice(for: .taskCompleted).isSilent
        content.sound = atollWillPlay ? nil : .default
        var info: [String: String] = [Self.taskKey: task.id.uuidString]
        if let sessionID = task.sessionID { info[Self.sessionKey] = sessionID }
        content.userInfo = info
        // `trigger: nil` = livraison immédiate.
        let request = UNNotificationRequest(identifier: task.id.uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                log.error("notification non livrée : \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    #if DEBUG
    /// Simule une tâche terminée pour vérifier la bannière et la notification
    /// sans attendre une vraie session `--bg`. La tâche est explicitement
    /// étiquetée : elle ne doit jamais pouvoir passer pour un vrai résultat.
    func debugSimulateCompletion() {
        let sessionID = "debug-\(UUID().uuidString)"
        register(task: "(test Atoll) vérifier la bannière de fin de tâche",
                 cwd: FileManager.default.currentDirectoryPath, sessionID: sessionID)
        handleTurnEnded(sessionID: sessionID, lastAssistantMessage: """
            **Terminé** : la chaîne de fin de tâche fonctionne.

            ```swift
            // ce bloc de code ne doit PAS apparaître dans le résumé
            let x = 1
            ```
            """)
    }
    #endif

    // MARK: - Persistance

    private func load() {
        guard let data = try? Data(contentsOf: BridgePaths.launchedTasksURL) else { return }
        guard let decoded = try? JSONDecoder().decode(LaunchedTaskLog.self, from: data) else {
            // Fichier illisible (format d'une version future, corruption) : on
            // repart d'un journal vide plutôt que de rester coincé — ce fichier
            // n'est qu'un confort, jamais une source de vérité.
            log.error("journal des tâches illisible — réinitialisé")
            return
        }
        tasks = decoded
    }

    /// Écriture SYNCHRONE sur le MainActor, comme `SessionStore.writeSnapshot`.
    ///
    /// Surtout pas en `Task.detached` : deux sauvegardes rapprochées (le
    /// rattachement d'une session par le poller, puis le hook `Stop` 50 ms plus
    /// tard) partiraient en parallèle et l'ordre des renames n'est pas garanti.
    /// Le plus ANCIEN état pouvait gagner — donc perdre le drapeau `notified`,
    /// et re-notifier la même tâche au redémarrage suivant. Le fichier fait
    /// quelques kilo-octets : le coût est négligeable, l'ordre est gratuit.
    private func save() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        let url = BridgePaths.launchedTasksURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Clic sur la notification

/// Délégué séparé, volontairement SANS état : `TaskCompletionNotifier` est
/// `@Observable` et @MainActor, on évite de lui greffer une conformité ObjC.
/// Il est retenu par le notifier (la propriété `delegate` du centre est faible).
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {

    /// Afficher la bannière même quand Atoll est « au premier plan » : l'app est
    /// LSUIElement (aucune fenêtre principale), donc être active ne veut pas dire
    /// que l'utilisateur regarde quelque chose d'Atoll. Sans ceci, macOS avale
    /// silencieusement la notification.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let sessionID = info["sessionID"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // On n'ACQUITTE PAS ici : acquitter retire la tâche de la
                // bannière, et l'îlot qu'on vient d'ouvrir s'afficherait vide.
                // Le cas dominant est un clic tardif (la notification a attendu
                // dans le centre de notifications) : la session a alors déjà été
                // retirée du store, et la bannière est la SEULE trace du
                // résultat. C'est le bouton « VU » qui acquitte.
                NotificationCenter.default.post(
                    name: .atollRevealTask, object: nil,
                    userInfo: sessionID.map { ["sessionID": $0] })
            }
            completionHandler()
        }
    }
}
