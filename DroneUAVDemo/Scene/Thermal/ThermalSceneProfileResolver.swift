import Foundation

/// Resolves the effective `ThermalSceneProfile` from the map, weather, and the user's
/// (possibly `.auto`) selection.
enum ThermalSceneProfileResolver {
    /// Terrains whose ground material actually switches to snow under snow weather — must mirror
    /// `DroneSceneController.refreshGroundMaterial`'s condition exactly. `.city` always keeps its
    /// brittle-stone/concrete ground regardless of weather, and `.gridDemo` is excluded from
    /// ground-material switching entirely (`terrain.preset != .gridDemo` guard) — promoting either
    /// of them to the `.snow` profile would apply a normalization band tuned for organic,
    /// mostly-very-cold snow terrain to a population that's actually concrete/road/roof/metal
    /// sitting in a much narrower, warmer cluster, bunching everything into the orange/red part of
    /// the palette — a uniformly "hot"-looking scene despite the (correctly, much colder) absolute
    /// temperatures, exactly backwards from what snow weather should look like.
    private static func groundActuallyBecomesSnow(for terrain: TerrainPreset) -> Bool {
        switch terrain {
        case .field, .forest, .cargoYard: return true
        case .city, .gridDemo: return false
        }
    }

    static func resolve(
        terrain: TerrainPreset,
        weather: WeatherPreset,
        selection: ThermalProfileSelection
    ) -> ThermalSceneProfile {
        if let explicit = selection.explicitProfile {
            return explicit
        }

        if weather == .snow, groundActuallyBecomesSnow(for: terrain) {
            return .snow
        }

        switch terrain {
        case .forest: return .forest
        case .field: return .field
        case .cargoYard: return .neutral
        case .city: return .city
        case .gridDemo: return .neutral
        }
    }
}
