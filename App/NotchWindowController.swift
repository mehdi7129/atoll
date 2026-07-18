import AppKit
import SwiftUI
import AtollCore

/// Une fenêtre d'îlot par écran. La fenêtre a une frame fixe (taille max déployée),
/// top-centrée ; toute l'animation se joue en SwiftUI à l'intérieur.
@MainActor
final class NotchWindowController {
    let panel: NotchPanel
    let viewModel: NotchViewModel
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    init(screen: NSScreen) {
        viewModel = NotchViewModel(screen: screen)

        let rect = IslandGeometry.windowRect(screenFrame: screen.frame)
        panel = NotchPanel(contentRect: rect)

        let host = NSHostingView(rootView: NotchRootView(viewModel: viewModel))
        host.frame = NSRect(origin: .zero, size: rect.size)
        panel.contentView = host
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()

        // Un clic en dehors de l'îlot le referme. Le moniteur global couvre les
        // clics dans les autres apps ; le moniteur local couvre nos propres
        // fenêtres (Réglages, îlot d'un autre écran…) que le global ne voit pas.
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak viewModel] _ in
            Task { @MainActor in
                guard let viewModel, viewModel.state == .expanded else { return }
                viewModel.close()
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak viewModel, weak panel] event in
            Task { @MainActor in
                guard let viewModel, viewModel.state == .expanded else { return }
                if event.window !== panel {
                    viewModel.close()
                }
            }
            return event
        }
    }

    func tearDown() {
        removeMonitors()
        panel.orderOut(nil)
    }

    private func removeMonitors() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
        }
        globalClickMonitor = nil
        localClickMonitor = nil
    }

    deinit {
        // Filet de sécurité si le contrôleur est libéré sans tearDown().
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
        }
    }
}
