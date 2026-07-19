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

    /// Un seul écran (l'écran principal) pilote l'ouverture auto et le focus
    /// clavier des cartes interactives, pour que les panneaux ne se disputent
    /// pas le focus en multi-écrans.
    let isPrimary: Bool
    /// Hauteur de l'écran de ce contrôleur : borne le panneau chat (par écran).
    let screenHeight: CGFloat

    /// Posé par le contrôleur : demande/rend le focus clavier du panneau
    /// (nécessaire pour ⌘Y/⌘N et les champs texte des cartes interactives).
    @ObservationIgnored var onKeyFocusRequest: ((Bool) -> Void)?

    /// L'îlot était-il épinglé par l'utilisateur AVANT qu'une carte l'ouvre ?
    /// Si oui, on ne le referme pas quand la carte se résout.
    @ObservationIgnored private var wasUserPinnedBeforeCard = false

    /// Source de vérité partagée entre tous les écrans.
    private let store: SessionStore

    @ObservationIgnored private var hoverTask: Task<Void, Never>?

    init(screen: NSScreen, isPrimary: Bool, store: SessionStore = .shared) {
        notchSize = screen.notchSize
        menuBarHeight = screen.menuBarHeight
        screenHeight = screen.frame.height
        self.isPrimary = isPrimary
        self.store = store
    }

    // MARK: - Cartes interactives

    /// Applique l'état d'ouverture/focus en fonction du nombre de demandes en
    /// attente. Appelé sur changement ET à l'apparition (reconstruction de fenêtre).
    func syncInteractionState(pendingCount: Int, previousCount: Int) {
        guard isPrimary else { return }
        if pendingCount > 0, previousCount == 0 {
            wasUserPinnedBeforeCard = isPinned
            isPinned = true
            open()
            onKeyFocusRequest?(true)
        } else if pendingCount == 0, previousCount > 0 {
            onKeyFocusRequest?(false)
            // Ne pas refermer un îlot que l'utilisateur avait épinglé lui-même.
            if !wasUserPinnedBeforeCard {
                close()
            }
            wasUserPinnedBeforeCard = false
        }
    }

    var sessions: [AgentSession] { store.uiSessions }
    var usage: UsageSnapshot { store.displayQuota }
    var quotaResets: (five: Date?, seven: Date?) { store.quotaResets }
    var hasRealQuota: Bool { store.hasRealQuota }
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

    var hasActivity: Bool { !sessions.isEmpty }
    var workingCount: Int { sessions.filter(\.isActive).count }
    var attentionCount: Int { sessions.filter(\.needsAttention).count }

    var islandSize: CGSize {
        switch state {
        case .compact:
            return IslandGeometry.compactSize(
                notch: notchSize,
                menuBarHeight: menuBarHeight,
                hasActivity: hasActivity
            )
        case .expanded:
            // Le chat obtient un panneau plus haut (historique de conversation).
            // Lire isChatTall inscrit la dépendance d'observation : la vue qui
            // évalue islandSize se ré-évalue à l'ouverture/fermeture du chat.
            return IslandGeometry.expandedIslandSize(
                notch: notchSize,
                menuBarHeight: menuBarHeight,
                chat: isChatTall,
                screenHeight: screenHeight
            )
        }
    }

    /// Le panneau doit-il être HAUT (mode chat) ? Seulement quand le chat est la
    /// vue réellement affichée : une carte d'interaction est PRIORITAIRE dans le
    /// routage (ExpandedView) et se contenterait d'un panneau standard — sinon
    /// elle flotterait dans un panneau aux deux tiers vide.
    var isChatTall: Bool {
        ChatCenter.shared.isActive && InteractionCenter.shared.current == nil
    }

    /// Hauteur du contenu du panneau étendu (partagée avec ExpandedView pour
    /// que la frame du contenu et celle de l'îlot restent alignées).
    var expandedContentHeight: CGFloat {
        IslandGeometry.expandedContentHeight(chat: isChatTall, screenHeight: screenHeight)
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
