import AppKit

extension NSScreen {
    /// Test canonique : les zones auxiliaires n'existent que sur les écrans à encoche.
    var hasNotch: Bool {
        auxiliaryTopLeftArea != nil && auxiliaryTopRightArea != nil
    }

    /// Taille du notch physique (nil sur les écrans sans encoche).
    var notchSize: CGSize? {
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        return CGSize(
            width: frame.width - left.width - right.width,
            height: safeAreaInsets.top
        )
    }

    /// Hauteur de la barre de menus sur cet écran (fallback pour la pilule simulée).
    var menuBarHeight: CGFloat {
        max(frame.maxY - visibleFrame.maxY, 0)
    }

    /// Identifiant stable de l'écran, pour indexer une fenêtre par affichage.
    var displayUUIDString: String {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else {
            return localizedName
        }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
