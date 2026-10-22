import AppKit
import SwiftUI
import Observation
import AtollCore

@MainActor
@Observable
final class NotchViewModel {
    enum IslandState: Equatable {
        case compact
        case expanded
    }

    // Caractéristiques de l'écran hôte (figées à la création ; les changements
    // d'écran reconstruisent le contrôleur).
    let notchSize: CGSize?
    let menuBarHeight: CGFloat
    var hasNotch: Bool { notchSize != nil }

    var state: IslandState = .compact
    var isPinned = false
    /// Session ouverte en vue détaillée (clic sur une ligne). nil = liste.
    var selectedSessionID: String?
    /// Alimenté seulement par la recette isolée, jamais persisté.
    var previewSessions: [AgentSession]?
    var previewUsage: UsageSnapshot?

    /// Écran principal utilisé par les actions de debug ciblées.
    let isPrimary: Bool

    /// Rend le focus au terminal lorsque le panneau change d’état.
    @ObservationIgnored var onKeyFocusRequest: ((Bool) -> Void)?

    /// Source de vérité partagée entre tous les écrans.
    private let store: SessionStore

    @ObservationIgnored private var hoverTask: Task<Void, Never>?

    /// Identifiant de l'écran de ce contrôleur : clé de la taille réglable.
    let displayID: String

    /// Densité de l'écran hôte. Sert à tracer le liseré sur UN pixel physique :
    /// 0,5 pt sur un écran Retina, 1 pt sur un écran non-Retina. Un trait de
    /// 1 pt sur du Retina fait deux pixels et se voit comme un cadre.
    let hairline: CGFloat

    /// Largeur compacte choisie pour CET écran (observe IslandSettings → l'îlot
    /// se redimensionne en direct quand on change le réglage).
    var compactWidth: IslandWidth {
        if CodexPreview.enabled {
            return IslandWidth.allCases.first { CommandLine.arguments.contains("--preview-width-\($0.rawValue)") } ?? .small
        }
        return IslandSettings.shared.width(for: displayID)
    }

    init(screen: NSScreen, isPrimary: Bool, store: SessionStore? = nil) {
        notchSize = CodexPreview.enabled && !CommandLine.arguments.contains("--preview-native-screen")
            ? (CommandLine.arguments.contains("--preview-notch") ? CGSize(width: 180, height: 32) : nil)
            : screen.notchSize
        menuBarHeight = screen.menuBarHeight
        displayID = screen.displayUUIDString
        hairline = 1 / max(screen.backingScaleFactor, 1)
        self.isPrimary = isPrimary
        // Résolu ICI (init MainActor) et non en argument par défaut, qui
        // s'évalue en contexte nonisolated → warning d'isolation (erreur Swift 6).
        self.store = store ?? .shared
    }

    var allSessions: [AgentSession] {
        if let previewSessions { return previewSessions }
        return (store.uiSessions + CodexService.shared.sessions).sorted {
            if $0.needsAttention != $1.needsAttention { return $0.needsAttention }
            if $0.isActive != $1.isActive { return $0.isActive }
            return $0.startedAt > $1.startedAt
        }
    }
    var selectedProvider: AgentProvider { ProviderPreferences.shared.selection }
    var sessions: [AgentSession] { allSessions.filter { $0.provider == selectedProvider } }

    func selectProvider(_ provider: AgentProvider) {
        ProviderPreferences.shared.selection = provider
        selectedSessionID = nil
    }
    var usage: UsageSnapshot { previewUsage ?? store.displayQuota }
    var quotaResets: (five: Date?, seven: Date?) { store.quotaResets }
    var hasRealQuota: Bool { previewUsage != nil || store.hasRealQuota }
    var hasFreshFiveHour: Bool { previewUsage != nil || store.hasFreshFiveHour }
    var quotaReceivedAt: Date? { store.quotaReceivedAt }

    var selectedSession: AgentSession? {
        guard let id = selectedSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    func selectSession(_ id: String) {
        selectedSessionID = (selectedSessionID == id) ? nil : id
    }

    func clearSelection() {
        selectedSessionID = nil
    }

    /// Y a-t-il quelque chose à MONTRER dans les ailes ? Sessions uniquement.
    var hasActivity: Bool { !allSessions.isEmpty }
    var workingCount: Int { sessions.filter(\.isActive).count }
    var attentionCount: Int { sessions.filter(\.needsAttention).count }

    /// Au repos, le compact retrouve sa taille discrète d’origine.
    func islandSize() -> CGSize {
        switch state {
        case .compact:
            return IslandGeometry.compactSize(
                notch: notchSize,
                menuBarHeight: menuBarHeight,
                hasActivity: hasActivity,
                width: compactWidth
            )
        case .expanded:
            // La taille ne joue que sur le compact ; le panneau étendu est fixe.
            return IslandGeometry.expandedIslandSize(
                notch: notchSize,
                menuBarHeight: menuBarHeight,
                width: compactWidth
            )
        }
    }

    // MARK: - Interactions

    /// Survol : ouverture après un délai minimal, fermeture après une courte grâce
    /// (pattern boring.notch — évite les ouvertures accidentelles et les flickers).
    func hoverChanged(_ hovering: Bool, openDelay: TimeInterval) {
        hoverTask?.cancel()
        if hovering {
            guard state == .compact else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(openDelay * 1000)))
                guard !Task.isCancelled else { return }
                self?.open()
            }
        } else {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self, !self.isPinned else { return }
                self.close()
            }
        }
    }

    /// Clic sur l'îlot : épingle l'état étendu (ne se referme plus au départ de la souris).
    func togglePinned() {
        if state == .expanded, isPinned {
            close()
        } else {
            isPinned = true
            open()
        }
    }

    func open() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) {
            state = .expanded
        }
    }

    func close() {
        isPinned = false
        hoverTask?.cancel()
        selectedSessionID = nil
        withAnimation(.spring(response: 0.45, dampingFraction: 1.0)) {
            state = .compact
        }
    }
}
