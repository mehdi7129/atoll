import SwiftUI
import AtollCore

/// Détail en lecture seule : aucune commande n’est envoyée aux CLI.
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
                    if let badge = AsciiArt.statusBadge(session.status) {
                        Text(badge)
                            .foregroundStyle(badgeColor)
                    }
                }
                .font(AtollFont.mono(11, weight: .bold))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(AsciiArt.rule(79))
                .foregroundStyle(colors.dim)
                .lineLimit(1)

            Text(session.needsAttention ? "Action attendue dans le CLI." : "Suivi de session en lecture seule.")
                .font(AtollFont.mono(9)).foregroundStyle(colors.dim)

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
                    if let usage = session.contextTokenUsage {
                        Text(usage.formattedCounts)
                            .foregroundStyle(colors.dim)
                    }
                }
                .font(AtollFont.mono(10))
                if session.provider == .codex {
                    Text(session.contextMeasuredAt.map { "Dernière mesure : \($0.formatted(date: .omitted, time: .standard))" } ?? "Mesure de contexte, date inconnue")
                        .font(AtollFont.mono(9)).foregroundStyle(colors.dim)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("agent", session.provider.label)
            row("modèle", session.model.map { ModelName.display($0) } ?? "inconnu")
            row(session.provider == .codex ? "branche init." : "branche", session.gitBranch ?? "non renseignée")
            row("sous-agents", session.subagentCountIsKnown
                ? "\(session.subagentCount) actifs\(session.provider == .codex ? " observés" : "")" : "non mesuré")
            row("MCP", session.mcpServers.isEmpty ? "non renseigné" : session.mcpServers.joined(separator: ", "))
            if session.contextUsedFraction == nil { row("contexte", "non mesuré") }
            if session.provider == .codex {
                row("état", session.stateConfirmedByHook ? "confirmé par hook" : "non confirmé récemment")
            }
            if let cost = session.costUSD {
                row("coût session", String(format: "$%.2f", cost))
            }
            row("dossier", session.cwd ?? "inconnu")
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
        case .awaitingPermission: return colors.warn
        // Voir `ExpandedView.badgeColor` : inatteignable, mais pas orange.
        case .awaitingInput: return colors.dim
        case .done: return colors.ok
        }
    }
}
