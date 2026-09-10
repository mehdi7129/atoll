import SwiftUI
import AtollCore

/// Compact d'origine : activité à gauche, quota à droite. La couleur porte le
/// fournisseur ; son sélecteur reste dans le panneau ouvert.
struct CompactView: View {
    let viewModel: NotchViewModel
    let colors: ThemeColors
    @AppStorage(InteractionCenter.autonomyKey) private var autonomyRaw = AutonomyLevel.manual.rawValue
    private var rockstar: Bool { AutonomyLevel(rawValue: autonomyRaw) == .rockstar }
    private var activityIsRockstar: Bool { rockstar && viewModel.selectedProvider == .claude }

    var body: some View {
        if viewModel.hasActivity || rockstar {
            if let notch = viewModel.notchSize {
                HStack(spacing: 0) {
                    activityLabel
                        .padding(.leading, 12)
                        .frame(width: viewModel.compactWidth.wingWidth)
                    Color.clear.frame(width: notch.width)
                    rightSide.padding(.trailing, 12).frame(width: viewModel.compactWidth.wingWidth)
                }
                .frame(height: notch.height)
            } else {
                HStack(spacing: 6) {
                    activityLabel
                    Spacer(minLength: 4)
                    rightSide
                }
                .padding(.horizontal, 10)
                .frame(height: max(viewModel.menuBarHeight, IslandGeometry.minimumPillHeight))
            }
        }
    }

    private var focusSession: AgentSession? {
        viewModel.sessions.first { $0.needsAttention } ?? viewModel.sessions.first { $0.isActive }
    }

    private var activityLabel: some View {
        HStack(spacing: 5) {
            statusGlyph
            if let session = focusSession {
                Text(shortName(session.projectName))
                    .foregroundStyle(session.needsAttention ? colors.warn : colors.dim)
                if viewModel.sessions.count > 1 {
                    Text("+\(viewModel.sessions.count - 1)")
                        .foregroundStyle(colors.dim).fixedSize()
                }
            } else if !viewModel.hasNotch {
                Text("atoll").foregroundStyle(colors.dim)
            }
            Spacer(minLength: 0)
        }
        .font(AtollFont.mono(10))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(viewModel.selectedProvider.label), \(focusSession?.projectName ?? "au repos")")
    }

    private func shortName(_ name: String) -> String {
        let last = String(name.split(separator: "/").last ?? "")
        return last.count > 10 ? String(last.prefix(9)) + "…" : last
    }

    private var rightSide: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if rockstar {
                Text("◆")
                    .foregroundStyle(Color(hex: 0xFF3B30))
                    .accessibilityLabel("Claude Rockstar actif, y compris en arrière-plan")
                    .help("Rockstar reste actif pour Claude ; Codex conserve ses autorisations")
            }
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                if let quota = compactQuota {
                    HStack(spacing: 4) {
                        if !quota.label.isEmpty { Text(quota.label) }
                        Text("\(Int(quota.fraction * 100))%")
                    }
                    .foregroundStyle(colors.dim)
                } else {
                    Text("·").foregroundStyle(colors.dim)
                }
            }
        }
        .font(AtollFont.mono(10))
        .lineLimit(1)
        .fixedSize()
    }

    private var compactQuota: (label: String, fraction: Double)? {
        if viewModel.selectedProvider == .codex {
            guard let quota = CodexService.shared.quota, quota.isFresh(at: Date()),
                  let bucket = quota.primaryBucket,
                  let window = bucket.windows.first, window.isCurrent(at: Date()) else { return nil }
            // Sans durée connue, le détail nomme la fenêtre. Le compact garde
            // le pourcentage réel, sans inventer « 5h » ni répéter le fournisseur.
            let label = window.label == "principale" || window.label == "secondaire" ? "" : window.label
            return (label, window.usedFraction)
        }
        guard viewModel.hasFreshFiveHour else { return nil }
        return ("5h", viewModel.usage.fiveHourFraction)
    }

    @ViewBuilder private var statusGlyph: some View {
        if viewModel.attentionCount > 0 {
            Text("?").foregroundStyle(colors.warn)
        } else if viewModel.workingCount > 0 {
            AsciiSpinnerView(color: activityIsRockstar ? Color(hex: 0xFF3B30) : colors.accent)
        } else { Text("·").foregroundStyle(colors.accent) }
        if !CodexPreview.enabled && SkillReviewCenter.shared.pendingCount > 0 {
            Text("+").foregroundStyle(colors.accent).accessibilityLabel("Skill proposé")
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
