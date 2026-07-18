import SwiftUI
import AtollCore

/// État compact : ailes de part et d'autre du notch (ou pilule sur écran sans notch).
struct CompactView: View {
    let viewModel: NotchViewModel
    let colors: ThemeColors

    var body: some View {
        if let notch = viewModel.notchSize {
            // Écran à encoche : contenu dans les ailes, le centre reste vide
            // (il est physiquement masqué par le notch).
            if viewModel.hasActivity {
                HStack(spacing: 0) {
                    leftWing
                        .frame(width: IslandGeometry.wingWidth)
                    Color.clear
                        .frame(width: notch.width)
                    rightWing
                        .frame(width: IslandGeometry.wingWidth)
                }
                .frame(height: notch.height)
            }
        } else {
            // Pilule simulée : tout le contenu est visible, centré verticalement.
            HStack(spacing: 6) {
                statusGlyph
                Text("atoll")
                    .foregroundStyle(colors.dim)
                Spacer(minLength: 4)
                Text("5h \(Int(viewModel.usage.fiveHourFraction * 100))%")
                    .foregroundStyle(colors.dim)
            }
            .font(AtollFont.mono(10))
            .padding(.horizontal, 10)
            .frame(height: pillHeight)
        }
    }

    private var pillHeight: CGFloat {
        IslandGeometry.compactSize(
            notch: nil,
            menuBarHeight: viewModel.menuBarHeight,
            hasActivity: viewModel.hasActivity
        ).height
    }

    private var leftWing: some View {
        HStack(spacing: 5) {
            statusGlyph
            if viewModel.attentionCount > 0 {
                Text("!\(viewModel.attentionCount)")
                    .foregroundStyle(colors.warn)
            } else {
                Text("\(viewModel.sessions.count)")
                    .foregroundStyle(colors.dim)
            }
            Spacer(minLength: 0)
        }
        .font(AtollFont.mono(11))
        .padding(.leading, 12)
    }

    private var rightWing: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            Text("5h")
                .foregroundStyle(colors.dim)
            Text(AsciiArt.progressBar(fraction: viewModel.usage.fiveHourFraction, cells: 4))
                .foregroundStyle(colors.accent)
            Text("\(Int(viewModel.usage.fiveHourFraction * 100))%")
                .foregroundStyle(colors.dim)
        }
        .font(AtollFont.mono(10))
        .padding(.trailing, 12)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        if viewModel.workingCount > 0 {
            AsciiSpinnerView(color: colors.accent)
        } else if viewModel.attentionCount > 0 {
            Text("?")
                .foregroundStyle(colors.warn)
        } else {
            Text("·")
                .foregroundStyle(colors.dim)
        }
    }
}

/// Spinner braille piloté par TimelineView — aucune @State, aucune invalidation manuelle.
struct AsciiSpinnerView: View {
    var color: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: AsciiArt.spinnerInterval)) { context in
            Text(AsciiArt.spinnerFrame(at: context.date))
                .foregroundStyle(color)
                .contentTransition(.identity)
        }
    }
}
