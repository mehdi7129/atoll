import AppKit
import SwiftUI
import AtollCore

/// Recette des vraies vues, sans socket, installation, analyse ou connexion.
enum CodexPreview {
    static var enabled: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--codex-preview")
        #else
        false
        #endif
    }

    @MainActor static func makeWindow() -> NSWindow {
        #if DEBUG
        let args = CommandLine.arguments
        let screen = NSScreen.screens.dropFirst().first ?? NSScreen.screens[0]
        let model = NotchViewModel(screen: screen, isPrimary: true)
        model.previewSessions = args.contains("--preview-empty") ? [] : (0..<(args.contains("--preview-many") ? 24 : 2)).map { i in
            AgentSession(id: "preview-\(i)", projectName: "projet-\(i) — libellé très long à vérifier",
                         status: i % 3 == 0 ? .awaitingPermission(tool: "Tests Swift") : .working(tool: "Analyse"),
                         provider: i % 2 == 0 ? .claude : .codex)
        }
        model.previewUsage = UsageSnapshot(fiveHourFraction: 0.27, sevenDayFraction: 0.64)
        CodexService.shared.seedPreviewQuota()
        ProviderPreferences.shared.selection = args.contains("--preview-claude") ? .claude : .codex
        if args.contains("--preview-cards") {
            InteractionCenter.shared.seedPreviewRequests()
            CodexInteractionCenter.shared.seedPreviewRequests()
        }
        model.state = args.contains("--preview-compact") ? .compact : .expanded
        model.isPinned = model.state == .expanded

        // Domaine dédié aux seuls @AppStorage des vues : aucune écriture dans
        // les préférences d'Atoll, même en testant le regroupement des sessions.
        let domain = "dev.mehdiguiard.atoll.preview.\(getpid())"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.register(defaults: [
            "paletteID": Palette.monoOrange.id,
            ProviderPreferences.codexPaletteKey: Palette.monoCyan.id,
            InteractionCenter.autonomyKey: args.contains("--preview-rockstar") ? "rockstar" : "manual"
        ])
        let content = PreviewContent(model: model, light: args.contains("--preview-light"))
            .defaultAppStorage(defaults)
            .onDisappear { defaults.removePersistentDomain(forName: domain) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Atoll — recette isolée"
        window.contentView = NSHostingView(rootView: content)
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 390, y: screen.visibleFrame.midY - 290))
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        return window
        #else
        preconditionFailure("Aperçu réservé au build Debug")
        #endif
    }
}

#if DEBUG
private struct PreviewContent: View {
    let model: NotchViewModel
    @State var light: Bool
    @State private var reduceMotion = false
    @State private var cycling = false

    var body: some View {
        VStack(spacing: 14) {
            Text("RECETTE ISOLÉE · données fictives · aucune connexion")
                .font(.caption)
            HStack {
                Button("Compact") { model.close() }
                Button("Étendu") { model.isPinned = true; model.open() }
                Button("Rejouer les cartes") {
                    InteractionCenter.shared.seedPreviewRequests()
                    CodexInteractionCenter.shared.seedPreviewRequests()
                    InteractionPresentation.shared.refresh()
                }
                Toggle("Clair", isOn: $light)
                Toggle("Mouvement réduit", isOn: $reduceMotion)
                Button("Animation") {
                    guard !cycling else { return }
                    cycling = true
                    model.close()
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        model.isPinned = true
                        model.open()
                        cycling = false
                    }
                }
            }
            .controlSize(.small).fixedSize()
            NotchRootView(viewModel: model, previewReduceMotion: reduceMotion)
                .frame(width: 760, height: 460, alignment: .top)
        }
        .padding(10)
        .frame(width: 780, height: 580)
        .background(light ? Color(white: 0.8) : Color(white: 0.13))
        .preferredColorScheme(light ? .light : .dark)
    }
}
#endif
