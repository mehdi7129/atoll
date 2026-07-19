import Foundation
import CoreGraphics

/// Géométrie pure de l'îlot — aucune dépendance AppKit, entièrement testable.
/// Convention : coordonnées AppKit (origine en bas à gauche).
public enum IslandGeometry {

    /// Taille fixe de la fenêtre transparente (jamais animée) : l'îlot s'anime dedans en SwiftUI.
    /// La hauteur doit contenir le PLUS HAUT des modes (chat avec historique) —
    /// un îlot plus haut que la fenêtre serait rogné SILENCIEUSEMENT.
    public static let windowSize = CGSize(width: 760, height: 680)

    /// Largeur d'une aile de contenu de part et d'autre du notch en mode compact.
    public static let wingWidth: CGFloat = 88

    /// Taille de la pilule simulée sur les écrans sans notch.
    public static let pillWidth: CGFloat = 200
    public static let minimumPillHeight: CGFloat = 26

    /// Taille du panneau étendu (assez haut pour les cartes interactives).
    public static let expandedSize = CGSize(width: 600, height: 340)

    /// Hauteur idéale du panneau en mode CHAT : l'historique de conversation a
    /// besoin de place pour donner le contexte.
    public static let chatExpandedHeight: CGFloat = 560

    /// Hauteur du contenu étendu selon le mode. Le chat obtient un panneau plus
    /// haut, borné par l'écran (marge pour le notch + un peu d'air en bas) et
    /// jamais plus bas que le panneau standard.
    public static func expandedContentHeight(chat: Bool, screenHeight: CGFloat? = nil) -> CGFloat {
        guard chat else { return expandedSize.height }
        guard let screenHeight, screenHeight > 0 else { return chatExpandedHeight }
        return min(chatExpandedHeight, max(expandedSize.height, screenHeight - 160))
    }

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
    public static func compactSize(notch: CGSize?, menuBarHeight: CGFloat, hasActivity: Bool) -> CGSize {
        if let notch {
            let width = hasActivity ? notch.width + wingWidth * 2 : notch.width
            return CGSize(width: width, height: notch.height)
        }
        return CGSize(width: pillWidth, height: max(menuBarHeight, minimumPillHeight))
    }

    /// Taille de l'îlot étendu : jamais plus étroit que le compact, panneau sous le notch.
    /// `chat` : panneau haut pour l'historique de conversation (borné par l'écran).
    public static func expandedIslandSize(notch: CGSize?, menuBarHeight: CGFloat,
                                          chat: Bool = false, screenHeight: CGFloat? = nil) -> CGSize {
        let compact = compactSize(notch: notch, menuBarHeight: menuBarHeight, hasActivity: true)
        return CGSize(
            width: max(expandedSize.width, compact.width),
            height: compact.height + expandedContentHeight(chat: chat, screenHeight: screenHeight)
        )
    }
}
