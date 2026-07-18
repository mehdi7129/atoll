import AppKit

/// Le panneau de l'îlot : sans bordure, non-activant (ne vole jamais le focus),
/// au-dessus de la barre de menus, présent sur tous les Spaces et en plein écran.
final class NotchPanel: NSPanel {
    /// Passera à true en Phase 3/6 pour la saisie de texte dans l'îlot étendu.
    var allowsKeyFocus = false

    override var canBecomeKey: Bool { allowsKeyFocus }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
    }
}
