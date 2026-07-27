import SceneKit
import simd

/// What the simulator needs from an imported world, whatever it was built from.
///
/// Two very different pipelines produce a world here — a photogrammetric mesh tile and a map
/// constructed from open vector data — and everything downstream of this protocol is indifferent to
/// which one it got. That indifference is the point, and it is not a stylistic preference: the
/// ground-height contract, the water rule, the launch pad, the boundary geofence, the suppression of
/// procedural scenery and the project's saved reference were all built and debugged once, against a
/// photogrammetric world. Wiring a second world in beside them would have re-derived every one of
/// those assumptions, and the flight tests that found them the first time were expensive.
///
/// The requirements are deliberately few. A world is flyable when it can say where its surfaces are,
/// where its water is, where an aircraft may start, and how far it extends.
@MainActor
protocol FlyableWorld: AnyObject {

    /// Scene content. Parented into the live scene on install and removed on replacement.
    var rootNode: SCNNode { get }

    /// Every surface the aircraft can touch: ground, quaysides, rooftops, walls.
    var collision: MeshCollisionIndex { get }

    /// Where the water is, or nil for a landlocked world — or one whose source has no water data.
    var water: WaterSurfaceModel? { get }

    /// A clear, level, open patch to start from, or nil if the world offers none.
    var spawnPoint: SIMD3<Float>? { get }

    /// Real-world anchor of scene (0, 0, 0), so telemetry and waypoints stay geographic.
    var origin: GeoOrigin { get }

    /// Extent in scene metres. The world boundary and its geofence are sized from this — a world
    /// larger than the boundary would strand the aircraft outside its own map.
    var worldBounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>) { get }

    /// Per-frame level-of-detail work. A world that holds all its geometry at once does nothing
    /// here, which is why this is not optional to *call* but is trivial to *implement*.
    func updateStreaming(camera: MeshStreamingPolicy.Camera)

    /// What kind of surface a collision triangle is, when the world knows. A world assembled from
    /// vector data built each triangle for a reason — ground, a wall, a carriageway, a deck, a tree
    /// — and can say so; a photogrammetric mesh is one continuous textured surface with no such
    /// provenance and returns nil. Used by the LiDAR payload to classify returns from fact rather
    /// than from a plausible-looking guess about their normals.
    func surfaceClass(forTriangle index: Int) -> LidarSurfaceClass?

    /// The world's contents as discrete objects, for the shared environment registry.
    ///
    /// A world knows more than the triangle soup it hands to `collision`: it was assembled from
    /// buildings with footprints and heights, and from mapped trees. Publishing that lets the map
    /// overlay, the route planner and the obstacle registry see an imported city as *objects* —
    /// which, before this existed, they simply could not: those consumers read the procedural
    /// registry, nothing filled it on an imported world, and the aircraft flew through a city it
    /// had no representation of.
    func registryObjects() -> [FlyableWorldObject]

    /// Tree crowns as porous volumes, for the LiDAR's foliage model only. Read by no part of the
    /// flight model — the collision proxy stays exactly as the physics and the autopilot expect it.
    var lidarFoliage: LidarFoliageIndex? { get }
}

extension FlyableWorld {
    func surfaceClass(forTriangle index: Int) -> LidarSurfaceClass? { nil }
    var lidarFoliage: LidarFoliageIndex? { nil }
    func registryObjects() -> [FlyableWorldObject] { [] }
}

/// One discrete thing in a world, in the terms the shared registry needs.
struct FlyableWorldObject {
    let id: UUID
    let kind: EnvironmentObjectKind
    /// Base centre: horizontal centre, vertical bottom.
    let position: SIMD3<Float>
    /// Footprint in X/Z, height in Y.
    let size: SIMD3<Float>
    let yawRadians: Float
    let source: String
    /// The object's true outline in world X/Z, when it has one.
    ///
    /// A box around a footprint is the right shape for a route search and the wrong one for
    /// touching: measured over this package's 5863 buildings the minimum-area rectangle covers
    /// ×1.02 of the real footprint at the median but ×1.29 at the 90th percentile and ×7.4 at
    /// worst, and 42% of outlines are not even quads. That surplus sits in the street, where the
    /// operator is trying to fly.
    let footprint: [SIMD2<Float>]?

    init(
        id: UUID,
        kind: EnvironmentObjectKind,
        position: SIMD3<Float>,
        size: SIMD3<Float>,
        yawRadians: Float,
        source: String,
        footprint: [SIMD2<Float>]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.position = position
        self.size = size
        self.yawRadians = yawRadians
        self.source = source
        self.footprint = footprint
    }
}
