import SwiftUI
import AtollCore

/// État étendu : en-tête, liste des sessions (ou détail), quota.
struct ExpandedView: View {
    let viewModel: NotchViewModel
    let colors: ThemeColors
    let capColors: ThemeColors

    @AppStorage(InteractionCenter.autonomyKey) private var autonomyRaw = AutonomyLevel.manual.rawValue
    private var level: AutonomyLevel { AutonomyLevel(rawValue: autonomyRaw) ?? .manual }

    /// Projets dépliés (racines de projet). Les dossiers multi-sessions sont
    /// repliés par défaut : on voit un dossier par projet, on déplie pour voir
    /// les sessions — clarifie « 3 sessions pour 2 projets » (une nichée dans
    /// notre projet de dev).
    @State private var expandedProjects: Set<String> = []

    /// Hauteur de la zone « cap » en haut de l'îlot : le notch physique sur un
    /// écran à encoche, la hauteur de la pilule sinon.
    private var topInset: CGFloat {
        IslandGeometry.compactSize(
            notch: viewModel.notchSize,
            menuBarHeight: viewModel.menuBarHeight,
            hasActivity: true
        ).height
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let request = InteractionCenter.shared.current {
                // Une demande en attente prend toute la place (priorité maximale).
                InteractionCardView(request: request, colors: colors)
                    .id(request.id)
                Spacer(minLength: 0)
            } else if let session = viewModel.selectedSession {
                // Détail d'une session (clic sur une ligne).
                SessionDetailView(session: session, colors: colors) {
                    viewModel.clearSelection()
                }
            } else {
                sessionList
                Spacer(minLength: 0)
                // Bannière passive : jamais par-dessus une carte de permission
                // (branche else uniquement), aucune ouverture forcée.
                if SkillReviewCenter.shared.pendingCount > 0 {
                    learningBanner
                }
                footer
            }
        }
        .font(AtollFont.mono(11))
        .padding(.horizontal, IslandGeometry.expandedContentInset)
        .padding(.top, topInset + 10)
        .padding(.bottom, 16)
        .frame(
            width: IslandGeometry.expandedSize.width,
            height: topInset + IslandGeometry.expandedSize.height,
            alignment: .top
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("░▒▓")
                .foregroundStyle(colors.accent)
            Text("ATOLL")
                .fontWeight(.bold)
                .foregroundStyle(colors.fg)
            switch level {
            case .rockstar:
                Text("[ ROCKSTAR ]")
                    .foregroundStyle(Color(hex: 0xFF3B30))
            case .auto:
                Text("[ AUTO ]")
                    .foregroundStyle(colors.accent)
            case .manual:
                EmptyView()
            }
            Spacer()
            Text("\(viewModel.sessions.count) session\(viewModel.sessions.count > 1 ? "s" : "")")
                .foregroundStyle(colors.dim)
        }
        .font(AtollFont.mono(12))
    }

    private var sessionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AsciiArt.sectionHeader("SESSIONS", width: 72))
                .lineLimit(1)
                .foregroundStyle(colors.dim)

            if viewModel.sessions.isEmpty {
                Text("· aucune session — lance `claude` dans un terminal")
                    .foregroundStyle(colors.dim)
            } else {
                ForEach(projectGroups) { group in
                    if group.sessions.count == 1 {
                        // Un seul projet = une seule session : ligne directe
                        // (pas de dossier inutile).
                        SessionRow(session: group.sessions[0], colors: colors) {
                            viewModel.selectSession(group.sessions[0].id)
                        }
                    } else {
                        // Plusieurs sessions dans le même projet → dossier pliable.
                        folderHeader(group)
                        if expandedProjects.contains(group.id) {
                            ForEach(group.sessions) { session in
                                SessionRow(session: session, colors: colors) {
                                    viewModel.selectSession(session.id)
                                }
                                .padding(.leading, 16)
                            }
                        }
                    }
                }
                Text("· clique une session pour ses détails")
                    .font(AtollFont.mono(9))
                    .foregroundStyle(colors.dim)
            }
        }
    }

    /// Sessions regroupées par PROJET (racine `.git`), ordre de première apparition
    /// préservé.
    private var projectGroups: [ProjectGroup] {
        var order: [String] = []
        var byRoot: [String: [AgentSession]] = [:]
        for session in viewModel.sessions {
            let key = ProjectRoot.key(for: session)
            if byRoot[key] == nil { order.append(key) }
            byRoot[key, default: []].append(session)
        }
        return order.map { key in
            ProjectGroup(id: key, name: ProjectRoot.name(for: key), sessions: byRoot[key] ?? [])
        }
    }

    /// En-tête d'un dossier de projet : flèche de pliage, nom, nombre, et un
    /// glyphe d'attention si une session du groupe a besoin de toi (sinon le
    /// détail reste replié — l'info reste visible d'un coup d'œil).
    private func folderHeader(_ group: ProjectGroup) -> some View {
        let isOpen = expandedProjects.contains(group.id)
        return Button {
            if isOpen { expandedProjects.remove(group.id) } else { expandedProjects.insert(group.id) }
        } label: {
            HStack(spacing: 6) {
                Text(isOpen ? "▾" : "▸").foregroundStyle(colors.accent)
                Text(group.name).fontWeight(.bold).foregroundStyle(colors.fg).lineLimit(1)
                Text("· \(group.sessions.count)").foregroundStyle(colors.dim)
                Spacer()
                if group.sessions.contains(where: \.needsAttention) {
                    Text("!").foregroundStyle(colors.warn)
                } else if group.sessions.contains(where: \.isActive) {
                    AsciiSpinnerView(color: colors.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var learningBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AsciiArt.sectionHeader("APPRENTISSAGE", width: 72))
                .lineLimit(1)
                .foregroundStyle(colors.dim)
            HStack(spacing: 8) {
                Text("+")
                    .foregroundStyle(colors.accent)
                Text(learningBannerLabel)
                    .lineLimit(1)
                    .foregroundStyle(colors.fg)
                Spacer(minLength: 6)
                AsciiButton(label: "REVOIR ⏎", color: colors.accent,
                            shortcut: .return, modifiers: []) {
                    SkillReviewCenter.shared.requestReviewWindow()
                }
            }
        }
    }

    private var learningBannerLabel: String {
        let count = SkillReviewCenter.shared.pendingCount
        let names = SkillReviewCenter.shared.proposals.prefix(2)
            .map(\.title).joined(separator: ", ")
        return count > 1 ? "\(count) skills proposés · \(names)…"
                         : "1 skill proposé · \(names)"
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AsciiArt.sectionHeader("QUOTA", width: 72))
                .lineLimit(1)
                .foregroundStyle(colors.dim)

            // Jauges seulement avec de VRAIES données (jamais le mock de dev).
            if viewModel.hasRealQuota {
                HStack(spacing: 16) {
                    quotaGauge(label: "5h", fraction: viewModel.usage.fiveHourFraction, resetsAt: viewModel.quotaResets.five)
                    quotaGauge(label: "7j", fraction: viewModel.usage.sevenDayFraction, resetsAt: viewModel.quotaResets.seven)
                    // Jauges par modèle (« fable ») — opt-in, même ligne. Leur
                    // reset ≈ celui du 7j : omis pour tenir dans la largeur.
                    ForEach(ModelQuotaPoller.shared.displayedLimits, id: \.label) { limit in
                        quotaGauge(label: limit.label.lowercased(),
                                   fraction: limit.usedFraction,
                                   resetsAt: nil)
                    }
                    Spacer()
                }
                if let receivedAt = viewModel.quotaReceivedAt {
                    // Indicateur d'âge : la statusline ne pousse le quota qu'à
                    // chaque message assistant → signaler la donnée périmée.
                    QuotaAgeLabel(receivedAt: receivedAt, colors: colors)
                }
            } else {
                Text("quota indisponible — ouvre une session Claude pour l'alimenter")
                    .font(AtollFont.mono(9))
                    .foregroundStyle(colors.dim)
            }
        }
    }

    private func quotaGauge(label: String, fraction: Double, resetsAt: Date?) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .foregroundStyle(colors.dim)
            Text(AsciiArt.progressBar(fraction: fraction, cells: 10))
                .foregroundStyle(fraction > 0.85 ? colors.warn : colors.accent)
            Text("\(Int(fraction * 100))%")
                .foregroundStyle(colors.fg)
            if let resetsAt {
                ResetCountdown(resetsAt: resetsAt)
                    .foregroundStyle(colors.dim)
            }
        }
    }
}

