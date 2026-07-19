import SwiftUI
import AtollCore

/// Bouton ASCII : `[ LABEL ]` cliquable, avec raccourci clavier optionnel.
struct AsciiButton: View {
    let label: String
    let color: Color
    var shortcut: KeyEquivalent?
    var modifiers: EventModifiers = .command
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Text("[ \(label) ]")
                .font(AtollFont.mono(11, weight: .bold))
                .foregroundStyle(color)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if let shortcut {
            button.keyboardShortcut(shortcut, modifiers: modifiers)
        } else {
            button
        }
    }
}

/// Carte interactive : permission, plan ou question — le cœur d'Atoll.
struct InteractionCardView: View {
    let request: InteractionCenter.Pending
    let colors: ThemeColors

    private var center: InteractionCenter { .shared }

    @State private var planFeedback = ""
    @State private var planAcceptEdits = false
    @State private var selectedOptions: [String: Set<String>] = [:]
    @State private var freeTexts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            switch request.kind {
            case .permission:
                permissionBody
            case .plan(let markdown):
                planBody(markdown)
            case .questions(let questions, _):
                questionsBody(questions)
            }
        }
    }

    // MARK: - En-tête

    private var header: some View {
        HStack(spacing: 6) {
            Text(AsciiArt.sectionHeader(headerTitle, width: 30))
                .lineLimit(1)
                .foregroundStyle(colors.warn)
            Text(request.projectName)
                .foregroundStyle(colors.dim)
                .lineLimit(1)
            // Autres demandes en file : chacune bloque son propre helper jusqu'à
            // résolution ; on signale qu'il y en a d'autres derrière.
            if center.pending.count > 1 {
                Text("(1/\(center.pending.count))")
                    .foregroundStyle(colors.accent)
            }
            Spacer(minLength: 4)
            ElapsedText(since: request.receivedAt)
                .foregroundStyle(colors.dim)
        }
        .font(AtollFont.mono(10))
    }

    private var headerTitle: String {
        switch request.kind {
        case .permission: return "PERMISSION"
        case .plan: return "PLAN"
        case .questions: return "QUESTION"
        }
    }

    // MARK: - Permission

    private var permissionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("⚠")
                    .foregroundStyle(colors.warn)
                Text(request.toolSummary ?? request.toolName ?? "outil inconnu")
                    .foregroundStyle(colors.fg)
                    .lineLimit(3)
            }
            .font(AtollFont.mono(11))
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.surface)

            HStack(spacing: 14) {
                AsciiButton(label: "DENY ⌘N", color: colors.warn, shortcut: "n") {
                    center.deny(request.id)
                }
                AsciiButton(label: "TERMINAL", color: colors.dim, shortcut: nil) {
                    center.handBackToTerminal(request.id)
                }
                Spacer()
                AsciiButton(label: "ALLOW ⌘Y", color: colors.ok, shortcut: "y") {
                    center.allow(request.id)
                }
            }
        }
    }

    // MARK: - Plan

    private func planBody(_ markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(renderedMarkdown(markdown))
                    .font(AtollFont.mono(10))
                    .foregroundStyle(colors.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 150)
            .padding(8)
            .background(colors.surface)

            Button {
                planAcceptEdits.toggle()
            } label: {
                Text("\(planAcceptEdits ? "[x]" : "[ ]") auto-accepter les éditions ensuite")
                    .font(AtollFont.mono(10))
                    .foregroundStyle(planAcceptEdits ? colors.accent : colors.dim)
            }
            .buttonStyle(.plain)

            TextField("feedback si révision…", text: $planFeedback, axis: .vertical)
                .textFieldStyle(.plain)
                .font(AtollFont.mono(10))
                .foregroundStyle(colors.fg)
                .lineLimit(1...3)
                .padding(6)
                .background(colors.surface)

            HStack(spacing: 14) {
                AsciiButton(label: "REVISE ⌘N", color: colors.warn, shortcut: "n") {
                    center.rejectPlan(request.id, feedback: planFeedback)
                }
                Spacer()
                AsciiButton(label: "APPROVE ⌘Y", color: colors.ok, shortcut: "y") {
                    center.approvePlan(request.id, acceptEdits: planAcceptEdits)
                }
            }
        }
    }

    private func renderedMarkdown(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }

    // MARK: - Questions

    private func questionsBody(_ questions: [ParsedHookEvent.AskQuestion]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                        questionBlock(question)
                    }
                }
            }
            .frame(maxHeight: 210)

            HStack(spacing: 10) {
                AsciiButton(label: "TERMINAL", color: colors.dim, shortcut: nil) {
                    center.handBackToTerminal(request.id)
                }
                Spacer()
                if !allAnswered(questions) {
                    Text("répondez à tout")
                        .font(AtollFont.mono(9))
                        .foregroundStyle(colors.dim)
                }
                // Le CLI attend une réponse à CHAQUE question : ENVOYER reste
                // désactivé tant que tout n'est pas répondu.
                AsciiButton(
                    label: "ENVOYER ⏎",
                    color: allAnswered(questions) ? colors.ok : colors.dim,
                    shortcut: allAnswered(questions) ? .return : nil,
                    modifiers: []
                ) {
                    sendAnswers(questions)
                }
                .disabled(!allAnswered(questions))
            }
        }
    }

    private func questionBlock(_ question: ParsedHookEvent.AskQuestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question.question)
                .font(AtollFont.mono(11, weight: .bold))
                .foregroundStyle(colors.fg)

            ForEach(question.options, id: \.label) { option in
                optionRow(question: question, option: option)
            }

            TextField("autre réponse…", text: freeTextBinding(question.question))
                .textFieldStyle(.plain)
                .font(AtollFont.mono(10))
                .foregroundStyle(colors.fg)
                .padding(4)
                .background(colors.surface)
        }
    }

    private func optionRow(question: ParsedHookEvent.AskQuestion, option: ParsedHookEvent.AskQuestion.Option) -> some View {
        let isSelected = selectedOptions[question.question, default: []].contains(option.label)
        return Button {
            toggle(question: question, label: option.label)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(question.multiSelect ? (isSelected ? "[x]" : "[ ]") : (isSelected ? "▸" : "·"))
                    .foregroundStyle(isSelected ? colors.accent : colors.dim)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label)
                        .foregroundStyle(isSelected ? colors.accent : colors.fg)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .foregroundStyle(colors.dim)
                            .lineLimit(2)
                    }
                }
            }
            .font(AtollFont.mono(10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(question: ParsedHookEvent.AskQuestion, label: String) {
        var selection = selectedOptions[question.question, default: []]
        if question.multiSelect {
            if selection.contains(label) { selection.remove(label) } else { selection.insert(label) }
        } else {
            selection = selection.contains(label) ? [] : [label]
        }
        selectedOptions[question.question] = selection
        // Options et texte libre s'excluent : ce qui est affiché est ce qui sera
        // envoyé (le texte libre ne doit pas écraser silencieusement une sélection).
        if !selection.isEmpty { freeTexts[question.question] = "" }
    }

    private func freeTextBinding(_ question: String) -> Binding<String> {
        Binding(
            get: { freeTexts[question] ?? "" },
            set: { newValue in
                freeTexts[question] = newValue
                if !newValue.isEmpty { selectedOptions[question] = [] }
            }
        )
    }

    /// Chaque question a-t-elle une réponse (sélection ou texte libre) ?
    private func allAnswered(_ questions: [ParsedHookEvent.AskQuestion]) -> Bool {
        questions.allSatisfy { question in
            !(freeTexts[question.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !selectedOptions[question.question, default: []].isEmpty
        }
    }

    private func sendAnswers(_ questions: [ParsedHookEvent.AskQuestion]) {
        var answers: [String: String] = [:]
        for question in questions {
            let free = (freeTexts[question.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let selected = selectedOptions[question.question, default: []]
            if !free.isEmpty {
                answers[question.question] = free
            } else if !selected.isEmpty {
                // Ordre stable : celui des options d'origine.
                let ordered = question.options.map(\.label).filter { selected.contains($0) }
                answers[question.question] = ordered.joined(separator: ", ")
            }
        }
        // Aucune réponse fournie : ne rien envoyer (l'utilisateur peut choisir
        // TERMINAL ou répondre d'abord).
        guard !answers.isEmpty else { return }
        center.answerQuestions(request.id, answers: answers)
    }
}

/// « il y a Xs » qui se met à jour toutes les secondes.
struct ElapsedText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            Text(seconds < 60 ? "il y a \(seconds) s" : "il y a \(seconds / 60) min")
                .font(AtollFont.mono(9))
        }
    }
}
