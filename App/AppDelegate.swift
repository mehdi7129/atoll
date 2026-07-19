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

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeManager.applyStored()
        InteractionCenter.migrateAutonomyIfNeeded()
        ClaudeLocator.warmUp() // résout le binaire en fond → 1er chat instantané

        // Répare le wrapper ~/.atoll/bin si l'app a été déplacée (idempotent).
        HookInstaller.repairIfInstalled()

        // Récupération après crash / relance : le parking des règles deny doit
        // TOUJOURS refléter le niveau d'autonomie courant (jamais de règles
        // parquées hors Rockstar, jamais de règles actives en Rockstar).
        HookInstaller.syncDenyParking(level: InteractionCenter.shared.autonomyLevel)

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
        bridgeServer?.stop()
        ChatCenter.shared.close() // ne pas laisser un claude -p orphelin
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
        // Démarre un chat de test + envoie un message (test visuel Phase 6).
        var chatToken: Int32 = 0
        notify_register_dispatch("dev.mehdiguiard.atoll.debug.chat", &chatToken, DispatchQueue.main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controllers.forEach { $0.viewModel.isPinned = true; $0.viewModel.open() }
                ChatCenter.shared.startNew(cwd: "/tmp")
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    ChatCenter.shared.active?.send("Dis bonjour en exactement 4 mots.")
                }
            }
        }
        debugTokens.append(contentsOf: [allowToken, denyToken, selectToken, jumpToken, chatToken])
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
