import AppKit
import OSLog
import AtollCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [NotchWindowController] = []
    private var screenObserver: NSObjectProtocol?
    private var rebuildTask: Task<Void, Never>?
    private var lastScreenSignature = ""
    private var bridgeServer: BridgeServer?
    private var debugTokens: [Int32] = []
    private var onboardingController: OnboardingWindowController?

    /// Affiche la fenêtre de bienvenue — appelée par le menu et au 1er lancement.
    /// Recréée à NEUF à chaque fois : évite tout état résiduel après fermeture
    /// (une fenêtre réutilisée pouvait rester invisible → « rien ne se passe »).
    func showOnboarding() {
        onboardingController?.close()
        onboardingController = OnboardingWindowController()
        onboardingController?.show()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeManager.applyStored()
        InteractionCenter.migrateAutonomyIfNeeded()

        // Répare le wrapper ~/.atoll/bin si l'app a été déplacée (idempotent).
        HookInstaller.repairIfInstalled()

        // Récupération après crash / relance : le parking des règles deny doit
        // TOUJOURS refléter le niveau d'autonomie courant (jamais de règles
        // parquées hors Rockstar, jamais de règles actives en Rockstar).
        HookInstaller.syncDenyParking(level: InteractionCenter.shared.autonomyLevel)

        // Le menu « Bienvenue… » demande l'onboarding via cette notif (le cast
        // NSApp.delegate as? AppDelegate échoue avec @NSApplicationDelegateAdaptor).
        NotificationCenter.default.addObserver(
            forName: .atollShowOnboarding, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showOnboarding() }
        }

        // Premier lancement : fenêtre de bienvenue (hooks, fail-open, autonomie).
        if OnboardingWindowController.shouldShowAtLaunch {
            showOnboarding()
        }

        // Jauges par modèle (opt-in) : démarre le poller si le réglage est actif.
        ModelQuotaPoller.shared.syncWithSettings()

        // Démarre la réception des événements de hooks puis le suivi des sessions.
        let store = SessionStore.shared
        let server = BridgeServer(
            onEvent: { event, requestID in
                Task { @MainActor in
                    // apply() AVANT register() : la machine à états pose d'abord
                    // waitingPermission ; si register auto-approuve (rockstar/auto),
                    // il ré-avance la phase — sinon la carte reste en attente.
                    SessionStore.shared.apply(event)
                    if let requestID {
                        InteractionCenter.shared.register(event: event, requestID: requestID)
                    }
                }
            },
            onStatusline: { data in
                Task { @MainActor in
                    SessionStore.shared.applyStatusline(data)
                }
            },
            onStateChange: { running in
                Task { @MainActor in
                    SessionStore.shared.serverRunning = running
                }
            }
        )
        bridgeServer = server
        InteractionCenter.shared.server = server
        try? server.start()
        store.start()

        // Index mémoire (opt-out) : backfill + suivi incrémental des transcripts,
        // entièrement hors bande — jamais dans le chemin des hooks.
        MemoryIndexer.shared.syncWithSettings()

        // Apprentissage (opt-in, OFF par défaut) : rétrospectives de fin de
        // session. Le store notifie le runner, le runner indexe ses notes.
        LearningSettings.shared.syncWithSettings()
        SessionStore.shared.onSessionEnded = { snapshot, reason in
            RetrospectiveRunner.shared.sessionEnded(snapshot, reason: reason)
        }
        SessionStore.shared.onSessionResumed = { sessionID in
            RetrospectiveRunner.shared.sessionResumed(sessionID)
        }
        RetrospectiveRunner.shared.noteSink = { url, note in
            MemoryIndexer.shared.indexNote(url: url, slug: note.slug)
        }

        rebuildWindows()
        registerDebugTriggers()

        // didChangeScreenParameters arrive souvent en rafale (réveil, branchement
        // d'écran) : on débounce, et on ne reconstruit que si la configuration
        // d'écrans a réellement changé — sinon un îlot épinglé serait perdu.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleRebuild()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        RetrospectiveRunner.shared.terminateActive()
        bridgeServer?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.rebuildWindowsIfNeeded()
        }
    }

    private func rebuildWindowsIfNeeded() {
        guard screenSignature() != lastScreenSignature else { return }
        rebuildWindows()
    }

    private func rebuildWindows() {
        controllers.forEach { $0.tearDown() }
        let screens = NSScreen.screens
        // Un seul écran « primaire » pilote l'ouverture auto et le focus des
        // cartes (évite que les panneaux se disputent le clavier). L'écran
        // principal, ou à défaut le premier.
        let primaryScreen = NSScreen.main ?? screens.first
        controllers = screens.map { screen in
            NotchWindowController(screen: screen, isPrimary: screen == primaryScreen)
        }
        lastScreenSignature = screenSignature()
    }

    /// Pilotage de debug par notifications Darwin (local, même utilisateur) :
    ///   notifyutil -p dev.mehdiguiard.atoll.debug.expand    → étend + épingle
    ///   notifyutil -p dev.mehdiguiard.atoll.debug.compact   → replie
    /// Permet l'inspection visuelle automatisée (screenshots) sans souris.
    private func registerDebugTriggers() {
        var expandToken: Int32 = 0
        notify_register_dispatch("dev.mehdiguiard.atoll.debug.expand", &expandToken, DispatchQueue.main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controllers.forEach {
                    $0.viewModel.isPinned = true
                    $0.viewModel.open()
                }
            }
        }
        var compactToken: Int32 = 0
        notify_register_dispatch("dev.mehdiguiard.atoll.debug.compact", &compactToken, DispatchQueue.main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controllers.forEach { $0.viewModel.close() }
            }
        }
        debugTokens = [expandToken, compactToken]

        // Les triggers qui PRENNENT une décision (approuver/refuser une permission)
        // ne doivent JAMAIS exister en release : sans cela, n'importe quel processus
        // local pourrait approuver silencieusement des permissions via une simple
        // notification Darwin. Réservés aux builds Debug pour les tests scriptés.
        #if DEBUG
        // Rétrospective sur la dernière session terminée (bypass le gate —
        // consomme du quota : jamais en release).
        var retroToken: Int32 = 0
        notify_register_dispatch("dev.mehdiguiard.atoll.debug.retro", &retroToken, DispatchQueue.main) { _ in
            MainActor.assumeIsolated {
                RetrospectiveRunner.shared.debugRunOnLastEnded()
            }
        }
        debugTokens.append(retroToken)

        var allowToken: Int32 = 0
        notify_register_dispatch("dev.mehdiguiard.atoll.debug.allow", &allowToken, DispatchQueue.main) { _ in
            MainActor.assumeIsolated {
                let center = InteractionCenter.shared
                guard let request = center.current else { return }
                switch request.kind {
                case .permission:
                    center.allow(request.id)
                case .plan:
                    center.approvePlan(request.id, acceptEdits: false)
                case .questions(let questions, _):
                    var answers: [String: String] = [:]
                    for question in questions {
                        answers[question.question] = question.options.first?.label ?? "ok"
                    }
                    center.answerQuestions(request.id, answers: answers)
                }
            }
        }
        var denyToken: Int32 = 0
        notify_register_dispatch("dev.mehdiguiard.atoll.debug.deny", &denyToken, DispatchQueue.main) { _ in
            MainActor.assumeIsolated {
                let center = InteractionCenter.shared
                guard let request = center.current else { return }
                center.deny(request.id, message: "Refus de test automatisé Atoll.")
            }
        }
        // Sélectionne la 1re session (test visuel de la vue détail).
        var selectToken: Int32 = 0
        notify_register_dispatch("dev.mehdiguiard.atoll.debug.select", &selectToken, DispatchQueue.main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let vm = self?.controllers.first(where: { $0.viewModel.isPrimary })?.viewModel,
                      let first = vm.sessions.first else { return }
                vm.isPinned = true
                vm.open()
                vm.selectSession(first.id)
            }
        }
        // Jump-back de la 1re session (test visuel Phase 4).
        var jumpToken: Int32 = 0
        notify_register_dispatch("dev.mehdiguiard.atoll.debug.jump", &jumpToken, DispatchQueue.main) { _ in
            MainActor.assumeIsolated {
                let logger = Logger(subsystem: "dev.mehdiguiard.atoll", category: "jump")
                // Choisir la 1re session dont l'ancre est résolvable (pas .unknown).
                let anchors = SessionStore.shared.uiSessions.compactMap {
                    SessionStore.shared.terminalAnchor(for: $0.id)
                }
                guard let anchor = anchors.first(where: {
                    if case .unknown = TerminalResolver.resolve($0) { return false }
                    return true
                }) ?? anchors.first else {
                    logger.info("debug.jump → aucune ancre")
                    return
                }
                TerminalJumpService.jump(to: anchor) { result in
                    logger.info("debug.jump → \(String(describing: result), privacy: .public)")
                }
            }
        }
        // Ouvre la fenêtre Réglages (captures d'écran scriptées).
        var settingsToken: Int32 = 0
        notify_register_dispatch("dev.mehdiguiard.atoll.debug.settings", &settingsToken, DispatchQueue.main) { _ in
            MainActor.assumeIsolated {
                NotificationCenter.default.post(name: .atollDebugOpenSettings, object: nil)
            }
        }
        // Ouvre la fenêtre Bienvenue via la MÊME notif que le menu (test du
        // chemin complet notif → observateur → showOnboarding).
        var onboardingToken: Int32 = 0
        notify_register_dispatch("dev.mehdiguiard.atoll.debug.onboarding", &onboardingToken, DispatchQueue.main) { _ in
            MainActor.assumeIsolated {
                NotificationCenter.default.post(name: .atollShowOnboarding, object: nil)
            }
        }
        debugTokens.append(contentsOf: [allowToken, denyToken, selectToken, jumpToken, settingsToken, onboardingToken])
        #endif
    }

    /// Empreinte de la configuration d'écrans. Un tableau (pas un dictionnaire) :
    /// deux écrans identiques peuvent partager le même UUID CGDisplay.
    private func screenSignature() -> String {
        NSScreen.screens
            .map { screen in
                "\(screen.displayUUIDString)|\(NSStringFromRect(screen.frame))|\(screen.notchSize.map { "\($0)" } ?? "-")"
            }
            .sorted()
            .joined(separator: ";")
    }
}

extension Notification.Name {
    /// Le menu « Bienvenue… » demande l'ouverture de l'onboarding (l'AppDelegate
    /// l'observe — le cast NSApp.delegate as? AppDelegate échoue).
    static let atollShowOnboarding = Notification.Name("dev.mehdiguiard.atoll.showOnboarding")
    #if DEBUG
    /// Relaie le trigger Darwin debug.settings vers la vue SwiftUI qui détient
    /// l'action openSettings (fiable, contrairement à showSettingsWindow:).
    static let atollDebugOpenSettings = Notification.Name("dev.mehdiguiard.atoll.debug.openSettings")
    #endif
}
