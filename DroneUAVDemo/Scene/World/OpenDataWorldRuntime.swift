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
/// The important difference is what open vector data does *not* contain: relief. OSM supplies the
/// building and shoreline geometry; a stored Terrarium grid supplies elevation, and a flat datum is
/// used only when that optional layer is unavailable. Both still enter the same ground-height
/// contract as the procedural presets.
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
        waterGeometry: UAVWorldWaterGeometry = .empty,
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
        // First pass has no water mask yet and is used only to establish a non-coastal lake datum.
        // Once water is rasterised, the final pass excludes bathymetry from the land filter so a
        // harbour sounding cannot turn the neighbouring quay into a pit.
        let preliminaryGround = elevation?.bareEarth()

        // The water's *surface*, which is not the lowest number in the elevation grid.
        //
        // Terrarium carries bathymetry — depth below the sea, not height of the ground you can stand
        // on. Taking the grid minimum as the water level put New York Bay's water plane at −969 m,
        // which is the ocean floor: the water vanished from sight, and the ground tiles reaching down
        // to it became the spikes hanging under a city that appeared to float. Taking the median over
        // water cells and flooring at sea level gives the right answer for both a coast and a lake.
        // Only water a UAV could actually ditch in. Tiny fountains are real OSM water but do not
        // belong in the flight model; the authoritative river outline, its islands and its mapped
        // piers keep their distinct roles. Shape/compactness is deliberately not a filter: a long,
        // narrow canal is valid water, while malformed open coastline members are now rejected at
        // the source instead of guessed into closed polygons here.
        var floodableGeometry = waterGeometry
        floodableGeometry.outerRings = waterGeometry.outerRings.filter {
            Self.ringArea($0) >= Self.minimumWaterAreaSquareMeters
        }
        #if DEBUG
        print("[OpenDataWorld] OSM water: \(waterGeometry.outerRings.count) outer → "
              + "\(floodableGeometry.outerRings.count) floodable, "
              + "\(waterGeometry.innerRings.count) islands, "
              + "\(waterGeometry.landRings.count) mapped land/pier areas, "
              + "\(waterGeometry.coastlineSegments.count) coastline ways")
        #endif

        let surfaceLevel = Self.waterLevel(
            geometry: floodableGeometry,
            halfSpan: halfSpan,
            elevation: preliminaryGround,
            marineLevel: Float(-manifest.origin.coordinate.altitudeMetersMSL)
        )
        let waterModel = WaterSurfaceModel.rasterizing(
            geometry: floodableGeometry,
            halfSpan: halfSpan,
            level: surfaceLevel
        )
        // Keep the coastal relief correction tied to the sea itself. The complete water model also
        // contains inland OSM polygons (for example reflecting pools); using that as a proximity mask
        // would quietly flatten legitimate city terrain around every pond in a coastal world.
        let coastlineGeometry = UAVWorldWaterGeometry(
            outerRings: [],
            innerRings: [],
            // This is only a filter mask. Leave mapped piers submerged here so their DEM samples
            // cannot be altered; the separate pier model supplies their explicit deck height.
            landRings: [],
            landInnerRings: [],
            coastlineSegments: floodableGeometry.coastlineSegments
        )
        let coastalWaterModel = WaterSurfaceModel.rasterizing(
            geometry: coastlineGeometry,
            halfSpan: halfSpan,
            level: surfaceLevel
        )
        let minimumCoastalDrySample = floodableGeometry.coastlineSegments.isEmpty
            ? nil
            : surfaceLevel - 0.5
        let filteredGround = waterModel == nil
            ? preliminaryGround
            : elevation?.bareEarth(
                excluding: waterModel,
                rejectingDrySamplesBelow: minimumCoastalDrySample
            )
        let ground: TerrariumElevationSource.Grid?
        if let filteredGround,
           let elevation,
           let coastalWaterModel,
           let minimumCoastalDrySample {
            ground = filteredGround.suppressingCoastalSurfacePlateaus(
                near: coastalWaterModel,
                usingDryMaskFrom: elevation,
                rejectingDrySamplesBelow: minimumCoastalDrySample,
                radiusCells: Self.coastalSurfacePlateauRadiusCells,
                maximumRiseAboveLocalLowMeters: Self.maximumCoastalRiseAboveLocalLowMeters,
                maximumLocalLowAboveWaterMeters: Self.maximumCoastalLowlandHeightMeters
            )
        } else {
            ground = filteredGround
        }
        // The uncut water envelope is used only to recognise waterfront structures when seating
        // buildings. It is not rendered and does not affect water physics.
        var envelopeGeometry = floodableGeometry
        envelopeGeometry.landRings = []
        envelopeGeometry.landInnerRings = []
        let waterEnvelope = WaterSurfaceModel.rasterizing(
            geometry: envelopeGeometry,
            halfSpan: halfSpan,
            level: surfaceLevel
        )
        let pierGeometry = UAVWorldWaterGeometry(
            outerRings: floodableGeometry.landRings,
            innerRings: floodableGeometry.landInnerRings,
            landRings: [],
            landInnerRings: []
        )
        let pierModel = WaterSurfaceModel.rasterizing(
            geometry: pierGeometry,
            halfSpan: halfSpan,
            level: surfaceLevel + Self.pierDeckHeightAboveWater,
            // A one-cell pier tip is still authoritative mapped land. Generic water de-noising
            // removes isolated wet cells, which is useful for a river mask and destructive when
            // this auxiliary mask represents narrow man-made decks.
            denoise: false
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
                    mappedLand: pierModel,
                    waterLevel: surfaceLevel
                ))
            }
            if !lowest.isFinite {
                lowest = OpenDataWorldRuntime.terrainHeight(
                    x: building.centroid.x, z: building.centroid.y,
                    elevation: ground,
                    water: waterModel,
                    mappedLand: pierModel,
                    waterLevel: surfaceLevel
                )
            }
            let base = lowest - Self.buildingFoundationSkirtMeters
            let probes = building.footprint + [building.centroid]
            let touchesMappedWater = probes.contains {
                waterEnvelope?.isWater(x: $0.x, z: $0.y) == true
            }
            // Clamp only waterfront structures. The previous unconditional sea-level clamp lifted
            // every inland building by 25 cm; piers need the protection, city blocks do not.
            copy.baseElevationMeters = touchesMappedWater
                ? max(base, surfaceLevel + Self.visibleWaterOffset)
                : base
            return copy
        }

        let assembly = UAVWorldSceneAssembler.assemble(buildings: seatedBuildings)
        self.rootNode = assembly.root

        // Collision must be the surface the pilot sees. The old collision terrain was an
        // independent 12 m grid which continued through water and cut diagonally across the exact
        // 2 m shoreline. Those hidden triangles were the "invisible wall" under the Battery.
        // Reuse the clipped render mesh instead; water remains semantic (immersion/sinking), not a
        // solid floor an aircraft can land on.
        let waterClippedGround = waterModel.map {
            Self.visibleGroundGeometry(
                water: $0,
                elevation: ground,
                mappedLand: pierModel,
                waterLevel: surfaceLevel + Self.visibleWaterOffset
            )
        }
        let collisionGroundCorners: [SIMD3<Float>]
        if let waterClippedGround {
            // The short quay face is visible geometry and therefore belongs in collision as well;
            // unlike the old independent under-water grid, it cannot stop the aircraft somewhere
            // the pilot sees as empty space.
            collisionGroundCorners = waterClippedGround.surfaceCorners
                + waterClippedGround.shorelineWallCorners
        } else {
            collisionGroundCorners = Self.groundCorners(
                halfSpan: halfSpan,
                elevation: ground,
                water: waterModel,
                mappedLand: pierModel,
                waterLevel: surfaceLevel
            )
        }
        var corners = collisionGroundCorners
        for building in seatedBuildings {
            for triangle in UAVWorldBuildingGeometryFactory.makeCollisionTriangles(for: building) {
                corners.append(triangle.point0)
                corners.append(triangle.point1)
                corners.append(triangle.point2)
            }
        }
        self.collision = MeshCollisionIndex(triangleCorners: corners)
        self.worldBounds = (
            minimum: SIMD3<Float>(
                -halfSpan,
                collision.bounds.minimum.y,
                -halfSpan
            ),
            maximum: SIMD3<Float>(
                halfSpan,
                collision.bounds.maximum.y,
                halfSpan
            )
        )

        // Something to actually see standing on.
        //
        // Installing an imported world hides the procedural ground plane, on the reasonable
        // assumption that the world brings its own. A photogrammetric tile does; this one only
        // brought *collision* ground, so the aircraft rested on a surface that was provably there —
        // 676 of 676 columns answered the support query — and completely invisible, leaving the city
        // floating over open sky.

        // Water and land must share one contour. Reusing the coarse 12 m collision terrain visually
        // made its shoreline triangles protrude through the 2 m water mask as the large beige teeth
        // seen in the screenshots. Around water, build an adaptive land mesh from the same mask;
        // inland it still collapses to coarse blocks, while boundary cells meet the water exactly.
        if waterModel != nil,
           let waterClippedGround,
           let terrain = TerrainMeshFactory.makeNode(corners: waterClippedGround.surfaceCorners) {
            terrain.name = "world.terrain.water-clipped"
            rootNode.insertChildNode(terrain, at: 0)
            if let shoreline = TerrainMeshFactory.makeNode(
                corners: waterClippedGround.shorelineWallCorners
            ) {
                shoreline.name = "world.terrain.shoreline"
                shoreline.geometry?.firstMaterial?.diffuse.contents = NSColor(
                    calibratedRed: 0.34,
                    green: 0.35,
                    blue: 0.32,
                    alpha: 1
                )
                rootNode.insertChildNode(shoreline, at: 1)
            }
        } else if ground == nil {
            let plane = UAVWorldSceneAssembler.makePlaceholderGround(spanMeters: halfSpan * 2)
            plane.castsShadow = false
            rootNode.insertChildNode(plane, at: 0)
        } else if let terrain = TerrainMeshFactory.makeNode(corners: collisionGroundCorners) {
            rootNode.insertChildNode(terrain, at: 0)
        }

        // Visible water is rasterised from the mask, not triangulated from the polygons.
        //
        // Building it from the rings would give smooth banks, and was tried — but real OSM water
        // polygons are self-touching and non-simple, and the ear-clipping triangulator rejected 15
        // of 15 of them, so the water simply vanished. The grid does not care about polygon
        // simplicity: it asks "is this cell inside any ring" and nothing else, which is why it is
        // robust where triangulation is fragile. The cost is a stair-stepped shoreline at the cell
        // size; that is the honest trade for water that is actually always there.
        if let waterModel, let surface = WaterSurfaceGeometryFactory.makeNode(for: waterModel) {
            // Lift the visible sheet slightly to make the water line unambiguous. The semantic
            // physics datum stays at `waterModel.level`; there is deliberately no solid collision
            // floor under the river.
            surface.simdPosition.y = Self.visibleWaterOffset
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
        geometry: UAVWorldWaterGeometry,
        halfSpan: Float,
        elevation: TerrariumElevationSource.Grid?,
        marineLevel: Float
    ) -> Float {
        guard !geometry.isEmpty else { return 0 }

        // A directed OSM coastline means this is connected marine water, whose datum is mean sea
        // level. Sampling Terrarium here is actively wrong: its coarse coastal pixels mix low land,
        // roofs and harbour soundings, and their median lifted New York Harbor to +2.4 m. The
        // subsequent dry-sample rejection then deleted the real 0–2 m Battery shoreline and filled
        // it from inland values, producing the 7–9 m ridge seen in flight. Lakes still need their
        // local elevation inferred below; the sea does not.
        if !geometry.coastlineSegments.isEmpty {
            return marineLevel
        }

        guard let elevation else { return 0 }
        guard let probe = WaterSurfaceModel.rasterizing(
            geometry: geometry,
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

    /// Rendering-only separation from the semantic water datum, avoiding shoreline z-fighting.
    private static let visibleWaterOffset: Float = 0.08

    /// Mapped pier decks sit just above the visible water sheet and participate in collision.
    private static let pierDeckHeightAboveWater: Float = 0.18

    /// The coastal DEM filter looks six 20 m Terrarium samples in every direction.
    private static let coastalSurfacePlateauRadiusCells = 6

    /// Lower Manhattan's waterfront is low and flat; allow local relief without retaining roofs.
    private static let maximumCoastalRiseAboveLocalLowMeters: Float = 2.0

    /// Never apply the lowland correction to a genuinely elevated coast or cliff.
    private static let maximumCoastalLowlandHeightMeters: Float = 5.0

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
        mappedLand: WaterSurfaceModel?,
        waterLevel: Float
    ) -> Float {
        if let mappedLand, mappedLand.isWater(x: x, z: z) {
            // An OSM pier already has a semantic deck. Terrarium is a surface model here and often
            // reports the roof of a pier building instead; taking the larger value turns the whole
            // footprint into a several-metre cliff. Keep the explicit deck datum instead.
            return mappedLand.level
        }
        guard let elevation else { return 0 }
        if water?.isWater(x: x, z: z) == true { return waterLevel }
        return max(elevation.height(x: x, z: z), waterLevel - maximumDepressionBelowWater)
    }

    /// Visible land tessellated against the exact same cell-centre contour as the water surface.
    ///
    /// Six-by-six groups of wholly dry cells use one coarse 12 m centre fan whose perimeter retains
    /// every two-metre grid point. Groups touching the shoreline become the matching marching-
    /// squares complement. The common perimeter prevents LOD cracks without turning the entire
    /// 1.7 km city into a uniform million-triangle terrain mesh.
    private struct VisibleGroundGeometry {
        var surfaceCorners: [SIMD3<Float>] = []
        var shorelineWallCorners: [SIMD3<Float>] = []
    }

    private static func visibleGroundGeometry(
        water: WaterSurfaceModel,
        elevation: TerrariumElevationSource.Grid?,
        mappedLand: WaterSurfaceModel?,
        waterLevel: Float
    ) -> VisibleGroundGeometry {
        let blockSize = 6
        var result = VisibleGroundGeometry()
        result.surfaceCorners.reserveCapacity(
            ((water.columns / blockSize) + 2) * ((water.rows / blockSize) + 2) * 6
        )

        func centre(_ column: Int, _ row: Int) -> SIMD2<Float> {
            SIMD2<Float>(
                water.minimum.x + (Float(column) + 0.5) * water.cellSize,
                water.minimum.y + (Float(row) + 0.5) * water.cellSize
            )
        }

        let maximum = SIMD2<Float>(
            water.minimum.x + Float(water.columns) * water.cellSize,
            water.minimum.y + Float(water.rows) * water.cellSize
        )

        func clampedToWorld(_ point: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2<Float>(
                max(water.minimum.x, min(maximum.x, point.x)),
                max(water.minimum.y, min(maximum.y, point.y))
            )
        }

        func isMappedLand(_ point: SIMD2<Float>) -> Bool {
            mappedLand?.isWater(x: point.x, z: point.y) == true
        }

        func dryHeight(_ point: SIMD2<Float>, mappedLandHint: Bool? = nil) -> Float {
            if mappedLandHint ?? isMappedLand(point), let mappedLand {
                return mappedLand.level
            }
            let measuredHeight = elevation?.height(x: point.x, z: point.y) ?? waterLevel
            // Lower Manhattan's waterfront is reclaimed, nearly level land ending at quays and
            // ferry slips. Pulling every dry vertex down toward the water over 24 m turned each
            // narrow real pier into an invented ridge. Preserve the filtered DEM right to the OSM
            // coastline; a separate visible shoreline face connects it to the water.
            return max(measuredHeight, waterLevel)
        }

        func dryVertex(_ point: SIMD2<Float>) -> SIMD3<Float> {
            // Marching squares samples one synthetic dry centre outside the mask so water closes
            // exactly on the world boundary. Clamp the terrain half of that square to the boundary;
            // otherwise its one-metre outside lip appears as the long grey line on the horizon.
            let bounded = clampedToWorld(point)
            return SIMD3<Float>(bounded.x, dryHeight(bounded), bounded.y)
        }

        func appendSurfaceTriangle(
            _ first: SIMD3<Float>,
            _ second: SIMD3<Float>,
            _ third: SIMD3<Float>
        ) {
            let cross = simd_cross(second - first, third - first)
            let areaSquared = simd_length_squared(cross)
            guard areaSquared.isFinite, areaSquared > 0.000_000_01 else { return }
            result.surfaceCorners.append(contentsOf: [first, second, third])
        }

        func appendShorelineWallTriangle(
            _ first: SIMD3<Float>,
            _ second: SIMD3<Float>,
            _ third: SIMD3<Float>
        ) {
            let cross = simd_cross(second - first, third - first)
            let areaSquared = simd_length_squared(cross)
            guard areaSquared.isFinite, areaSquared > 0.000_000_01 else { return }
            result.shorelineWallCorners.append(contentsOf: [first, second, third])
        }

        func shorelinePoint(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
            (a + b) * 0.5
        }

        typealias LandPoint = (
            position: SIMD2<Float>,
            isShoreline: Bool,
            isMappedLand: Bool
        )

        func appendPolygon(_ polygon: [LandPoint]) {
            guard polygon.count >= 3 else { return }
            let top = polygon.map { point -> SIMD3<Float> in
                let bounded = clampedToWorld(point.position)
                return SIMD3<Float>(
                    bounded.x,
                    dryHeight(bounded, mappedLandHint: point.isMappedLand),
                    bounded.y
                )
            }
            // XZ perimeter order is counter-clockwise, hence reversed here for an upward +Y face.
            for index in 1..<(top.count - 1) {
                appendSurfaceTriangle(top[0], top[index + 1], top[index])
            }

            // The top stays faithful to the bare-earth DEM; this matching skirt closes the short
            // quay face to the water. Both are used for collision, so every solid face is visible;
            // the unrelated terrain grid which used to continue invisibly under the river is gone.
            let shorelineIndices = polygon.indices.filter { polygon[$0].isShoreline }
            if shorelineIndices.count == 2 {
                let topA = top[shorelineIndices[0]]
                let topB = top[shorelineIndices[1]]
                let bottomA = SIMD3<Float>(topA.x, waterLevel, topA.z)
                let bottomB = SIMD3<Float>(topB.x, waterLevel, topB.z)
                appendShorelineWallTriangle(topA, bottomB, bottomA)
                appendShorelineWallTriangle(topA, topB, bottomB)
            }
        }

        func appendDryBlock(
            from startColumn: Int,
            _ startRow: Int,
            to endColumn: Int,
            _ endRow: Int
        ) {
            guard startColumn < endColumn, startRow < endRow else { return }

            // Keep every two-metre boundary vertex even though the block interior is coarse.
            // A neighbouring mixed shoreline block uses those same vertices. The previous two-
            // triangle quad skipped the intermediate points, creating a T-junction: its straight
            // edge and the detailed neighbour had different heights between the endpoints, leaving
            // the triangular blue/white cracks visible in grazing views.
            var perimeter: [SIMD3<Float>] = []
            perimeter.reserveCapacity((endColumn - startColumn + endRow - startRow) * 2)
            for column in startColumn..<endColumn {
                perimeter.append(dryVertex(centre(column, startRow)))
            }
            for row in startRow..<endRow {
                perimeter.append(dryVertex(centre(endColumn, row)))
            }
            for column in stride(from: endColumn, to: startColumn, by: -1) {
                perimeter.append(dryVertex(centre(column, endRow)))
            }
            for row in stride(from: endRow, to: startRow, by: -1) {
                perimeter.append(dryVertex(centre(startColumn, row)))
            }
            guard perimeter.count >= 3 else { return }

            let centrePoint = (
                centre(startColumn, startRow) + centre(endColumn, endRow)
            ) * 0.5
            let blockCentre = dryVertex(centrePoint)
            for index in perimeter.indices {
                let next = perimeter.index(after: index) == perimeter.endIndex
                    ? perimeter.startIndex
                    : perimeter.index(after: index)
                // The perimeter walks counter-clockwise in XZ; reverse for an upward +Y face.
                appendSurfaceTriangle(blockCentre, perimeter[next], perimeter[index])
            }
        }

        var blockRow = -1
        while blockRow < water.rows {
            let endRow = min(blockRow + blockSize, water.rows)
            var blockColumn = -1
            while blockColumn < water.columns {
                let endColumn = min(blockColumn + blockSize, water.columns)
                var wetCount = 0
                var sampleCount = 0
                for row in blockRow...endRow {
                    for column in blockColumn...endColumn {
                        sampleCount += 1
                        if water.isWaterCell(column: column, row: row) { wetCount += 1 }
                    }
                }

                if wetCount == 0 {
                    appendDryBlock(
                        from: blockColumn,
                        blockRow,
                        to: endColumn,
                        endRow
                    )
                } else if wetCount < sampleCount {
                    for row in blockRow..<endRow {
                        for column in blockColumn..<endColumn {
                            let cornerColumns = [column, column + 1, column + 1, column]
                            let cornerRows = [row, row, row + 1, row + 1]
                            let positions = (0..<4).map {
                                centre(cornerColumns[$0], cornerRows[$0])
                            }
                            let dry = (0..<4).map {
                                !water.isWaterCell(column: cornerColumns[$0], row: cornerRows[$0])
                            }
                            guard dry.contains(true) else { continue }

                            let diagonalSaddle = dry[0] == dry[2]
                                && dry[1] == dry[3]
                                && dry[0] != dry[1]
                            if diagonalSaddle {
                                for index in 0..<4 where dry[index] {
                                    let previous = (index + 3) % 4
                                    let next = (index + 1) % 4
                                    let mapped = isMappedLand(positions[index])
                                    appendPolygon([
                                        (positions[index], false, mapped),
                                        (
                                            shorelinePoint(positions[index], positions[next]),
                                            true,
                                            mapped
                                        ),
                                        (
                                            shorelinePoint(positions[previous], positions[index]),
                                            true,
                                            mapped
                                        )
                                    ])
                                }
                                continue
                            }

                            var polygon: [LandPoint] = []
                            for index in 0..<4 {
                                if dry[index] {
                                    polygon.append((
                                        positions[index],
                                        false,
                                        isMappedLand(positions[index])
                                    ))
                                }
                                let next = (index + 1) % 4
                                if dry[index] != dry[next] {
                                    let dryIndex = dry[index] ? index : next
                                    polygon.append((
                                        shorelinePoint(positions[index], positions[next]),
                                        true,
                                        isMappedLand(positions[dryIndex])
                                    ))
                                }
                            }
                            appendPolygon(polygon)
                        }
                    }
                }

                blockColumn = endColumn
            }
            blockRow = endRow
        }
        return result
    }

    private static func groundCorners(
        halfSpan: Float,
        elevation: TerrariumElevationSource.Grid?,
        water: WaterSurfaceModel?,
        mappedLand: WaterSurfaceModel?,
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
                    terrainHeight(
                        x: x,
                        z: z,
                        elevation: elevation,
                        water: water,
                        mappedLand: mappedLand,
                        waterLevel: waterLevel
                    )
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
