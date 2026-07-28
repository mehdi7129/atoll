import SwiftUI
import AtollCore

/// Effets visuels de l'îlot : fond « Liquid Glass » (API publique macOS 26, repli
/// propre en deçà) et onde d'expansion (shader Metal via `layerEffect`, macOS 14+).
/// Choix « sur rails supportés » : on utilise l'API PUBLIQUE `.glassEffect` gardée
/// par disponibilité — jamais le hack d'API privée (CABackdropLayer + filtre
/// `glassBackground`) qui casserait à une MAJ macOS.
enum VisualEffects {
    /// Interrupteur unique (verre + onde). Défaut : activé.
    static let enabledKey = "visualEffects"

    /// **Intensité du Liquid Glass** (le nom Apple) : 0 = aucun verre, fond
    /// plein ; 1 = verre pur, le bureau transparaît. Défaut 0,5.
    ///
    /// La CLÉ garde son nom historique `glassTransparency` : la renommer
    /// remettrait tout le monde au défaut. Seule la sémantique affichée change
    /// — et elle est identique (plus la valeur monte, plus le verre domine).
    static let glassIntensityKey = "glassTransparency"
    static let defaultGlassIntensity = 0.5

    /// En dessous de ce seuil, on N'UTILISE PAS `.glassEffect` du tout : le
    /// verre `.regular` réfracte toujours un peu, si bien qu'un scrim même
    /// totalement opaque laissait passer une lueur du fond — « le curseur ne
    /// change plus rien » côté utilisateur (constaté en capture à 0 %).
    /// En dessous du seuil, aplat pur : la plage est utile de bout en bout.
    static let glassFloor = 0.06

}

// MARK: - Fond de l'îlot (verre ou aplat)

/// Fond de l'îlot, dessiné SOUS le contenu ASCII dans la ZStack.
/// - encoche en compact → noir opaque (prolonge le notch physique, jamais de verre) ;
/// - étendu + effets activés + macOS 26 → vrai Liquid Glass, qui réfracte le
///   bureau derrière la fenêtre transparente, recouvert d'un aplat `colors.bg`
///   dont l'opacité vaut (1 − intensité) : blend alpha DIRECT, donc net et
///   prévisible ;
/// - sinon → aplat `colors.bg` comme avant.
///
/// PIÈGE VÉRIFIÉ EN CAPTURE : même sous un aplat opaque à 100 %, le verre
/// `.regular` continue de réfracter — le bas de la plage ne rendait donc jamais
/// un fond franchement plein. D'où `VisualEffects.glassFloor` : sous ce seuil on
/// ne pose PAS de verre du tout, au lieu d'essayer de le masquer.
struct IslandBackground: View {
    let shape: NotchShape
    let colors: ThemeColors
    let isCompactCap: Bool
    let isExpanded: Bool
    let effectsEnabled: Bool
    /// Intensité du Liquid Glass : 0 = aucun verre (fond plein), 1 = verre pur.
    var glassIntensity: Double = VisualEffects.defaultGlassIntensity
    /// Avancement du dévoilement : 0 = fond PLEIN quelle que soit l'intensité,
    /// 1 = l'intensité demandée. Piloté par `NotchRootView` à l'ouverture, pour
    /// que la matérialisation du verre (~250 ms, hors de notre contrôle) se
    /// fasse SOUS un aplat au lieu de se voir arriver.
    var glassReveal: Double = 1

