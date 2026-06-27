import Foundation

/// Resolves the effective `ThermalSceneProfile` from the map, weather, and the user's
/// (possibly `.auto`) selection. Snow weather promotes any map to the cold snow profile so the
/// display range goes cold — matching the EO feed, whose ground/trees also switch to snow.
enum ThermalSceneProfileResolver {
    static func resolve(
        terrain: TerrainPreset,
        weather: WeatherPreset,
        selection: ThermalProfileSelection
    ) -> ThermalSceneProfile {
        if let explicit = selection.explicitProfile {
            return explicit
        }

        if weather == .snow {
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
