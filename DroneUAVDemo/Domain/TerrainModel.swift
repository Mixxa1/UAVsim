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

    var numericPreset: Float {
        switch self {
        case .x4:
            return 4.0
        case .x8:
            return 8.0
        case .x16:
            return 16.0
        case .x32:
            return 32.0
        case .x64:
            return 64.0
        case .x128:
            return 128.0
        case .x256:
            return 256.0
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
        case .x64:
            return "terrain.scale.64x64"
        case .x128:
            return "terrain.scale.128x128"
        case .x256:
            return "terrain.scale.256x256"
        }
    }

    var worldHalfExtentMeters: Float {
        sideLengthMeters * 0.5
    }

    var sideLengthMeters: Float {
        numericPreset * 100.0
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
        MapScale(rawValue: rawValue)
    }
}

enum TerrainPreset: String, CaseIterable, Identifiable {
    case gridDemo
    case field
    case forest
    case cargoYard
    case city

    var id: String { rawValue }

    var isFixedWingCompatible: Bool {
        switch self {
        case .cargoYard, .city:
            return false
        case .gridDemo, .field, .forest:
            return true
        }
    }

    func isAvailable(for airframeClass: AirframeClass) -> Bool {
        airframeClass != .fixedWing || isFixedWingCompatible
    }

    func compatiblePreset(for airframeClass: AirframeClass) -> TerrainPreset {
        isAvailable(for: airframeClass) ? self : .field
    }

    static func available(for airframeClass: AirframeClass) -> [TerrainPreset] {
        allCases.filter { $0.isAvailable(for: airframeClass) }
    }

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
            return [.cargoContainer, .cargoContainer, .cargoContainer, .pole, .marker]
        case .city:
            return []
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
    case cargoContainer
    case rock
    case marker
}

enum CargoContainerAssetKind: String, CaseIterable {
    case container18MB
    case freeShipContainer
    case shippingContainerOpen
    case seaCargoContainer
    case containersCluster

    var nominalSize: SIMD3<Float> {
        switch self {
        case .container18MB:
            return SIMD3<Float>(11.98, 3.00, 2.92)
        case .freeShipContainer:
            return SIMD3<Float>(12.20, 2.59, 2.44)
        case .shippingContainerOpen, .seaCargoContainer:
            return SIMD3<Float>(6.06, 2.59, 2.44)
        case .containersCluster:
            return SIMD3<Float>(8.90, 5.20, 8.10)
        }
    }

    var hasFlyableInterior: Bool {
        switch self {
        case .shippingContainerOpen, .freeShipContainer, .container18MB:
            return true
        case .seaCargoContainer, .containersCluster:
            return false
        }
    }

    /// `freeShipContainer`'s source mesh has no end caps at all, and `container18MB`'s isolated
    /// "doors open" module has door geometry swung open at both ends — both stay open all the
    /// way through, so neither gets a rear wall. `shippingContainerOpen` is confirmed
    /// single-ended from its own door node data, so it keeps one.
    var hasOpenRearEnd: Bool {
        self == .freeShipContainer || self == .container18MB
    }
}

struct EnvironmentCollisionPart {
    let id: UUID
    let localCenter: SIMD3<Float>
    let size: SIMD3<Float>
    let yawRadians: Float
    let source: String
    let supportsLanding: Bool

    init(
        id: UUID = UUID(),
        localCenter: SIMD3<Float>,
        size: SIMD3<Float>,
        yawRadians: Float = 0.0,
        source: String,
        supportsLanding: Bool = false
    ) {
        self.id = id
        self.localCenter = localCenter
        self.size = size
        self.yawRadians = yawRadians
        self.source = source
        self.supportsLanding = supportsLanding
    }
}

struct EnvironmentSupportSurfacePart {
    let localCenter: SIMD3<Float>
    let halfExtents: SIMD2<Float>
    let yawRadians: Float
    let normal: SIMD3<Float>
    let source: String
}

