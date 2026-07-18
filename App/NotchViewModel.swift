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

    // Données factices en Phase 1 — la Phase 2 branchera les vraies sessions.
    var sessions: [AgentSession] = MockData.sessions
    var usage: UsageSnapshot = MockData.usage

    @ObservationIgnored private var hoverTask: Task<Void, Never>?

    init(screen: NSScreen) {
        notchSize = screen.notchSize
        menuBarHeight = screen.menuBarHeight
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
            return IslandGeometry.expandedIslandSize(
                notch: notchSize,
                menuBarHeight: menuBarHeight
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
        withAnimation(.spring(response: 0.45, dampingFraction: 1.0)) {
            state = .compact
        }
    }
}
