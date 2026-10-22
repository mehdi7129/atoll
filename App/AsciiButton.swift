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
