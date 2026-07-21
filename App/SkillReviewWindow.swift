import AppKit
import SwiftUI
import AtollCore

/// Fenêtre de revue des skills appris (Phase 7c) — pattern
/// OnboardingWindowController : on n'approuve JAMAIS un skill sans avoir vu son
/// SKILL.md complet, et l'îlot (600×340) ne s'y prête pas. Décision uniquement
/// ici (approuver / rejeter) ; l'îlot n'a qu'une bannière de signalement.
@MainActor
final class SkillReviewWindowController: NSWindowController, NSWindowDelegate {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
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
        guard let window else { return }
        window.contentView = NSHostingView(rootView: SkillReviewView { [weak self] in
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

struct SkillReviewView: View {
    let onClose: () -> Void

    @State private var center = SkillReviewCenter.shared
    @State private var currentIndex = 0
    @State private var confirmingOverwrite = false
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("paletteID") private var paletteID = Palette.monoOrange.id

    private var colors: ThemeColors { ThemeColors(paletteID: paletteID, scheme: colorScheme) }

    private var current: SkillProposal? {
        guard center.proposals.indices.contains(currentIndex) else { return nil }
        return center.proposals[currentIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("░░▒▒▓▓  R E V U E   D E   S K I L L S  ▓▓▒▒░░")
                .font(AtollFont.mono(13, weight: .bold))
                .foregroundStyle(colors.accent)
                .frame(maxWidth: .infinity, alignment: .center)

            if let proposal = current {
                proposalView(proposal)
            } else {
                Spacer()
                Text("Aucune proposition en attente.")
                    .font(AtollFont.mono(12))
                    .foregroundStyle(colors.dim)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
                HStack {
                    Spacer()
                    AsciiButton(label: "FERMER", color: colors.dim, shortcut: .escape, modifiers: []) {
                        onClose()
                    }
                    Spacer()
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 560, alignment: .top)
        .background(colors.bg)
        .onAppear { center.refresh() }
    }

    @ViewBuilder
    private func proposalView(_ proposal: SkillProposal) -> some View {
        // Titre + provenance
        VStack(alignment: .leading, spacing: 4) {
            Text(AsciiArt.sectionHeader("PROPOSITION \(currentIndex + 1)/\(center.proposals.count)", width: 60))
                .foregroundStyle(colors.dim)
            HStack {
                Text(SkillSlug.dirName(for: proposal.slug))
                    .fontWeight(.bold)
                    .foregroundStyle(colors.fg)
                Spacer()
                Text(center.isUpdateOfModifiedSkill(proposal) ? "(màj — modifié par vous)" : "(nouveau)")
                    .foregroundStyle(center.isUpdateOfModifiedSkill(proposal) ? colors.warn : colors.dim)
            }
            Text(proposal.description)
                .foregroundStyle(colors.fg)
            if let project = proposal.sourceProject {
                Text("origine : \((project as NSString).lastPathComponent) · \(proposal.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(AtollFont.mono(9))
                    .foregroundStyle(colors.dim)
            }
        }

        if let rationale = proposal.rationale, !rationale.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(AsciiArt.sectionHeader("POURQUOI", width: 60)).foregroundStyle(colors.dim)
                Text(rationale).foregroundStyle(colors.fg)
            }
        }

        // Contenu exact qui sera installé.
        VStack(alignment: .leading, spacing: 2) {
            Text(AsciiArt.sectionHeader("SKILL.MD (installé tel quel)", width: 60))
                .foregroundStyle(colors.dim)
            ScrollView {
                Text(proposal.skillMD)
                    .font(AtollFont.mono(10))
                    .foregroundStyle(colors.fg)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 220)
            .background(colors.surface)
        }

        Spacer(minLength: 4)

        // Navigation
        if center.proposals.count > 1 {
            HStack {
                Spacer()
                AsciiButton(label: "◀ PRÉC", color: colors.dim, shortcut: .leftArrow, modifiers: []) {
                    currentIndex = max(0, currentIndex - 1)
                }
                Text("\(currentIndex + 1) / \(center.proposals.count)").foregroundStyle(colors.dim)
                AsciiButton(label: "SUIV ▶", color: colors.dim, shortcut: .rightArrow, modifiers: []) {
                    currentIndex = min(center.proposals.count - 1, currentIndex + 1)
                }
                Spacer()
            }
        }

        // Décisions — raccourcis DÉLIBÉRÉMENT différents des permissions (⌘⏎/⌘⌫,
        // pas ⌘Y/⌘N) : approuver un skill est un acte plus lourd, friction voulue.
        HStack(spacing: 12) {
            AsciiButton(label: "REJETER ⌘⌫", color: colors.warn, shortcut: .delete, modifiers: .command) {
                center.reject(proposal.id)
                clampIndex()
            }
            Spacer()
            AsciiButton(label: "PLUS TARD", color: colors.dim, shortcut: nil) {
                onClose()
            }
            Spacer()
            AsciiButton(label: "APPROUVER ⌘⏎", color: colors.ok, shortcut: .return, modifiers: .command) {
                if center.isUpdateOfModifiedSkill(proposal) {
                    confirmingOverwrite = true
                } else {
                    center.approve(proposal.id)
                    clampIndex()
                }
            }
        }
        .font(AtollFont.mono(11))

        if let error = center.lastError {
            Text(error).font(AtollFont.mono(9)).foregroundStyle(colors.warn)
        }

        EmptyView()
            .alert("Écraser un skill modifié à la main ?", isPresented: $confirmingOverwrite) {
                Button("Annuler", role: .cancel) { }
                Button("Écraser", role: .destructive) {
                    if let proposal = current {
                        center.approve(proposal.id, force: true)
                        clampIndex()
                    }
                }
            } message: {
                Text("Vous avez édité ce skill après son installation. L'approbation archivera votre version avant de la remplacer.")
            }
    }

    private func clampIndex() {
        currentIndex = min(currentIndex, max(0, center.proposals.count - 1))
    }
}
