import AppKit
import SwiftUI
import AtollCore

/// Recette des vraies vues, sans socket, installation, analyse ou connexion.
enum CodexPreview {
    static var modelCatalog: CodexModel.Catalog {
        guard enabled else { return .unavailable("Recette désactivée") }
        if CommandLine.arguments.contains("--preview-models-unavailable") {
            return .unavailable("Codex ne répond pas. Réessaie dans quelques instants.")
        }
        let data = Data("""
        [{"id":"example-a","model":"example-a","displayName":"Modèle de test A","isDefault":true,"hidden":false},
         {"id":"example-b","model":"example-b","displayName":"Modèle de test B","isDefault":false,"hidden":false}]
        """.utf8)
        return .available((try? JSONDecoder().decode([CodexModel].self, from: data)) ?? [])
    }

    static var hookDiagnosticSummary: String {
        guard enabled,
              let definitions = try? CodexHookSettingsEditor.edit(nil, install: true),
              let root = try? JSONSerialization.jsonObject(with: definitions) as? [String: Any],
              let events = root["hooks"] as? [String: [[String: Any]]] else { return "" }
        let hooks: [[String: Any]] = events.flatMap { event, groups in
            groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.map { handler in
                var hook = handler
                hook["eventName"] = event.prefix(1).lowercased() + event.dropFirst()
                hook["timeoutSec"] = handler["timeout"]
                hook["enabled"] = true
                hook["trustStatus"] = ["SubagentStart", "SubagentStop"].contains(event) ? "untrusted" : "trusted"
                return hook
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["data": [["hooks": hooks, "errors": []]]]) else { return "" }
        return CodexHookDiagnostics(data: data)?.summary ?? ""
    }

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
        let requestedScreen = args.first { $0.hasPrefix("--preview-screen=") }
            .flatMap { Int($0.dropFirst("--preview-screen=".count)) }
        let screen = requestedScreen.flatMap { NSScreen.screens.indices.contains($0) ? NSScreen.screens[$0] : nil }
            ?? NSScreen.screens.dropFirst().first ?? NSScreen.screens[0]
        let model = NotchViewModel(screen: screen, isPrimary: true)
        model.previewSessions = args.contains("--preview-empty") ? [] : (0..<(args.contains("--preview-many") ? 24 : 2)).map { i in
            var session = AgentSession(id: "preview-\(i)", projectName: "projet-\(i) — libellé très long à vérifier",
                         status: i % 3 == 0 ? .awaitingPermission(tool: "Tests Swift") : .working(tool: "Analyse"),
                         cwd: args.contains("--preview-detail") ? "/tmp" : nil,
                         provider: i % 2 == 0 ? .claude : .codex)
            if args.contains("--preview-detail"), session.provider == .codex {
                session.contextTokenUsage = ContextTokenUsage(usedTokens: 173_617, windowTokens: 258_400)
                session.contextUsedFraction = session.contextTokenUsage?.fraction
                session.contextMeasuredAt = Date()
            }
            return session
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
        if args.contains("--preview-codex-settings") || args.contains("--preview-analysis-settings") || args.contains("--preview-settings=learning") || args.contains("--preview-all-settings") {
            defaults.set(args.contains("--preview-analysis-claude") ? "claude" : "codex", forKey: LearningSettings.analysisProviderKey)
            defaults.set(args.contains("--preview-model-selected") ? "example-b"
                : args.contains("--preview-model-obsolete") ? "ancien-modele" : "", forKey: LearningSettings.codexModelKey)
            defaults.set(!args.contains("--preview-quota-disabled"), forKey: CodexService.quotaEnabledKey)
        }
        let otherPane = args.first { $0.hasPrefix("--preview-settings=") }
            .map { String($0.dropFirst("--preview-settings=".count)) }
        defaults.set(true, forKey: MemoryIndexer.enabledKey)
        defaults.set(args.contains("--preview-recall-enabled"), forKey: LearningSettings.proactiveRecallKey)
        defaults.set(!args.contains("--preview-sounds-off"), forKey: SoundCenter.enabledKey)
        if args.contains("--preview-learning-proposals") { SkillReviewCenter.shared.seedPreviewProposals() }
        if args.contains("--preview-all-settings") {
            let tabs = ["learning": "apprentissage", "alerts": "alertes", "autonomy": "autonomie", "updates": "maj", "about": "apropos"]
            defaults.set(tabs[otherPane ?? ""] ?? otherPane ?? "general", forKey: "settingsTab")
        }
        let settingsPreview = args.contains("--preview-codex-settings") || args.contains("--preview-analysis-settings") || args.contains("--preview-all-settings") || otherPane != nil
        let windowHeight: CGFloat = args.contains("--preview-short") ? 520 : args.contains("--preview-codex-settings")
            ? min(screen.visibleFrame.height - 80, args.contains("--preview-advanced") ? 1_200 : 840)
            : otherPane != nil ? min(screen.visibleFrame.height - 80, 1_100) : 580
        let windowWidth: CGFloat = args.contains("--preview-narrow") ? 640 : 780
        let content = Group {
            if args.contains("--preview-onboarding") {
                OnboardingView(onDone: {})
            } else if args.contains("--preview-skills") {
                SkillReviewView(onClose: {})
            } else if args.contains("--preview-all-settings") {
                PreviewSettingsLauncher()
            } else if args.contains("--preview-codex-settings") {
                // Les actions externes sont simulées ; disclosures, menus et
                // sélections restent les vrais contrôles SwiftUI interactifs.
                PreviewCodexSettings().frame(width: windowWidth, height: windowHeight)
            } else if args.contains("--preview-analysis-settings") {
                Form { AnalysisSettingsSection() }.formStyle(.grouped)
                    .frame(width: windowWidth, height: windowHeight)
            } else if let otherPane {
                SettingsView.previewPane(otherPane).frame(width: windowWidth, height: windowHeight)
            } else {
                PreviewContent(model: model, light: args.contains("--preview-light"))
            }
        }
            .defaultAppStorage(defaults)
            .preferredColorScheme(settingsPreview ? (args.contains("--preview-light") ? .light : .dark) : nil)
            .onDisappear {
                // Le lanceur s'efface après ouverture de la vraie scène Settings.
                // Cette scène utilise encore ces préférences jusqu'à la fermeture.
                if !args.contains("--preview-all-settings") { defaults.removePersistentDomain(forName: domain) }
            }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Atoll — recette isolée"
        window.contentView = NSHostingView(rootView: content)
        window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - windowWidth / 2, y: screen.visibleFrame.midY - windowHeight / 2))
        window.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        return window
        #else
        preconditionFailure("Aperçu réservé au build Debug")
        #endif
    }

    #if DEBUG
    /// La vraie scène Settings donne les mêmes onglets et la même barre de
    /// titre que le produit. Ses préférences et toutes ses actions sont isolées.
    @MainActor static func settingsScene(updater: UpdaterModel) -> some View {
        SettingsView(updaterModel: updater)
            .defaultAppStorage(UserDefaults(suiteName: preferenceDomain)!)
            .preferredColorScheme(CommandLine.arguments.contains("--preview-light") ? .light : .dark)
            .background(PreviewSettingsWindow())
    }
    #endif
}

