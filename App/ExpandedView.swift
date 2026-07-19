import SwiftUI
import AtollCore

/// État étendu : en-tête, liste des sessions (ou détail), quota.
struct ExpandedView: View {
    let viewModel: NotchViewModel
    let colors: ThemeColors
    let capColors: ThemeColors

    @AppStorage(InteractionCenter.autoAcceptKey) private var autoAccept = false

    /// Hauteur de la zone « cap » en haut de l'îlot : le notch physique sur un
    /// écran à encoche, la hauteur de la pilule sinon.
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

            if let request = InteractionCenter.shared.current {
                // Une demande en attente prend toute la place.
                InteractionCardView(request: request, colors: colors)
                    .id(request.id)
                Spacer(minLength: 0)
            } else if let session = viewModel.selectedSession {
                // Détail d'une session (clic sur une ligne).
                SessionDetailView(session: session, colors: colors) {
                    viewModel.clearSelection()
                }
            } else {
                sessionList
                Spacer(minLength: 0)
                footer
            }
        }
        .font(AtollFont.mono(11))
        .padding(.horizontal, IslandGeometry.expandedContentInset)
        .padding(.top, topInset + 10)
        .padding(.bottom, 16)
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
            if autoAccept {
                Text("[ AUTO ]")
                    .foregroundStyle(colors.accent)
            }
            Spacer()
            Text("\(viewModel.sessions.count) session\(viewModel.sessions.count > 1 ? "s" : "")")
                .foregroundStyle(colors.dim)
        }
        .font(AtollFont.mono(12))
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AsciiArt.sectionHeader("SESSIONS", width: 72))
                .lineLimit(1)
                .foregroundStyle(colors.dim)

            if viewModel.sessions.isEmpty {
                Text("· aucune session — lance `claude` dans un terminal")
                    .foregroundStyle(colors.dim)
            } else {
                ForEach(viewModel.sessions) { session in
                    SessionRow(session: session, colors: colors) {
                        viewModel.selectSession(session.id)
                    }
                }
                Text("· clique une session pour ses détails")
                    .font(AtollFont.mono(9))
                    .foregroundStyle(colors.dim)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AsciiArt.sectionHeader("QUOTA", width: 72))
                .lineLimit(1)
                .foregroundStyle(colors.dim)

            HStack(spacing: 16) {
                quotaGauge(label: "5h", fraction: viewModel.usage.fiveHourFraction, resetsAt: viewModel.quotaResets.five)
                quotaGauge(label: "7j", fraction: viewModel.usage.sevenDayFraction, resetsAt: viewModel.quotaResets.seven)
                Spacer()
            }

            if !viewModel.hasRealQuota {
                Text("quota indisponible — ouvre une session Claude pour l'alimenter")
                    .font(AtollFont.mono(9))
                    .foregroundStyle(colors.dim)
            }
        }
    }

    private func quotaGauge(label: String, fraction: Double, resetsAt: Date?) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .foregroundStyle(colors.dim)
            Text(AsciiArt.progressBar(fraction: fraction, cells: 10))
                .foregroundStyle(fraction > 0.85 ? colors.warn : colors.accent)
            Text("\(Int(fraction * 100))%")
                .foregroundStyle(colors.fg)
            if let resetsAt {
                ResetCountdown(resetsAt: resetsAt)
                    .foregroundStyle(colors.dim)
            }
        }
    }
}

/// « ↻ 2h14 » : temps restant avant réinitialisation du quota.
struct ResetCountdown: View {
    let resetsAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let remaining = resetsAt.timeIntervalSince(context.date)
            if remaining > 0 {
                Text("↻\(format(remaining))")
                    .font(AtollFont.mono(9))
            }
        }
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h\(String(format: "%02d", minutes))" }
        return "\(minutes)m"
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let colors: ThemeColors
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        var parts = [session.projectName]
        if let branch = session.gitBranch { parts.append(branch) }
        if let model = session.model { parts.append(ModelName.display(model)) }
        return parts.joined(separator: " · ")
    }

    private var detail: String? {
        // Badges d'enrichissement (sous-agents / MCP) quand présents.
        var badges: [String] = []
        if session.subagentCount > 0 { badges.append("⑂\(session.subagentCount)") }
        if !session.mcpServers.isEmpty { badges.append("mcp:\(session.mcpServers.count)") }
        let suffix = badges.isEmpty ? "" : "  " + badges.joined(separator: " ")

        switch session.status {
        case .working(let tool):
            return (tool ?? session.subtitle).map { $0 + suffix } ?? (suffix.isEmpty ? nil : suffix.trimmingCharacters(in: .whitespaces))
        case .awaitingPermission(let tool):
            return tool + suffix
        case .awaitingInput, .done:
            return (session.subtitle).map { $0 + suffix } ?? (suffix.isEmpty ? nil : suffix.trimmingCharacters(in: .whitespaces))
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch session.status {
        case .working:
            AsciiSpinnerView(color: colors.accent)
        case .awaitingPermission, .awaitingInput:
            Text("!").foregroundStyle(colors.warn)
        case .done:
            Text("·").foregroundStyle(colors.ok)
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
