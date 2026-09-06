import SwiftUI
import AtollCore

/// Vue détaillée d'une session : modèle, branche, sous-agents, MCP, contexte, coût.
/// Affichée quand l'utilisateur clique une ligne de session dans l'îlot étendu.
struct SessionDetailView: View {
    let session: AgentSession
    let colors: ThemeColors
    let onBack: () -> Void

    @State private var jumpMessage: String?
    @State private var needsPermissionApp: String?
    @State private var confirmingStop = false
    @State private var stopMessage: String?
    @State private var handoffMessage: String?
    @State private var preparingHandoff = false

    /// Le relais vers Codex est proposé quand la bascule est armée, que `codex`
    /// est réellement installé, et pour une session Claude — reprendre une
    /// session Codex dans Codex n'a pas de sens.
    ///
    /// Il n'est PAS conditionné à un quota Claude épuisé : le geste est utile
    /// avant la panne (préparer la reprise) autant qu'après. Ce qui suit le
    /// quota, c'est le BANDEAU d'alerte, pas le bouton — un bouton qui apparaît
    /// au moment où l'on en a besoin est un bouton qu'on ne trouve pas.
    private var canHandOffToCodex: Bool {
        session.provider == .claude
            && LearningSettings.shared.isFailoverEnabled
            && CodexExecutable.resolveCheap() != nil
    }

    /// Le quota Claude est-il épuisé au sens de la bascule ? Sert UNIQUEMENT à
    /// afficher un bandeau : la décision de dépense, elle, est prise par
    /// `ProviderFailover` avec les mêmes faits.
    private var claudeIsExhausted: Bool {
        let facts = LearningGate.QuotaFacts(
            usedFraction: store.realQuota?.fiveHour.usedFraction,
            receivedAt: store.rawQuotaReceivedAt,
            resetsAt: store.realQuota?.fiveHour.resetsAt
        )
        let decision = ProviderFailover.choose(
            claude: facts, codex: CodexService.shared.quota,
            config: LearningSettings.shared.failoverConfig)
        return decision.reason == .claudeExhausted || decision.reason == .bothExhausted
    }

    /// `claude stop` ne peut agir que sur une session gérée par le daemon.
    /// Un simple `stat` sur un chemin : assez peu coûteux pour un `body`, et le
    /// détail n'affiche qu'une session à la fois.
    private var canStop: Bool {
        session.provider == .claude && FleetLaunch.hasJobDirectory(for: session.id, jobsRoot: BridgePaths.claudeJobsURL)
    }

