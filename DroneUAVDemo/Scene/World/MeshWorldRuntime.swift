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

    /// Where the water is, or nil for a landlocked tile.
    ///
    /// Derived during the off-main-thread preparation alongside the collision index, because it
    /// reads the same surface queries and finishes in a fraction of a second — making it a separate
    /// load step would only add a stage to the progress bar for no measurable time.
    let water: WaterSurfaceModel?

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
        let water: WaterSurfaceModel?
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
        self.water = prepared.water
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
        self.water = WaterSurfaceDetector.detect(collision: collisionResult.index).model

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

        let waterResult = WaterSurfaceDetector.detect(collision: collisionResult.index)
        #if DEBUG
        if let water = waterResult.model {
            print(String(format: "[MeshWorld] water plane at %.2f m covering %.1f%% of the tile",
                         water.level, water.coverageFraction * 100))
        } else {
            print("[MeshWorld] no water: \(waterResult.rejection ?? "unknown")")
        }
        #endif

        return Preparation(
            tileIndex: tileIndex,
            quadtree: quadtree,
            collision: collisionResult.index,
            water: waterResult.model,
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

    /// The chosen start point, resolved once.
    ///
    /// Cached because three separate consumers need the *same* answer — the launch deck, the
    /// reset/home point and the initial aircraft state. Letting each run its own search would put
    /// the deck in one place and the aircraft in another.
    private(set) lazy var spawnPoint: SIMD3<Float>? = findSpawnPoint()

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

        var candidates: [Candidate] = []
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

                guard footprintSpread(x: x, z: z) <= Self.maximumFootprintSpread else { continue }
                let survey = surroundings(x: x, z: z, surface: surface)
                guard survey.openness >= Self.minimumLateralClearance else { continue }
                candidates.append(
                    Candidate(
                        point: SIMD3<Float>(x, surface, z),
                        openness: survey.openness,
                        standsAbove: surface - survey.lowestNeighbour
                    )
                )
                // Keep looking until there are enough *ground-level* options, not merely enough
                // options: the first candidates found are near the tile centre, which in a city
                // centre means rooftops, and stopping there is what parked the launch pad 19 m up.
                if candidates.filter(\.isGroundLevel).count >= 24 { return bestCandidate(candidates) }
            }
            radius += 12
        }
        return bestCandidate(candidates)
    }

    /// A start point must have room *around* it, not just above it.
    ///
    /// Level ground and clear sky are both true inside a six-metre light well between two blocks,
    /// which is where the search actually put the aircraft in central Helsinki: walls 6 m west, 6 m
    /// south and 10 m east of a rooftop 7.5 m up, reported to the pilot as a dark box with a patch
    /// of sky and a standing collision warning. Flatness was measured over a 3 m probe and the
    /// headroom ray went straight up, so neither test could see the walls.
    private static let minimumLateralClearance: Float = 14.0
    private static let opennessProbeLimit: Float = 45.0

    /// What counts as being in the way.
    ///
    /// Set at 2.5 m this missed parked cars, and the search duly delivered the aircraft into a car
    /// park wedged between vehicles: 34 m of clearance by the old measure, 1 m by any measure that
    /// can see a van. A drone cares about anything it can strike, and 1.2 m catches cars, bollards
    /// and railings while still ignoring kerbs and low walls.
    private static let obstructionHeight: Float = 1.2

    /// An apron is smooth; a car park, a rubble field and a tree line are not. Measured as the
    /// height spread across the immediate footprint, this rejects them all without needing to know
    /// what they are — and it is the test that would have caught the car park on its own.
    private static let maximumFootprintSpread: Float = 1.0

    /// How far a surface may stand above its own surroundings and still count as ground.
    ///
    /// A roof is not distinguished by its absolute height — terrain varies and the vertical datum is
    /// arbitrary — but by standing above everything around it. One generous storey is the line: it
    /// keeps quaysides, which sit a couple of metres over the water they look onto, and rejects the
    /// rooftops that an openness-only test happily selects.
    private static let groundLevelTolerance: Float = 5.0

    private struct Candidate {
        let point: SIMD3<Float>
        let openness: Float
        let standsAbove: Float
        var isGroundLevel: Bool { standsAbove <= MeshWorldRuntime.groundLevelTolerance }
    }

    /// Height spread over the patch the aircraft actually stands on.
    private func footprintSpread(x: Float, z: Float) -> Float {
        var lowest = Float.greatestFiniteMagnitude
        var highest = -Float.greatestFiniteMagnitude
        for stepX in -3...3 {
            for stepZ in -3...3 {
                guard let height = collision.highestSurface(
                    x: x + Float(stepX) * 1.5,
                    z: z + Float(stepZ) * 1.5
                ) else { continue }
                lowest = min(lowest, height)
                highest = max(highest, height)
            }
        }
        return highest > lowest ? highest - lowest : .greatestFiniteMagnitude
    }

    /// Walks eight directions once, answering both questions the choice depends on: how far the
    /// clear space extends, and how far the surface drops away around it.
    private func surroundings(
        x: Float,
        z: Float,
        surface: Float
    ) -> (openness: Float, lowestNeighbour: Float) {
        var worst = Self.opennessProbeLimit
        var lowest = surface
        for step in 0..<8 {
            let angle = Float(step) / 8 * 2 * .pi
            let dx = cos(angle), dz = sin(angle)
            var distance: Float = 2
            while distance < Self.opennessProbeLimit {
                guard let height = collision.highestSurface(x: x + dx * distance, z: z + dz * distance)
                else { break }
                lowest = min(lowest, height)
                if height > surface + Self.obstructionHeight { break }
                distance += 2
            }
            worst = min(worst, distance)
        }
        return (worst, lowest)
    }

    /// The most open of the candidates found, and among equally open ones the lowest.
    ///
    /// Openness alone happily selects a large flat roof — it is level, it has sky above it and
    /// nothing taller nearby, which is precisely the definition being tested. But a roof nineteen
    /// metres up is a strange place to find a launch pad parked, and a quayside or a plaza reads as
    /// the apron it is meant to be. Since the openness probe saturates, ties are common and the
    /// elevation tie-break does the real work here.
    private func bestCandidate(_ candidates: [Candidate]) -> SIMD3<Float>? {
        // Ground wins outright when any exists; a rooftop is accepted only when the tile offers
        // nothing else, which is better than refusing to start at all.
        let ground = candidates.filter(\.isGroundLevel)
        let pool = ground.isEmpty ? candidates : ground
        return pool.max { left, right in
            if abs(left.openness - right.openness) > 1.0 {
                return left.openness < right.openness
            }
            return left.standsAbove > right.standsAbove
        }?.point
    }
}