#if DEBUG
private struct PreviewCodexSettings: View {
    @AppStorage("settingsTab") private var tab = "codex"
    @State private var focusRequest: UUID?

    var body: some View {
        Group {
            if tab == "apprentissage" {
                LearningPane(focusRequest: focusRequest)
            } else {
                CodexSettingsPane(onShowAnalyses: { focusRequest = UUID(); tab = "apprentissage" })
            }
        }
        .disclosureGroupStyle(SettingsDisclosureStyle())
    }
}

private struct PreviewSettingsLauncher: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("Ouverture des réglages isolés…")
            .task {
                openSettings()
                for window in NSApp.windows where window.title == "Atoll — recette isolée" {
                    window.orderOut(nil)
                }
            }
    }
}

private struct PreviewSettingsWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let args = CommandLine.arguments
            let screen = NSScreen.screens.dropFirst().first ?? NSScreen.screens[0]
            let width: CGFloat = args.contains("--preview-narrow") ? 640 : 780
            let height: CGFloat = args.contains("--preview-short") ? 520 : min(screen.visibleFrame.height - 100, 1_100)
            window.setContentSize(NSSize(width: width, height: height))
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - window.frame.width / 2,
                                          y: screen.visibleFrame.midY - window.frame.height / 2))
            window.makeKeyAndOrderFront(nil)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { }
}

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
