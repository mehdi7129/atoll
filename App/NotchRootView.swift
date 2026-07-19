import SwiftUI
import AtollCore

/// Vue racine de la fenêtre d'îlot : occupe toute la fenêtre transparente,
/// dessine l'îlot en haut au centre et anime ses transitions d'état.
struct NotchRootView: View {
    let viewModel: NotchViewModel

    @AppStorage("paletteID") private var paletteID = Palette.monoOrange.id
    @AppStorage("hoverDelay") private var hoverDelay = 0.15
    @Environment(\.colorScheme) private var colorScheme

    private var colors: ThemeColors {
        ThemeColors(paletteID: paletteID, scheme: colorScheme)
    }

    /// Sur un écran à encoche, l'îlot compact prolonge le notch physique : il doit
    /// rester noir quel que soit le thème (le matériel, lui, ne change pas de couleur).
    /// Ses textes utilisent donc toujours la variante sombre de la palette.
    private var capColors: ThemeColors {
        viewModel.hasNotch ? ThemeColors(variant: Palette.named(paletteID).dark) : colors
    }

    private var isCompactCap: Bool {
        viewModel.hasNotch && viewModel.state == .compact
    }

    private var topRadius: CGFloat {
        viewModel.state == .expanded ? 19 : 6
    }

    private var bottomRadius: CGFloat {
        viewModel.state == .expanded ? 24 : 14
    }

    private var pendingCount: Int {
        InteractionCenter.shared.pending.count
    }

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(
            width: IslandGeometry.windowSize.width,
            height: IslandGeometry.windowSize.height,
            alignment: .top
        )
        .onChange(of: pendingCount) { oldCount, newCount in
            // Claude demande quelque chose → l'îlot s'ouvre tout seul (écran
            // principal) et prend le clavier ; tout résolu → il se replie et
            // rend le focus au terminal.
            viewModel.syncInteractionState(pendingCount: newCount, previousCount: oldCount)
        }
        .onAppear {
            // Fenêtre reconstruite (changement d'écran) pendant qu'une carte est
            // en attente : réappliquer l'état, sinon la carte serait invisible et
            // les raccourcis morts.
            if pendingCount > 0 {
                viewModel.syncInteractionState(pendingCount: pendingCount, previousCount: 0)
            }
        }
    }

    @ViewBuilder
    private var island: some View {
        let size = viewModel.islandSize
        let shape = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)

        ZStack(alignment: .top) {
            shape.fill(isCompactCap ? Color.black : colors.bg)

            // Étendu sur écran à encoche : bandeau noir en haut, à hauteur du notch
            // physique, pour que l'encoche reste visuellement intégrée même en clair.
            if viewModel.hasNotch, viewModel.state == .expanded, let notch = viewModel.notchSize {
                Rectangle()
                    .fill(Color.black)
                    .frame(height: notch.height)
            }

            content
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay {
            // Après le clip, sinon la moitié extérieure du trait serait rognée.
            // Pas de bordure en compact sur encoche : fusion invisible avec le notch.
            if !isCompactCap {
                shape.stroke(
                    colors.dim.opacity(colorScheme == .dark ? 0.35 : 0.6),
                    lineWidth: 1
                )
            }
        }
        .contentShape(shape)
        .onHover { hovering in
            viewModel.hoverChanged(hovering, openDelay: hoverDelay)
        }
        .onTapGesture {
            viewModel.togglePinned()
        }
        .shadow(
            color: .black.opacity(viewModel.state == .expanded ? 0.45 : 0),
            radius: 14,
            y: 6
        )
        // Pas de .animation(value:) ici : les springs (ouverture/fermeture distinctes)
        // sont posés par withAnimation dans le view model.
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .compact:
            CompactView(viewModel: viewModel, colors: capColors)
        case .expanded:
            ExpandedView(viewModel: viewModel, colors: colors, capColors: capColors)
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }
}
