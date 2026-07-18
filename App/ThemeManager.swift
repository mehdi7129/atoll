import AppKit

enum ThemePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "Auto (système)"
        case .light: return "Clair"
        case .dark: return "Sombre"
        }
    }
}

/// Applique le thème au niveau app : `NSApp.appearance = nil` = suivre le système (auto).
@MainActor
enum ThemeManager {
    static let themeKey = "themePreference"

    static var storedPreference: ThemePreference {
        ThemePreference(rawValue: UserDefaults.standard.string(forKey: themeKey) ?? "") ?? .system
    }

    static func applyStored() {
        apply(storedPreference)
    }

    static func apply(_ preference: ThemePreference) {
        switch preference {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
