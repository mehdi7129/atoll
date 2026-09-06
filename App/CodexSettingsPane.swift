import SwiftUI
import AtollCore

struct CodexSettingsPane: View {
    @AppStorage(CodexService.quotaEnabledKey) private var quotaEnabled = false
    @AppStorage(CodexService.executableKey) private var executablePath = ""
    @State private var installed = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Codex · intégration expérimentale") {
                Text("Les sessions ayant émis un hook apparaissent dans l'îlot. Les autorisations restent dans Codex ; le mode Rockstar ne s'applique qu'à Claude.")
                LabeledContent("Configuration", value: CodexPaths.hooksURL.path)
                LabeledContent("Hooks Atoll", value: installed ? "présents · confiance à vérifier dans /hooks" : "non installés")
                Button(installed ? "Retirer les hooks Codex" : "Installer les hooks Codex") {
                    do {
                        try HookInstaller.configureCodex(install: !installed)
                        refreshInstalled()
                        message = installed
                            ? "Dans Codex, ouvre /hooks et approuve les définitions Atoll, puis démarre une nouvelle session."
                            : "Hooks retirés. Les autres hooks et la configuration Claude sont préservés."
                    } catch { message = error.localizedDescription }
                }
                if let message { Text(message).font(.caption).textSelection(.enabled) }
                Text("Installation séparée de Claude, avec sauvegarde unique hooks.json.atoll-backup. Ni config.toml ni les choix de confiance ne sont modifiés. Si l'app a été déplacée, retire puis réinstalle ces hooks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Quota de l'abonnement ChatGPT / Codex") {
                Toggle("Lire le quota Codex (toutes les 2 minutes)", isOn: $quotaEnabled)
                    .onChange(of: quotaEnabled) { _, _ in CodexService.shared.syncQuotaSettings() }
                TextField("Chemin de codex (vide = détection)", text: $executablePath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { CodexService.shared.syncQuotaSettings() }
                Button("Appliquer et actualiser") { CodexService.shared.syncQuotaSettings() }
                    .disabled(CodexService.shared.isLoading)
                Text(CodexService.shared.status).font(.caption).foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let quota = CodexService.shared.quota {
                        ForEach(quota.buckets) { bucket in
                            ForEach(bucket.windows) { window in
                                if quota.isFresh(at: context.date), window.isCurrent(at: context.date) {
                                    HStack {
                                        Text("\(bucket.label) · \(window.label)")
                                        Spacer()
                                        Text("\(Int(window.usedFraction * 100)) % utilisés")
                                        if let reset = window.resetsAt { ResetCountdown(resetsAt: reset) }
                                    }
                                } else {
                                    Text("\(bucket.label) · \(window.label) : en attente d'une mesure récente")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                Text("Utilise la connexion de ton CLI (codex login) et son app-server officiel. Aucun message généré, aucun jeton de connexion extrait par Atoll. Les comptes API et les quotas absents ne sont pas affichés comme un abonnement à 0 %. Les durées viennent de Codex, elles ne sont pas supposées être 5 h / 7 j.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Limites de cette première version") {
                Text("Pas d'inventaire des anciennes sessions, de lecture des transcripts Codex, de mémoire injectée, ni de discussion automatique entre agents. Une activité silencieuse devient « état non confirmé » après 15 min (2 min pour une autorisation), puis disparaît après 24 h sans événement.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshInstalled() }
    }

    private func refreshInstalled() {
        installed = CodexHookSettingsEditor.isInstalled(try? Data(contentsOf: CodexPaths.hooksURL))
    }
}
