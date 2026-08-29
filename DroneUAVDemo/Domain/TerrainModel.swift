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
    // Extended range, added for the supersonic scope.
    //
    // The step from x256 to x512 is not just "one more size". Up to x256 a map is a
    // place: 25.6 km across, a flight lasts long enough to look at it, and the object
    // budget covers it. From x512 up a map is a *range* — somewhere to accelerate,
    // climb and turn around, with an aircraft that crosses the whole of x256 in
    // twenty-one seconds at Mach 2. They are deliberately kept out of the automatic
    // map-size recommendation (see `isExtendedRange`), because recommending a
    // 100-kilometre map to a survey quadcopter would be worse than useless.
    case x512
    case x1024
    case x2048
    case x4096
    case x8192

    var id: String { rawValue }

    /// Is this one of the ranges added for high-altitude, high-speed work rather than
    /// one of the ordinary mission map sizes?
    ///
    /// Read by the map-size adviser so a small airframe is never told to fly on a
    /// hundred-kilometre range, and by the flight-ceiling rule, which is the other
    /// thing these scales exist to unlock.
    var isExtendedRange: Bool {
        switch self {
        case .x4, .x8, .x16, .x32, .x64, .x128, .x256:
            return false
        case .x512, .x1024, .x2048, .x4096, .x8192:
            return true
        }
    }

    /// The ordinary mission map sizes, in order. This is what the map-size adviser
    /// searches; `allCases` still carries everything for the pickers and for saved
    /// scenarios.
    static let conventionalCases: [MapScale] = allCases.filter { !$0.isExtendedRange }

    /// How high an aircraft may be commanded on a map of this size, metres.
    ///
    /// Not a physical ceiling — the atmosphere model runs to 32 km either way. It is
    /// the limit the mission planner, the route validators and the altitude clamps
    /// read, and it used to be `min(720, …)` for every map in the catalogue. 720 m is
    /// a sensible roof over a city and an absurd one for an aircraft whose published
    /// dash sits at 13,700 m, which is why the two are separated here instead of both
    /// falling out of one formula about how big the ground is.
    ///
    /// 25 km on the extended ranges, matching the top of the modelled atmosphere's
    /// useful band — above that the single-gas ISA relations stop describing the air.
    var altitudeCeilingMeters: Float {
        isExtendedRange ? 25_000.0 : 720.0
    }

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
        case .x512:
            return 512.0
        case .x1024:
            return 1024.0
        case .x2048:
            return 2048.0
        case .x4096:
            return 4096.0
        case .x8192:
            return 8192.0
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
        case .x512:
            return "terrain.scale.512x512"
        case .x1024:
            return "terrain.scale.1024x1024"
        case .x2048:
            return "terrain.scale.2048x2048"
        case .x4096:
            return "terrain.scale.4096x4096"
        case .x8192:
            return "terrain.scale.8192x8192"
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
        // The trend flattens rather than continuing: this fraction is how much of the
        // map the control link reaches, and on a hundred-kilometre range the limit is
        // the radio, not the map edge. Pushing it toward 1.0 would quietly promise a
        // link that no airframe in the catalogue has.
        case .x512:
            return 0.85
        case .x1024:
            return 0.86
        case .x2048:
            return 0.86
        case .x4096:
            return 0.87
        case .x8192:
            return 0.87
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
        // Deliberately almost flat above x256. This factor multiplies the generated
        // object count, and `ScenePopulationService` already clamps what it derives
        // from it to 2.2 — so growing it further buys nothing except a longer
        // generation pass. An extended range is meant to read as open country anyway:
        // there is nothing to fill four hundred kilometres of it with at Mach 2.
        case .x512:
            return 4.40
        case .x1024:
            return 4.55
        case .x2048:
            return 4.65
        case .x4096:
            return 4.70
        case .x8192:
            return 4.75
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
    let supportsLanding: Bool
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

    /// How far the procedurally-continued, lower-density "outer belt" reaches beyond
    /// `scenicHalfExtent` before the world becomes flat, undecorated ground — large but finite,
    /// scaled with map size so a realistic flight runs out of battery/fuel/fiber before it runs
    /// out of world, without attempting a genuinely unbounded/streamed terrain (that's separate,
    /// deferred work). Ground geometry and the boundary-belt decoration both key off this same
    /// radius so neither a bare patch of ground nor a decorated area without ground can occur.
    var beltOuterRadius: Float {
        scenicHalfExtent + max(400.0, worldHalfExtent * 0.75)
    }

    /// How high the mission planner, the route validators and the altitude clamps will
    /// let an aircraft be commanded, metres.
    ///
    /// The `720.0` that used to sit in this expression was the single hardest limit in
    /// the simulation: it is read in eighteen places and it capped every map in the
    /// catalogue at roughly the height of a tall building. That is the right roof for a
    /// survey quadcopter over a city and the wrong one for an aircraft whose published
    /// supersonic dash happens at 13,700 m — at 720 m a Firebee II cannot exceed Mach
    /// 1.1 no matter what the aerodynamics say, because it never leaves the thickest
    /// air there is.
    ///
    /// The roof now comes from the map's own class rather than from a constant, and for
    /// every conventional map size the arithmetic is unchanged down to the last bit.
    var maxFlightAltitude: Float {
        max(240.0, min(mapScale.altitudeCeilingMeters, worldHalfExtent * 1.6))
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
