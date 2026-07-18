import Foundation
import CoreGraphics

/// Géométrie pure de l'îlot — aucune dépendance AppKit, entièrement testable.
/// Convention : coordonnées AppKit (origine en bas à gauche).
public enum IslandGeometry {

    /// Taille fixe de la fenêtre transparente (jamais animée) : l'îlot s'anime dedans en SwiftUI.
    public static let windowSize = CGSize(width: 720, height: 320)

    /// Largeur d'une aile de contenu de part et d'autre du notch en mode compact.
    public static let wingWidth: CGFloat = 88

    /// Taille de la pilule simulée sur les écrans sans notch.
    public static let pillWidth: CGFloat = 200
    public static let minimumPillHeight: CGFloat = 26

    /// Taille du panneau étendu.
    public static let expandedSize = CGSize(width: 580, height: 240)

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
    public static func compactSize(notch: CGSize?, menuBarHeight: CGFloat, hasActivity: Bool) -> CGSize {
        if let notch {
            let width = hasActivity ? notch.width + wingWidth * 2 : notch.width
            return CGSize(width: width, height: notch.height)
        }
        return CGSize(width: pillWidth, height: max(menuBarHeight, minimumPillHeight))
    }

    /// Taille de l'îlot étendu : jamais plus étroit que le compact, panneau sous le notch.
    public static func expandedIslandSize(notch: CGSize?, menuBarHeight: CGFloat) -> CGSize {
        let compact = compactSize(notch: notch, menuBarHeight: menuBarHeight, hasActivity: true)
        return CGSize(
            width: max(expandedSize.width, compact.width),
            height: compact.height + expandedSize.height
        )
    }
}
