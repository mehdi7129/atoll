#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>

using namespace metal;

// Onde d'expansion appliquée via SwiftUI `layerEffect` (API PUBLIQUE, macOS 14+).
// Une seule onde amortie part de `origin` (le notch, en haut au centre) et
// déplace radialement les pixels de la couche, en rehaussant discrètement les
// crêtes. Le shader vit dans le default.metallib de l'app → ShaderLibrary.default.
//
// Signature imposée par layerEffect : (float2 position, SwiftUI::Layer layer, …args).
// Adapté de l'exemple officiel Apple « applying a ripple effect » — 100 % supporté,
// aucune API privée (contrairement au verre par CABackdropLayer d'AgentGlance).
[[ stitchable ]] half4 expansionRipple(
    float2 position,
    SwiftUI::Layer layer,
    float2 origin,
    float time,
    float amplitude,
    float frequency,
    float decay,
    float speed
) {
    // Distance du pixel courant à l'origine de l'onde.
    float dist = length(position - origin);

    // Retard de propagation : l'onde atteint les pixels lointains plus tard.
    float delay = dist / max(speed, 1.0);
    time -= delay;
    time = max(0.0, time);

    // Sinusoïde amortie par une exponentielle (une seule crête perceptible).
    float rippleAmount = amplitude * sin(frequency * time) * exp(-decay * time);

    // Direction unitaire depuis l'origine (0 au centre exact pour éviter un NaN).
    float2 dir = dist > 0.0001 ? normalize(position - origin) : float2(0.0, 0.0);

    // Position déplacée puis échantillonnage de la couche.
    float2 displaced = position + rippleAmount * dir;
    half4 color = layer.sample(displaced);

    // Rehausse/atténue selon l'amplitude locale, pondérée par l'alpha (ne
    // touche pas les pixels transparents autour de l'îlot).
    color.rgb += 0.3h * half(rippleAmount / max(amplitude, 0.0001)) * color.a;

    return color;
}
