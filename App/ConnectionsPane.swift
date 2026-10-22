import SwiftUI
import AtollCore

/// Les deux collecteurs restent actifs ; ce choix ne sélectionne que le volet.
struct ConnectionsPane: View {
    let onShowAnalyses: () -> Void
    @State private var provider = AgentProvider.claude

    var body: some View {
        VStack(spacing: 0) {
            Picker("Connexion", selection: $provider) {
                Text("Claude Code").tag(AgentProvider.claude)
                Text("Codex CLI").tag(AgentProvider.codex)
            }
            .pickerStyle(.segmented).padding()
            if !CodexPreview.enabled {
                if let error = EssentialMigration.shared.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Migration à terminer").font(.headline)
                        Text(error).font(.callout).textSelection(.enabled)
                        Button("Réessayer la migration") {
                            Task { @MainActor in
                                if await EssentialMigration.shared.run() {
                                    SkillReviewCenter.shared.reconcileAndScan()
                                    LearningSettings.shared.syncWithSettings()
                                }
                            }
                        }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading)
                }
                if !EssentialMigration.shared.warnings.isEmpty {
                    DisclosureGroup("Diagnostics de migration") {
                        ForEach(EssentialMigration.shared.warnings, id: \.self) { Text($0).font(.caption) }
                    }.padding(.horizontal)
                }
            }
            if provider == .codex { CodexSettingsPane(onShowAnalyses: onShowAnalyses) }
            else { ClaudeCodePane(onShowAnalyses: onShowAnalyses) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { provider = ProviderPreferences.shared.selection }
    }
}
