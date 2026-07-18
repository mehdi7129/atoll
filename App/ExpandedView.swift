import SwiftUI
import AtollCore

/// État étendu : en-tête, liste des sessions, quota.
struct ExpandedView: View {
    let viewModel: NotchViewModel
    let colors: ThemeColors
    let capColors: ThemeColors

    /// Hauteur de la zone « cap » en haut de l'îlot : le notch physique sur un
    /// écran à encoche, la hauteur de la pilule sinon. Le contenu commence dessous —
    /// même géométrie que IslandGeometry.expandedIslandSize.
    private var topInset: CGFloat {
        IslandGeometry.compactSize(
            notch: viewModel.notchSize,
            menuBarHeight: viewModel.menuBarHeight,
            hasActivity: true
        ).height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            sessionList
            Spacer(minLength: 0)
            footer
        }
        .font(AtollFont.mono(11))
        .padding(.horizontal, 18)
        .padding(.top, topInset + 10)
        .padding(.bottom, 14)
        .frame(
            width: IslandGeometry.expandedSize.width,
            height: topInset + IslandGeometry.expandedSize.height,
            alignment: .top
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("░▒▓")
                .foregroundStyle(colors.accent)
            Text("ATOLL")
                .fontWeight(.bold)
                .foregroundStyle(colors.fg)
            Spacer()
            if viewModel.isPinned {
                Text("[ épinglé ]")
                    .foregroundStyle(colors.dim)
            }
        }
        .font(AtollFont.mono(12))
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AsciiArt.sectionHeader("SESSIONS", width: 46))
                .foregroundStyle(colors.dim)

            ForEach(viewModel.sessions) { session in
                SessionRow(session: session, colors: colors)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AsciiArt.sectionHeader("QUOTA", width: 46))
                .foregroundStyle(colors.dim)

            HStack(spacing: 16) {
                quotaGauge(label: "5h", fraction: viewModel.usage.fiveHourFraction)
                quotaGauge(label: "7j", fraction: viewModel.usage.sevenDayFraction)
                Spacer()
            }

            Text("données de démonstration · phase 2 = sessions réelles")
                .font(AtollFont.mono(9))
                .foregroundStyle(colors.dim)
        }
    }

    private func quotaGauge(label: String, fraction: Double) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .foregroundStyle(colors.dim)
            Text(AsciiArt.progressBar(fraction: fraction, cells: 10))
                .foregroundStyle(colors.accent)
            Text("\(Int(fraction * 100))%")
                .foregroundStyle(colors.fg)
        }
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let colors: ThemeColors

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                glyph
                Text(title)
                    .foregroundStyle(colors.fg)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(AsciiArt.statusBadge(session.status))
                    .foregroundStyle(badgeColor)
            }
            if let detail {
                Text("  └ \(detail)")
                    .foregroundStyle(colors.dim)
                    .lineLimit(1)
            }
        }
    }

    private var title: String {
        if let branch = session.gitBranch {
            return "\(session.projectName) · \(branch)"
        }
        return session.projectName
    }

    private var detail: String? {
        switch session.status {
        case .working(let tool): return tool
        case .awaitingPermission(let tool): return tool
        case .awaitingInput, .done: return nil
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch session.status {
        case .working:
            AsciiSpinnerView(color: colors.accent)
        case .awaitingPermission, .awaitingInput:
            Text("!")
                .foregroundStyle(colors.warn)
        case .done:
            Text("·")
                .foregroundStyle(colors.ok)
        }
    }

    private var badgeColor: Color {
        switch session.status {
        case .working: return colors.accent
        case .awaitingPermission, .awaitingInput: return colors.warn
        case .done: return colors.ok
        }
    }
}
