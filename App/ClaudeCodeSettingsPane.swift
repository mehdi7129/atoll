import SwiftUI
import AtollCore

struct ClaudeCodePane: View {
    let onShowAnalyses: () -> Void
    @AppStorage(ModelQuotaPoller.enabledKey) private var perModelQuota = false
    @State private var hooksInstalled = false
    @State private var hookError: String?
    @State private var configuring = false

    var body: some View {
        Form {
            Section("Connexion à Claude Code") {
                LabeledContent("Suivi des sessions", value: hooksInstalled ? "Installé" : "À installer")
                SettingsHelp("Atoll observe les sessions. Les autorisations et les questions restent dans Claude Code.")
                if !hooksInstalled {
                    Button("Installer l’intégration Claude Code") { configure(install: true) }
                        .disabled(configuring)
                }
                if let hookError { Text(hookError).foregroundStyle(.red) }
            }
            Section("Quota") {
                SettingsHelp("Le quota principal est transmis par la statusline du CLI. Une ancienne mesure garde sa date ; aucune mesure n’est un quota nul.")
                Toggle("Afficher le détail par modèle", isOn: $perModelQuota)
                    .onChange(of: perModelQuota) { _, _ in
                        if !CodexPreview.enabled { ModelQuotaPoller.shared.syncWithSettings() }
                    }
                SettingsHelp("Ajoute les jauges disponibles pour chaque modèle. macOS peut demander l’accès au trousseau.")
            }
            Section("Skills") {
                Button("Régler la création de skills…", action: onShowAnalyses)
            }
            Section {
                DisclosureGroup("Dépannage") {
                    LabeledContent("Réception d’Atoll", value: CodexPreview.enabled ? "active · exemple"
                        : SessionStore.shared.serverRunning ? "active" : "inactive")
                    if hooksInstalled {
                        Button("Réparer les hooks Atoll") { configure(install: true) }.disabled(configuring)
                        Button("Retirer les hooks Atoll") { configure(install: false) }.disabled(configuring)
                    }
                    SettingsHelp("Les autres hooks et les skills installés sont conservés. Une réparation explicite réinstalle les événements Atoll.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { refresh() }
    }

    private func refresh() {
        hooksInstalled = CodexPreview.enabled ? !CommandLine.arguments.contains("--preview-uninstalled") : HookInstaller.isInstalled
    }

    private func configure(install: Bool) {
        guard !configuring else { return }
        if CodexPreview.enabled { hooksInstalled = install; return }
        configuring = true
        hookError = nil
        Task { @MainActor in
            defer { configuring = false; refresh() }
            do {
                if install { try await HookInstaller.install() }
                else { try await HookInstaller.uninstall() }
            } catch { hookError = error.localizedDescription }
        }
    }
}
