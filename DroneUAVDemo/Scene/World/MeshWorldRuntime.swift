import SceneKit
import simd

/// Everything one imported photogrammetric world needs to be flown in, assembled together.
///
/// Bundling the tile index, the LOD tree, the streamer and the collision surface into a single
/// value matters because they must agree on one thing absolutely: the origin offset. Visual
/// geometry and collision geometry derived from different anchors would disagree by whole metres
/// and the aircraft would collide with air. Constructing them here, from one offset, makes that
/// impossible to get wrong at a call site.
@MainActor
final class MeshWorldRuntime {

    struct LoadReport {
        let tileKey: String
        let visualNodes: Int
        let collisionTriangles: Int
        let originCoordinate: GeoCoordinate
        let bounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)
        let seconds: Double
    }

    let tileIndex: ContextCaptureTileIndex
    let quadtree: MeshQuadtree
    let streamer: UAVWorldMeshStreamer
    let collision: MeshCollisionIndex
    /// Real-world anchor of scene (0, 0, 0), so telemetry, waypoints and replay stay geographic.
    let origin: GeoOrigin
    let report: LoadReport

    var rootNode: SCNNode { streamer.rootNode }

    /// Loads an extracted tile directory.
    ///
    /// The world is re-anchored on the tile's own centre rather than on the export origin: the
    /// export sits tens of kilometres away, and while the geodesy is exact in `Double`, the scene
    /// graph and the flight model both work in `Float`. Keeping local coordinates within about a
    /// kilometre of zero preserves millimetre precision where it is actually used.
    /// Stage of a load, for a progress indicator.
    ///
    /// Worth reporting individually because they are wildly unequal: indexing is instant, the
    /// bounds pass and the collision extraction each take tens of seconds on a cold cache, and a
    /// single undifferentiated spinner for half a minute is indistinguishable from a hang.
    enum LoadStage: Equatable {
        case indexing
        case measuring(done: Int, total: Int)
        case buildingCollision
        case installing

        var titleKey: String {
            switch self {
            case .indexing: return "world.load.stage.indexing"
            case .measuring: return "world.load.stage.measuring"
            case .buildingCollision: return "world.load.stage.collision"
            case .installing: return "world.load.stage.installing"
            }
        }

        var fraction: Double {
            switch self {
            case .indexing: return 0.02
            case .measuring(let done, let total):
                return total > 0 ? 0.05 + 0.55 * Double(done) / Double(total) : 0.05
            case .buildingCollision: return 0.65
            case .installing: return 0.97
            }
        }
    }

    /// Heavy, actor-free part of a load. Everything expensive happens here so it can run off the
    /// main thread; only the streamer, which mutates the scene graph, is left for the main actor.
    struct Preparation: Sendable {
        let tileIndex: ContextCaptureTileIndex
        let quadtree: MeshQuadtree
        let collision: MeshCollisionIndex
        let collisionTriangles: Int
        let originOffset: SIMD3<Double>
        let originCoordinate: GeoCoordinate
        let seconds: Double
    }

    /// Loads a world without blocking the main thread.
    ///
    /// The synchronous initialiser below would freeze the UI for the ~25 s a cold cache costs —
    /// long enough that the progress bar meant to reassure the user would itself never draw.
    static func load(
        tileDirectory: URL,
        collisionLevel: Int = MeshCollisionBuilder.defaultLevel,
        cacheDirectory: URL?,
        progress: @escaping @Sendable (LoadStage) -> Void
    ) async -> MeshWorldRuntime? {
        let prepared = await Task.detached(priority: .userInitiated) { () -> Preparation? in
            Self.prepare(
                tileDirectory: tileDirectory,
                collisionLevel: collisionLevel,
                cacheDirectory: cacheDirectory,
                progress: progress
            )
        }.value

        guard let prepared else { return nil }
        progress(.installing)
        return MeshWorldRuntime(prepared: prepared, tileKey: tileDirectory.lastPathComponent)
    }

    /// Main-actor tail of a prepared load: creates the streamer and warms its root level.
    private init(prepared: Preparation, tileKey: String) {
        self.tileIndex = prepared.tileIndex
        self.quadtree = prepared.quadtree
        self.collision = prepared.collision
        self.origin = GeoOrigin(coordinate: prepared.originCoordinate, geoidSeparationMeters: 0)
        self.streamer = UAVWorldMeshStreamer(
            tree: prepared.quadtree,
            originOffset: prepared.originOffset
        )
        streamer.preloadRoots()
        self.report = LoadReport(
            tileKey: tileKey,
            visualNodes: prepared.quadtree.nodes.count,
            collisionTriangles: prepared.collisionTriangles,
            originCoordinate: prepared.originCoordinate,
            bounds: prepared.collision.bounds,
            seconds: prepared.seconds
        )
    }

    init?(
        tileDirectory: URL,
        collisionLevel: Int = MeshCollisionBuilder.defaultLevel,
        cacheDirectory: URL?
    ) {
        let started = Date()
        guard let tileIndex = try? ContextCaptureTileIndex(rootURL: tileDirectory),
              let crs = tileIndex.georeference.horizontalCRS else {
            return nil
        }
        self.tileIndex = tileIndex

        // The tile's own extent, taken from the coarsest level so this costs almost nothing.
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for node in tileIndex.covering(level: tileIndex.levelRange.lowerBound) {
            guard let bounds = MeshQuadtree.vertexBounds(of: node.objectURL) else { continue }
            minimum = simd_min(minimum, bounds.minimum)
            maximum = simd_max(maximum, bounds.maximum)
        }
        guard minimum.x < maximum.x else { return nil }

        // OBJ axes here: x east, y north, z up.
        let centreEast = Double((minimum.x + maximum.x) * 0.5)
        let centreNorth = Double((minimum.y + maximum.y) * 0.5)
        let originOffset = SIMD3<Double>(-centreEast, -centreNorth, 0)

        let originGeo = crs.geographic(
            easting: tileIndex.georeference.originEasting + centreEast,
            northing: tileIndex.georeference.originNorthing + centreNorth
        )
        // Finnish N2000 heights are orthometric, so the tile's own vertical datum already matches
        // the simulator's mean-sea-level convention; no geoid separation is applied.
        self.origin = GeoOrigin(
            coordinate: GeoCoordinate(
                latitudeDegrees: originGeo.latitudeDegrees,
                longitudeDegrees: originGeo.longitudeDegrees,
                altitudeMetersMSL: 0
            ),
            geoidSeparationMeters: 0
        )

        let tileKey = tileDirectory.lastPathComponent
        let boundsCache = cacheDirectory?.appendingPathComponent("\(tileKey)-bounds.json")
        let collisionCache = cacheDirectory?.appendingPathComponent("\(tileKey)-collision-L\(collisionLevel).bin")
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }

        self.quadtree = MeshQuadtree.build(
            index: tileIndex,
            originOffset: originOffset,
            cacheURL: boundsCache
        )
        self.streamer = UAVWorldMeshStreamer(tree: quadtree, originOffset: originOffset)
        streamer.preloadRoots()

        let collisionResult = MeshCollisionBuilder.build(
            index: tileIndex,
            level: collisionLevel,
            originOffset: originOffset,
            cacheURL: collisionCache
        )
        self.collision = collisionResult.index

        self.report = LoadReport(
            tileKey: tileKey,
            visualNodes: quadtree.nodes.count,
            collisionTriangles: collisionResult.triangleCount,
            originCoordinate: origin.coordinate,
            bounds: collisionResult.index.bounds,
            seconds: Date().timeIntervalSince(started)
        )
    }

    /// The expensive half of a load, free of actor isolation so it can run on a background task.
    nonisolated static func prepare(
        tileDirectory: URL,
        collisionLevel: Int,
        cacheDirectory: URL?,
        // Escaping because it is forwarded into `MeshQuadtree.build`'s optional progress closure,
        // and an optional closure parameter is implicitly escaping.
        progress: @escaping @Sendable (LoadStage) -> Void
    ) -> Preparation? {
        let started = Date()
        progress(.indexing)

        guard let tileIndex = try? ContextCaptureTileIndex(rootURL: tileDirectory),
              let crs = tileIndex.georeference.horizontalCRS else {
            return nil
        }

        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for node in tileIndex.covering(level: tileIndex.levelRange.lowerBound) {
            guard let bounds = MeshQuadtree.vertexBounds(of: node.objectURL) else { continue }
            minimum = simd_min(minimum, bounds.minimum)
            maximum = simd_max(maximum, bounds.maximum)
        }
        guard minimum.x < maximum.x else { return nil }

        let centreEast = Double((minimum.x + maximum.x) * 0.5)
        let centreNorth = Double((minimum.y + maximum.y) * 0.5)
        let originOffset = SIMD3<Double>(-centreEast, -centreNorth, 0)
        let originGeo = crs.geographic(
            easting: tileIndex.georeference.originEasting + centreEast,
            northing: tileIndex.georeference.originNorthing + centreNorth
        )

        let tileKey = tileDirectory.lastPathComponent
        if let cacheDirectory {
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }

        let quadtree = MeshQuadtree.build(
            index: tileIndex,
            originOffset: originOffset,
            cacheURL: cacheDirectory?.appendingPathComponent("\(tileKey)-bounds.json"),
            progress: { done, total in progress(.measuring(done: done, total: total)) }
        )

        progress(.buildingCollision)
        let collisionResult = MeshCollisionBuilder.build(
            index: tileIndex,
            level: collisionLevel,
            originOffset: originOffset,
            cacheURL: cacheDirectory?.appendingPathComponent("\(tileKey)-collision-L\(collisionLevel).bin")
        )

        return Preparation(
            tileIndex: tileIndex,
            quadtree: quadtree,
            collision: collisionResult.index,
            collisionTriangles: collisionResult.triangleCount,
            originOffset: originOffset,
            originCoordinate: GeoCoordinate(
                latitudeDegrees: originGeo.latitudeDegrees,
                longitudeDegrees: originGeo.longitudeDegrees,
                altitudeMetersMSL: 0
            ),
            seconds: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Runtime

    func update(cameraPosition: SIMD3<Float>, forward: SIMD3<Float>, fieldOfViewDegrees: Float, viewportHeight: Float) {
        streamer.update(
            camera: MeshStreamingPolicy.Camera(
                position: cameraPosition,
                forward: forward,
                verticalFieldOfViewRadians: max(fieldOfViewDegrees, 20) * .pi / 180.0,
                viewportHeightPixels: max(viewportHeight, 240),
                aspectRatio: 16.0 / 9.0
            )
        )
    }

    /// A clear spot to start from: a level patch of ground away from walls, with headroom.
    ///
    /// Searched outward from the tile centre in a spiral rather than taken at the centre itself,
    /// because the middle of a 2 km tile is as likely to be a rooftop, a tree or open water as a
    /// usable apron.
    func findSpawnPoint(clearanceRadius: Float = 3.0) -> SIMD3<Float>? {
        let centre = (collision.bounds.minimum + collision.bounds.maximum) * 0.5
        let maximumRadius = min(
            collision.bounds.maximum.x - collision.bounds.minimum.x,
            collision.bounds.maximum.z - collision.bounds.minimum.z
        ) * 0.45

        var radius: Float = 0
        while radius < maximumRadius {
            let samples = max(8, Int(radius / 12) * 8)
            for sample in 0..<samples {
                let angle = Float(sample) / Float(samples) * 2 * .pi
                let x = centre.x + cos(angle) * radius
                let z = centre.z + sin(angle) * radius
                guard let surface = collision.highestSurface(x: x, z: z) else { continue }
                // Above sea level, so the aircraft does not start on the water.
                guard surface > 0.6 else { continue }

                // Level: the four neighbours must sit at a similar height.
                var levelEnough = true
                for offset in [SIMD2<Float>(clearanceRadius, 0), SIMD2<Float>(-clearanceRadius, 0),
                               SIMD2<Float>(0, clearanceRadius), SIMD2<Float>(0, -clearanceRadius)] {
                    guard let neighbour = collision.highestSurface(x: x + offset.x, z: z + offset.y),
                          abs(neighbour - surface) < 0.6 else {
                        levelEnough = false
                        break
                    }
                }
                guard levelEnough else { continue }

                // Headroom: nothing directly overhead for a comfortable climb-out.
                let overhead = collision.raycast(
                    origin: SIMD3<Float>(x, surface + 1.0, z),
                    direction: SIMD3<Float>(0, 1, 0),
                    maxDistance: 45
                )
                guard overhead == nil else { continue }

                return SIMD3<Float>(x, surface, z)
            }
            radius += 12
        }
        return nil
    }
}
