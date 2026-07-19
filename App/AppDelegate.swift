import AppKit
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

        // Répare le wrapper ~/.atoll/bin si l'app a été déplacée (idempotent).
        HookInstaller.repairIfInstalled()

        // Démarre la réception des événements de hooks puis le suivi des sessions.
        let store = SessionStore.shared
        let server = BridgeServer(
            onEvent: { event, requestID in
                Task { @MainActor in
                    if let requestID {
                        InteractionCenter.shared.register(event: event, requestID: requestID)
                    }
                    SessionStore.shared.apply(event)
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
        controllers = NSScreen.screens.map { NotchWindowController(screen: $0) }
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
        // Résolution automatisée de la première demande en attente — pour les
        // tests de bout en bout scriptés (mêmes chemins de code que les boutons).
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
        debugTokens = [expandToken, compactToken, allowToken, denyToken]
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