    var body: some View {
        // L'APLAT est TOUJOURS là — c'est lui qui donne sa continuité au fond.
        //
        // La version précédente basculait entre trois branches `if/else` selon
        // l'état. Or changer de branche, pour SwiftUI, c'est DÉTRUIRE une vue et
        // en INSÉRER une autre : rien n'est interpolé, la nouvelle naît à sa
        // géométrie FINALE et se contente d'un fondu. Le fond ne suivait donc
        // pas la croissance du panneau.
        //
        // Le verre, lui, reste conditionnel : sur macOS 26 la seule surcharge
        // publique est `glassEffect(_:in:)`, sans paramètre `isEnabled` (SDK
        // vérifié) — et l'éteindre par `opacity(0)` serait imprudent, puisqu'on
        // sait déjà qu'un aplat opaque à 100 % ne suffit pas à le masquer
        // (cf. `VisualEffects.glassFloor`). Cette insertion-là est INVISIBLE :
        // à l'instant où elle se produit, `glassReveal` vaut 0, donc l'aplat
        // est opaque et couvre entièrement le verre qui vient de naître.
        ZStack {
            if #available(macOS 26.0, *), glassActive {
                Color.clear.glassEffect(.regular, in: shape)
            }
            shape.fill(scrimColor).opacity(scrimOpacity)
        }
    }

    /// macOS 26 ET effets activés ET panneau déployé ET intensité au-dessus du
    /// plancher. En deçà, `scrimOpacity` vaut 1 : aplat pur, comme avant.
    private var glassActive: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return effectsEnabled && isExpanded && !isCompactCap
            && glassIntensity > VisualEffects.glassFloor
    }

    /// Le capuchon compact d'un écran à encoche prolonge le matériel : il reste
    /// noir quel que soit le thème.
    private var scrimColor: Color { isCompactCap ? .black : colors.bg }

    /// Opacité de l'aplat posé PAR-DESSUS le verre. 1 = fond plein (aucun verre
    /// visible), 0 = verre pur.
    private var scrimOpacity: Double {
        guard glassActive else { return 1 }
        // Valeur au repos : l'inverse de l'intensité réglée par l'utilisateur.
        let settled = min(max(1 - glassIntensity, 0), 1)
        // À l'ouverture (`glassReveal` = 0) on force 1 — fond plein — puis on
        // redescend vers `settled`. Le verre se matérialise à l'abri de l'aplat.
        let reveal = min(max(glassReveal, 0), 1)
        return settled + (1 - settled) * (1 - reveal)
    }

}

// MARK: - Onde d'expansion

/// Applique l'onde d'expansion au contenu quand `trigger` change (→ étendu).
/// Rejoue une seule onde de 0,9 s partant du haut-centre (le notch). Désactivé
/// hors de cette fenêtre (`isEnabled`) → aucun coût le reste du temps.
struct ExpansionRipple: ViewModifier {
    var trigger: Int

    // `nonisolated` : lues depuis la closure Sendable de layerEffect (constantes
    // immuables Sendable → sûr, et évite l'erreur d'isolation en mode Swift 6).
    nonisolated static let duration: TimeInterval = 0.9
    nonisolated static let amplitude: Double = 6   // déplacement max (pt) — discret sur l'ASCII
    nonisolated static let frequency: Double = 12
    nonisolated static let decay: Double = 8
    nonisolated static let speed: Double = 900     // pt/s de propagation

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, elapsed in
            view.visualEffect { effect, proxy in
                effect.layerEffect(
                    ShaderLibrary.default.expansionRipple(
                        .float2(CGPoint(x: proxy.size.width / 2, y: 0)),
                        .float(Float(elapsed)),
                        .float(Float(Self.amplitude)),
                        .float(Float(Self.frequency)),
                        .float(Float(Self.decay)),
                        .float(Float(Self.speed))
                    ),
                    maxSampleOffset: CGSize(width: Self.amplitude, height: Self.amplitude),
                    // trigger > 0 : jamais d'onde au tout premier rendu (avant
                    // la première expansion), même si keyframeAnimator s'amorce.
                    isEnabled: trigger > 0 && elapsed > 0 && elapsed < Self.duration
                )
            }
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(Self.duration, duration: Self.duration)
            }
        }
    }
}

extension View {
    /// Onde à l'expansion, seulement si les effets sont actifs et hors Reduce Motion
    /// (l'accessibilité prime : mouvement supprimé = pas d'onde).
    @ViewBuilder
    func expansionRipple(trigger: Int, active: Bool) -> some View {
        if active {
            modifier(ExpansionRipple(trigger: trigger))
        } else {
            self
        }
    }
}