    private var store: SessionStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // En-tête cliquable pour revenir à la liste.
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Text("‹ retour")
                        .foregroundStyle(colors.accent)
                    Text(session.projectName)
                        .foregroundStyle(colors.fg)
                        .lineLimit(1)
                    Spacer()
                    if let badge = AsciiArt.statusBadge(session.status) {
                        Text(badge)
                            .foregroundStyle(badgeColor)
                    }
                }
                .font(AtollFont.mono(11, weight: .bold))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(AsciiArt.rule(79))
                .foregroundStyle(colors.dim)
                .lineLimit(1)

            jumpBar

            grid

            if let subtitle = session.subtitle, !subtitle.isEmpty {
                Text("« \(subtitle) »")
                    .font(AtollFont.mono(10))
                    .foregroundStyle(colors.dim)
                    .lineLimit(2)
            }

            if let context = session.contextUsedFraction {
                HStack(spacing: 6) {
                    Text("contexte")
                        .foregroundStyle(colors.dim)
                    Text(AsciiArt.progressBar(fraction: context, cells: 14))
                        .foregroundStyle(context > 0.85 ? colors.warn : colors.accent)
                    Text("\(Int(context * 100))%")
                        .foregroundStyle(colors.fg)
                }
                .font(AtollFont.mono(10))
            }

            // Recall proactif : ce qui a été JOINT au dernier message. Sans
            // cette ligne, l'injection est totalement muette (le bloc part
            // avec `suppressOutput`, il n'apparaît qu'au fond du transcript).
            if session.recallInjected > 0 {
                Text("mémoire · \(session.recallInjected) souvenir(s) joint(s) au dernier message")
                    .font(AtollFont.mono(10))
                    .foregroundStyle(colors.dim)
            }

            Spacer(minLength: 0)
        }
        .alert("Arrêter cette session ?", isPresented: $confirmingStop) {
            Button("Annuler", role: .cancel) { }
            Button("Arrêter", role: .destructive) {
                Task {
                    let ok = await FleetLauncher.shared.stop(sessionID: session.id)
                    if ok {
                        onBack() // la session disparaîtra du notch au prochain poll
                    } else {
                        stopMessage = FleetLauncher.shared.lastError ?? "Arrêt échoué."
                    }
                }
            }
        } message: {
            Text("« \(session.projectName) » sera arrêtée (claude stop). Son travail en cours s'interrompt.")
        }
    }

    /// Bouton d'ouverture du terminal de la session (ramène la fenêtre Cursor /
    /// Terminal) + retours (permission, échec).
    private var jumpBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if session.provider == .codex {
                Text(session.needsAttention ? "Autorisation à traiter dans Codex (pas dans Atoll)." : "Suivi Codex par hooks · retourne dans ton client Codex pour interagir.")
                    .font(AtollFont.mono(9)).foregroundStyle(colors.dim)
            }
            HStack(spacing: 12) {
                AsciiButton(label: openLabel, color: colors.accent, shortcut: nil) {
                    performJump()
                }
                .disabled(session.provider == .codex)
                Spacer()
                // Kill-switch par session (`claude stop`). CONFIRMATION obligatoire :
                // le bouton s'affiche pour toute session vivante, y compris la tienne
                // — un clic direct arrêterait ta session de travail (footgun).
                // …et SEULEMENT si le daemon a un job à arrêter : sans dossier
                // dans ~/.claude/jobs, `claude stop` sort en 1 (« No job
                // matching »). C'est le cas de toute session interactive.
                if canHandOffToCodex {
                    AsciiButton(label: preparingHandoff ? "PRÉPARATION…" : "CONTINUER DANS CODEX",
                                color: claudeIsExhausted ? colors.warn : colors.dim,
                                shortcut: nil) {
                        performHandoff()
                    }
                    .disabled(preparingHandoff)
                }
                if session.status != .done, canStop {
                    AsciiButton(label: "ARRÊTER", color: colors.warn, shortcut: nil) {
                        confirmingStop = true
                    }
                }
            }
            if canHandOffToCodex, claudeIsExhausted {
                Text("Quota Claude épuisé — Codex peut prendre le relais.")
                    .font(AtollFont.mono(9)).foregroundStyle(colors.warn)
            }
            if let handoffMessage {
                Text(handoffMessage).font(AtollFont.mono(9)).foregroundStyle(colors.dim)
            }
            if let stopMessage {
                Text(stopMessage).font(AtollFont.mono(9)).foregroundStyle(colors.warn)
            }
            if let needsPermissionApp {
                Button {
                    AutomationPermission.openSettings()
                } label: {
                    Text("⚠ autorise Atoll à contrôler \(needsPermissionApp) → Réglages")
                        .font(AtollFont.mono(9))
                        .foregroundStyle(colors.warn)
                }
                .buttonStyle(.plain)
            } else if let jumpMessage {
                Text(jumpMessage)
                    .font(AtollFont.mono(9))
                    .foregroundStyle(colors.dim)
            }
        }
    }

    /// Libellé du bouton : nomme l'app cible quand on la connaît (« OUVRIR DANS
    /// CURSOR »), sinon générique. C'est l'action principale du détail — ouvrir
    /// la fenêtre où la session vit pour y travailler.
    private var openLabel: String {
        guard let anchor = store.terminalAnchor(for: session.id) else {
            return "ALLER AU TERMINAL ↵"
        }
        return "OUVRIR DANS \(TerminalResolver.resolve(anchor).displayName.uppercased()) ↵"
    }

    private func performJump() {
        jumpMessage = "…"
        needsPermissionApp = nil
        guard let anchor = store.terminalAnchor(for: session.id) else {
            jumpMessage = "ancrage terminal indisponible"
            return
        }
        TerminalJumpService.jump(to: anchor) { result in
            switch result {
            case .focused(_, let granularity):
                jumpMessage = "focus (\(granularity))"
            case .needsAutomationPermission(let appName):
                jumpMessage = nil
                needsPermissionApp = appName
            case .failed(let reason):
                jumpMessage = reason
            }
        }
    }

    /// Prépare la reprise sur Codex : condensé HORS du fil principal (lire et
    /// parser un JSONL de plusieurs dizaines de Mo n'a rien à faire sur le
    /// MainActor), puis écriture des fichiers et ouverture du terminal.
    private func performHandoff() {
        guard !preparingHandoff else { return } // garde de ré-entrance (double-clic)
        preparingHandoff = true
        handoffMessage = nil
        let transcript = store.transcriptPath(for: session.id)
        let session = session
        Task {
            // Budget RÉDUIT à dessein : c'est une reprise, pas une analyse. Les
            // 150 000 caractères du bilan seraient payés au premier tour Codex.
            let digest = await Task.detached(priority: .userInitiated) {
                transcript.flatMap {
                    RetrospectiveRunner.digest(ofTranscriptAt: $0, budget: 40_000)
                }?.text ?? ""
            }.value
            preparingHandoff = false
            switch CodexHandoffService.start(session: session, digest: digest) {
            case .opened:
                handoffMessage = digest.isEmpty
                    ? "Codex ouvert — transcript illisible, aucun contexte joint."
                    : "Codex ouvert dans un terminal, contexte joint."
            case .failed(let reason):
                handoffMessage = reason
            }
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("agent", session.provider.label)
            row("modèle", session.model.map { ModelName.display($0) } ?? "—")
            row("branche", session.gitBranch ?? "—")
            row("sous-agents", session.subagentCount > 0 ? "\(session.subagentCount) actifs" : "—")
            row("MCP", session.mcpServers.isEmpty ? "—" : session.mcpServers.joined(separator: ", "))
            if let cost = session.costUSD {
                row("coût session", String(format: "$%.2f", cost))
            }
            row("dossier", session.cwd ?? "—")
        }
        .font(AtollFont.mono(10))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label.padding(toLength: 12, withPad: " ", startingAt: 0))
                .foregroundStyle(colors.dim)
            Text(value)
                .foregroundStyle(colors.fg)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    private var badgeColor: Color {
        switch session.status {
        case .working: return colors.accent
        case .awaitingPermission: return colors.warn
        // Voir `ExpandedView.badgeColor` : inatteignable, mais pas orange.
        case .awaitingInput: return colors.dim
        case .done: return colors.ok
        }
    }
}
