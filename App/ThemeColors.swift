import SwiftUI
import AtollCore

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Couleurs sémantiques résolues pour la palette + le mode (clair/sombre) courants.
struct ThemeColors {
    let variant: Palette.Variant

    init(paletteID: String, scheme: ColorScheme) {
        let palette = Palette.named(paletteID)
        variant = scheme == .dark ? palette.dark : palette.light
    }

    init(variant: Palette.Variant) {
        self.variant = variant
    }

    var bg: Color { Color(hex: variant.bg) }
    var surface: Color { Color(hex: variant.surface) }
    var fg: Color { Color(hex: variant.fg) }
    var dim: Color { Color(hex: variant.dim) }
    var accent: Color { Color(hex: variant.accent) }
    var warn: Color { Color(hex: variant.warn) }
    var ok: Color { Color(hex: variant.ok) }
}

/// La fonte Atoll : monospace système (SF Mono à runtime — aucune fonte embarquée,
/// donc aucun problème de licence). Fontes OFL embarquées prévues plus tard.
enum AtollFont {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
