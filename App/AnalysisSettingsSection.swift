import SwiftUI
import AtollCore

struct AnalysisSettingsSection: View {
    var focusRequest: UUID? = nil
    @AppStorage(LearningSettings.analysisProviderKey) private var provider = AgentProvider.claude.rawValue
    @AppStorage(LearningSettings.unknownQuotaKey) private var allowUnknown = true
    @AppStorage(LearningSettings.maxPerWindowKey) private var maximum = 2
    @AppStorage(LearningSettings.thresholdKey) private var threshold = 0.7
    @State private var optionsExpanded = false

    var body: some View {
        Section("Moteur d’analyse") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Moteur", selection: $provider) {
                    Text("Claude Code").tag(AgentProvider.claude.rawValue)
                    Text("Codex CLI").tag(AgentProvider.codex.rawValue)
                }
                .pickerStyle(.segmented)
                SettingsHelp("Abonnement utilisé uniquement pour proposer des skills. Le choix dans l’îlot ne change pas ce moteur.")
            }
            if provider == AgentProvider.codex.rawValue {
                CodexAnalysisModelPicker(focusRequest: focusRequest)
            }
            if provider == AgentProvider.claude.rawValue {
                ClaudeAnalysisModelPickers()
            }
            DisclosureGroup("Limites de création", isExpanded: $optionsExpanded) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Stepper("\(maximum) analyses maximum / 5 h / abonnement", value: $maximum, in: 1...10)
                        SettingsHelp("Une limite commune aux analyses d'Atoll, indépendante du quota de ton CLI.")
                    }
                    Picker("Quota utilisé maximum", selection: $threshold) {
                        Text("50 %").tag(0.5)
                        Text("60 %").tag(0.6)
                        Text("70 %").tag(0.7)
                        Text("80 %").tag(0.8)
                    }
                    Toggle("Quota inconnu : une tentative par 5 h", isOn: $allowUnknown)
                }
                .padding(.vertical, 8)
            }
        }
        .disclosureGroupStyle(SettingsDisclosureStyle())
    }
}

private struct ClaudeAnalysisModelPickers: View {
    @AppStorage(LearningSettings.modelKey) private var sessionModel = "sonnet"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Modèles Claude Code").font(.callout.weight(.medium))
            modelPicker("Création de skills", selection: $sessionModel)
        }
        .padding(.vertical, 4)
    }

    private func modelPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(LearningSettings.availableModels, id: \.self) { model in
                Text(model.capitalized).tag(model)
            }
        }
    }
}