struct EnvironmentCollisionMeshTriangle {
    let point0: SIMD3<Float>
    let point1: SIMD3<Float>
    let point2: SIMD3<Float>
}

struct EnvironmentCollisionMeshPart {
    let id: UUID
    let triangles: [EnvironmentCollisionMeshTriangle]
    let source: String

    init(
        id: UUID = UUID(),
        triangles: [EnvironmentCollisionMeshTriangle],
        source: String
    ) {
        self.id = id
        self.triangles = triangles
        self.source = source
    }
}

struct EnvironmentSupportSurfaceTrianglePart {
    let point0: SIMD3<Float>
    let point1: SIMD3<Float>
    let point2: SIMD3<Float>
    let normal: SIMD3<Float>
    let source: String
}

struct TerrainConfiguration {
    var preset: TerrainPreset
    var mapScale: MapScale
    var density: Float
    var seed: UInt64
    var safeSpawnRadius: Float
    /// Raises both the generated object count and the collidable-object cap in
    /// `ScenePopulationService` — off by default (and for every existing flow); set for mission
    /// terrain only, where "this looks like real forest cover" matters more than the normal
    /// freeform-flight object budget.
    var missionDensityBoost: Bool = false
    /// When set (mission only), concentrates forest generation around this point/radius instead
    /// of spreading uniformly over the whole map — the collidable-object budget is finite
    /// regardless of map size, so without this it gets diluted across terrain the search sector
    /// doesn't even cover, while the sector itself reads sparse.
    var missionSearchSectorCenter: SIMD2<Float>?
    var missionSearchSectorRadius: Float?

    var worldHalfExtent: Float {
        mapScale.worldHalfExtentMeters
    }

    var hardWorldBoundsRadius: Float {
        let minimumHalfExtent = safeSpawnRadius + 18.0
        let edgeMargin = max(12.0, min(48.0, worldHalfExtent * 0.05))
        let maximumHalfExtent = worldHalfExtent - edgeMargin
        return min(maximumHalfExtent, max(minimumHalfExtent, worldHalfExtent * 0.95))
    }

    var signalBoundaryRadius: Float {
        hardWorldBoundsRadius
    }

    var scenicHalfExtent: Float {
        max(worldHalfExtent * preset.extentMultiplier + 110.0, hardWorldBoundsRadius + 130.0)
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
    let cargoAsset: CargoContainerAssetKind?
    let collisionParts: [EnvironmentCollisionPart]
    let supportSurfaceParts: [EnvironmentSupportSurfacePart]
    let collisionMeshParts: [EnvironmentCollisionMeshPart]
    let supportSurfaceTriangleParts: [EnvironmentSupportSurfaceTrianglePart]
    let usesScenePhysicsCollision: Bool

    init(
        id: UUID,
        kind: EnvironmentObjectKind,
        biome: TerrainPreset,
        position: SIMD3<Float>,
        yawRadians: Float,
        size: SIMD3<Float>,
        boundingRadius: Float,
        isCollidable: Bool,
        cargoAsset: CargoContainerAssetKind? = nil,
        collisionParts: [EnvironmentCollisionPart] = [],
        supportSurfaceParts: [EnvironmentSupportSurfacePart] = [],
        collisionMeshParts: [EnvironmentCollisionMeshPart] = [],
        supportSurfaceTriangleParts: [EnvironmentSupportSurfaceTrianglePart] = [],
        usesScenePhysicsCollision: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.biome = biome
        self.position = position
        self.yawRadians = yawRadians
        self.size = size
        self.boundingRadius = boundingRadius
        self.isCollidable = isCollidable
        self.cargoAsset = cargoAsset
        self.collisionParts = collisionParts
        self.supportSurfaceParts = supportSurfaceParts
        self.collisionMeshParts = collisionMeshParts
        self.supportSurfaceTriangleParts = supportSurfaceTriangleParts
        self.usesScenePhysicsCollision = usesScenePhysicsCollision
    }
}
