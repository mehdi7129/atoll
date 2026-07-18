import SwiftUI

/// La forme de l'îlot : coins supérieurs évasés vers l'extérieur (fusion avec le
/// bord de l'écran / le notch), coins inférieurs arrondis vers l'intérieur.
/// Les rayons sont animables pour accompagner l'expansion.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = min(topRadius, rect.width / 4)
        let bottom = min(bottomRadius, min(rect.width / 4, rect.height / 2))

        var path = Path()
        // Bord supérieur gauche, évasé vers l'extérieur.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )
        // Flanc gauche.
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        // Coin inférieur gauche.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )
        // Bord inférieur.
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        // Coin inférieur droit.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )
        // Flanc droit.
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        // Bord supérieur droit, évasé vers l'extérieur.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
