import SceneKit
import simd

/// A world built from open vector data, made flyable.
///
/// The counterpart to `MeshWorldRuntime`: same obligations, completely different source. Where the
/// photogrammetric path streams a measured surface, this one holds a modest amount of generated
/// geometry all at once — a square kilometre of Lower Manhattan is a few hundred buildings and some
/// fifteen thousand triangles, which is nothing to a scene graph — so there is no streaming to do
/// and `updateStreaming` is deliberately empty.
///
/// The important difference is what open vector data does *not* contain: relief. OSM gives building
/// footprints and heights, not terrain, so the ground here is genuinely a plane at zero. That is not
/// a placeholder to be apologised for — it is what the source says, and the ground-height contract
/// handles it without a special case, exactly as it handles the procedural presets.
@MainActor
final class OpenDataWorldRuntime: FlyableWorld {

    let rootNode: SCNNode
    let collision: MeshCollisionIndex
    let water: WaterSurfaceModel?
    let origin: GeoOrigin
    let worldBounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)

    /// Identifier of the package this was built from, for the project's saved reference.
    let identifier: String
    let displayName: String
    let buildingCount: Int

    /// Cached: the search is not free and several callers need the same answer.
    private(set) lazy var spawnPoint: SIMD3<Float>? = WorldSpawnFinder(collision: collision, water: water).find()

    func updateStreaming(camera: MeshStreamingPolicy.Camera) {}

    init(
        manifest: UAVWorldManifest,
        buildings: [UAVWorldBuilding],
        waterRings: [[SIMD2<Float>]] = [],
        elevation: TerrariumElevationSource.Grid? = nil
    ) {
        self.origin = manifest.origin
        self.identifier = manifest.identifier
        self.displayName = manifest.displayName
        self.buildingCount = buildings.count

        // Ground has to reach at least as far as the things standing on it.
        //
        // The requested extent alone is not enough: Overpass returns whole ways, so a building that
        // straddles the boundary is imported complete and stands beyond it. Measured on Lower
        // Manhattan, buildings reached z 842 against a requested half-span of 500 — and the spawn
        // search duly picked a rooftop 36 m up, because out there it was the only surface in
        // existence and there was no ground beneath it to prefer.
        let halfSpan = max(
            Self.halfSpanMeters(of: manifest),
            Self.buildingReachMeters(buildings)
        ) + 30.0

        // Bare-earth is applied here, at load, not at fetch. The package stores the raw surface
        // model, so a map built by any version of the app — including one that predated this filter
        // — still renders as real ground rather than as its own skyline. A surface model over a
        // dense city is mostly rooftops; opening it removes anything narrower than a city block and
        // leaves the landforms, so Lower Manhattan reads as 0–12 m of real relief, not 40 m of towers.
        let ground = elevation?.bareEarth()

        // The water's *surface*, which is not the lowest number in the elevation grid.
        //
        // Terrarium carries bathymetry — depth below the sea, not height of the ground you can stand
        // on. Taking the grid minimum as the water level put New York Bay's water plane at −969 m,
        // which is the ocean floor: the water vanished from sight, and the ground tiles reaching down
        // to it became the spikes hanging under a city that appeared to float. Taking the median over
        // water cells and flooring at sea level gives the right answer for both a coast and a lake.
        // Only water a UAV could actually ditch in. OSM maps fountains, reflecting pools and
        // ornamental ponds as `natural=water`, and at a four-metre mask each becomes a scattered
        // blue fleck on a plaza — visual noise, and a drowning hazard over a feature a person steps
        // around. Rivers and harbours are orders of magnitude larger, so an area floor keeps them
        // and drops the decoration.
        let floodableRings = waterRings.filter { Self.ringArea($0) >= Self.minimumWaterAreaSquareMeters }

        let surfaceLevel = Self.waterLevel(rings: floodableRings, halfSpan: halfSpan, elevation: ground)
        let waterModel = WaterSurfaceModel.rasterizing(
            rings: floodableRings,
            halfSpan: halfSpan,
            level: surfaceLevel
        )
        self.water = waterModel

        // Buildings stand on the terrain, not on a base height baked at import time.
        //
        // The importer stored each building's `baseElevationMeters` from a separate reading, so the
        // roof-level DEM and the footprint base disagreed: a building could sit metres above the
        // ground drawn under it or be buried to its second floor. Re-seating every building on the
        // *same* height field the terrain is built from is the only thing that keeps them consistent,
        // and it has to be the bare-earth field, or a building would climb onto its own rooftop.
        let seatedBuildings = buildings.map { building -> UAVWorldBuilding in
            var copy = building
            // Seated on the *lowest* ground under the footprint, not the centroid.
            //
            // A footprint spans several terrain cells, and on any slope the centroid sits above the
            // downhill corner — so a building seated at its centre floats along its lower edge, which
            // is exactly the small gap seen from the air. Taking the minimum over the outline, and
            // sinking a further skirt below it, guarantees the walls meet the ground everywhere; the
            // cost is the uphill side being buried a little, which reads as a building cut into the
            // slope rather than hovering over it.
            var lowest = Float.greatestFiniteMagnitude
            for vertex in building.footprint {
                lowest = min(lowest, OpenDataWorldRuntime.terrainHeight(
                    x: vertex.x,
                    z: vertex.y,
                    elevation: ground,
                    water: waterModel,
                    waterLevel: surfaceLevel
                ))
            }
            if !lowest.isFinite {
                lowest = OpenDataWorldRuntime.terrainHeight(
                    x: building.centroid.x, z: building.centroid.y,
                    elevation: ground, water: waterModel, waterLevel: surfaceLevel
                )
            }
            copy.baseElevationMeters = lowest - Self.buildingFoundationSkirtMeters
            return copy
        }

        let assembly = UAVWorldSceneAssembler.assemble(buildings: seatedBuildings)
        self.rootNode = assembly.root

        var corners = Self.groundCorners(
            halfSpan: halfSpan,
            elevation: ground,
            water: waterModel,
            waterLevel: surfaceLevel
        )
        let groundCornerCount = corners.count
        for building in seatedBuildings {
            for triangle in UAVWorldBuildingGeometryFactory.makeCollisionTriangles(for: building) {
                corners.append(triangle.point0)
                corners.append(triangle.point1)
                corners.append(triangle.point2)
            }
        }
        self.collision = MeshCollisionIndex(triangleCorners: corners)
        self.worldBounds = collision.bounds

        // Something to actually see standing on.
        //
        // Installing an imported world hides the procedural ground plane, on the reasonable
        // assumption that the world brings its own. A photogrammetric tile does; this one only
        // brought *collision* ground, so the aircraft rested on a surface that was provably there —
        // 676 of 676 columns answered the support query — and completely invisible, leaving the city
        // floating over open sky.

        // With relief, the collision surface *is* the visible ground, so a flat placeholder under it
        // would only poke through the valleys.
        if ground == nil {
            let plane = UAVWorldSceneAssembler.makePlaceholderGround(spanMeters: halfSpan * 2)
            plane.castsShadow = false
            rootNode.insertChildNode(plane, at: 0)
        } else if let terrain = TerrainMeshFactory.makeNode(
            corners: Array(corners.prefix(groundCornerCount))
        ) {
            rootNode.insertChildNode(terrain, at: 0)
        }

        // Drawn a little under the ground plane so the shoreline is a clean edge rather than two
        // coplanar surfaces fighting for the depth buffer — a fight this project has already lost
        // once, at a cost of several days, on the photogrammetric side.
        if let waterModel, let surface = WaterSurfaceGeometryFactory.makeNode(for: waterModel) {
            surface.position.y = -0.02
            rootNode.insertChildNode(surface, at: 1)
        }
    }

    /// How far the furthest building corner sits from the origin.
    private static func buildingReachMeters(_ buildings: [UAVWorldBuilding]) -> Float {
        var reach: Float = 0
        for building in buildings {
            for point in building.footprint {
                reach = max(reach, max(abs(point.x), abs(point.y)))
            }
        }
        return reach
    }

    /// Half the world's side length, in scene metres, taken from the manifest's geographic bounds.
    private static func halfSpanMeters(of manifest: UAVWorldManifest) -> Float {
        let bounds = manifest.bounds
        let origin = manifest.origin
        let corner = origin.localMeters(
            of: GeoCoordinate(
                latitudeDegrees: bounds.maximumLatitudeDegrees,
                longitudeDegrees: bounds.maximumLongitudeDegrees,
                altitudeMetersMSL: 0
            )
        )
        let half = Float(max(abs(corner.x), abs(corner.z)))
        return half.isFinite && half > 50 ? half : 500
    }

    /// The ground, tiled — flat when there is no elevation data, following the relief when there is.
    ///
    /// Tiled rather than two big triangles because the collision index is a uniform grid: a triangle
    /// spanning the whole world would be registered in every cell of it, and every ray query would
    /// then have to consider it. Tiles near the index's own cell size keep queries local.
    ///
    /// It also has to exist at all. An imported world with no ground under the aircraft is not
    /// merely featureless — the support query returns nothing, the ground height stays at zero
    /// while the aircraft is somewhere else entirely, and the flight model free-falls. That failure
    /// has already been diagnosed once from a startup log, and it is not worth reproducing.
    /// Median elevation over the water cells, never below sea level.
    private static func waterLevel(
        rings: [[SIMD2<Float>]],
        halfSpan: Float,
        elevation: TerrariumElevationSource.Grid?
    ) -> Float {
        guard let elevation, !rings.isEmpty else { return 0 }
        guard let probe = WaterSurfaceModel.rasterizing(
            rings: rings,
            halfSpan: halfSpan,
            level: 0
        ) else { return 0 }

        var samples: [Float] = []
        var row = 0
        while row < probe.rows {
            var column = 0
            while column < probe.columns {
                if probe.isWaterCell(column: column, row: row) {
                    let x = probe.minimum.x + (Float(column) + 0.5) * probe.cellSize
                    let z = probe.minimum.y + (Float(row) + 0.5) * probe.cellSize
                    samples.append(elevation.height(x: x, z: z))
                }
                column += 4
            }
            row += 4
        }
        guard !samples.isEmpty else { return 0 }
        samples.sort()
        return max(0, samples[samples.count / 2])
    }

    /// How far below the local water datum the ground is allowed to reach.
    ///
    /// Deep enough for a genuine depression — the lowest dry land on Earth is a few hundred metres
    /// down — and shallow enough that a stray bathymetry sample cannot pull a ground tile into the
    /// abyss and leave a spike hanging across the sky.
    private static let maximumDepressionBelowWater: Float = 60.0

    /// Smallest water body kept — a 20 m pond. Below this is fountains and reflecting pools.
    private static let minimumWaterAreaSquareMeters: Float = 400.0

    /// How far a building's base is sunk below the lowest ground under it, closing the last gap.
    private static let buildingFoundationSkirtMeters: Float = 1.0

    /// Absolute area of a closed ring in square metres (shoelace).
    private static func ringArea(_ ring: [SIMD2<Float>]) -> Float {
        guard ring.count >= 3 else { return 0 }
        var sum: Float = 0
        for index in ring.indices {
            let a = ring[index]
            let b = ring[(index + 1) % ring.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) * 0.5
    }

    /// The one place that turns an elevation grid, water mask and datum into a ground height.
    ///
    /// Both the terrain surface and every building's base go through this, so the two cannot drift
    /// apart — which is exactly how buildings ended up floating and half-buried when each had its own
    /// idea of where the ground was. Under water it returns the water surface, because the seabed is
    /// not a place an aircraft can rest.
    static func terrainHeight(
        x: Float,
        z: Float,
        elevation: TerrariumElevationSource.Grid?,
        water: WaterSurfaceModel?,
        waterLevel: Float
    ) -> Float {
        guard let elevation else { return 0 }
        if water?.isWater(x: x, z: z) == true { return waterLevel }
        return max(elevation.height(x: x, z: z), waterLevel - maximumDepressionBelowWater)
    }

    private static func groundCorners(
        halfSpan: Float,
        elevation: TerrariumElevationSource.Grid?,
        water: WaterSurfaceModel?,
        waterLevel: Float
    ) -> [SIMD3<Float>] {
        // Finer tiles when there is relief to resolve: a 25 m tile would step a hillside into
        // staircases the aircraft could catch a leg on, while on flat ground it costs nothing.
        let tile: Float = elevation == nil ? 25.0 : 12.0
        let steps = max(2, Int((halfSpan * 2 / tile).rounded(.up)))
        var corners: [SIMD3<Float>] = []
        corners.reserveCapacity(steps * steps * 6)

        for column in 0..<steps {
            for row in 0..<steps {
                let x0 = -halfSpan + Float(column) * tile
                let z0 = -halfSpan + Float(row) * tile
                let x1 = min(x0 + tile, halfSpan)
                let z1 = min(z0 + tile, halfSpan)
                func height(_ x: Float, _ z: Float) -> Float {
                    terrainHeight(x: x, z: z, elevation: elevation, water: water, waterLevel: waterLevel)
                }
                let a = SIMD3<Float>(x0, height(x0, z0), z0)
                let b = SIMD3<Float>(x1, height(x1, z0), z0)
                let c = SIMD3<Float>(x1, height(x1, z1), z1)
                let d = SIMD3<Float>(x0, height(x0, z1), z1)
                // Wound so the face points up. This list feeds the collision index, which does not
                // care, *and* the visible terrain, which very much does: emitted the other way the
                // ground was back-face culled from above and lit from beneath, so the world had no
                // floor and the tiles seen edge-on read as black slabs hanging in the sky.
                corners.append(contentsOf: [a, c, b])
                corners.append(contentsOf: [a, d, c])
            }
        }
        return corners
    }
}
