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

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var glassIntensity: Double {
        UserDefaults.standard.object(forKey: glassIntensityKey) as? Double
            ?? defaultGlassIntensity
    }
}

// MARK: - Fond de l'îlot (verre ou aplat)

/// Fond de l'îlot, dessiné SOUS le contenu ASCII dans la ZStack.
/// - encoche en compact → noir opaque (prolonge le notch physique, jamais de verre) ;
/// - étendu + effets activés + macOS 26 → vrai Liquid Glass teinté (contraste ASCII
///   préservé), qui réfracte le bureau derrière la fenêtre transparente ;
/// - sinon → aplat `colors.bg` comme avant.
struct IslandBackground: View {
    let shape: NotchShape
    let colors: ThemeColors
    let isCompactCap: Bool
    let isExpanded: Bool
    let effectsEnabled: Bool
    /// Intensité du Liquid Glass : 0 = aucun verre (fond plein), 1 = verre pur.
    var glassIntensity: Double = VisualEffects.defaultGlassIntensity

    var body: some View {
        if isCompactCap {
            // Le matériel ne change pas de couleur : le capuchon reste noir.
            shape.fill(Color.black)
        } else if effectsEnabled, isExpanded, glassIntensity > VisualEffects.glassFloor {
            glass
        } else {
            // Effets coupés, îlot compact, OU intensité au plancher : aplat.
            shape.fill(colors.bg)
        }
    }

    @ViewBuilder
    private var glass: some View {
        if #available(macOS 26.0, *) {
            // Le VRAI Liquid Glass (`.regular`) réfracte le fond ; par-dessus, un
            // scrim `colors.bg` d'opacité (1 − intensité) pilote combien on le
            // voit. Intensité 1 → scrim 0 → verre pur. Blend alpha DIRECT = effet
            // net et prévisible ; le teint seul (essai précédent) était quasi
            // imperceptible sur fond sombre.
            //
            // PIÈGE VÉRIFIÉ EN CAPTURE : même avec un scrim opaque à 100 %, le
            // verre `.regular` continue de réfracter — le bas de la plage ne
            // rendait donc jamais un fond franchement plein, et le réglage
            // « semblait ne plus rien faire ». D'où le plancher au-dessus :
            // sous `glassFloor`, on ne pose PAS de verre du tout.
            let scrim = min(max(1 - glassIntensity, 0), 1)
            ZStack {
                Color.clear.glassEffect(.regular, in: shape)
                shape.fill(colors.bg).opacity(scrim)
            }
        } else {
            // Repli macOS 14/15 : aplat identique à avant.
            shape.fill(colors.bg)
        }
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
