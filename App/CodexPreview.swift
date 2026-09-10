import AppKit
import SwiftUI
import AtollCore

/// Recette des vraies vues, sans socket, installation, analyse ou connexion.
enum CodexPreview {
    // Un domaine par copie, réinitialisé au prochain lancement même après
    // SIGKILL. Ne jamais balayer les domaines d'autres processus ou apps.
    static var preferenceDomain: String {
        "dev.mehdiguiard.atoll.preview." + (Bundle.main.bundleIdentifier ?? "local-debug")
    }

    static func clearPreferences() {
        guard enabled else { return }
        UserDefaults.standard.removePersistentDomain(forName: preferenceDomain)
    }

    static var enabled: Bool {
        #if DEBUG
        if let fixtureHome = Bundle.main.object(forInfoDictionaryKey: "AtollValidationHome") as? String,
           let fixtureCodex = Bundle.main.object(forInfoDictionaryKey: "AtollValidationCodexHome") as? String {
            // Une copie de recette native rouverte depuis Finder redevient un
            // aperçu : seul le lanceur avec les DEUX racines isolées peut
            // démarrer les services réels, jamais sur le home personnel.
            let rootMatches = BridgePaths.homeDirectory.resolvingSymlinksInPath().path
                == URL(fileURLWithPath: fixtureHome).resolvingSymlinksInPath().path
            let codexMatches = CodexPaths.homeURL.resolvingSymlinksInPath().path
                == URL(fileURLWithPath: fixtureCodex).resolvingSymlinksInPath().path
            return !rootMatches || !codexMatches || CommandLine.arguments.contains("--codex-preview")
        }
        return CommandLine.arguments.contains("--codex-preview")
            || Bundle.main.object(forInfoDictionaryKey: "AtollPreviewOnly") as? Bool == true
        #else
        return false
        #endif
    }

    @MainActor static func makeWindow() -> NSWindow {
        #if DEBUG
        if Bundle.main.object(forInfoDictionaryKey: "AtollValidationHome") != nil {
            fputs("Recette native en aperçu : home=\(BridgePaths.homeDirectory.path), codex=\(CodexPaths.homeURL.path)\n", stderr)
        }
        let args = CommandLine.arguments
        let screen = NSScreen.screens.dropFirst().first ?? NSScreen.screens[0]
        let model = NotchViewModel(screen: screen, isPrimary: true)
        model.previewSessions = args.contains("--preview-empty") ? [] : (0..<(args.contains("--preview-many") ? 24 : 2)).map { i in
            AgentSession(id: "preview-\(i)", projectName: "projet-\(i) — libellé très long à vérifier",
                         status: i % 3 == 0 ? .awaitingPermission(tool: "Tests Swift") : .working(tool: "Analyse"),
                         cwd: args.contains("--preview-detail") ? NSTemporaryDirectory() : nil,
                         provider: i % 2 == 0 ? .claude : .codex)
        }
        model.previewUsage = UsageSnapshot(fiveHourFraction: 0.27, sevenDayFraction: 0.64)
        CodexService.shared.seedPreviewQuota()
        ProviderPreferences.shared.selection = args.contains("--preview-claude") ? .claude : .codex
        if args.contains("--preview-cards") {
            InteractionCenter.shared.seedPreviewRequests()
            CodexInteractionCenter.shared.seedPreviewRequests()
            if args.contains("--preview-codex-card") { InteractionPresentation.shared.move(1) }
        }
        if args.contains("--preview-skills") { SkillReviewCenter.shared.seedPreviewProposals() }
        model.state = args.contains("--preview-compact") ? .compact : .expanded
        model.isPinned = model.state == .expanded
        if args.contains("--preview-detail") { model.selectedSessionID = model.sessions.first?.id }

        // Domaine dédié aux seuls @AppStorage des vues : aucune écriture dans
        // les préférences d'Atoll, même en testant le regroupement des sessions.
        let domain = preferenceDomain
        clearPreferences()
        let defaults = UserDefaults(suiteName: domain)!
        defaults.register(defaults: [
            "paletteID": Palette.monoOrange.id,
            ProviderPreferences.codexPaletteKey: Palette.monoCyan.id,
            InteractionCenter.autonomyKey: args.contains("--preview-rockstar") ? "rockstar" : "manual"
        ])
        let content = Group {
            if args.contains("--preview-onboarding") {
                OnboardingView(onDone: {})
            } else if args.contains("--preview-skills") {
                SkillReviewView(onClose: {})
            } else if args.contains("--preview-codex-settings") {
                // Recette de rendu seulement : les callbacks de ce panneau
                // changent le home suivi et démarrent des lectures natives.
                CodexSettingsPane().disabled(true).frame(width: 780, height: 580)
            } else {
                PreviewContent(model: model, light: args.contains("--preview-light"))
            }
        }
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
    @State private var reduceMotion = CommandLine.arguments.contains("--preview-reduce-motion")
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
