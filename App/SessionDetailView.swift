import SwiftUI
import AtollCore

/// Vue détaillée d'une session : modèle, branche, sous-agents, MCP, contexte, coût.
/// Affichée quand l'utilisateur clique une ligne de session dans l'îlot étendu.
struct SessionDetailView: View {
    let session: AgentSession
    let colors: ThemeColors
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // En-tête cliquable pour revenir à la liste.
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Text("‹ retour")
                        .foregroundStyle(colors.accent)
                    Text(session.projectName)
                        .foregroundStyle(colors.fg)
                        .lineLimit(1)
                    Spacer()
                    Text(AsciiArt.statusBadge(session.status))
                        .foregroundStyle(badgeColor)
                }
                .font(AtollFont.mono(11, weight: .bold))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(AsciiArt.rule(56))
                .foregroundStyle(colors.dim)
                .lineLimit(1)

            grid

            if let subtitle = session.subtitle, !subtitle.isEmpty {
                Text("« \(subtitle) »")
                    .font(AtollFont.mono(10))
                    .foregroundStyle(colors.dim)
                    .lineLimit(2)
            }

            if let context = session.contextUsedFraction {
                HStack(spacing: 6) {
                    Text("contexte")
                        .foregroundStyle(colors.dim)
                    Text(AsciiArt.progressBar(fraction: context, cells: 14))
                        .foregroundStyle(context > 0.85 ? colors.warn : colors.accent)
                    Text("\(Int(context * 100))%")
                        .foregroundStyle(colors.fg)
                }
                .font(AtollFont.mono(10))
            }

            Spacer(minLength: 0)
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("modèle", session.model.map { ModelName.display($0) } ?? "—")
            row("branche", session.gitBranch ?? "—")
            row("sous-agents", session.subagentCount > 0 ? "\(session.subagentCount) actifs" : "—")
            row("MCP", session.mcpServers.isEmpty ? "—" : session.mcpServers.joined(separator: ", "))
            if let cost = session.costUSD {
                row("coût session", String(format: "$%.2f", cost))
            }
            row("dossier", session.cwd ?? "—")
        }
        .font(AtollFont.mono(10))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label.padding(toLength: 12, withPad: " ", startingAt: 0))
                .foregroundStyle(colors.dim)
            Text(value)
                .foregroundStyle(colors.fg)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
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
