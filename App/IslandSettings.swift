import Foundation
import Observation
import AtollCore

/// Réglages d'apparence de l'îlot indexés PAR ÉCRAN (identifiant de display).
/// Observable : changer une taille dans les Réglages met à jour l'îlot de
/// l'écran concerné en direct (les vues qui lisent `width(for:)` se ré-évaluent).
@MainActor
@Observable
final class IslandSettings {
    static let shared = IslandSettings()

    private static let widthKeyPrefix = "islandWidth."

    /// Cache observable : displayID → largeur choisie. Absent = défaut (moyen).
    private var widths: [String: IslandWidth] = [:]

    init() {
        // Précharge les choix persistés (pas de mutation pendant un rendu de vue).
        for (key, value) in UserDefaults.standard.dictionaryRepresentation()
        where key.hasPrefix(Self.widthKeyPrefix) {
            if let raw = value as? String, let width = IslandWidth(rawValue: raw) {
                widths[String(key.dropFirst(Self.widthKeyPrefix.count))] = width
            }
        }
    }

    /// Largeur de la barre compacte pour un écran (défaut : moyen).
    func width(for displayID: String) -> IslandWidth {
        widths[displayID] ?? .medium
    }

    func setWidth(_ width: IslandWidth, for displayID: String) {
        widths[displayID] = width
        UserDefaults.standard.set(width.rawValue, forKey: Self.widthKeyPrefix + displayID)
    }
}