/// Âge de la donnée de quota : discret si frais, visible dès qu'il vieillit.
struct QuotaAgeLabel: View {
    let receivedAt: Date
    let colors: ThemeColors

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let age = Int(context.date.timeIntervalSince(receivedAt))
            if age < 90 {
                Text("quota exact · à jour")
                    .font(AtollFont.mono(9))
                    .foregroundStyle(colors.dim)
            } else {
                let text = age < 3600 ? "il y a \(age / 60) min" : "il y a \(age / 3600) h"
                Text("quota · données \(text) (envoie un message pour rafraîchir)")
                    .font(AtollFont.mono(9))
                    .foregroundStyle(colors.warn)
            }
        }
    }
}

/// « ↻2h14 » (< 24 h) ou « ↻dim 03:59 » (au-delà — illisible en heures,
/// même présentation que la page Utilisation de claude.ai).
struct ResetCountdown: View {
    let resetsAt: Date

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let remaining = resetsAt.timeIntervalSince(context.date)
            if remaining > 0 {
                Text("↻\(format(remaining))")
                    .font(AtollFont.mono(9))
            }
        }
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours >= 24 {
            return Self.dayFormatter.string(from: resetsAt).replacingOccurrences(of: ".", with: "")
        }
        if hours > 0 { return "\(hours)h\(String(format: "%02d", minutes))" }
        return "\(minutes)m"
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let colors: ThemeColors
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    glyph
                    Text(title)
                        .foregroundStyle(colors.fg)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // Remplissage du contexte de la conversation (statusline) —
                    // l'info clé pour anticiper un /compact.
                    if let context = session.contextUsedFraction {
                        Text("ctx \(Int(context * 100))%")
                            .foregroundStyle(context >= 0.8 ? colors.warn : colors.dim)
                    }
                    Text(AsciiArt.statusBadge(session.status))
                        .foregroundStyle(badgeColor)
                }
                if let detail {
                    Text("  └ \(detail)")
                        .foregroundStyle(colors.dim)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        var parts = [session.projectName]
        if let branch = session.gitBranch { parts.append(branch) }
        if let model = session.model { parts.append(ModelName.display(model)) }
        return parts.joined(separator: " · ")
    }

    private var detail: String? {
        // Badges d'enrichissement (sous-agents / MCP) quand présents.
        var badges: [String] = []
        if session.subagentCount > 0 { badges.append("⑂\(session.subagentCount)") }
        if !session.mcpServers.isEmpty { badges.append("mcp:\(session.mcpServers.count)") }
        let suffix = badges.isEmpty ? "" : "  " + badges.joined(separator: " ")

        switch session.status {
        case .working(let tool):
            return (tool ?? session.subtitle).map { $0 + suffix } ?? (suffix.isEmpty ? nil : suffix.trimmingCharacters(in: .whitespaces))
        case .awaitingPermission(let tool):
            return tool + suffix
        case .awaitingInput, .done:
            return (session.subtitle).map { $0 + suffix } ?? (suffix.isEmpty ? nil : suffix.trimmingCharacters(in: .whitespaces))
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch session.status {
        case .working:
            AsciiSpinnerView(color: colors.accent)
        case .awaitingPermission, .awaitingInput:
            Text("!").foregroundStyle(colors.warn)
        case .done:
            Text("·").foregroundStyle(colors.ok)
        }
    }

    private var badgeColor: Color {
        switch session.status {
        case .working: return colors.accent
        case .awaitingPermission, .awaitingInput: return colors.warn
        case .done: return colors.ok
        }
    }
}

