import Foundation
import CoreGraphics

/// Largeur de la barre compacte (réglable par écran). N'affecte QUE le compact :
/// les « ailes » de contenu de part et d'autre du notch, et la pilule sur les
/// écrans sans encoche. L'encoche physique, elle, garde sa largeur matérielle.
public enum IslandWidth: String, CaseIterable, Sendable, Identifiable {
    case small, medium, large

    public var id: String { rawValue }

    /// Largeur d'une aile de contenu (écran à encoche). « Petit » reste assez
    /// large pour « 5h 97% » et un nom court sans retour à la ligne.
    public var wingWidth: CGFloat {
        switch self {
        case .small: return 76
        case .medium: return 96
        case .large: return 158   // +20 % (demande de Mehdi)
        }
    }

    /// Largeur de la pilule (écran sans encoche).
    public var pillWidth: CGFloat {
        switch self {
        case .small: return 170
        case .medium: return 210
        case .large: return 360   // +20 %
        }
    }

    public var displayName: String {
        switch self {
        case .small: return "Petit"
        case .medium: return "Moyen"
        case .large: return "Large"
        }
    }
}

/// Géométrie pure de l'îlot — aucune dépendance AppKit, entièrement testable.
/// Convention : coordonnées AppKit (origine en bas à gauche).
public enum IslandGeometry {

    /// Taille fixe de la fenêtre transparente (jamais animée) : l'îlot s'anime dedans en SwiftUI.
    public static let windowSize = CGSize(width: 760, height: 460)

    /// Largeur d'une aile de contenu (taille moyenne). Conservé pour compat ;
    /// préférer `IslandWidth.wingWidth` (réglable par écran).
    public static let wingWidth: CGFloat = IslandWidth.medium.wingWidth

    /// Taille de la pilule simulée sur les écrans sans notch (taille moyenne).
    public static let pillWidth: CGFloat = IslandWidth.medium.pillWidth
    public static let minimumPillHeight: CGFloat = 26

    /// Taille du panneau étendu (assez haut pour les cartes interactives).
    public static let expandedSize = CGSize(width: 600, height: 340)

    /// Marge horizontale du contenu étendu : les flancs de la NotchShape sont
    /// insetés de topRadius (19 pt) — le contenu doit s'en écarter en plus de
    /// sa propre respiration, sinon il déborde du corps visible du panneau.
    public static let expandedContentInset: CGFloat = 38

    /// Rect de la fenêtre : top-centrée sur l'écran, collée au bord supérieur.
    public static func windowRect(screenFrame: CGRect) -> CGRect {
        CGRect(
            x: (screenFrame.midX - windowSize.width / 2).rounded(),
            y: screenFrame.maxY - windowSize.height,
            width: windowSize.width,
            height: windowSize.height
        )
    }

    /// Taille de l'îlot compact.
    /// - Avec notch : le notch physique + une aile de chaque côté quand il y a de l'activité
    ///   (sans activité, l'îlot épouse exactement le notch et reste invisible).
    /// - Sans notch : pilule simulée, collée au bord supérieur.
    public static func compactSize(notch: CGSize?, menuBarHeight: CGFloat,
                                   hasActivity: Bool, width: IslandWidth = .medium) -> CGSize {
        if let notch {
            let full = hasActivity ? notch.width + width.wingWidth * 2 : notch.width
            return CGSize(width: full, height: notch.height)
        }
        return CGSize(width: width.pillWidth, height: max(menuBarHeight, minimumPillHeight))
    }

    /// Taille de l'îlot étendu : jamais plus étroit que le compact, panneau sous
    /// le notch. La taille compacte ne change QUE la largeur des ailes (< 600),
    /// donc le panneau étendu reste à `expandedSize.width` — inchangé.
    public static func expandedIslandSize(notch: CGSize?, menuBarHeight: CGFloat,
                                          width: IslandWidth = .medium) -> CGSize {
        let compact = compactSize(notch: notch, menuBarHeight: menuBarHeight,
                                  hasActivity: true, width: width)
        return CGSize(
            width: max(expandedSize.width, compact.width),
            height: compact.height + expandedSize.height
        )
    }
}
