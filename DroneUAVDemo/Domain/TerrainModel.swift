import Foundation
import simd

enum MapScale: String, CaseIterable, Identifiable {
    case x4
    case x8
    case x16
    case x32
    case x64
    case x128
    case x256

    var id: String { rawValue }

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
        case .x64:
            return "terrain.scale.64x64"
        case .x128:
            return "terrain.scale.128x128"
        case .x256:
            return "terrain.scale.256x256"
        }
    }

    var worldHalfExtentMeters: Float {
        switch self {
        case .x4:
            return 72.0
        case .x8:
            return 104.0
        case .x16:
            return 148.0
        case .x32:
            return 212.0
        case .x64:
            return 280.0
        case .x128:
            return 360.0
        case .x256:
            return 480.0
        }
    }

    var signalBoundaryCoverage: Float {
        switch self {
        case .x4:
            return 0.75
        case .x8:
            return 0.76
        case .x16:
            return 0.77
        case .x32:
            return 0.79
        case .x64:
            return 0.80
        case .x128:
            return 0.82
        case .x256:
            return 0.84
        }
    }

    var populationBudgetFactor: Float {
        switch self {
        case .x4:
            return 0.82
        case .x8:
            return 1.05
        case .x16:
            return 1.35
        case .x32:
            return 1.78
        case .x64:
            return 2.30
        case .x128:
            return 3.05
        case .x256:
            return 4.20
        }
    }

    static func fromPersistedRawValue(_ rawValue: String) -> MapScale? {
        if let directMatch = MapScale(rawValue: rawValue) {
            return directMatch
        }

        switch rawValue {
        case "x4", "x8":
            return .x64
        case "x16":
            return .x128
        case "x32":
            return .x256
        default:
            return nil
        }
    }
}

enum TerrainPreset: String, CaseIterable, Identifiable {
    case gridDemo
    case field
    case forest
    case cargoYard
    case city

    var id: String { rawValue }

    var title: String {
        NSLocalizedString(titleKey, comment: "")
    }

    var titleKey: String {
        switch self {
        case .gridDemo:
            return "terrain.grid_demo"
        case .field:
            return "terrain.field"
        case .forest:
            return "terrain.forest"
        case .cargoYard:
            return "terrain.cargo_yard"
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
        case .cargoYard:
            return 0.58
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
        case .cargoYard:
            return [.crate, .crate, .crate, .pole, .marker]
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
        case .cargoYard:
            return 0.96
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

    var signalBoundaryRadius: Float {
        let minimumRadius = safeSpawnRadius + 12.0
        let targetRadius = worldHalfExtent * mapScale.signalBoundaryCoverage
        let edgeMargin = max(12.0, worldHalfExtent * 0.10)
        let maximumRadius = worldHalfExtent - edgeMargin
        return min(maximumRadius, max(minimumRadius, targetRadius))
    }

    var scenicHalfExtent: Float {
        max(worldHalfExtent + 110.0, signalBoundaryRadius + 130.0)
    }

    var maxFlightAltitude: Float {
        max(240.0, min(720.0, worldHalfExtent * 1.6))
    }

    var areaScaleFactor: Float {
        mapScale.populationBudgetFactor
    }

    static let `default` = TerrainConfiguration(
        preset: .field,
        mapScale: .x16,
        density: TerrainPreset.field.defaultDensity,
        seed: 42,
        safeSpawnRadius: 15.0
    )
}

struct EnvironmentObjectDescriptor: Identifiable {
    let id: UUID
    let kind: EnvironmentObjectKind
    let biome: TerrainPreset
    let position: SIMD3<Float>
    let yawRadians: Float
    let size: SIMD3<Float>
    let boundingRadius: Float
    let isCollidable: Bool
}
