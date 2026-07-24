import AppKit
import SwiftUI
import AtollCore

/// Fenêtre de lancement d'une tâche en arrière-plan (Milestone C) — pattern
/// OnboardingWindowController/SkillReviewWindow, esthétique ASCII. Le notch est
/// trop étroit pour saisir un prompt : on ouvre une fenêtre dédiée (choix de Mehdi).
@MainActor
final class FleetLauncherWindowController: NSWindowController, NSWindowDelegate {
    /// cwd pré-rempli, transmis à l'ouverture (dossier de la session sélectionnée).
    var suggestedCwd: String?

    convenience init(suggestedCwd: String?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        self.suggestedCwd = suggestedCwd
        window.delegate = self
    }

    func show() {
        guard let window else { return }
        let cwd = FleetLauncher.shared.suggestedDirectory(selectedCwd: suggestedCwd)
        window.contentView = NSHostingView(rootView: FleetLauncherView(initialCwd: cwd) { [weak self] in
            self?.close()
        })
        centerOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func centerOnActiveScreen() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { window.center(); return }
        let size = window.frame.size
        var x = visible.midX - size.width / 2
        var y = visible.midY - size.height / 2
        x = min(max(x, visible.minX), visible.maxX - size.width)
        y = min(max(y, visible.minY), visible.maxY - size.height)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct FleetLauncherView: View {
    let initialCwd: String
    let onClose: () -> Void

    @State private var launcher = FleetLauncher.shared
    @State private var task = ""
    @State private var cwd: String
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("paletteID") private var paletteID = Palette.monoOrange.id
    @FocusState private var taskFocused: Bool

    init(initialCwd: String, onClose: @escaping () -> Void) {
        self.initialCwd = initialCwd
        self.onClose = onClose
        _cwd = State(initialValue: initialCwd)
    }

    private var colors: ThemeColors { ThemeColors(paletteID: paletteID, scheme: colorScheme) }
    private var isRockstar: Bool { InteractionCenter.shared.autonomyLevel == .rockstar }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("░░▒▒▓▓  L A N C E R   U N E   T Â C H E  ▓▓▒▒░░")
                .font(AtollFont.mono(12, weight: .bold))
                .foregroundStyle(colors.accent)
                .frame(maxWidth: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(AsciiArt.sectionHeader("TÂCHE", width: 64)).foregroundStyle(colors.dim)
                TextEditor(text: $task)
                    .font(AtollFont.mono(11))
                    .foregroundStyle(colors.fg)
                    .scrollContentBackground(.hidden)
                    .background(colors.surface)
                    .frame(height: 96)
                    .focused($taskFocused)
                    .overlay(alignment: .topLeading) {
                        if task.isEmpty {
                            Text("ex. lance les tests et corrige les échecs")
                                .font(AtollFont.mono(11))
                                .foregroundStyle(colors.dim)
                                .padding(.horizontal, 5).padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(AsciiArt.sectionHeader("DOSSIER", width: 64)).foregroundStyle(colors.dim)
                HStack(spacing: 6) {
                    TextField("", text: $cwd)
                        .textFieldStyle(.plain)
                        .font(AtollFont.mono(10))
                        .foregroundStyle(colors.fg)
                        .padding(6).background(colors.surface)
                    AsciiButton(label: "PARCOURIR", color: colors.dim, shortcut: nil) {
                        chooseDirectory()
                    }
                }
            }

            if let error = launcher.lastError {
                Text(error).font(AtollFont.mono(9)).foregroundStyle(colors.warn)
            }
            if isRockstar {
                Text("⚠ Rockstar : la tâche s'exécutera en arrière-plan et approuvera TOUT sans surveillance.")
                    .font(AtollFont.mono(9)).foregroundStyle(colors.warn)
            }

            HStack {
                Text("s'exécute en arrière-plan · visible dans le notch")
                    .font(AtollFont.mono(9)).foregroundStyle(colors.dim)
                Spacer()
                AsciiButton(label: "ANNULER", color: colors.dim, shortcut: .escape, modifiers: []) {
                    onClose()
                }
                AsciiButton(label: launcher.isLaunching ? "…" : "LANCER ⌘⏎",
                            color: colors.ok, shortcut: .return, modifiers: .command) {
                    launch()
                }
            }
            .font(AtollFont.mono(11))
        }
        .padding(18)
        .frame(width: 560, height: 320, alignment: .top)
        .background(colors.bg)
        .onAppear { taskFocused = true; launcher.reset() }
    }

    private func launch() {
        // Garde de ré-entrance côté vue (ceinture + bretelles avec FleetLauncher).
        guard !launcher.isLaunching, FleetLaunch.isValidTask(task) else { return }
        Task {
            let id = await launcher.launch(task: task, cwd: cwd)
            if id != nil || launcher.lastError == nil { onClose() }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: cwd)
        if panel.runModal() == .OK, let url = panel.url { cwd = url.path }
    }
}
