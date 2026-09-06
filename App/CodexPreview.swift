import AppKit
import SwiftUI
import AtollCore

/// Visual review without socket binding, hook repair, login, network, or recall.
/// This mode is compiled into Debug only and is deliberately non-interactive.
enum CodexPreview {
    static var enabled: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--codex-preview")
        #else
        false
        #endif
    }

    @MainActor static func makeWindow() -> NSWindow {
        let model = NotchViewModel(screen: NSScreen.main ?? NSScreen.screens[0], isPrimary: true)
        model.previewSessions = [
            AgentSession(id: "preview-claude", projectName: "atoll", status: .working(tool: "Tests Swift"), provider: .claude),
            AgentSession(id: "codex:preview", projectName: "atoll", status: .awaitingPermission(tool: "git push"),
                         subtitle: "Compatibilité Codex", provider: .codex)
        ]
        model.previewUsage = UsageSnapshot(fiveHourFraction: 0.27, sevenDayFraction: 0.64)
        CodexService.shared.seedPreviewQuota()
        let colors = ThemeColors(paletteID: Palette.monoOrange.id, scheme: .dark)
        let content = VStack(spacing: 0) {
            Text("APERÇU · données fictives · aucune connexion ni installation")
                .font(.caption).padding(8)
            ExpandedView(viewModel: model, colors: colors)
                .allowsHitTesting(false)
        }
        .background(colors.bg)
        .preferredColorScheme(.dark)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 450),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Atoll — aperçu Codex (sans connexion)"
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }
}
