import Foundation
import simd

enum MapScale: String, CaseIterable, Identifiable {
    case x4
    case x8
    case x16
    case x32

    var id: String { rawValue }

    var tilesPerSide: Int {
        switch self {
        case .x4:
            return 4
        case .x8:
            return 8
        case .x16:
            return 16
        case .x32:
            return 32
        
        }
    }

    var titleKey: String {
        switch self {
        case .x4:
            return "terrain.scale.4x4"
        case .x8:
            return "terrain.scale.8x8"
        case .x16:
            return "terrain.scale.16x16"
        case .x32:
            return "terrain.scale.32x32"
        }
    }

    var worldHalfExtentMeters: Float {
        Float(tilesPerSide) * 6.0
    }

    var relativeAreaTo16: Float {
        let ratio = Float(tilesPerSide) / 16.0
        return ratio * ratio
    }
}

enum TerrainPreset: String, CaseIterable, Identifiable {
    case gridDemo
    case field
    case forest
    case city

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gridDemo:
            return "Grid Demo"
        case .field:
            return "Field"
        case .forest:
            return "Forest"
        case .city:
            return "City"
        }
    }

    var titleKey: String {
        switch self {
        case .gridDemo:
            return "terrain.grid_demo"
        case .field:
            return "terrain.field"
        case .forest:
            return "terrain.forest"
        case .city:
            return "terrain.city"
        }
    }

    var defaultDensity: Float {
        switch self {
        case .gridDemo:
            return 0.35
        case .field:
            return 0.24
        case .forest:
            return 0.72
        case .city:
            return 0.82
        }
    }

    var defaultObjectKinds: [EnvironmentObjectKind] {
        switch self {
        case .gridDemo:
            return [.marker, .pole, .crate]
        case .field:
            return [.tree, .rock, .crate]
        case .forest:
            return [.tree, .tree, .tree, .rock, .pole]
        case .city:
            return [.building, .building, .building, .pole, .crate]
        }
    }

    var extentMultiplier: Float {
        switch self {
        case .gridDemo:
            return 0.78
        case .field:
            return 1.0
        case .forest:
            return 1.12
        case .city:
            return 1.0
        }
    }
}

enum EnvironmentObjectKind: String {
    case tree
    case building
    case pole
    case crate
    case rock
    case marker
    case distantBelt
}

struct TerrainConfiguration {
    var preset: TerrainPreset
    var mapScale: MapScale
    var density: Float
    var seed: UInt64
    var safeSpawnRadius: Float

    var worldHalfExtent: Float {
        mapScale.worldHalfExtentMeters * preset.extentMultiplier
    }

    var maxFlightAltitude: Float {
        max(220.0, worldHalfExtent * 2.8)
    }

    var areaScaleFactor: Float {
        mapScale.relativeAreaTo16
    }

    static let `default` = TerrainConfiguration(
        preset: .field,
        mapScale: .x16,
        density: TerrainPreset.field.defaultDensity,
        seed: 42,
        safeSpawnRadius: 8.0
    )
}

struct EnvironmentObjectDescriptor: Identifiable {
    let id: UUID
    let kind: EnvironmentObjectKind
    let biome: TerrainPreset
    let position: SIMD3<Float>
    let size: SIMD3<Float>
    let boundingRadius: Float
    let isCollidable: Bool
}
