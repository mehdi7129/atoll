import SwiftUI
import AtollCore

/// Mémoire des deux CLI ; les clés et la synchronisation des hooks restent
/// celles de l'ancien panneau Claude. Le recall automatique reste propre à Claude.
struct MemorySettingsSection: View {
    @AppStorage(MemoryIndexer.enabledKey) private var indexing = true
    @AppStorage(LearningSettings.proactiveRecallKey) private var proactive = false
    @AppStorage(LearningSettings.proactiveRecallMaxHitsKey) private var maxHits = ProactiveRecallConfig.defaultMaxHits
    @AppStorage(LearningSettings.proactiveRecallProjectScopedKey) private var projectScoped = true
    @State private var confirmingRebuild = false
    @State private var recallError: String?
    @State private var indexer = MemoryIndexer.shared

    var body: some View {
        Section("Mémoire commune") {
            Toggle("Indexer les conversations", isOn: Binding(
                get: { indexing },
                set: { enabled in
                    indexing = enabled
                    if !CodexPreview.enabled { indexer.syncWithSettings() }
                    // Un réglage grisé ne doit pas laisser son hook actif.
                    if !enabled, proactive {
                        proactive = false
                        syncRecall()
                    }
                }
            ))
            .accessibilityIdentifier("memory-indexing")
            SettingsHelp("Une mémoire locale pour Claude Code et Codex. Désactiver arrête l'indexation des deux CLI, sans effacer les souvenirs existants.")
            if !CodexPreview.enabled, let stats = indexer.stats {
                LabeledContent("Index", value: "\(stats.sessionCount) sessions · \(stats.messageCount) messages · "
                    + ByteCountFormatter.string(fromByteCount: stats.databaseBytes, countStyle: .file))
                    .font(.callout)
            }
            SettingsHelp("Retrouve un souvenir avec le skill atoll-recall dans Claude Code ou $atoll-recall dans Codex. La recherche est locale ; les extraits joints à la conversation sont transmis à son fournisseur.")
            DisclosureGroup("Rappel automatique · Claude Code") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Joindre les souvenirs liés à mes messages", isOn: Binding(
                        get: { proactive },
                        set: { proactive = $0; syncRecall() }
                    ))
                    .disabled(!indexing)
                    .accessibilityIdentifier("memory-proactive")
                    if proactive {
                        Picker("Nombre de souvenirs", selection: $maxHits) {
                            ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                        }
                        .onChange(of: maxHits) { _, _ in syncRecall() }
                        Toggle("Limiter au projet courant", isOn: $projectScoped)
                            .onChange(of: projectScoped) { _, _ in syncRecall() }
                    }
                    SettingsHelp("Dans Codex, le rappel reste à ta demande.")
                }
                .padding(.vertical, 4)
            }
            // Une erreur de synchronisation ne disparaît pas en repliant le volet.
            if let recallError {
                Text(recallError).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Entretien de la mémoire") {
                Button("Reconstruire l'index…") { confirmingRebuild = true }
                    .disabled(!indexing || indexer.isIndexing)
                SettingsHelp("Relit les conversations encore présentes sur le Mac.")
            }
        }
        .alert("Reconstruire l'index mémoire ?", isPresented: $confirmingRebuild) {
            Button("Annuler", role: .cancel) { }
            Button("Reconstruire", role: .destructive) {
                if !CodexPreview.enabled { indexer.rebuild() }
            }
        } message: {
            Text("L'index est reconstruit depuis tes transcripts. Les messages dont le fichier source a disparu, notamment les sessions purgées par Claude Code, seront perdus.")
        }
        .onAppear {
            if !CodexPreview.enabled { indexer.refreshStats() }
        }
    }

    private func syncRecall() {
        guard !CodexPreview.enabled else { return }
        recallError = LearningSettings.shared.syncProactiveRecall()
    }
}