/// Un groupe de sessions partageant le même projet (racine `.git`).
private struct ProjectGroup: Identifiable {
    let id: String              // chemin de la racine du projet (clé de groupe)
    let name: String            // nom affiché (dernier composant)
    let sessions: [AgentSession]
}

/// Racine de projet d'une session : le dossier `.git` le plus proche en
/// remontant depuis son cwd (regroupe ainsi un dépôt et ses sous-dossiers —
/// ex. `Dynamic_Island` et `Dynamic_Island/AtollCore`). À défaut, le cwd lui-même.
@MainActor
enum ProjectRoot {
    /// Cache cwd → racine (accédé depuis le rendu, MainActor).
    private static var cache: [String: String] = [:]

    static func key(for session: AgentSession) -> String {
        guard let cwd = session.cwd, !cwd.isEmpty else { return session.id }
        if let cached = cache[cwd] { return cached }
        let root = gitRoot(cwd) ?? cwd
        cache[cwd] = root
        return root
    }

    static func name(for key: String) -> String {
        let base = (key as NSString).lastPathComponent
        return base.isEmpty ? key : base
    }

    private static func gitRoot(_ cwd: String) -> String? {
        var url = URL(fileURLWithPath: cwd)
        let fm = FileManager.default
        while url.path != "/" {
            if fm.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }
}
