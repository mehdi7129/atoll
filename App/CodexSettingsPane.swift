import SwiftUI
import AtollCore

struct CodexSettingsPane: View {
    @AppStorage(CodexService.quotaEnabledKey) private var quotaEnabled = false
    @AppStorage(CodexService.executableKey) private var executablePath = ""
    @AppStorage(LearningSettings.failoverEnabledKey) private var failoverEnabled = false
    @AppStorage(LearningSettings.failoverThresholdKey) private var failoverThreshold = 0.95
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
                Text("Installation séparée de Claude, avec sauvegarde unique hooks.json.atoll-backup. Ni config.toml ni les choix de confiance ne sont modifiés. Si l'app est déplacée, le lanceur est corrigé tout seul au démarrage suivant.")
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
            Section("Prendre le relais quand Claude est épuisé") {
                Toggle("Basculer sur Codex quand le quota Claude est épuisé", isOn: $failoverEnabled)
                Text("Concerne les deux analyses qu'Atoll lance lui-même : le bilan de fin de session et le rangement des notes. Elles s'arrêtaient net quand le quota Claude était plein ; elles peuvent désormais être payées par l'abonnement Codex.")
                    .font(.caption).foregroundStyle(.secondary)
                if failoverEnabled {
                    VStack(alignment: .leading) {
                        Text("Claude est tenu pour épuisé à partir de \(Int(failoverThreshold * 100)) %")
                        Slider(value: $failoverThreshold, in: 0.50...1.0, step: 0.05)
                    }
                    Text("Volontairement plus haut que le seuil de l'apprentissage : celui-ci dit « pas assez de marge pour me le permettre », celui-là « il n'y a plus rien ». Basculer trop tôt ferait payer Codex alors que Claude peut encore servir ton propre travail.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !quotaEnabled {
                        // DÉPENDANCE RÉELLE, pas une préférence : sans lecture du
                        // quota Codex, `ProviderFailover` rend toujours
                        // `codexUnknown` et rien ne bascule JAMAIS. Le dire ici
                        // plutôt que d'activer le réglage à la place de
                        // l'utilisateur — et plutôt que de le laisser croire que
                        // c'est armé.
                        Label("Rien ne basculera : la lecture du quota Codex est désactivée plus haut. Sans mesure récente des deux comptes, Atoll refuse de dépenser.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("La bascule exige une mesure RÉCENTE des deux quotas. Un quota Claude inconnu ne déclenche rien : sans mesure, « épuisé » est une supposition, et une supposition ne doit pas dépenser un second abonnement.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Le bouton « CONTINUER DANS CODEX » apparaît aussi dans le détail d'une session : il ouvre un terminal sur Codex dans le même dossier, avec un condensé de la session à côté. Atoll ne peut PAS transformer une session Claude en cours en session Codex — il prépare la reprise, le geste reste le tien.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
