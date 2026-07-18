import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [NotchWindowController] = []
    private var screenObserver: NSObjectProtocol?
    private var rebuildTask: Task<Void, Never>?
    private var lastScreenSignature = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemeManager.applyStored()
        rebuildWindows()

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
