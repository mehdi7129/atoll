import SwiftUI
import AtollCore

/// Choix d'agent accessible aussi en compact ; le mode Claude reste identifié.
struct CompactView: View {
    let viewModel: NotchViewModel
    let colors: ThemeColors
    @AppStorage(InteractionCenter.autonomyKey) private var autonomyRaw = AutonomyLevel.manual.rawValue
    private var rockstar: Bool { AutonomyLevel(rawValue: autonomyRaw) == .rockstar }
    private var activityIsRockstar: Bool { rockstar && viewModel.selectedProvider == .claude }

    var body: some View {
        if let notch = viewModel.notchSize {
            HStack(spacing: 0) {
                VStack(spacing: 1) {
                    ProviderSelector(viewModel: viewModel, colors: colors, compact: true)
                    activityLabel
                }
                .frame(width: viewModel.compactWidth.wingWidth)
                Color.clear.frame(width: notch.width)
                rightSide.frame(width: viewModel.compactWidth.wingWidth)
            }
            .frame(height: notch.height)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ProviderSelector(viewModel: viewModel, colors: colors, compact: true)
                    activityLabel
                    rightSide
                }
                HStack(spacing: 6) {
                    ProviderSelector(viewModel: viewModel, colors: colors, compact: true)
                    rightSide
                }
            }
            .padding(.horizontal, 8)
            .frame(height: max(viewModel.menuBarHeight, IslandGeometry.minimumPillHeight))
        }
    }

    private var focusSession: AgentSession? {
        viewModel.sessions.first { $0.needsAttention } ?? viewModel.sessions.first { $0.isActive }
    }

    private var activityLabel: some View {
        HStack(spacing: 3) {
            statusGlyph
            Text(focusSession.map { String($0.projectName.split(separator: "/").last ?? "").prefix(9) } ?? "au repos")
                .lineLimit(1).foregroundStyle(colors.dim)
        }
        .font(AtollFont.mono(8))
        .frame(maxWidth: .infinity)
    }

    private var rightSide: some View {
        Group {
            if rockstar {
                VStack(spacing: 0) {
                    Text("CLAUDE")
                    Text("◆ ROCKSTAR")
                }
                .font(AtollFont.mono(8, weight: .bold))
                .foregroundStyle(Color(hex: 0xFF3B30))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Claude Rockstar actif, y compris en arrière-plan")
                .help("Rockstar reste actif pour Claude ; Codex conserve ses autorisations")
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    if let quota = compactQuota {
                        Text("\(quota.label) \(Int(quota.fraction * 100))%")
                            .foregroundStyle(colors.dim)
                    } else {
                        Text("\(viewModel.selectedProvider.label) · —").foregroundStyle(colors.dim)
                    }
                }
                .font(AtollFont.mono(9))
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    private var compactQuota: (label: String, fraction: Double)? {
        if viewModel.selectedProvider == .codex {
            guard let quota = CodexService.shared.quota, quota.isFresh(at: Date()),
                  let bucket = quota.buckets.first(where: { $0.id == "codex" }),
                  let window = bucket.windows.first, window.isCurrent(at: Date()) else { return nil }
            return ("CX \(window.label)", window.usedFraction)
        }
        guard viewModel.hasFreshFiveHour else { return nil }
        return ("CL 5h", viewModel.usage.fiveHourFraction)
    }

    @ViewBuilder private var statusGlyph: some View {
        if viewModel.attentionCount > 0 {
            Text("?").foregroundStyle(colors.warn)
        } else if viewModel.workingCount > 0 {
            AsciiSpinnerView(color: activityIsRockstar ? Color(hex: 0xFF3B30) : colors.accent)
        } else { Text("·").foregroundStyle(colors.dim) }
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
