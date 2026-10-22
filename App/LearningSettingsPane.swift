import SwiftUI
import AtollCore

struct LearningPane: View {
    var focusRequest: UUID? = nil
    @AppStorage(LearningSettings.enabledKey) private var learningEnabled = false
    @AppStorage(LearningSettings.skillDestinationKey) private var skillDestination = "origin"
    @State private var center = SkillReviewCenter.shared
    @State private var runner = RetrospectiveRunner.shared
    @State private var attempts: [RetrospectiveRunner.AttemptRecord] = []

    var body: some View {
        ScrollViewReader { scroll in
            Form {
                Section("Création de skills") {
                    Toggle("Créer automatiquement des propositions de skills", isOn: $learningEnabled)
                        .accessibilityIdentifier("skill-generation-enabled")
                        .onChange(of: learningEnabled) { _, _ in
                            if !CodexPreview.enabled { LearningSettings.shared.syncWithSettings() }
                        }
                    SettingsHelp("Analyse les sessions terminées pour proposer des procédures réutilisables. Utilise le quota du moteur choisi. Les skills existants restent disponibles quand cette option est désactivée.")
                }
                AnalysisSettingsSection(focusRequest: focusRequest).id("analyses")
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
            attempts = runner.recentAttempts()
        }
        .onChange(of: runner.journalRevision) { _, _ in
            if !CodexPreview.enabled { attempts = runner.recentAttempts() }
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
                                Text(row.skill.destination.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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

                SettingsHelp("Les skills approuvés sont disponibles dans leur CLI de destination, même quand la création est désactivée.")
            }
        }
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
        case "disabled": return "création désactivée"
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
        let skills = attempt.skillsProposed ?? 0
        return "\(skills) skill(s)"
    }
}
