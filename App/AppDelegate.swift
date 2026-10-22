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
    private var codexBridgeServer: BridgeServer?
    private var debugTokens: [Int32] = []
    private var onboardingController: OnboardingWindowController?
    private var skillReviewController: SkillReviewWindowController?
    private var codexPreviewWindow: NSWindow?

    /// Affiche la fenêtre de revue des skills — recréée à neuf (comme l'onboarding).
    func showSkillReview() {
        skillReviewController?.close()
        skillReviewController = SkillReviewWindowController()
        skillReviewController?.show()
    }


    /// Affiche la fenêtre de bienvenue — appelée par le menu et au 1er lancement.
    /// Recréée à NEUF à chaque fois : évite tout état résiduel après fermeture
    /// (une fenêtre réutilisée pouvait rester invisible → « rien ne se passe »).
    func showOnboarding() {
        onboardingController?.close()
        onboardingController = OnboardingWindowController()
        onboardingController?.show()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CodexPreview.enabled {
            codexPreviewWindow = CodexPreview.makeWindow()
            return
        }
        ThemeManager.applyStored()
        RetrospectiveRunner.shared.generationAllowed = { EssentialMigration.shared.isComplete }
        NotificationCenter.default.addObserver(forName: .atollShowOnboarding, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showOnboarding() }
        }
        NotificationCenter.default.addObserver(forName: .atollShowSkillReview, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showSkillReview() }
        }
        rebuildWindows()
        registerDebugTriggers()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.scheduleRebuild() } }

        Task { @MainActor in
            // La migration capture l’héritage avant toute réconciliation de store.
            let ready = await EssentialMigration.shared.run()
            self.startObservation()
            if ready {
                SkillReviewCenter.shared.reconcileAndScan()
                LearningSettings.shared.syncWithSettings()
                RetrospectiveRunner.shared.recoverPendingDeliveries()
            }
            if OnboardingWindowController.shouldShowAtLaunch { self.showOnboarding() }
        }
    }

    private func startObservation() {
        ModelQuotaPoller.shared.syncWithSettings()
        let server = BridgeServer(onEvent: { event, _ in
            MainActor.assumeIsolated { SessionStore.shared.apply(event) }
        }, onStatusline: { data in
            Task { @MainActor in SessionStore.shared.applyStatusline(data) }
        }, onStateChange: { running in
            Task { @MainActor in SessionStore.shared.serverRunning = running }
        })
        bridgeServer = server
        try? server.start()
        SessionStore.shared.start()

        let codexServer = BridgeServer(onEvent: { _, _ in }, onStatusline: { _ in },
            onStateChange: { running in
                Task { @MainActor in CodexService.shared.serverRunning = running }
            }, onCodexEvent: { event, _, _ in
                Task { @MainActor in
                    guard CodexService.shared.accepts(event) else { return }
                    CodexService.shared.apply(event)
                }
            }, socketPath: CodexPaths.socketPath)
        codexBridgeServer = codexServer
        try? codexServer.start()
        SessionStore.shared.onSessionEnded = { snapshot, reason in
            RetrospectiveRunner.shared.sessionEnded(snapshot, reason: reason)
        }
        SessionStore.shared.onSessionResumed = { id in RetrospectiveRunner.shared.sessionResumed(id) }
        RetrospectiveRunner.shared.onProposalsChanged = { SkillReviewCenter.shared.refresh() }
        CodexService.shared.start()
        FleetPoller.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !CodexPreview.enabled else { CodexPreview.clearPreferences(); return }
        CodexService.shared.stop()
        FleetPoller.shared.stop()
        RetrospectiveRunner.shared.terminateActive()
        bridgeServer?.stop()
        codexBridgeServer?.stop()
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
        // Les actions de debug ciblent l’écran principal, ou le premier.
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

        #if DEBUG
        // Revue des skills (décisions → DEBUG uniquement).
        var seedToken: Int32 = 0
        notify_register_dispatch("dev.mehdiguiard.atoll.debug.seedSkill", &seedToken, DispatchQueue.main) { _ in
            MainActor.assumeIsolated { SkillReviewCenter.shared.debugSeedProposal() }
        }
        var skillReviewToken: Int32 = 0
        notify_register_dispatch("dev.mehdiguiard.atoll.debug.skillReview", &skillReviewToken, DispatchQueue.main) { _ in
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .atollShowSkillReview, object: nil)
            }
        }
        var approveSkillToken: Int32 = 0
        notify_register_dispatch("dev.mehdiguiard.atoll.debug.approveSkill", &approveSkillToken, DispatchQueue.main) { _ in
            MainActor.assumeIsolated {
                if let first = SkillReviewCenter.shared.proposals.first {
                    SkillReviewCenter.shared.approve(first)
                }
            }
        }
        var rejectSkillToken: Int32 = 0
        notify_register_dispatch("dev.mehdiguiard.atoll.debug.rejectSkill", &rejectSkillToken, DispatchQueue.main) { _ in
            MainActor.assumeIsolated {
                if let first = SkillReviewCenter.shared.proposals.first {
                    SkillReviewCenter.shared.reject(first.id)
                }
            }
        }
        debugTokens.append(contentsOf: [seedToken, skillReviewToken, approveSkillToken, rejectSkillToken])

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
        debugTokens.append(contentsOf: [selectToken, settingsToken, onboardingToken])
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
    /// Ouvre la fenêtre de revue des skills proposés (même chemin que l'onboarding).
    static let atollShowSkillReview = Notification.Name("dev.mehdiguiard.atoll.showSkillReview")
    #if DEBUG
    /// Relaie le trigger Darwin debug.settings vers la vue SwiftUI qui détient
    /// l'action openSettings (fiable, contrairement à showSettingsWindow:).
    static let atollDebugOpenSettings = Notification.Name("dev.mehdiguiard.atoll.debug.openSettings")
    #endif
}
