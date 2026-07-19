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

    /// App qui avait le focus avant qu'une carte prenne le clavier — restituée
    /// quand la carte se résout, pour ne pas laisser l'utilisateur sans focus.
    private var previousApp: NSRunningApplication?

    init(screen: NSScreen, isPrimary: Bool) {
        viewModel = NotchViewModel(screen: screen, isPrimary: isPrimary)

        let rect = IslandGeometry.windowRect(screenFrame: screen.frame)
        panel = NotchPanel(contentRect: rect)

        let host = NSHostingView(rootView: NotchRootView(viewModel: viewModel))
        host.frame = NSRect(origin: .zero, size: rect.size)
        panel.contentView = host
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()

        // Focus clavier accordé seulement pendant une carte interactive
        // (⌘Y/⌘N, champs texte) — sans jamais activer l'app.
        viewModel.onKeyFocusRequest = { [weak panel, weak self] wantsFocus in
            guard let panel else { return }
            panel.allowsKeyFocus = wantsFocus
            if wantsFocus {
                // Mémoriser l'app active pour lui rendre le focus ensuite.
                self?.previousApp = NSWorkspace.shared.frontmostApplication
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.orderFrontRegardless()
                // Rendre le focus à l'app précédente (le terminal, typiquement).
                if panel.isKeyWindow {
                    panel.resignKey()
                    self?.previousApp?.activate()
                }
                self?.previousApp = nil
            }
        }

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
