import SwiftUI
import AtollCore

struct AnalysisSettingsSection: View {
    @AppStorage(LearningSettings.analysisProviderKey) private var provider = AgentProvider.claude.rawValue
    @AppStorage(LearningSettings.failoverEnabledKey) private var fallback = false
    @AppStorage(LearningSettings.unknownQuotaKey) private var allowUnknown = true
    @AppStorage(LearningSettings.maxPerWindowKey) private var maximum = 2
    @AppStorage(LearningSettings.skillDestinationKey) private var destination = "origin"

    var body: some View {
        Section("Abonnement des analyses Atoll") {
            Picker("Moteur", selection: $provider) {
                Text("Claude Code").tag(AgentProvider.claude.rawValue)
                Text("Codex CLI").tag(AgentProvider.codex.rawValue)
            }
            .pickerStyle(.segmented)
            Picker("Skills proposés pour", selection: $destination) {
                Text("L'agent de la session source").tag("origin")
                Text("Claude Code").tag(AgentProvider.claude.rawValue)
                Text("Codex CLI").tag(AgentProvider.codex.rawValue)
            }
            Text("Bilan, rangement des notes et recherche IA facultative de plugins. Ce choix est indépendant du bouton d'affichage. Une analyse déjà préparée garde son moteur et son modèle.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Autoriser l'autre abonnement si celui-ci est épuisé", isOn: $fallback)
            Text("La bascule exige un quota récent et applicable des deux côtés. Une portée ambiguë ou un quota inconnu ne déclenche jamais de bascule.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Quota inconnu : autoriser une tentative interne par 5 h", isOn: $allowUnknown)
            Stepper("Plafond interne : \(maximum) analyses / 5 h / abonnement", value: $maximum, in: 1...10)
            Text("Ces 5 h sont une limite d'Atoll, pas la fenêtre contractuelle de Codex. Les trois analyses partagent ce plafond. Un lancement impossible ne dépense pas de créneau.")
                .font(.caption).foregroundStyle(.secondary)
            if provider == AgentProvider.codex.rawValue {
                Text(LearningSettings.shared.codexModel.isEmpty
                     ? "Choisis un modèle disponible dans Réglages → Codex avant de lancer une analyse."
                     : "Modèle Codex : \(LearningSettings.shared.codexModel)")
                    .font(.caption)
            }
        }
    }
}
