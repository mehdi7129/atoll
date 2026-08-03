import SwiftUI
import AtollCore

/// État étendu : en-tête, liste des sessions (ou détail), quota.
struct ExpandedView: View {
    let viewModel: NotchViewModel
    let colors: ThemeColors

    @AppStorage(InteractionCenter.autonomyKey) private var autonomyRaw = AutonomyLevel.manual.rawValue
    private var level: AutonomyLevel { AutonomyLevel(rawValue: autonomyRaw) ?? .manual }

    /// Projets dépliés (racines de projet). Les dossiers multi-sessions sont
    /// repliés par défaut : on voit un dossier par projet, on déplie pour voir
    /// les sessions — clarifie « 3 sessions pour 2 projets » (une nichée dans
    /// notre projet de dev).
    @State private var expandedProjects: Set<String> = []
    /// Mode de regroupement des sessions. Persisté (et partagé par tous les
    /// écrans) : c'est une préférence de lecture, pas un état d'écran.
    @AppStorage("sessionsGroupByState") private var groupByState = false

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
                //
                // Une tâche qui vient de finir passe AVANT un skill proposé :
                // elle est datée, l'autre attendra.
                if let finished = TaskCompletionNotifier.shared.unacknowledged.first {
                    taskDoneBanner(finished)
                        .layoutPriority(1)
                } else if SkillReviewCenter.shared.pendingCount > 0 {
                    learningBanner
                        .layoutPriority(1)
                }
                // Ceinture et bretelles du bornage : le panneau a une hauteur
                // FIXE et il est clippé. Si l'estimation de budget se trompait,
                // c'est la LISTE qui cède — jamais le quota, qui disparaissait
                // en silence (audit du 2026-07-27).
                footer
                    .layoutPriority(1)
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
            // En-tête + bascule de mode. Le titre rétrécit pour laisser la
            // place au sélecteur (la grille ASCII reste sur une ligne).
            HStack(spacing: 6) {
                // 68 et non 70 : la rangée partage sa largeur avec la bascule
                // `[ PROJET ]` (la plus large des deux libellés, 55,6 pt) et les
                // 16 pt incompressibles du HStack. À 70 caractères il ne restait
                // que 0,38 pt de marge sur 548 — la moindre variation d'avance
                // monospace, sur une autre version de macOS, tronquait l'en-tête
                // principal de l'îlot avec une ellipse. 68 laisse 13,6 pt.
                Text(AsciiArt.sectionHeader("SESSIONS", width: 68))
                    .lineLimit(1)
                    .foregroundStyle(colors.dim)
                Spacer(minLength: 4)
                groupingToggle
            }

