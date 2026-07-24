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
        osmSurfaceFeatures: UAVWorldOSMSurfaceFeatures = .empty,
        elevation: TerrariumElevationSource.Grid? = nil
    ) {
        self.origin = manifest.origin
        self.identifier = manifest.identifier
        self.displayName = manifest.displayName
        // Feature-specific corrections belong in the tag-driven importer, never in runtime ID
        // lists. This keeps the same rules valid for every package and every OSM object.
        let renderableBuildings = buildings
        self.buildingCount = renderableBuildings.count

        // Ground has to reach at least as far as the things standing on it.
        //
        // The requested extent alone is not enough: Overpass returns whole ways, so a building that
        // straddles the boundary is imported complete and stands beyond it. Measured on Lower
        // Manhattan, buildings reached z 842 against a requested half-span of 500 — and the spawn
        // search duly picked a rooftop 36 m up, because out there it was the only surface in
        // existence and there was no ground beneath it to prefer.
        let halfSpan = max(
            Self.halfSpanMeters(of: manifest),
            Self.buildingReachMeters(renderableBuildings),
            Self.surfaceFeatureReachMeters(osmSurfaceFeatures)
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

        // Packages made before closed OSM piers were queried without requiring `area=yes` can
        // legitimately contain a waterfront building but lack the matching pier ring. Recover
        // those packages at load time instead of asking the user to rebuild the world: if the
        // centre and a clear majority of a building's outline lie in the uncut OSM water
        // envelope, its exact footprint is an authoritative minimum support deck. This does not
        // move the coastline or invent a broad island; it only prevents water from passing through
        // an opaque building. New imports normally get the larger, explicit OSM pier polygon.
        var envelopeGeometry = floodableGeometry
        envelopeGeometry.landRings = []
        envelopeGeometry.landInnerRings = []
        let waterEnvelope = WaterSurfaceModel.rasterizing(
            geometry: envelopeGeometry,
            halfSpan: halfSpan,
            level: surfaceLevel
        )
        let inferredBuildingSupports = Self.inferredWaterfrontBuildingSupports(
            buildings: renderableBuildings,
            waterEnvelope: waterEnvelope
        )
        floodableGeometry.landRings.append(contentsOf: inferredBuildingSupports)
        #if DEBUG
        if !inferredBuildingSupports.isEmpty {
            print(
                "[OpenDataWorld] recovered \(inferredBuildingSupports.count) "
                + "waterfront building support footprint(s)"
            )
        }
        #endif

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
        let seatedBuildings = renderableBuildings.map { building -> UAVWorldBuilding in
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
        let osmAssembly = OSMSurfaceGeometryFactory.assemble(
            features: osmSurfaceFeatures,
            buildings: seatedBuildings,
            water: waterModel
        ) { x, z in
            Self.terrainHeight(
                x: x,
                z: z,
                elevation: ground,
                water: waterModel,
                mappedLand: pierModel,
                waterLevel: surfaceLevel
            )
        }
        if !osmAssembly.root.childNodes.isEmpty {
            rootNode.addChildNode(osmAssembly.root)
        }

        // Collision must be the surface the pilot sees. The old collision terrain was an
        // independent 12 m grid which continued through water and cut diagonally across the exact
        // 1 m shoreline. Those hidden triangles were the "invisible wall" under the Battery.
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
        corners.append(contentsOf: osmAssembly.collisionCorners)
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
        // made its shoreline triangles protrude through the 1 m water mask as the large beige teeth
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
        // robust where triangulation is fragile. The remaining sub-metre stepping follows the
        // one-metre semantic mask and is below the positional precision of the source coastline.
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

    private static func surfaceFeatureReachMeters(
        _ features: UAVWorldOSMSurfaceFeatures
    ) -> Float {
        var reach: Float = 0
        for feature in features.transport {
            for point in feature.centerline {
                reach = max(reach, max(abs(point.x), abs(point.y)) + feature.widthMeters)
            }
        }
        for area in features.vegetationAreas {
            for point in area.outerRing {
                reach = max(reach, max(abs(point.x), abs(point.y)))
            }
        }
        for area in features.bridgeAreas {
            for point in area.outerRing {
                reach = max(reach, max(abs(point.x), abs(point.y)))
            }
        }
        for tree in features.trees {
            reach = max(reach, max(abs(tree.position.x), abs(tree.position.y)) + 3)
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

    /// Only sub-pixel slivers are rejected. Every mapped pond, fountain and reflecting pool is a
    /// visible OSM water feature; the old 400 m² cut-off contradicted the package-wide import.
    private static let minimumWaterAreaSquareMeters: Float = 4.0

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

    /// Finds opaque buildings which are predominantly on the marine side of the OSM shoreline.
    ///
    /// Vertices alone can all sit on the water side of a concave footprint while most of its area
    /// remains on land, so every edge midpoint is sampled too. Requiring the centroid to be wet and
    /// at least 60% of all probes to be wet keeps an ordinary shoreline building from being
    /// reclassified because one corner crosses a shoreline raster cell.
    private static func inferredWaterfrontBuildingSupports(
        buildings: [UAVWorldBuilding],
        waterEnvelope: WaterSurfaceModel?
    ) -> [[SIMD2<Float>]] {
        guard let waterEnvelope else { return [] }

        return buildings.compactMap { building in
            let footprint = building.footprint
            guard footprint.count >= 3,
                  ringArea(footprint) >= minimumWaterfrontBuildingAreaSquareMeters,
                  waterEnvelope.isWater(
                    x: building.centroid.x,
                    z: building.centroid.y
                  ) else {
                return nil
            }

            var probes: [SIMD2<Float>] = [building.centroid]
            probes.reserveCapacity(footprint.count * 2 + 1)
            for index in footprint.indices {
                let current = footprint[index]
                let next = footprint[(index + 1) % footprint.count]
                probes.append(current)
                probes.append((current + next) * 0.5)
            }

            let wetProbeCount = probes.reduce(into: 0) { count, probe in
                if waterEnvelope.isWater(x: probe.x, z: probe.y) {
                    count += 1
                }
            }
            let wetFraction = Float(wetProbeCount) / Float(probes.count)
            return wetFraction >= minimumWaterfrontBuildingWetFraction ? footprint : nil
        }
    }

    /// Ignores tiny sheds and kiosks which may sit beside a rasterised shoreline cell.
    private static let minimumWaterfrontBuildingAreaSquareMeters: Float = 40.0

    private static let minimumWaterfrontBuildingWetFraction: Float = 0.60

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
    /// Twelve-by-twelve groups of wholly dry cells use one coarse 12 m centre fan whose perimeter
    /// retains every one-metre grid point. Groups touching the shoreline become the matching marching-
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
        let blockSize = 12
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
            // Every contour edge is a pair of consecutive shoreline points in the polygon's cyclic
            // order. Walking that order matters: sorting two indices reverses the closing edge
            // (last → first), flipping its normal and producing the alternating black/grey triangles
            // seen along an otherwise straight quay. Handling all consecutive pairs also closes both
            // sides of an ambiguous diagonal cell, whose connected land polygon has four shoreline
            // points rather than two.
            for index in polygon.indices {
                let next = polygon.index(after: index) == polygon.endIndex
                    ? polygon.startIndex
                    : polygon.index(after: index)
                guard polygon[index].isShoreline, polygon[next].isShoreline else { continue }
                let topA = top[index]
                let topB = top[next]
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

            // Keep every one-metre boundary vertex even though the block interior is coarse.
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

                            // In the diagonal saddle, water deliberately remains two disconnected
                            // corner triangles (see WaterSurfaceGeometryFactory). Land must therefore
                            // be the connected six-point complement. Splitting *both* materials into
                            // corner triangles leaves the central diamond completely uncovered — the
                            // blue holes through the world visible around the narrow mapped piers.
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

// MARK: - OSM roads, bridges and vegetation

/// Batched SceneKit geometry for every persisted OSM surface feature.
///
/// The factory consumes semantic classes, never feature IDs. It therefore behaves identically for
/// a single village road and for every street in Manhattan, and produces bridge/tree collision from
/// the same triangles that are visible.
@MainActor
private enum OSMSurfaceGeometryFactory {
    struct Assembly {
        let root: SCNNode
        let collisionCorners: [SIMD3<Float>]
    }

    private enum RoadMaterialKey: Hashable {
        case motorway, arterial, street, service, pedestrian, track, railway, bridgeSide
    }

    static func assemble(
        features: UAVWorldOSMSurfaceFeatures,
        buildings: [UAVWorldBuilding],
        water: WaterSurfaceModel?,
        terrainHeight: (Float, Float) -> Float
    ) -> Assembly {
        let root = SCNNode()
        root.name = "world.osm.surface-features"
        var collision: [SIMD3<Float>] = []

        var roadCorners: [RoadMaterialKey: [SIMD3<Float>]] = [:]
        for feature in features.transport where feature.centerline.count >= 2 {
            appendTransport(
                feature,
                terrainHeight: terrainHeight,
                corners: &roadCorners,
                collision: &collision
            )
        }
        var bridgeAreaTopCorners: [SIMD3<Float>] = []
        var bridgeAreaSideCorners: [SIMD3<Float>] = []
        for area in features.bridgeAreas {
            appendBridgeArea(
                area,
                terrainHeight: terrainHeight,
                corners: &bridgeAreaTopCorners,
                sideCorners: &bridgeAreaSideCorners,
                collision: &collision
            )
        }
        roadCorners[.service, default: []].append(contentsOf: bridgeAreaTopCorners)
        roadCorners[.bridgeSide, default: []].append(contentsOf: bridgeAreaSideCorners)
        for (key, corners) in roadCorners {
            guard let node = makeNode(
                corners: corners,
                color: roadColor(key),
                roughness: key == .railway ? 0.62 : 0.92
            ) else { continue }
            node.name = "world.osm.transport.\(key)"
            node.castsShadow = key == .bridgeSide
            root.addChildNode(node)
        }

        var vegetationCorners: [UAVWorldVegetationKind: [SIMD3<Float>]] = [:]
        for area in features.vegetationAreas {
            appendVegetationCover(
                area,
                terrainHeight: terrainHeight,
                into: &vegetationCorners[area.kind, default: []]
            )
        }
        for (kind, corners) in vegetationCorners {
            guard let node = makeNode(
                corners: corners,
                color: vegetationColor(kind),
                roughness: 1
            ) else { continue }
            node.name = "world.osm.vegetation.\(kind.rawValue)"
            node.castsShadow = false
            root.addChildNode(node)
        }

        var candidates = features.trees.map {
            (
                identifier: $0.sourceIdentifier,
                position: $0.position,
                kind: $0.kind
            )
        }
        candidates.append(contentsOf: generatedVegetation(
            areas: features.vegetationAreas,
            transport: features.transport,
            buildings: buildings,
            water: water
        ))

        var trunkCorners: [SIMD3<Float>] = []
        var canopyCorners: [SIMD3<Float>] = []
        for candidate in candidates {
            if water?.isWater(x: candidate.position.x, z: candidate.position.y) == true {
                continue
            }
            let seed = stableHash(candidate.identifier)
            appendPlant(
                at: candidate.position,
                kind: candidate.kind,
                seed: seed,
                ground: terrainHeight(candidate.position.x, candidate.position.y),
                trunks: &trunkCorners,
                canopies: &canopyCorners,
                collision: &collision
            )
        }
        if let trunks = makeNode(
            corners: trunkCorners,
            color: NSColor(calibratedRed: 0.24, green: 0.16, blue: 0.08, alpha: 1),
            roughness: 1
        ) {
            trunks.name = "world.osm.vegetation.trunks"
            trunks.castsShadow = true
            root.addChildNode(trunks)
        }
        if let canopies = makeNode(
            corners: canopyCorners,
            color: NSColor(calibratedRed: 0.13, green: 0.32, blue: 0.13, alpha: 1),
            roughness: 1
        ) {
            canopies.name = "world.osm.vegetation.canopies"
            canopies.castsShadow = true
            root.addChildNode(canopies)
        }

        return Assembly(root: root, collisionCorners: collision)
    }

    private static func appendTransport(
        _ feature: UAVWorldTransportFeature,
        terrainHeight: (Float, Float) -> Float,
        corners: inout [RoadMaterialKey: [SIMD3<Float>]],
        collision: inout [SIMD3<Float>]
    ) {
        let key = roadKey(feature)
        let halfWidth = max(0.35, feature.widthMeters * 0.5)
        let bridgeLift: Float
        if feature.isBridge {
            let sampled = feature.centerline.map { terrainHeight($0.x, $0.y) }
            let approachHeight = max(sampled.first ?? 0, sampled.last ?? 0)
            let lowestCrossing = sampled.min() ?? approachHeight
            bridgeLift = max(
                approachHeight + 0.2,
                lowestCrossing + feature.clearanceMeters
                    + Float(max(0, feature.layer - 1)) * 3.5
            )
        } else {
            bridgeLift = 0
        }

        for index in 0..<(feature.centerline.count - 1) {
            let start = feature.centerline[index]
            let end = feature.centerline[index + 1]
            let delta = end - start
            let length = simd_length(delta)
            guard length.isFinite, length > 0.05 else { continue }
            let perpendicular = SIMD2<Float>(-delta.y, delta.x) / length * halfWidth
            let y0 = feature.isBridge
                ? bridgeLift
                : terrainHeight(start.x, start.y) + 0.09
            let y1 = feature.isBridge
                ? bridgeLift
                : terrainHeight(end.x, end.y) + 0.09

            let a = SIMD3<Float>(start.x + perpendicular.x, y0, start.y + perpendicular.y)
            let b = SIMD3<Float>(start.x - perpendicular.x, y0, start.y - perpendicular.y)
            let c = SIMD3<Float>(end.x - perpendicular.x, y1, end.y - perpendicular.y)
            let d = SIMD3<Float>(end.x + perpendicular.x, y1, end.y + perpendicular.y)
            let top = [a, c, b, a, d, c]
            corners[key, default: []].append(contentsOf: top)
            if index > 0 {
                let joint = feature.centerline[index]
                let jointY = feature.isBridge
                    ? bridgeLift
                    : terrainHeight(joint.x, joint.y) + 0.09
                let cap = circularCap(
                    centre: SIMD3<Float>(joint.x, jointY, joint.y),
                    radius: halfWidth
                )
                corners[key, default: []].append(contentsOf: cap)
                if feature.isBridge { collision.append(contentsOf: cap) }
            }

            guard feature.isBridge else { continue }
            collision.append(contentsOf: top)
            let thickness: Float = 0.65
            let belowA = a - SIMD3<Float>(0, thickness, 0)
            let belowB = b - SIMD3<Float>(0, thickness, 0)
            let belowC = c - SIMD3<Float>(0, thickness, 0)
            let belowD = d - SIMD3<Float>(0, thickness, 0)
            let sides = [
                a, b, belowB, a, belowB, belowA,
                d, belowD, belowC, d, belowC, c,
                a, belowA, belowD, a, belowD, d,
                b, c, belowC, b, belowC, belowB
            ]
            corners[.bridgeSide, default: []].append(contentsOf: sides)
            collision.append(contentsOf: sides)
        }
    }

    private static func appendBridgeArea(
        _ area: UAVWorldBridgeArea,
        terrainHeight: (Float, Float) -> Float,
        corners: inout [SIMD3<Float>],
        sideCorners: inout [SIMD3<Float>],
        collision: inout [SIMD3<Float>]
    ) {
        guard area.outerRing.count >= 3 else { return }
        let sampled = area.outerRing.map { terrainHeight($0.x, $0.y) }
        let deck = max(
            (sampled.max() ?? 0) + 0.2,
            (sampled.min() ?? 0) + area.clearanceMeters
                + Float(max(0, area.layer - 1)) * 3.5
        )
        var topCorners: [SIMD3<Float>] = []
        if area.holes.isEmpty,
           let indices = PolygonTriangulator.triangulate(area.outerRing) {
            let vertices = area.outerRing.map { SIMD3<Float>($0.x, deck, $0.y) }
            for index in stride(from: 0, to: indices.count, by: 3) {
                topCorners.append(vertices[indices[index]])
                topCorners.append(vertices[indices[index + 2]])
                topCorners.append(vertices[indices[index + 1]])
            }
        } else {
            let minimum = area.outerRing.reduce(
                SIMD2<Float>(repeating: .greatestFiniteMagnitude),
                simd_min
            )
            let maximum = area.outerRing.reduce(
                SIMD2<Float>(repeating: -.greatestFiniteMagnitude),
                simd_max
            )
            let cell: Float = 2
            var x = floor(minimum.x / cell) * cell
            while x < maximum.x {
                var z = floor(minimum.y / cell) * cell
                while z < maximum.y {
                    let centre = SIMD2<Float>(x + 1, z + 1)
                    if pointInRing(centre, ring: area.outerRing)
                        && !area.holes.contains(where: { pointInRing(centre, ring: $0) }) {
                        let a = SIMD3<Float>(x, deck, z)
                        let b = SIMD3<Float>(x + cell, deck, z)
                        let c = SIMD3<Float>(x + cell, deck, z + cell)
                        let d = SIMD3<Float>(x, deck, z + cell)
                        topCorners.append(contentsOf: [a, c, b, a, d, c])
                    }
                    z += cell
                }
                x += cell
            }
        }
        corners.append(contentsOf: topCorners)
        collision.append(contentsOf: topCorners)

        let bottom = deck - 0.75
        for index in area.outerRing.indices {
            let current = area.outerRing[index]
            let next = area.outerRing[(index + 1) % area.outerRing.count]
            let a = SIMD3<Float>(current.x, deck, current.y)
            let b = SIMD3<Float>(next.x, deck, next.y)
            let c = SIMD3<Float>(next.x, bottom, next.y)
            let d = SIMD3<Float>(current.x, bottom, current.y)
            let faces = [a, b, c, a, c, d]
            sideCorners.append(contentsOf: faces)
            collision.append(contentsOf: faces)
        }
    }

    private static func circularCap(
        centre: SIMD3<Float>,
        radius: Float
    ) -> [SIMD3<Float>] {
        let sides = 10
        var corners: [SIMD3<Float>] = []
        corners.reserveCapacity(sides * 3)
        for index in 0..<sides {
            let angle0 = Float(index) / Float(sides) * .pi * 2
            let angle1 = Float(index + 1) / Float(sides) * .pi * 2
            let a = SIMD3<Float>(
                centre.x + cos(angle0) * radius,
                centre.y,
                centre.z + sin(angle0) * radius
            )
            let b = SIMD3<Float>(
                centre.x + cos(angle1) * radius,
                centre.y,
                centre.z + sin(angle1) * radius
            )
            corners.append(contentsOf: [centre, b, a])
        }
        return corners
    }

    private static func appendVegetationCover(
        _ area: UAVWorldVegetationArea,
        terrainHeight: (Float, Float) -> Float,
        into corners: inout [SIMD3<Float>]
    ) {
        guard area.outerRing.count >= 3 else { return }
        if area.holes.isEmpty,
           let indices = PolygonTriangulator.triangulate(area.outerRing) {
            let vertices = area.outerRing.map {
                SIMD3<Float>($0.x, terrainHeight($0.x, $0.y) + 0.035, $0.y)
            }
            for index in stride(from: 0, to: indices.count, by: 3) {
                // Ring indices are CCW in XZ, hence reversed for +Y SceneKit faces.
                corners.append(vertices[indices[index]])
                corners.append(vertices[indices[index + 2]])
                corners.append(vertices[indices[index + 1]])
            }
            return
        }

        // Polygons with holes use a deterministic occupancy grid. Every inner ring is respected,
        // and only the complicated cases pay for the extra triangles.
        let minimum = area.outerRing.reduce(
            SIMD2<Float>(repeating: .greatestFiniteMagnitude),
            simd_min
        )
        let maximum = area.outerRing.reduce(
            SIMD2<Float>(repeating: -.greatestFiniteMagnitude),
            simd_max
        )
        let cell: Float = 6
        var x = floor(minimum.x / cell) * cell
        while x < maximum.x {
            var z = floor(minimum.y / cell) * cell
            while z < maximum.y {
                let centre = SIMD2<Float>(x + cell * 0.5, z + cell * 0.5)
                if contains(centre, in: area) {
                    let a = SIMD3<Float>(x, terrainHeight(x, z) + 0.035, z)
                    let b = SIMD3<Float>(x + cell, terrainHeight(x + cell, z) + 0.035, z)
                    let c = SIMD3<Float>(
                        x + cell,
                        terrainHeight(x + cell, z + cell) + 0.035,
                        z + cell
                    )
                    let d = SIMD3<Float>(x, terrainHeight(x, z + cell) + 0.035, z + cell)
                    corners.append(contentsOf: [a, c, b, a, d, c])
                }
                z += cell
            }
            x += cell
        }
    }

    private static func generatedVegetation(
        areas: [UAVWorldVegetationArea],
        transport: [UAVWorldTransportFeature],
        buildings: [UAVWorldBuilding],
        water: WaterSurfaceModel?
    ) -> [(identifier: String, position: SIMD2<Float>, kind: UAVWorldVegetationKind)] {
        var result: [(String, SIMD2<Float>, UAVWorldVegetationKind)] = []
        let maximumGeneratedPlants = 4_000

        for area in areas {
            guard result.count < maximumGeneratedPlants else { break }
            let spacing: Float
            switch area.kind {
            case .forest: spacing = 18
            case .orchard: spacing = 12
            case .scrub: spacing = 16
            case .garden: spacing = 28
            case .grass, .meadow: continue
            }
            let minimum = area.outerRing.reduce(
                SIMD2<Float>(repeating: .greatestFiniteMagnitude),
                simd_min
            )
            let maximum = area.outerRing.reduce(
                SIMD2<Float>(repeating: -.greatestFiniteMagnitude),
                simd_max
            )
            let seed = stableHash(area.sourceIdentifier)
            let offset = SIMD2<Float>(
                Float(seed & 0xffff) / 65_535 * spacing,
                Float((seed >> 16) & 0xffff) / 65_535 * spacing
            )
            var x = floor(minimum.x / spacing) * spacing + offset.x
            while x <= maximum.x, result.count < maximumGeneratedPlants {
                var z = floor(minimum.y / spacing) * spacing + offset.y
                while z <= maximum.y, result.count < maximumGeneratedPlants {
                    let point = SIMD2<Float>(x, z)
                    if contains(point, in: area),
                       water?.isWater(x: x, z: z) != true,
                       !insideAnyBuilding(point, buildings: buildings),
                       !nearTransport(point, transport: transport) {
                        result.append((
                            "\(area.sourceIdentifier)/generated-\(result.count)",
                            point,
                            area.kind
                        ))
                    }
                    z += spacing
                }
                x += spacing
            }
        }
        return result
    }

    private static func appendPlant(
        at position: SIMD2<Float>,
        kind: UAVWorldVegetationKind,
        seed: UInt64,
        ground: Float,
        trunks: inout [SIMD3<Float>],
        canopies: inout [SIMD3<Float>],
        collision: inout [SIMD3<Float>]
    ) {
        let variation = Float(seed & 0xffff) / 65_535
        let shrub = kind == .scrub
        let height: Float = shrub ? 1.8 + variation : 5.5 + variation * 4
        let trunkHeight = shrub ? height * 0.25 : height * 0.55
        let trunkRadius: Float = shrub ? 0.12 : 0.20 + variation * 0.08
        let canopyRadius: Float = shrub ? 1.1 : 1.4 + variation * 0.8
        let sides = 6

        let trunkBottom = ground + 0.02
        let trunkTop = trunkBottom + trunkHeight
        for index in 0..<sides {
            let next = (index + 1) % sides
            let angle0 = Float(index) / Float(sides) * .pi * 2
            let angle1 = Float(next) / Float(sides) * .pi * 2
            let a = SIMD3<Float>(
                position.x + cos(angle0) * trunkRadius,
                trunkBottom,
                position.y + sin(angle0) * trunkRadius
            )
            let b = SIMD3<Float>(
                position.x + cos(angle1) * trunkRadius,
                trunkBottom,
                position.y + sin(angle1) * trunkRadius
            )
            let c = SIMD3<Float>(b.x, trunkTop, b.z)
            let d = SIMD3<Float>(a.x, trunkTop, a.z)
            let face = [a, c, b, a, d, c]
            trunks.append(contentsOf: face)
            collision.append(contentsOf: face)
        }

        let canopyBottom = trunkTop - (shrub ? 0.25 : 0.8)
        let canopyTop = ground + height
        let top = SIMD3<Float>(position.x, canopyTop, position.y)
        let bottom = SIMD3<Float>(position.x, canopyBottom, position.y)
        for index in 0..<sides {
            let next = (index + 1) % sides
            let angle0 = Float(index) / Float(sides) * .pi * 2
            let angle1 = Float(next) / Float(sides) * .pi * 2
            let a = SIMD3<Float>(
                position.x + cos(angle0) * canopyRadius,
                canopyBottom,
                position.y + sin(angle0) * canopyRadius
            )
            let b = SIMD3<Float>(
                position.x + cos(angle1) * canopyRadius,
                canopyBottom,
                position.y + sin(angle1) * canopyRadius
            )
            let faces = [a, top, b, a, b, bottom]
            canopies.append(contentsOf: faces)
            collision.append(contentsOf: faces)
        }
    }

    private static func makeNode(
        corners: [SIMD3<Float>],
        color: NSColor,
        roughness: CGFloat
    ) -> SCNNode? {
        guard let node = TerrainMeshFactory.makeNode(corners: corners) else { return nil }
        let material = node.geometry?.firstMaterial
        material?.diffuse.contents = color
        material?.roughness.contents = roughness
        material?.metalness.contents = 0
        material?.isDoubleSided = true
        return node
    }

    private static func roadKey(_ feature: UAVWorldTransportFeature) -> RoadMaterialKey {
        if let surface = feature.surface?.lowercased(),
           ["unpaved", "dirt", "earth", "ground", "gravel", "fine_gravel", "sand",
            "grass", "mud", "woodchips"].contains(surface) {
            return .track
        }
        switch feature.kind {
        case .motorway: return .motorway
        case .arterial: return .arterial
        case .street: return .street
        case .service: return .service
        case .pedestrian: return .pedestrian
        case .track: return .track
        case .railway: return .railway
        }
    }

    private static func roadColor(_ key: RoadMaterialKey) -> NSColor {
        switch key {
        case .motorway: return NSColor(calibratedWhite: 0.12, alpha: 1)
        case .arterial: return NSColor(calibratedWhite: 0.16, alpha: 1)
        case .street: return NSColor(calibratedWhite: 0.19, alpha: 1)
        case .service: return NSColor(calibratedWhite: 0.23, alpha: 1)
        case .pedestrian: return NSColor(calibratedRed: 0.42, green: 0.40, blue: 0.35, alpha: 1)
        case .track: return NSColor(calibratedRed: 0.31, green: 0.25, blue: 0.17, alpha: 1)
        case .railway: return NSColor(calibratedWhite: 0.10, alpha: 1)
        case .bridgeSide: return NSColor(calibratedWhite: 0.13, alpha: 1)
        }
    }

    private static func vegetationColor(_ kind: UAVWorldVegetationKind) -> NSColor {
        switch kind {
        case .forest: return NSColor(calibratedRed: 0.12, green: 0.25, blue: 0.12, alpha: 1)
        case .grass: return NSColor(calibratedRed: 0.31, green: 0.43, blue: 0.22, alpha: 1)
        case .meadow: return NSColor(calibratedRed: 0.38, green: 0.48, blue: 0.24, alpha: 1)
        case .scrub: return NSColor(calibratedRed: 0.24, green: 0.34, blue: 0.18, alpha: 1)
        case .orchard: return NSColor(calibratedRed: 0.29, green: 0.40, blue: 0.20, alpha: 1)
        case .garden: return NSColor(calibratedRed: 0.34, green: 0.46, blue: 0.25, alpha: 1)
        }
    }

    private static func contains(_ point: SIMD2<Float>, in area: UAVWorldVegetationArea) -> Bool {
        pointInRing(point, ring: area.outerRing)
            && !area.holes.contains { pointInRing(point, ring: $0) }
    }

    private static func pointInRing(_ point: SIMD2<Float>, ring: [SIMD2<Float>]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var previous = ring.count - 1
        for index in ring.indices {
            let a = ring[index]
            let b = ring[previous]
            if (a.y > point.y) != (b.y > point.y) {
                let x = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < x { inside.toggle() }
            }
            previous = index
        }
        return inside
    }

    private static func insideAnyBuilding(
        _ point: SIMD2<Float>,
        buildings: [UAVWorldBuilding]
    ) -> Bool {
        buildings.contains {
            pointInRing(point, ring: $0.footprint)
                && !$0.holes.contains { pointInRing(point, ring: $0) }
        }
    }

    private static func nearTransport(
        _ point: SIMD2<Float>,
        transport: [UAVWorldTransportFeature]
    ) -> Bool {
        for feature in transport {
            let clearance = feature.widthMeters * 0.5 + 1.5
            let threshold = clearance * clearance
            for index in 0..<(feature.centerline.count - 1) {
                if distanceSquared(
                    point,
                    toSegmentFrom: feature.centerline[index],
                    to: feature.centerline[index + 1]
                ) <= threshold {
                    return true
                }
            }
        }
        return false
    }

    private static func distanceSquared(
        _ point: SIMD2<Float>,
        toSegmentFrom a: SIMD2<Float>,
        to b: SIMD2<Float>
    ) -> Float {
        let delta = b - a
        let denominator = simd_length_squared(delta)
        guard denominator > 0.000_001 else { return simd_length_squared(point - a) }
        let t = max(0, min(1, simd_dot(point - a, delta) / denominator))
        return simd_length_squared(point - (a + delta * t))
    }

    private static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
