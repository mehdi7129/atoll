import SwiftUI
import AtollCore

struct AnalysisSettingsSection: View {
    var focusRequest: UUID? = nil
    @AppStorage(LearningSettings.analysisProviderKey) private var provider = AgentProvider.claude.rawValue
    @AppStorage(LearningSettings.failoverEnabledKey) private var fallback = false
    @AppStorage(LearningSettings.unknownQuotaKey) private var allowUnknown = true
    @AppStorage(LearningSettings.maxPerWindowKey) private var maximum = 2
    @AppStorage(LearningSettings.thresholdKey) private var threshold = 0.7
    @State private var optionsExpanded = false

    var body: some View {
        Section("Analyses d'Atoll") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Moteur", selection: $provider) {
                    Text("Claude Code").tag(AgentProvider.claude.rawValue)
                    Text("Codex CLI").tag(AgentProvider.codex.rawValue)
                }
                .pickerStyle(.segmented)
                SettingsHelp("Abonnement utilisé pour les bilans, le rangement des notes et la recherche IA de plugins.")
            }
            if provider == AgentProvider.codex.rawValue || fallback {
                CodexAnalysisModelPicker(focusRequest: focusRequest)
            }
            if provider == AgentProvider.claude.rawValue || fallback {
                ClaudeAnalysisModelPickers()
            }
            DisclosureGroup("Limites et second abonnement", isExpanded: $optionsExpanded) {
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
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Utiliser l'autre abonnement si nécessaire", isOn: $fallback)
                            .accessibilityIdentifier("analysis-fallback")
                        SettingsHelp("Seulement si le premier est épuisé et si les quotas des deux comptes sont connus.")
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .disclosureGroupStyle(SettingsDisclosureStyle())
    }
}

private struct ClaudeAnalysisModelPickers: View {
    @AppStorage(LearningSettings.modelKey) private var sessionModel = "sonnet"
    @AppStorage(LearningSettings.curationModelKey) private var curationModel = ""
    @AppStorage(LearningSettings.searchModelKey) private var searchModel = "haiku"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Modèles Claude Code").font(.callout.weight(.medium))
            modelPicker("Bilan de session", selection: $sessionModel)
            // Sans préférence dédiée, le service utilise le modèle du bilan.
            modelPicker("Rangement des notes", selection: Binding(
                get: { curationModel.isEmpty ? sessionModel : curationModel },
                set: { curationModel = $0 }
            ))
            modelPicker("Recherche de plugins", selection: $searchModel)
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
