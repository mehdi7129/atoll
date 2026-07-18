import Foundation

/// Une palette Atoll = une paire de variantes (sombre / claire) pour le mode auto.
/// Discipline terminal.shop : base quasi monochrome + un seul accent.
public struct Palette: Identifiable, Equatable, Sendable {
    public struct Variant: Equatable, Sendable {
        /// Fond de l'îlot / des panneaux.
        public let bg: UInt32
        /// Surface légèrement contrastée (cartes, champs).
        public let surface: UInt32
        /// Texte principal.
        public let fg: UInt32
        /// Texte secondaire, bordures.
        public let dim: UInt32
        /// L'accent unique (états actifs, curseur, liens).
        public let accent: UInt32
        /// Attention requise (permission, question).
        public let warn: UInt32
        /// Succès / terminé.
        public let ok: UInt32

        public init(bg: UInt32, surface: UInt32, fg: UInt32, dim: UInt32,
                    accent: UInt32, warn: UInt32, ok: UInt32) {
            self.bg = bg
            self.surface = surface
            self.fg = fg
            self.dim = dim
            self.accent = accent
            self.warn = warn
            self.ok = ok
        }
    }

    public let id: String
    public let displayName: String
    public let dark: Variant
    public let light: Variant

    public init(id: String, displayName: String, dark: Variant, light: Variant) {
        self.id = id
        self.displayName = displayName
        self.dark = dark
        self.light = light
    }
}

public extension Palette {
    /// Défaut : quasi-monochrome + accent orange (validé par Mehdi).
    static let monoOrange = Palette(
        id: "mono-orange",
        displayName: "Mono · Orange",
        dark: Variant(bg: 0x0A0A0A, surface: 0x161616, fg: 0xEAEAEA, dim: 0x8F8F8F,
                      accent: 0xFF5C00, warn: 0xFFB000, ok: 0x33FF33),
        light: Variant(bg: 0xFAF7F2, surface: 0xF0EBE2, fg: 0x141414, dim: 0x6B675C,
                       accent: 0xE04E00, warn: 0xB07600, ok: 0x1E7D1E)
    )

    /// CRT vert phosphore.
    static let phosphor = Palette(
        id: "phosphor",
        displayName: "Phosphor",
        dark: Variant(bg: 0x0D0208, surface: 0x101A10, fg: 0x33FF33, dim: 0x2DA82D,
                      accent: 0x00FF41, warn: 0xFFB000, ok: 0x33FF33),
        light: Variant(bg: 0xF2FAF2, surface: 0xE2F0E2, fg: 0x0C4A0C, dim: 0x477D47,
                       accent: 0x0E8F1E, warn: 0xB07600, ok: 0x0E8F1E)
    )

    /// Ambre monochrome.
    static let amber = Palette(
        id: "amber",
        displayName: "Amber",
        dark: Variant(bg: 0x1A1000, surface: 0x241800, fg: 0xFFB000, dim: 0xB08A28,
                      accent: 0xFFCC44, warn: 0xFF5C00, ok: 0x9ACD32),
        light: Variant(bg: 0xFBF4E4, surface: 0xF2E8D0, fg: 0x5C4400, dim: 0x7A6838,
                       accent: 0xB07600, warn: 0xC04A00, ok: 0x4E7D1E)
    )

    /// Solarized — conçue nativement en paire light/dark, idéale pour le mode auto.
    static let solarized = Palette(
        id: "solarized",
        displayName: "Solarized",
        dark: Variant(bg: 0x002B36, surface: 0x073642, fg: 0x93A1A1, dim: 0x657B83,
                      accent: 0x268BD2, warn: 0xB58900, ok: 0x859900),
        light: Variant(bg: 0xFDF6E3, surface: 0xEEE8D5, fg: 0x586E75, dim: 0x839496,
                       accent: 0x268BD2, warn: 0xB58900, ok: 0x859900)
    )

    static let all: [Palette] = [.monoOrange, .phosphor, .amber, .solarized]

    static func named(_ id: String) -> Palette {
        all.first { $0.id == id } ?? .monoOrange
    }
}