            if viewModel.sessions.isEmpty {
                Text("· aucune session — lance `claude` dans un terminal")
                    .foregroundStyle(colors.dim)
            } else if groupByState {
                stateGroupedList
            } else {
                let plan = projectRowPlan
                ForEach(plan.rows) { row in
                    switch row {
                    case .folder(let group):
                        folderHeader(group)
                    case .session(let session, let indented):
                        SessionRow(session: session, colors: colors) {
                            viewModel.selectSession(session.id)
                        }
                        .padding(.leading, indented ? 16 : 0)
                    }
                }
                if plan.hiddenCount > 0 {
                    // Même règle que la vue par état : ce qui ne tient pas est
                    // ANNONCÉ. Une liste tronquée en silence ferait croire à
                    // une flotte plus petite qu'elle n'est.
                    Text("· +\(plan.hiddenCount) autre\(plan.hiddenCount > 1 ? "s" : "") — replie un dossier pour les voir")
                        .font(AtollFont.mono(9))
                        .foregroundStyle(colors.dim)
                } else {
                    Text("· clique une session pour ses détails")
                        .font(AtollFont.mono(9))
                        .foregroundStyle(colors.dim)
                }
            }
        }
    }

    /// Bascule « par projet / par état ». Deux questions différentes : où ça se
    /// passe, versus qu'est-ce qui m'attend.
    private var groupingToggle: some View {
        Button {
            groupByState.toggle()
            // Les dossiers repliés d'un mode n'ont pas de sens dans l'autre.
            expandedProjects.removeAll()
        } label: {
            Text(groupByState ? "[ ÉTAT ]" : "[ PROJET ]")
                .font(AtollFont.mono(9))
                .foregroundStyle(colors.accent)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Basculer entre regroupement par projet et par état")
    }

    /// Vue par ÉTAT : ce qui attend une décision d'abord, ce qui dort en
    /// dernier. Les groupes sont toujours dépliés — l'intérêt est justement de
    /// voir d'un coup ce qui réclame quelque chose.
    private var stateGroupedList: some View {
        let bounded = SessionGrouping.byState(viewModel.sessions, rowBudget: rowBudget)
        return ForEach(bounded.groups) { group in
            HStack(spacing: 6) {
                Text(group.bucket == .awaitingDecision ? "!" : "·")
                    .foregroundStyle(group.bucket == .awaitingDecision ? colors.warn : colors.dim)
                Text(group.bucket.title)
                    .fontWeight(.bold)
                    .foregroundStyle(group.bucket == .awaitingDecision ? colors.warn : colors.dim)
                Text("· \(group.sessions.count)")
                    .foregroundStyle(colors.dim)
                Spacer()
            }
            .font(AtollFont.mono(10))
            ForEach(group.sessions) { session in
                SessionRow(session: session, colors: colors) {
                    viewModel.selectSession(session.id)
                }
                .padding(.leading, 16)
            }
            if group.id == bounded.groups.last?.id, bounded.hiddenCount > 0 {
                // Une liste tronquée en silence ferait croire à une flotte plus
                // petite qu'elle n'est. On le dit.
                Text("· +\(bounded.hiddenCount) autre\(bounded.hiddenCount > 1 ? "s" : "") — voir par projet")
                    .font(AtollFont.mono(9))
                    .foregroundStyle(colors.dim)
            }
        }
    }

    /// Une bannière occupe-t-elle le bas du panneau ? Elle coûte ~66 pt, donc
    /// autant de rangées en moins pour la liste.
    private var bannerShown: Bool {
        !TaskCompletionNotifier.shared.unacknowledged.isEmpty
            || SkillReviewCenter.shared.pendingCount > 0
    }

    /// Rangées DESSINABLES sans pousser le quota hors du cadre. Les deux modes
    /// d'affichage partagent ce budget : la vue par projet n'en avait aucun.
    private var rowBudget: Int { IslandRowBudget.rows(bannerShown: bannerShown) }

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
        // Le nom vient de la MÊME règle que les lignes de session : sans elle,
        // le projet de Mehdi s'affichait « claude » ici et
        // « Blender/claude » deux lignes plus bas (audit du 2026-07-27).
        let names = ProjectNaming.displayNames(for: order)
        return zip(order, names).map { key, name in
            ProjectGroup(id: key, name: name, sessions: byRoot[key] ?? [])
        }
    }

    /// Une rangée effectivement dessinée par la vue « par projet ».
    private enum ProjectRow: Identifiable {
        case folder(ProjectGroup)
        case session(AgentSession, indented: Bool)

        var id: String {
            switch self {
            case .folder(let group): return "f:" + group.id
            case .session(let session, _): return "s:" + session.id
            }
        }
    }

    private struct ProjectRowPlan {
        let rows: [ProjectRow]
        /// Sessions qu'on n'a PAS pu dessiner faute de place (les sessions d'un
        /// dossier replié ne comptent pas : leur nombre est sur l'en-tête).
        let hiddenCount: Int
    }

    /// Aplatit les groupes en rangées et s'arrête au budget. Sans ce plan, six
    /// projets suffisaient à pousser le quota hors du cadre, en silence.
    private var projectRowPlan: ProjectRowPlan {
        var rows: [ProjectRow] = []
        // La ligne de pied (« clique une session… » / « +N autres ») est
        // TOUJOURS dessinée : elle fait partie du budget.
        var remaining = rowBudget - IslandRowBudget.projectFooterCost
        var hidden = 0
        for group in projectGroups {
            guard remaining > 0 else {
                hidden += group.sessions.count
                continue
            }
            if group.sessions.count == 1 {
                // Un seul projet = une seule session : ligne directe (pas de
                // dossier inutile).
                rows.append(.session(group.sessions[0], indented: false))
                remaining -= 1
            } else {
                rows.append(.folder(group))
                remaining -= 1
                guard expandedProjects.contains(group.id) else { continue }
                let shown = group.sessions.prefix(remaining)
                rows.append(contentsOf: shown.map { .session($0, indented: true) })
                remaining -= shown.count
                hidden += group.sessions.count - shown.count
            }
        }
        return ProjectRowPlan(rows: rows, hiddenCount: hidden)
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
            Text(AsciiArt.sectionHeader("APPRENTISSAGE", width: 79))
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

    /// Une tâche lancée depuis le notch vient de se terminer : c'est ICI que le
    /// cockpit rend la main. La notification macOS peut avoir été manquée (Ne pas
    /// déranger, bannière évanouie) — cette trace-là, elle, attend d'être vue.
    private func taskDoneBanner(_ task: LaunchedTask) -> some View {
        let others = TaskCompletionNotifier.shared.unacknowledged.count - 1
        return VStack(alignment: .leading, spacing: 6) {
            Text(AsciiArt.sectionHeader("TÂCHE TERMINÉE", width: 79))
                .lineLimit(1)
                .foregroundStyle(colors.dim)
            HStack(spacing: 8) {
                Text("◇")
                    .foregroundStyle(colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(others > 0 ? "\(task.projectName) · +\(others) autre\(others > 1 ? "s" : "")"
                                    : task.projectName)
                        .lineLimit(1)
                        .foregroundStyle(colors.accent)
                    Text(task.summary ?? task.task)
                        .lineLimit(2)
                        .foregroundStyle(colors.fg)
                }
                Spacer(minLength: 6)
                // Sans raccourci clavier : ⏎ appartient déjà à la bannière
                // d'apprentissage et ⌘⏎/⌘⌫ aux cartes de permission.
                AsciiButton(label: "VU", color: colors.dim, shortcut: nil) {
                    TaskCompletionNotifier.shared.acknowledge(task)
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
        // `TimelineView` ENGLOBANT : la fraîcheur de la fenêtre 5 h dépend de
        // l'heure, pas d'une valeur observée. Sans réévaluation périodique, le
        // chiffre périmé restait à l'écran jusqu'à un re-render fortuit — et
        // toutes les sessions étant fermées, il n'en arrivait plus (revue des
        // corrections, 2026-07-27).
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            footerBody
        }
    }

    private var footerBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(AsciiArt.sectionHeader("QUOTA", width: 79))
                .lineLimit(1)
                .foregroundStyle(colors.dim)

            // Jauges seulement avec de VRAIES données (jamais le mock de dev).
            if viewModel.hasRealQuota {
                HStack(spacing: 16) {
                    // La jauge 5 h disparaît quand SA fenêtre a tourné ; le 7 j
                    // et les jauges par modèle, eux, restent valides et
                    // s'affichaient à tort « indisponibles » (revue des corrections).
                    if viewModel.hasFreshFiveHour {
                        quotaGauge(label: "5h", fraction: viewModel.usage.fiveHourFraction, resetsAt: viewModel.quotaResets.five)
                    }
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

    /// Largeur réservée au badge d'état, badge absent compris.
    /// « [ APPROVE? ] » est le plus large : 12 caractères × 6,7998 pt d'avance à
    /// `AtollFont.mono(11)` (mesuré par CoreText) = 81,6 pt, arrondi à 82.
    static let badgeSlot: CGFloat = 82

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
                    // Pas de badge pour une session au repos : rien à annoncer.
                    // Mais la PLACE reste réservée — sinon « ctx NN% » change de
                    // colonne d'une ligne à l'autre selon qu'un badge est présent
                    // ou non (mesuré : 80,8 pt d'écart). Dans une interface dont
                    // toute l'esthétique est une grille de caractères, la seule
                    // colonne chiffrée de la liste ne peut pas se déplacer.
                    Text(AsciiArt.statusBadge(session.status) ?? "")
                        .foregroundStyle(badgeColor)
                        .frame(width: Self.badgeSlot, alignment: .trailing)
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
        case .awaitingPermission:
            Text("!").foregroundStyle(colors.warn)
        case .awaitingInput:
            // Au repos : point discret, comme l'en-tête de son groupe. Le « ! »
            // orange est réservé à ce qui BLOQUE (`needsAttention`).
            Text("·").foregroundStyle(colors.dim)
        case .done:
            Text("·").foregroundStyle(colors.ok)
        }
    }

    private var badgeColor: Color {
        switch session.status {
        case .working: return colors.accent
        case .awaitingPermission: return colors.warn
        // Inatteignable tant que `statusBadge` rend `nil` pour cet état — mais
        // laisser `warn` ici serait une mine : le jour où l'on réintroduirait un
        // badge au repos, il ressortirait en orange d'alerte.
        case .awaitingInput: return colors.dim
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
