import SwiftUI
import AtollCore

struct ProviderSelector: View {
    let viewModel: NotchViewModel
    let colors: ThemeColors

    var body: some View {
        HStack(spacing: 8) {
            ForEach(AgentProvider.allCases, id: \.self) { provider in
                let count = viewModel.allSessions.filter { $0.provider == provider }.count
                let requests = InteractionPresentation.shared.items.filter { $0.id.provider == provider }.count
                let selected = viewModel.selectedProvider == provider
                Button {
                    viewModel.selectProvider(provider)
                } label: {
                    HStack(spacing: 6) {
                        Text(provider == .claude ? "CLAUDE CODE" : "CODEX")
                        Text("\(count)")
                        if requests > 0 { Text("!\(requests)").foregroundStyle(colors.warn) }
                    }
                    .font(AtollFont.mono(10, weight: selected ? .bold : .regular))
                    .foregroundStyle(selected ? colors.accent : colors.dim)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(selected ? colors.accent.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? colors.accent.opacity(0.7) : colors.dim.opacity(0.25)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(provider == .claude ? "Claude Code" : "Codex"), \(count) sessions, \(requests) demandes")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .help("Afficher \(provider.label) ; les deux agents restent suivis")
            }
        }
    }
}
