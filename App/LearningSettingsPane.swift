import SwiftUI
import AtollCore

struct LearningPane: View {
    var focusRequest: UUID? = nil
    @AppStorage(LearningSettings.enabledKey) private var learningEnabled = false
    @AppStorage(LearningSettings.curationScheduledKey) private var curationScheduled = false
    @AppStorage(LearningSettings.skillDestinationKey) private var skillDestination = "origin"
    @State private var center = SkillReviewCenter.shared
    @State private var curation = NotesCurationService.shared
    @State private var notes: [LearningNoteSummary] = []
    @State private var noteProjects: [(project: String, count: Int)] = []
    @State private var noteVolume = 0
    @State private var attempts: [RetrospectiveRunner.AttemptRecord] = []

    var body: some View {
        ScrollViewReader { scroll in
            Form {
                AnalysisSettingsSection(focusRequest: focusRequest).id("analyses")
                Section("Bilans de session") {
                    Toggle("Apprendre des sessions terminées", isOn: $learningEnabled)
                        .onChange(of: learningEnabled) { _, _ in
                            if !CodexPreview.enabled { LearningSettings.shared.syncWithSettings() }
                        }
                    SettingsHelp("Après une session importante, Atoll peut en tirer des notes et proposer des skills à revoir. Désactiver arrête ces bilans ; le rangement des notes garde son propre réglage.")
                }
                MemorySettingsSection()
                notesSection
                skillsSection
                Section {
                    DisclosureGroup("Journal des analyses") {
                        if attempts.isEmpty {
                            Text("Aucune évaluation enregistrée pour l'instant.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            // Chaque fin de session laisse une trace, même refusée :
                            // c'est ce qui manquait pour comprendre pourquoi rien ne
                            // sortait (le gate refusait en silence).
                            ForEach(attempts) { attempt in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(attemptTitle(attempt))
                                    Text(attemptDetail(attempt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let reason = attempt.failureReason {
                                        Text(reason).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        SettingsHelp("Les analyses lancées ou ignorées, avec leur motif.")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: focusRequest) {
                if focusRequest != nil { scroll.scrollTo("analyses", anchor: .top) }
            }
        }
        .onAppear {
            guard !CodexPreview.enabled else { return }
            center.refresh()
            refreshNotes()
            attempts = RetrospectiveRunner.shared.recentAttempts()
        }
        .onChange(of: curation.lastRunAt) { _, _ in
            if !CodexPreview.enabled { refreshNotes() }
        }
    }

    private var curationOutcome: String? {
        if CodexPreview.enabled {
            return CommandLine.arguments.contains("--preview-curation-blocked")
                ? "Rangement bloqué : le volume des notes dépasse la capacité de cette analyse." : nil
        }
        return curation.lastOutcome
    }

    private var notesSection: some View {
        Section("Notes et rangement") {
            Toggle("Ranger les notes chaque semaine", isOn: $curationScheduled)
                .onChange(of: curationScheduled) { _, _ in
                    if !CodexPreview.enabled { curation.syncWithSettings() }
                }
            HStack {
                Button(curation.phase == .running ? "Rangement en cours…" : "Ranger maintenant") {
                    if !CodexPreview.enabled { curation.curateNow() }
                }
                .disabled(curation.phase == .running || notes.count < 2)
                if curation.phase == .running { ProgressView().controlSize(.small) }
            }
            if let outcome = curationOutcome {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dernier passage").font(.callout.weight(.medium))
                    SettingsHelp(outcome)
                }
            }
            ForEach(CodexPreview.enabled ? [] : curation.warnings, id: \.self) { warning in
                Text(warning).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsHelp("Fusionne les doublons et signale les contradictions, en conservant une archive. Cette analyse utilise ton abonnement.")
            DisclosureGroup("Voir les notes (\(notes.count))") {
                if notes.isEmpty {
                    Text("Aucune note — elles arrivent avec les rétrospectives.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Les 5 plus récentes : un aperçu, pas un explorateur.
                    ForEach(notes.prefix(5)) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title)
                            Text(noteSubtitle(note))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if noteProjects.count > 1 {
                        LabeledContent("Projets", value: projectsSummary)
                            .font(.caption)
                    }
                    LabeledContent("Volume", value: volumeSummary)
                        .font(.caption)
                }

                Button("Ouvrir les notes dans le Finder") {
                    if !CodexPreview.enabled { NSWorkspace.shared.open(BridgePaths.learningDirectory) }
                }
            }
        }
    }

    private var skillsSection: some View {
        Section("Skills") {
            Picker("Proposer les skills pour", selection: $skillDestination) {
                Text("CLI de la session source").tag("origin")
                Text("Claude Code").tag(AgentProvider.claude.rawValue)
                Text("Codex CLI").tag(AgentProvider.codex.rawValue)
            }
            .accessibilityIdentifier("skill-destination")
            SettingsHelp("La destination est indépendante du moteur d'analyse. Chaque skill est installé après ta revue.")
            if center.pendingCount > 0 {
                LabeledContent("Propositions à revoir", value: "\(center.pendingCount)")
                Button("Revoir les propositions…") {
                    if !CodexPreview.enabled { center.requestReviewWindow() }
                }
                DisclosureGroup("Voir les propositions") {
                    ForEach(center.proposals) { proposal in
                        LabeledContent(proposal.title, value: proposal.createdAt.formatted(date: .abbreviated, time: .omitted))
                    }
                }
            } else {
                SettingsHelp("Aucune proposition à revoir pour l'instant.")
            }
            // Les erreurs d'archive et de manifeste restent hors de la liste fermée.
            ForEach(center.reconcileNotes, id: \.self) { note in
                Text(note).font(.callout).foregroundStyle(.secondary)
            }
            if let error = center.lastError { Text(error).font(.callout).foregroundStyle(.red) }
            DisclosureGroup("Skills appris (\(center.installed.count))") {
                if center.installed.isEmpty {
                    Text("Aucun skill appris actif.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(center.installed) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(SkillSlug.dirName(for: row.skill.slug))
                                Text(usageLabel(row))
                                    .font(.caption)
                                    .foregroundStyle(row.suggestedForArchive ? .orange : .secondary)
                            }
                            Spacer()
                            if row.userModified {
                                Text("modifié").font(.caption).foregroundStyle(.orange)
                            }
                            Button("Archiver") { if !CodexPreview.enabled { center.archiveInstalled(slug: row.skill.slug, destination: row.skill.destination) } }
                                .buttonStyle(.borderless)
                        }
                    }
                }

                SettingsHelp("Les skills approuvés sont disponibles dans leur CLI de destination. L'usage Codex reste non mesuré.")
            }
        }
    }

    private func refreshNotes() {
        let inventory = LearningInventory()
        notes = inventory.notes()
        noteProjects = inventory.projects()
        // MÊME mesure que le garde-fou (`NotesCurationPrompt.fitsBudget`) :
        // l'inventaire ne compte que les CORPS, sans front-matter ni noms de
        // fichiers. Le panneau annonçait « 95 % du budget » là où la curation
        // refusait pour dépassement — deux chiffres contradictoires pour la
        // même grandeur (audit du 2026-07-27).
        noteVolume = NotesCurationPrompt.corpusCharacterCount(
            notes: NotesCurationService.readNotes())
    }

    /// « 12 400 caractères · 15 % du budget de rangement » — le budget est ce
    /// qui décide si une curation est possible, autant le montrer.
    private var volumeSummary: String {
        let percent = Int(Double(noteVolume) / Double(NotesCurationPrompt.maxCorpusCharacters) * 100)
        return "\(noteVolume) caractères · \(percent) % du budget de rangement"
    }

    /// « pitfall · Dynamic_Island · 20 juil. » — les champs absents disparaissent.
    private func noteSubtitle(_ note: LearningNoteSummary) -> String {
        var parts: [String] = []
        if let category = note.category { parts.append(category) }
        if let project = note.project, !project.isEmpty {
            parts.append((project as NSString).lastPathComponent)
        }
        if let date = note.createdAt {
            parts.append(date.formatted(date: .abbreviated, time: .omitted))
        }
        return parts.isEmpty ? note.fileName : parts.joined(separator: " · ")
    }

    /// « Dynamic_Island 12 · site-vitrine 3 » (3 premiers projets).
    private var projectsSummary: String {
        noteProjects.prefix(3).map { entry in
            let name = entry.project.isEmpty
                ? "sans projet"
                : (entry.project as NSString).lastPathComponent
            return "\(name) \(entry.count)"
        }
        .joined(separator: " · ")
    }

    private func usageLabel(_ row: InstalledSkillRow) -> String {
        guard let count = row.usageCount else { return "\(row.skill.destination.label) · usage non mesuré" }
        if let last = row.lastUsedAt {
            return "\(row.skill.destination.label) · ≥ \(count) usage(s) observé(s) · dernier \(last.formatted(.relative(presentation: .named)))"
        }
        return "\(row.skill.destination.label) · ≥ \(count) usage(s) observé(s), date inconnue"
    }

    /// « 14:32 · lancée » ou « 14:32 · sautée : quota inconnu ».
    private func attemptTitle(_ attempt: RetrospectiveRunner.AttemptRecord) -> String {
        let time = attempt.decidedAt.formatted(date: .abbreviated, time: .shortened)
        if attempt.decision == "run" {
            return "\(time) · analysée"
        }
        let reason = attempt.decision
            .replacingOccurrences(of: "skip(", with: "")
            .replacingOccurrences(of: ")", with: "")
        return "\(time) · sautée : \(reasonLabel(reason))"
    }

    /// Traduction des raisons du gate — l'utilisateur ne lit pas des rawValue.
    private func reasonLabel(_ raw: String) -> String {
        switch raw {
        case "disabled": return "apprentissage désactivé"
        case "sessionResumed": return "session encore vivante"
        case "sessionTooShort": return "session trop courte"
        case "transcriptMissing": return "transcript introuvable"
        case "transcriptTooSmall": return "session trop légère"
        case "tooFewUserPrompts": return "trop peu d'échanges"
        case "alreadyProcessed": return "déjà analysée"
        case "quotaMissing": return "quota inconnu"
        case "quotaStale": return "quota périmé"
        case "quotaAboveThreshold": return "quota trop consommé"
        case "windowCapReached": return "plafond de la fenêtre 5 h"
        default: return raw
        }
    }

    /// « 2,1 Mo · quota 12 % · 1 note, 1 skill · 0,04 $ ».
    private func attemptDetail(_ attempt: RetrospectiveRunner.AttemptRecord) -> String {
        var parts: [String] = []
        if let bytes = attempt.transcriptBytes {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        if let quota = attempt.quotaFraction {
            parts.append("quota \(Int(quota * 100)) %")
        }
        if let outcome = attempt.outcome {
            parts.append(outcomeLabel(outcome, attempt: attempt))
        }
        if let cost = attempt.costUSD {
            let model = attempt.dominantModel.map { " (\($0.replacingOccurrences(of: "claude-", with: "")))" } ?? ""
            parts.append(String(format: "%.2f $", cost) + model)
        }
        return parts.isEmpty ? attempt.sessionID.prefix(8).description : parts.joined(separator: " · ")
    }

    private func outcomeLabel(_ outcome: String, attempt: RetrospectiveRunner.AttemptRecord) -> String {
        if outcome == "nothing_learned" { return "rien de durable" }
        if outcome.hasPrefix("failed") { return "échec (\(outcome))" }
        let notes = attempt.notesWritten ?? 0
        let skills = attempt.skillsProposed ?? 0
        return "\(notes) note(s), \(skills) skill(s)"
    }
}
