import AppKit
import SwiftUI
import AtollCore

/// Fenêtre de bienvenue au premier lancement : installer les hooks, comprendre
/// le fail-open, savoir où trouver l'autonomie et le jump-back. Réouvrable via
/// le menu de la barre (« Bienvenue… »).
@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let doneKey = "onboardingDone"

    static var shouldShowAtLaunch: Bool {
        !UserDefaults.standard.bool(forKey: doneKey)
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 470),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        window.delegate = self
    }

    func show() {
        // Racine SwiftUI recréée à CHAQUE affichage : l'état (hooks installés,
        // erreurs) repart du réel — onAppear ne se redéclencherait pas sur une
        // fenêtre conservée en mémoire.
        window?.contentView = NSHostingView(rootView: OnboardingView { [weak self] in
            self?.close()
        })
        // App LSUIElement : sans activation explicite la fenêtre resterait derrière.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Fermer = vu. On ne réaffiche plus au lancement (réouvrable via le menu).
    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
    }
}

struct OnboardingView: View {
    let onDone: () -> Void

    @AppStorage("paletteID") private var paletteID = Palette.monoOrange.id
    @Environment(\.colorScheme) private var scheme
    @State private var hooksInstalled = HookInstaller.isInstalled
    @State private var hookError: String?

    private var colors: ThemeColors { ThemeColors(paletteID: paletteID, scheme: scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // En-tête ASCII, même langage visuel que l'îlot.
            VStack(alignment: .center, spacing: 6) {
                Text("░░▒▒▓▓  A T O L L  ▓▓▒▒░░")
                    .font(AtollFont.mono(17, weight: .bold))
                    .foregroundStyle(colors.accent)
                Text("Une Dynamic Island pour Claude Code")
                    .font(AtollFont.mono(12))
                    .foregroundStyle(colors.dim)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 26)

            step(
                number: "1",
                title: "BRANCHER CLAUDE CODE",
                body: """
                Atoll écoute vos sessions via les hooks de Claude Code. Fail-open \
                garanti : Atoll fermé ou planté, le CLI claude fonctionne exactement \
                comme avant. Vos hooks existants sont préservés (backup unique de \
                settings.json) et la désinstallation restitue tout.
                """
            ) {
                HStack(spacing: 10) {
                    Button(hooksInstalled ? "HOOKS INSTALLÉS ✓" : "[ INSTALLER LES HOOKS ]") {
                        installHooks()
                    }
                    .buttonStyle(.plain)
                    .font(AtollFont.mono(12, weight: .bold))
                    .foregroundStyle(hooksInstalled ? colors.ok : colors.accent)
                    .disabled(hooksInstalled)
                    if let hookError {
                        Text(hookError)
                            .font(AtollFont.mono(10))
                            .foregroundStyle(.red)
                    }
                }
            }

            step(
                number: "2",
                title: "CHOISIR L'AUTONOMIE",
                body: """
                Dans le menu ≋ → Réglages… : Manuel (vous décidez de tout), Auto \
                (permissions sûres approuvées, allowlist) ou Rockstar (aucune \
                protection — à vos risques et périls).
                """
            ) { EmptyView() }

            step(
                number: "3",
                title: "REVENIR AU TERMINAL",
                body: """
                Cliquez une session dans l'îlot puis « ALLER AU TERMINAL » : sa \
                fenêtre remonte (Cursor/VS Code : direct ; Terminal/iTerm2 : macOS \
                demandera une fois l'autorisation d'automatisation).
                """
            ) { EmptyView() }

            Spacer(minLength: 0)

            Button("[ COMMENCER ]") { onDone() }
                .buttonStyle(.plain)
                .font(AtollFont.mono(14, weight: .bold))
                .foregroundStyle(colors.accent)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
        }
        .padding(.horizontal, 34)
        .frame(width: 560, height: 470)
        .background(colors.bg)
        .onAppear { hooksInstalled = HookInstaller.isInstalled }
    }

    @ViewBuilder
    private func step(number: String, title: String, body text: String,
                      @ViewBuilder accessory: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("─── \(number) · \(title) ").font(AtollFont.mono(12, weight: .bold))
                .foregroundStyle(colors.fg)
            Text(text)
                .font(AtollFont.mono(11))
                .foregroundStyle(colors.dim)
                .fixedSize(horizontal: false, vertical: true)
            accessory()
        }
    }

    private func installHooks() {
        hookError = nil
        do {
            try HookInstaller.install()
        } catch {
            hookError = error.localizedDescription
        }
        hooksInstalled = HookInstaller.isInstalled
        // Même chemin que les Réglages : le parking des règles deny suit la
        // disponibilité des hooks (ex. niveau Rockstar déjà choisi).
        HookInstaller.syncDenyParking(level: InteractionCenter.shared.autonomyLevel)
    }
}
