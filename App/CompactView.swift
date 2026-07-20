import SwiftUI
import AtollCore

/// État compact : ailes de part et d'autre du notch (ou pilule sur écran sans notch).
struct CompactView: View {
    let viewModel: NotchViewModel
    let colors: ThemeColors

    @AppStorage(InteractionCenter.autonomyKey) private var autonomyRaw = AutonomyLevel.manual.rawValue
    private var rockstar: Bool { AutonomyLevel(rawValue: autonomyRaw) == .rockstar }

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
            // Pilule simulée (écran sans encoche) : tout le contenu est visible.
            // Comme l'aile gauche du notch, elle nomme la session en cours / qui
            // attend une décision — sinon le 2e écran n'indiquait rien.
            HStack(spacing: 6) {
                statusGlyph
                if let session = focusSession {
                    Text(shortName(session.projectName))
                        .foregroundStyle(session.needsAttention ? colors.warn : colors.dim)
                        .lineLimit(1)
                    if viewModel.sessions.count > 1 {
                        Text("+\(viewModel.sessions.count - 1)")
                            .foregroundStyle(colors.dim)
                    }
                } else {
                    Text("atoll")
                        .foregroundStyle(colors.dim)
                }
                Spacer(minLength: 4)
                if viewModel.hasRealQuota {
                    Text("5h \(Int(viewModel.usage.fiveHourFraction * 100))%")
                        .foregroundStyle(colors.dim)
                }
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

    /// Session à mettre en avant sur le notch : une demande de permission
    /// d'abord (urgent), sinon une session qui travaille. Les sessions DORMANTES
    /// ne sont PAS mises en avant (sinon le notch afficherait le nom d'une
    /// session inactive comme si quelque chose se passait).
    private var focusSession: AgentSession? {
        viewModel.sessions.first { $0.needsAttention }
            ?? viewModel.sessions.first { $0.isActive }
    }

    private var leftWing: some View {
        HStack(spacing: 5) {
            statusGlyph
            if let session = focusSession {
                // Nom court de la session en cours / qui attend une décision.
                Text(shortName(session.projectName))
                    .foregroundStyle(session.needsAttention ? colors.warn : colors.dim)
                    .lineLimit(1)
                if viewModel.sessions.count > 1 {
                    Text("+\(viewModel.sessions.count - 1)")
                        .foregroundStyle(colors.dim)
                }
            }
            Spacer(minLength: 0)
        }
        .font(AtollFont.mono(10))
        .padding(.leading, 12)
    }

    /// Dernier segment du nom, tronqué pour tenir dans l'aile.
    private func shortName(_ name: String) -> String {
        let last = name.contains("/") ? String(name.split(separator: "/").last ?? "") : name
        return last.count > 10 ? String(last.prefix(9)) + "…" : last
    }

    private var rightWing: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            // Jamais de jauge factice : rien tant que le vrai quota n'est pas là.
            if viewModel.hasRealQuota {
                Text("5h")
                    .foregroundStyle(colors.dim)
                Text(AsciiArt.progressBar(fraction: viewModel.usage.fiveHourFraction, cells: 4))
                    .foregroundStyle(colors.accent)
                Text("\(Int(viewModel.usage.fiveHourFraction * 100))%")
                    .foregroundStyle(colors.dim)
            } else {
                Text("·")
                    .foregroundStyle(colors.dim)
            }
        }
        .font(AtollFont.mono(10))
        .padding(.trailing, 12)
    }

    // Rouge = mode rockstar actif (indicateur persistant permanent).
    private var rockstarRed: Color { Color(hex: 0xFF3B30) }

    @ViewBuilder
    private var statusGlyph: some View {
        if viewModel.workingCount > 0 {
            // Le spinner tourne toujours (= travail) ; rouge s'il est en rockstar.
            AsciiSpinnerView(color: rockstar ? rockstarRed : colors.accent)
        } else if viewModel.attentionCount > 0 {
            Text("?")
                .foregroundStyle(rockstar ? rockstarRed : colors.warn)
        } else {
            // Au repos : losange rouge en rockstar, sinon point discret.
            Text(rockstar ? "◆" : "·")
                .foregroundStyle(rockstar ? rockstarRed : colors.dim)
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
