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
    @State private var selectedID: SkillProposal.ID?
    @State private var overwriteProposal: SkillProposal?
    @State private var confirmingOverwrite = false
    @State private var installedContent: String?
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("paletteID") private var paletteID = Palette.monoOrange.id
    @AppStorage(ProviderPreferences.codexPaletteKey) private var codexPaletteID = Palette.monoCyan.id

    private var colors: ThemeColors {
        ThemeColors(paletteID: current?.destination == .codex ? codexPaletteID : paletteID, scheme: colorScheme)
    }

    private var current: SkillProposal? {
        center.proposals.first { $0.id == selectedID } ?? center.proposals.first
    }
    private var currentIndex: Int { center.proposals.firstIndex { $0.id == current?.id } ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("░░▒▒▓▓  R E V U E   D E   S K I L L S  ▓▓▒▒░░")
                .accessibilityLabel("Revue de skills")
                .font(AtollFont.mono(13, weight: .bold))
                .foregroundStyle(colors.accent)
                .frame(maxWidth: .infinity, alignment: .center)

            if let proposal = current {
                proposalView(proposal)
                    .id(proposal.id)
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
        .font(AtollFont.mono(11))
        .padding(20)
        .frame(width: 640, height: 560, alignment: .top)
        .background(colors.bg)
        .onAppear { center.refresh(); selectedID = current?.id }
        .onChange(of: center.proposals.map(\.id)) { previous, current in
            selectedID = SkillProposal.nextSelection(selectedID, previous: previous, current: current)
        }
        .task(id: current?.id) {
            guard let proposal = current else { installedContent = nil; return }
            installedContent = center.installedContent(for: proposal)
            await center.preloadCatalog(for: proposal)
        }
    }

    @ViewBuilder
    private func proposalView(_ proposal: SkillProposal) -> some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
        // Titre + provenance
        VStack(alignment: .leading, spacing: 4) {
            Text("Destination : \(proposal.destination.label) · installation après vérification du catalogue")
                .foregroundStyle(colors.accent)
            Text("PROPOSITION \(currentIndex + 1)/\(center.proposals.count)")
                .foregroundStyle(colors.dim)
            HStack {
                Text(SkillSlug.dirName(for: proposal.slug))
                    .fontWeight(.bold)
                    .foregroundStyle(colors.fg)
                Spacer()
                // Trois cas, pas deux : un skill déjà installé mais non édité
                // à la main s'annonçait « (nouveau) » alors qu'approuver
                // l'ÉCRASE — et le calcul d'antériorité exclut le jumeau en
                // comptant précisément sur cette mention.
                if center.isUpdateOfModifiedSkill(proposal) {
                    Text("(màj — modifié par vous)").foregroundStyle(colors.warn)
                } else if center.isUpdateOfInstalledSkill(proposal) {
                    Text("(màj — remplace l'installé)").foregroundStyle(colors.accent)
                } else {
                    Text("(nouveau)").foregroundStyle(colors.dim)
                }
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
                Text("POURQUOI").foregroundStyle(colors.dim)
                Text(rationale).foregroundStyle(colors.fg)
            }
        }

        // ANTÉRIORITÉ (jalon 12b) : ce que l'utilisateur peut DÉJÀ invoquer et
        // qui recoupe cette proposition. Affiché AVANT le SKILL.md, en accent :
        // c'est l'information qui fait refuser un doublon — elle ne doit pas se
        // découvrir après avoir approuvé.
        if let similar = SkillReviewCenter.shared.similarCapability(for: proposal) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DÉJÀ DISPONIBLE")
                    .foregroundStyle(colors.dim)
                Text("⚠ recoupe « \(similar) » — compare avant d'approuver")
                    .foregroundStyle(colors.accent)
            }
        }

        // CONTENU SIGNALÉ : la rétrospective a repéré des motifs suspects dans
        // ce SKILL.md (pipe-to-shell, base64, secret…). Ces motifs étaient
        // calculés et écrits dans meta.json, mais jamais relus — on approuvait
        // sans jamais voir l'alerte. En `warn`, et AVANT le contenu.
        if !proposal.flags.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("CONTENU SIGNALÉ")
                    .foregroundStyle(colors.dim)
                Text("⚠ \(proposal.flags.joined(separator: ", ")) — relis le SKILL.md avant d'approuver")
                    .foregroundStyle(colors.warn)
            }
        }

        // Contenu exact qui sera installé.
        VStack(alignment: .leading, spacing: 2) {
            Text("SKILL.MD · \(proposal.skillMD.split(whereSeparator: { $0.isWhitespace }).count) mots")
                .foregroundStyle(colors.dim)
            HStack(alignment: .top, spacing: 8) {
                if let installedContent { document(installedContent, label: "INSTALLÉ ACTUELLEMENT") }
                document(proposal.skillMD, label: "PROPOSITION · installée telle quelle")
            }
        }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)

        // Navigation
        if center.proposals.count > 1 {
            HStack {
                Spacer()
                AsciiButton(label: "◀ PRÉC", color: colors.dim, shortcut: .leftArrow, modifiers: []) {
                    select(at: currentIndex - 1)
                }
                Text("\(currentIndex + 1) / \(center.proposals.count)").foregroundStyle(colors.dim)
                AsciiButton(label: "SUIV ▶", color: colors.dim, shortcut: .rightArrow, modifiers: []) {
                    select(at: currentIndex + 1)
                }
                Spacer()
            }
        }

        // Décisions — raccourcis DÉLIBÉRÉMENT différents des permissions (⌘⏎/⌘⌫,
        // pas ⌘Y/⌘N) : approuver un skill est un acte plus lourd, friction voulue.
        HStack(spacing: 12) {
            AsciiButton(label: "REJETER ⌘⌫", color: colors.warn, shortcut: .delete, modifiers: .command) {
                center.reject(proposal.id)
            }
            Spacer()
            AsciiButton(label: "PLUS TARD", color: colors.dim, shortcut: nil) {
                onClose()
            }
            Spacer()
            AsciiButton(label: "APPROUVER ⌘⏎", color: colors.ok, shortcut: .return, modifiers: .command) {
                if center.isUpdateOfModifiedSkill(proposal) {
                    overwriteProposal = proposal
                    confirmingOverwrite = true
                } else {
                    center.approve(proposal)
                }
            }
        }
        .font(AtollFont.mono(11))
        .disabled(center.approving != nil)

        if center.approving != nil || center.catalogLoading == proposal.id {
            Text("Vérification du catalogue et de la destination…")
                .font(AtollFont.mono(9)).foregroundStyle(colors.dim)
        }

        if let error = center.lastError {
            Text(error).font(AtollFont.mono(9)).foregroundStyle(colors.warn)
        }

        EmptyView()
            .alert("Écraser un skill modifié à la main ?", isPresented: $confirmingOverwrite) {
                Button("Annuler", role: .cancel) { }
                Button("Écraser", role: .destructive) {
                    if let snapshot = overwriteProposal {
                        center.approve(snapshot, force: true)
                    }
                }
            } message: {
                Text("Vous avez édité ce skill après son installation. L'approbation archivera votre version avant de la remplacer.")
            }
    }

    private func select(at index: Int) {
        guard center.proposals.indices.contains(index) else { return }
        selectedID = center.proposals[index].id
    }

    private func document(_ text: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(AtollFont.mono(9)).foregroundStyle(colors.dim)
            Text(text).font(AtollFont.mono(10)).foregroundStyle(colors.fg)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true).padding(8).background(colors.surface)
        }
        .frame(maxWidth: .infinity)
    }
}
