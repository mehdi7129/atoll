import SwiftUI

/// La forme de l'îlot : **coins supérieurs droits**, coins inférieurs arrondis
/// en courbure continue. Le rayon du bas est animable pour accompagner
/// l'expansion.
///
/// POURQUOI LES COINS HAUTS SONT DROITS (2026-07-28, demande de Mehdi).
/// La version précédente évasait les coins supérieurs vers l'extérieur : le
/// tracé partait du coin de l'écran et rentrait en courbe concave, si bien que
/// l'arête haute était plus large que le corps du panneau, dont les flancs se
/// trouvaient insetés de `topRadius` (19 pt de chaque côté). Cet évasement a un
/// sens quand la surface ÉPOUSE l'encoche — il prolonge le rayon du matériel.
/// Il n'en a aucun sur un panneau de 600 pt de large : l'encoche n'en fait que
/// ~200, les deux coins hauts tombent en plein milieu du bord de l'écran, et
/// l'œil y lit deux contours emboîtés (vérifié en capture au zoom 4×).
///
/// Le panneau est COLLÉ au bord supérieur de l'écran. Une surface collée à un
/// bord n'arrondit pas ce bord-là : elle s'y confond. C'est ce que fait Apple
/// pour tout ce qui pend de la barre des menus. D'où : haut droit, bas arrondi.
///
/// La courbure est `.continuous` (le « squircle » d'Apple) et non un arc de
/// cercle : l'arc circulaire fait un coude à la jonction avec le flanc, là où la
/// courbure continue coule. Mesuré : sur un vrai menu macOS 26, l'ajustement
/// `.continuous` l'emporte sur le circulaire d'un facteur 1,7 en RMS. Une
/// courbure continue mord 1,294 · r d'arête droite de chaque côté — à vérifier
/// quand la surface est courte (l'îlot compact ne fait que ~26 à 38 pt de haut).
struct NotchShape: Shape, InsettableShape {
    /// Rayon des deux coins INFÉRIEURS. Les coins supérieurs sont droits.
    var bottomRadius: CGFloat

    /// Retrait des FLANCS, appliqué en compact seulement.
    ///
    /// L'ancienne forme insetait ses flancs de `topRadius` — un effet de bord de
    /// l'évasement, pas une intention. En le supprimant, l'îlot AU REPOS s'est
    /// mis à occuper exactement la largeur de l'encoche (220 pt mesurés) au lieu
    /// de 12 pt de moins. Or ce que macOS rapporte comme « l'encoche » est une
    /// BOÎTE ENGLOBANTE, et la découpe physique, elle, a des coins bas arrondis :
    /// à un pixel près, du noir peut se peindre sur la dalle de part et d'autre —
    /// invisible sur fond sombre, visible sur fond clair.
    ///
    /// On remet donc le retrait, mais NOMMÉ, et seulement là où il sert : le
    /// panneau déployé, lui, garde ses flancs au bord (c'est tout l'objet de la
    /// refonte). L'ancien `topRadius` cumulait les deux rôles, d'où la confusion.
    var sideInset: CGFloat = 0
    /// Rempli par `inset(by:)` — c'est ce qui permet `strokeBorder`, dont le
    /// trait tombe ENTIÈREMENT dans la forme (un `stroke` simple déborde de
    /// moitié et se fait rogner par le `clipShape`, d'où un liseré deux fois
    /// trop fin et crénelé).
    var insetAmount: CGFloat = 0

    /// Les deux valeurs s'interpolent ensemble : sans cela, passer de compact à
    /// déployé ferait sauter les flancs de 6 pt d'un coup au milieu du ressort.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, sideInset) }
        set {
            bottomRadius = newValue.first
            sideInset = newValue.second
        }
    }

    func inset(by amount: CGFloat) -> NotchShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let body = rect
            .insetBy(dx: sideInset, dy: 0)
            .insetBy(dx: insetAmount, dy: insetAmount)
        guard body.width > 0, body.height > 0 else { return Path() }
        // Rayon concentrique : l'insert rapproche le tracé du centre, le rayon
        // doit suivre, sinon les coins du liseré ne sont plus parallèles au bord.
        // Un rayon plus grand que la moitié de la largeur (ou que la hauteur)
        // replierait le tracé — l'îlot compact ne fait que ~26 pt de haut.
        let radius = max(0, min(bottomRadius - insetAmount,
                                min(body.width / 2, body.height)))
        return UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: 0,
            style: .continuous
        ).path(in: body)
    }
}
