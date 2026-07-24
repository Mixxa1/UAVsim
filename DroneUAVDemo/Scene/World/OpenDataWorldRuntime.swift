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

        // Ground roads stay in per-class buckets; bridge geometry is kept entirely apart so it can
        // keep real depth writes (an elevated deck must occlude what is under it) while flat roads
        // give theirs up.
        var roadCorners: [RoadMaterialKey: [SIMD3<Float>]] = [:]
        var bridgeDeckCorners: [SIMD3<Float>] = []
        var bridgeSideCorners: [SIMD3<Float>] = []
        var bridgePillarCorners: [SIMD3<Float>] = []
        // Built once from every way so a viaduct or interchange split across several bridge ways
        // stays continuously elevated at its shared nodes instead of each way diving to the ground.
        let bridgeNetwork = BridgeNetwork(transport: features.transport)
        let obstacleIndex = BuildingObstacleIndex(buildings: buildings)
        // Platform deck levels, precomputed so a way crossing a platform can ride on its slab (and
        // leave the supporting to the platform's own piers) instead of slicing through it.
        let platforms: [(ring: [SIMD2<Float>], level: Float)] = features.bridgeAreas.compactMap {
            guard $0.outerRing.count >= 3 else { return nil }
            return ($0.outerRing, platformDeckLevel($0, terrainHeight: terrainHeight))
        }
        for feature in features.transport where feature.centerline.count >= 2 {
            appendTransport(
                feature,
                terrainHeight: terrainHeight,
                network: bridgeNetwork,
                buildings: buildings,
                obstacles: obstacleIndex,
                platforms: platforms,
                roadCorners: &roadCorners,
                bridgeDeck: &bridgeDeckCorners,
                bridgeSides: &bridgeSideCorners,
                bridgePillars: &bridgePillarCorners,
                collision: &collision
            )
        }
        for area in features.bridgeAreas {
            appendBridgeArea(
                area,
                terrainHeight: terrainHeight,
                buildings: buildings,
                deck: &bridgeDeckCorners,
                sideCorners: &bridgeSideCorners,
                pillars: &bridgePillarCorners,
                collision: &collision
            )
        }

        // Flat roads are coplanar decals: overlaps resolve by paint order, not depth. A footway and
        // the street it crosses no longer z-fight (the old striping) and no longer sit at visibly
        // different heights (the sharp cut-out steps the height band traded the striping for). Each
        // class paints over the one below in a fixed order and writes no depth of its own; the
        // terrain beneath still occludes them because the terrain does write depth.
        for (key, corners) in roadCorners {
            guard let node = makeNode(
                corners: corners,
                color: roadColor(key),
                roughness: key == .railway ? 0.62 : 0.92
            ) else { continue }
            node.name = "world.osm.transport.\(key)"
            node.castsShadow = false
            node.renderingOrder = roadRenderingOrder(key)
            node.geometry?.firstMaterial?.writesToDepthBuffer = false
            root.addChildNode(node)
        }

        // Bridges are genuine 3-D structures: normal depth and shadows, drawn after the flat roads.
        if let deck = makeNode(corners: bridgeDeckCorners, color: roadColor(.motorway), roughness: 0.92) {
            deck.name = "world.osm.bridge.deck"
            deck.castsShadow = true
            root.addChildNode(deck)
        }
        if let bridgeSides = makeNode(corners: bridgeSideCorners, color: roadColor(.bridgeSide), roughness: 0.9) {
            bridgeSides.name = "world.osm.bridge.sides"
            bridgeSides.castsShadow = true
            root.addChildNode(bridgeSides)
        }
        if let pillars = makeNode(
            corners: bridgePillarCorners,
            color: NSColor(calibratedWhite: 0.30, alpha: 1),
            roughness: 0.95
        ) {
            pillars.name = "world.osm.bridge.pillars"
            pillars.castsShadow = true
            root.addChildNode(pillars)
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
        let treeRoot = SCNNode()
        treeRoot.name = "world.osm.vegetation.trees"
        for candidate in candidates {
            if water?.isWater(x: candidate.position.x, z: candidate.position.y) == true {
                continue
            }
            let seed = stableHash(candidate.identifier)
            let ground = terrainHeight(candidate.position.x, candidate.position.y)
            let metrics = plantMetrics(kind: candidate.kind, seed: seed)

            if let tree = PineTreeAssetLoader.shared.makeTreeNode(
                targetHeightMeters: metrics.height,
                yaw: metrics.yaw
            ) {
                // `clone()` shares the one loaded geometry and material, so a forest of thousands
                // costs the memory of a single tree while SceneKit still frustum-culls each instance
                // — the reason not to `flattenedClone` (that bakes 5.6k triangles per tree into one
                // un-cullable buffer, ~gigabytes at this count). Collision uses the cheap procedural
                // trunk+canopy proxy below, not the model's full foliage mesh, which the airframe
                // could never feel the difference against and which would bloat the collision index.
                tree.position = SCNVector3(candidate.position.x, ground, candidate.position.y)
                treeRoot.addChildNode(tree)
                appendPlant(
                    at: candidate.position,
                    seed: seed,
                    ground: ground,
                    height: metrics.height,
                    shrub: metrics.shrub,
                    emitVisual: false,
                    trunks: &trunkCorners,
                    canopies: &canopyCorners,
                    collision: &collision
                )
            } else {
                // Model unavailable — fall back to the original procedural cone tree, drawn as well
                // as collided so the world is never treeless when the asset is missing.
                appendPlant(
                    at: candidate.position,
                    seed: seed,
                    ground: ground,
                    height: metrics.height,
                    shrub: metrics.shrub,
                    emitVisual: true,
                    trunks: &trunkCorners,
                    canopies: &canopyCorners,
                    collision: &collision
                )
            }
        }
        if !treeRoot.childNodes.isEmpty {
            root.addChildNode(treeRoot)
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

    /// Which OSM nodes a bridge deck must ramp down to versus stay elevated over. An **abutment** —
    /// a node shared with a ground road, or a dangling end — is where the deck touches down onto the
    /// road. An **interior joint** — a node shared with another bridge way but no ground road — is
    /// where two bridge ways meet in the air and the deck must stay up. Built once for the whole
    /// world so a viaduct split into several ways, or an interchange of ramps, forms one continuous
    /// elevated structure rather than each way independently diving to the ground between segments.
    private struct BridgeNetwork {
        private let groundNodes: Set<Int64>
        private let bridgeTouch: [Int64: Int]
        private let nodeClearance: [Int64: Float]

        init(transport: [UAVWorldTransportFeature]) {
            var ground: Set<Int64> = []
            var touch: [Int64: Int] = [:]
            var clearance: [Int64: Float] = [:]
            for feature in transport where feature.centerline.count >= 2 {
                if feature.isBridge {
                    // Layer folds into the node elevation so stacked decks that genuinely share a
                    // node agree on one height including the stacking bump.
                    let clamped = min(max(feature.clearanceMeters, 2.0), 9.0)
                        + Float(max(0, feature.layer - 1)) * 3.5
                    var seen: Set<Int64> = []
                    for point in feature.centerline {
                        let k = Self.key(point)
                        if seen.insert(k).inserted { touch[k, default: 0] += 1 }
                        clearance[k] = max(clearance[k] ?? 0, clamped)
                    }
                } else {
                    for point in feature.centerline { ground.insert(Self.key(point)) }
                }
            }
            groundNodes = ground
            bridgeTouch = touch
            nodeClearance = clearance
        }

        /// Stays up only where a node is shared with another bridge way *and* is not anchored to a
        /// ground road. Abutments and dangling ends return false, so the deck ramps down there.
        func isInteriorJoint(_ point: SIMD2<Float>) -> Bool {
            let k = Self.key(point)
            return !groundNodes.contains(k) && (bridgeTouch[k] ?? 0) >= 2
        }

        /// The elevation of an interior joint above its terrain — the max clearance of the ways that
        /// meet there, so every way arriving at the node agrees on one height and they join cleanly.
        func jointClearance(_ point: SIMD2<Float>) -> Float {
            nodeClearance[Self.key(point)] ?? 5.5
        }

        /// Quantise to a 0.5 m grid so shared OSM nodes hash together despite float drift.
        private static func key(_ point: SIMD2<Float>) -> Int64 {
            pack(
                Int32((point.x / 0.5).rounded()),
                Int32((point.y / 0.5).rounded())
            )
        }

        private static func pack(_ qx: Int32, _ qy: Int32) -> Int64 {
            (Int64(qx) << 32) | Int64(UInt32(bitPattern: qy))
        }
    }

    /// Coarse spatial hash of building tops, so an elevated deck can ask "what stands under me?"
    /// without scanning the whole city for every resampled deck vertex.
    @MainActor
    struct BuildingObstacleIndex {
        private static let cellSize: Float = 48
        private var cells: [Int64: [Int]] = [:]
        private let buildings: [UAVWorldBuilding]

        init(buildings: [UAVWorldBuilding]) {
            self.buildings = buildings
            for (index, building) in buildings.enumerated() {
                guard building.footprint.count >= 3 else { continue }
                let minimum = building.footprint.reduce(
                    SIMD2<Float>(repeating: .greatestFiniteMagnitude),
                    simd_min
                )
                let maximum = building.footprint.reduce(
                    SIMD2<Float>(repeating: -.greatestFiniteMagnitude),
                    simd_max
                )
                let x0 = Int32((minimum.x / Self.cellSize).rounded(.down))
                let x1 = Int32((maximum.x / Self.cellSize).rounded(.down))
                let y0 = Int32((minimum.y / Self.cellSize).rounded(.down))
                let y1 = Int32((maximum.y / Self.cellSize).rounded(.down))
                for cx in x0...x1 {
                    for cy in y0...y1 {
                        cells[(Int64(cx) << 32) | Int64(UInt32(bitPattern: cy)), default: []]
                            .append(index)
                    }
                }
            }
        }

        /// The highest building top (roof included) standing at `point`, or nil for open ground.
        func top(at point: SIMD2<Float>) -> Float? {
            let cx = Int32((point.x / Self.cellSize).rounded(.down))
            let cy = Int32((point.y / Self.cellSize).rounded(.down))
            guard let candidates = cells[(Int64(cx) << 32) | Int64(UInt32(bitPattern: cy))]
            else { return nil }
            var best: Float?
            for index in candidates {
                let building = buildings[index]
                guard OSMSurfaceGeometryFactory.pointInRing(point, ring: building.footprint),
                      !building.holes.contains(where: {
                          OSMSurfaceGeometryFactory.pointInRing(point, ring: $0)
                      })
                else { continue }
                let top = building.baseElevationMeters + building.totalHeightMeters
                best = max(best ?? top, top)
            }
            return best
        }
    }

    private static func appendTransport(
        _ feature: UAVWorldTransportFeature,
        terrainHeight: (Float, Float) -> Float,
        network: BridgeNetwork,
        buildings: [UAVWorldBuilding],
        obstacles: BuildingObstacleIndex,
        platforms: [(ring: [SIMD2<Float>], level: Float)],
        roadCorners: inout [RoadMaterialKey: [SIMD3<Float>]],
        bridgeDeck: inout [SIMD3<Float>],
        bridgeSides: inout [SIMD3<Float>],
        bridgePillars: inout [SIMD3<Float>],
        collision: inout [SIMD3<Float>]
    ) {
        let key = roadKey(feature)
        let halfWidth = max(0.35, feature.widthMeters * 0.5)

        // Any `bridge=yes` way becomes a real ramped deck. The profile inside appendElevatedBridge
        // meets the road at its abutments and stays elevated at joints shared with other bridge ways,
        // so a lone overpass arches and touches down while a multi-way viaduct/interchange stays up.
        if feature.isBridge {
            appendElevatedBridge(
                feature,
                halfWidth: halfWidth,
                terrainHeight: terrainHeight,
                network: network,
                buildings: buildings,
                obstacles: obstacles,
                platforms: platforms,
                deck: &bridgeDeck,
                sides: &bridgeSides,
                pillars: &bridgePillars,
                collision: &collision
            )
            return
        }

        // Ground road: a terrain-draped ribbon. Heights used to be sampled only at the way's own
        // vertices, and wherever the terrain bulged more than the road offset between two vertices
        // the depth-writing ground rose through the decal and cut jagged notches out of it. Draping
        // fixes that: the centreline is resampled every few metres and *each edge vertex* of the
        // ribbon sits on the terrain under it, so the strip twists and climbs with the ground it
        // paints. Mitred joints (per-sample averaged direction) replace the old circular joint caps
        // — a continuous ribbon has no turn gaps to patch. Every road top is a landable, collidable
        // ledge, so the airframe rests on the asphalt it sees instead of the ground beneath it.
        var pathPoints: [SIMD2<Float>] = []
        let step: Float = 5
        for index in 0..<(feature.centerline.count - 1) {
            let start = feature.centerline[index]
            let end = feature.centerline[index + 1]
            let length = simd_length(end - start)
            guard length.isFinite, length > 0.05 else { continue }
            let divisions = max(1, Int((length / step).rounded(.up)))
            for division in 0..<divisions {
                pathPoints.append(start + (end - start) * (Float(division) / Float(divisions)))
            }
        }
        if let last = feature.centerline.last { pathPoints.append(last) }
        guard pathPoints.count >= 2 else { return }

        var leftEdge: [SIMD3<Float>] = []
        var rightEdge: [SIMD3<Float>] = []
        leftEdge.reserveCapacity(pathPoints.count)
        rightEdge.reserveCapacity(pathPoints.count)
        for index in pathPoints.indices {
            let previous = pathPoints[max(index - 1, 0)]
            let next = pathPoints[min(index + 1, pathPoints.count - 1)]
            let direction = next - previous
            let length = simd_length(direction)
            guard length > 0.001 else { continue }
            let perpendicular = SIMD2<Float>(-direction.y, direction.x) / length * halfWidth
            let left = pathPoints[index] + perpendicular
            let right = pathPoints[index] - perpendicular
            leftEdge.append(SIMD3<Float>(
                left.x,
                terrainHeight(left.x, left.y) + roadPlaneOffset,
                left.y
            ))
            rightEdge.append(SIMD3<Float>(
                right.x,
                terrainHeight(right.x, right.y) + roadPlaneOffset,
                right.y
            ))
        }
        for index in 0..<(min(leftEdge.count, rightEdge.count) - 1) {
            let a = leftEdge[index]
            let b = rightEdge[index]
            let c = rightEdge[index + 1]
            let d = leftEdge[index + 1]
            let top = [a, c, b, a, d, c]
            roadCorners[key, default: []].append(contentsOf: top)
            collision.append(contentsOf: top)
        }
    }

    /// A real overpass with genuine approaches, not a slab.
    ///
    /// Every vertex of the way that the network recognises — an end, a node shared with a ground
    /// road, or an aerial joint with another bridge way (including one landing on the *middle* of
    /// this way) — becomes a height anchor. The deck is then resampled every few metres between
    /// anchors: OSM bridge ways are frequently just two endpoints (22 of 37 in the Manhattan
    /// package), and computing heights only at vertices left the entire ramp/arch profile invisible.
    /// Between anchors the profile eases smoothly; it arches over the crossing only when both
    /// anchors sit on the ground. Where the deck runs close to the terrain its sides extend down
    /// into the ground as a solid embankment (the approach); where it stands clear it keeps a thin
    /// skirt and piers. Deck, sides and piers all keep real depth writes.
    private static func appendElevatedBridge(
        _ feature: UAVWorldTransportFeature,
        halfWidth: Float,
        terrainHeight: (Float, Float) -> Float,
        network: BridgeNetwork,
        buildings: [UAVWorldBuilding],
        obstacles: BuildingObstacleIndex,
        platforms: [(ring: [SIMD2<Float>], level: Float)],
        deck: inout [SIMD3<Float>],
        sides: inout [SIMD3<Float>],
        pillars: inout [SIMD3<Float>],
        collision: inout [SIMD3<Float>]
    ) {
        let raw = feature.centerline
        guard raw.count >= 2 else { return }
        var arcs: [Float] = [0]
        arcs.reserveCapacity(raw.count)
        for index in 0..<(raw.count - 1) {
            arcs.append(arcs[index] + simd_length(raw[index + 1] - raw[index]))
        }
        guard let totalLength = arcs.last, totalLength > 0.1 else { return }

        // Clamped so an over-tagged `min_height` cannot send the deck into orbit.
        let clearance = min(max(feature.clearanceMeters, 2.0), 9.0)
            + Float(max(0, feature.layer - 1)) * 3.5
        let thickness: Float = 0.65

        // Height anchors. Ends always anchor (joint stays up, anything else touches the road);
        // interior vertices anchor only where another bridge way genuinely meets this one in the
        // air. Deliberately NOT anchored: interior vertices that merely share a quantised cell with
        // a ground road — the road passing *under* the deck lands in the same 0.5 m cell, and
        // anchoring there made decks dive to the ground mid-span.
        var anchors: [(arc: Float, height: Float, onGround: Bool)] = []
        for (index, point) in raw.enumerated() {
            let ground = terrainHeight(point.x, point.y)
            if network.isInteriorJoint(point) {
                anchors.append((arcs[index], ground + network.jointClearance(point), false))
            } else if index == 0 || index == raw.count - 1 {
                anchors.append((arcs[index], ground + roadPlaneOffset, true))
            }
        }
        guard anchors.count >= 2 else { return }

        // Dense profile: the way resampled every ~4 m, so ramps and arches exist in the geometry
        // regardless of how few vertices OSM used.
        struct Sample {
            let position: SIMD2<Float>
            let arc: Float
            let ground: Float
            var height: Float
        }
        var samples: [Sample] = []
        let step: Float = 4
        for index in 0..<(raw.count - 1) {
            let start = raw[index]
            let end = raw[index + 1]
            let length = simd_length(end - start)
            guard length > 0.01 else { continue }
            let divisions = max(1, Int((length / step).rounded(.up)))
            for division in 0..<divisions {
                let t = Float(division) / Float(divisions)
                let position = start + (end - start) * t
                samples.append(Sample(
                    position: position,
                    arc: arcs[index] + length * t,
                    ground: terrainHeight(position.x, position.y),
                    height: 0
                ))
            }
        }
        if let last = raw.last {
            samples.append(Sample(
                position: last,
                arc: totalLength,
                ground: terrainHeight(last.x, last.y),
                height: 0
            ))
        }
        guard samples.count >= 2 else { return }

        for span in 0..<(anchors.count - 1) {
            let from = anchors[span]
            let to = anchors[span + 1]
            let spanLength = max(to.arc - from.arc, 0.01)
            let indices = samples.indices.filter {
                samples[$0].arc >= from.arc - 0.01 && samples[$0].arc <= to.arc + 0.01
            }
            let spanGroundLow = indices.map { samples[$0].ground }.min()
                ?? min(from.height, to.height)
            // Only a ground-to-ground span needs its own arch; a ramp up to a joint or a segment
            // between two joints is fully described by its anchor heights.
            let arch = from.onGround && to.onGround
            let plateau = spanGroundLow + clearance
            // A 6 m culvert must not balloon into a full-clearance arch.
            let lengthScale = min(1, spanLength / 24)
            let rampLength = max(4, min(spanLength * 0.4, 30))

            // OSM geometry is flat latitude/longitude — a bridge way carries NO altitude of its
            // own, only tags — so nothing in the data stops a deck from slicing through a building
            // whose footprint it crosses. Ask the building index what actually stands under the
            // span and lift the whole hump over it (roof + 2 m), capped so one skyscraper with bad
            // height data cannot launch the bridge into the sky. Near the abutments the ramp still
            // wins — a deck cannot both clear a building at the ramp's foot and reach the ground.
            let obstacleTop = indices
                .compactMap { obstacles.top(at: samples[$0].position) }
                .max()
            let obstacleCeiling = min(
                obstacleTop.map { $0 + 2 } ?? -.greatestFiniteMagnitude,
                spanGroundLow + 35
            )

            for sampleIndex in indices {
                let sample = samples[sampleIndex]
                let u = (sample.arc - from.arc) / spanLength
                let eased = u * u * (3 - 2 * u)
                var height = from.height + (to.height - from.height) * eased
                let linear = from.height + (to.height - from.height) * u
                let distanceToEnd = min(sample.arc - from.arc, to.arc - sample.arc)
                let ramp = min(1, distanceToEnd / rampLength)
                let smooth = ramp * ramp * (3 - 2 * ramp)
                var lift: Float = 0
                if arch {
                    lift = max(lift, max(0, plateau - linear) * lengthScale)
                }
                // Building clearance is never faded by span length: a short span crossing a
                // building must still climb over it.
                lift = max(lift, max(0, obstacleCeiling - linear))
                height = max(height, linear + lift * smooth)
                samples[sampleIndex].height = max(height, sample.ground + roadPlaneOffset) + 0.05
            }
        }

        // Where the way crosses a platform bridge, ride on its slab: the way and the
        // `man_made=bridge` polygon describe the same structure, and a deck arching independently
        // could dip below the slab and slice through it. The extra 0.08 keeps the path visibly on
        // top instead of coplanar-fighting the platform.
        if !platforms.isEmpty {
            for index in samples.indices {
                for platform in platforms
                where pointInRing(samples[index].position, ring: platform.ring) {
                    samples[index].height = max(samples[index].height, platform.level + 0.08)
                }
            }
        }

        // A platform can swallow the way almost whole — the Manhattan footbridge overlaps its slab
        // for 47 of its 48 metres — leaving no room inside the way's own geometry for an approach,
        // so the deck used to fall off the slab edge as a cliff. When an end that should sit on the
        // ground is still in the air, keep walking past it along the way's direction, descending at
        // a fixed ramp grade until the deck lands. In the data the path continues there as a ground
        // road, which is exactly where a real approach ramp lies.
        let rampGrade: Float = 0.45
        let extensionStep: Float = 2.5
        let landedTolerance: Float = 0.3
        if let last = anchors.last, last.onGround, samples.count >= 2 {
            var tail = samples[samples.count - 1]
            let direction = tail.position - samples[samples.count - 2].position
            let length = simd_length(direction)
            if length > 0.001 {
                let unit = direction / length
                var steps = 0
                while tail.height - (tail.ground + roadPlaneOffset + 0.05) > landedTolerance,
                      steps < 24 {
                    let position = tail.position + unit * extensionStep
                    let ground = terrainHeight(position.x, position.y)
                    tail = Sample(
                        position: position,
                        arc: tail.arc + extensionStep,
                        ground: ground,
                        height: max(
                            tail.height - rampGrade * extensionStep,
                            ground + roadPlaneOffset + 0.05
                        )
                    )
                    samples.append(tail)
                    steps += 1
                }
            }
        }
        if let first = anchors.first, first.onGround, samples.count >= 2 {
            var head = samples[0]
            let direction = head.position - samples[1].position
            let length = simd_length(direction)
            if length > 0.001 {
                let unit = direction / length
                var steps = 0
                var prefix: [Sample] = []
                while head.height - (head.ground + roadPlaneOffset + 0.05) > landedTolerance,
                      steps < 24 {
                    let position = head.position + unit * extensionStep
                    let ground = terrainHeight(position.x, position.y)
                    head = Sample(
                        position: position,
                        arc: head.arc - extensionStep,
                        ground: ground,
                        height: max(
                            head.height - rampGrade * extensionStep,
                            ground + roadPlaneOffset + 0.05
                        )
                    )
                    prefix.append(head)
                    steps += 1
                }
                samples.insert(contentsOf: prefix.reversed(), at: 0)
            }
        }

        for index in 0..<(samples.count - 1) {
            let start = samples[index]
            let end = samples[index + 1]
            let delta = end.position - start.position
            let length = simd_length(delta)
            guard length.isFinite, length > 0.02 else { continue }
            let perpendicular = SIMD2<Float>(-delta.y, delta.x) / length * halfWidth

            let a = SIMD3<Float>(start.position.x + perpendicular.x, start.height, start.position.y + perpendicular.y)
            let b = SIMD3<Float>(start.position.x - perpendicular.x, start.height, start.position.y - perpendicular.y)
            let c = SIMD3<Float>(end.position.x - perpendicular.x, end.height, end.position.y - perpendicular.y)
            let d = SIMD3<Float>(end.position.x + perpendicular.x, end.height, end.position.y + perpendicular.y)
            let top = [a, c, b, a, d, c]
            deck.append(contentsOf: top)
            collision.append(contentsOf: top)

            // Solid embankment where the deck hugs the ground (the approaches), hanging skirt where
            // it flies. Both close the structure visually; the embankment is what makes the ramp
            // read as an earthwork entrance instead of a floating wedge.
            let bottom0 = start.height - start.ground < 1.2 ? start.ground - 0.3 : start.height - thickness
            let bottom1 = end.height - end.ground < 1.2 ? end.ground - 0.3 : end.height - thickness
            let belowA = SIMD3<Float>(a.x, bottom0, a.z)
            let belowB = SIMD3<Float>(b.x, bottom0, b.z)
            let belowC = SIMD3<Float>(c.x, bottom1, c.z)
            let belowD = SIMD3<Float>(d.x, bottom1, d.z)
            let side = [
                a, b, belowB, a, belowB, belowA,
                d, belowD, belowC, d, belowC, c,
                a, belowA, belowD, a, belowD, d,
                b, c, belowC, b, belowC, belowB
            ]
            sides.append(contentsOf: side)
            collision.append(contentsOf: side)
        }

        // Piers every ~18 m along the resampled profile, only under genuinely elevated deck, never
        // inside a building footprint (a pier through a roof reads worse than a missing one) and
        // never inside a platform bridge — there the slab's own pier row does the supporting, and a
        // way pier would poke up beside the narrow deck as a mystery column standing on the bridge.
        let pillarHalf = min(max(halfWidth * 0.35, 0.6), 2.0)
        var lastPierArc: Float = 0
        for sample in samples {
            guard sample.arc - lastPierArc >= 18 else { continue }
            let deckBottom = sample.height - thickness
            guard deckBottom - sample.ground > 1.5 else { continue }
            guard !insideAnyBuilding(sample.position, buildings: buildings) else { continue }
            guard !platforms.contains(where: { pointInRing(sample.position, ring: $0.ring) })
            else { continue }
            appendPillar(
                centre: sample.position,
                top: deckBottom + 0.1,
                bottom: sample.ground - 0.3,
                half: pillarHalf,
                into: &pillars,
                collision: &collision
            )
            lastPierArc = sample.arc
        }
    }

    private static func appendPillar(
        centre: SIMD2<Float>,
        top: Float,
        bottom: Float,
        half: Float,
        into pillars: inout [SIMD3<Float>],
        collision: inout [SIMD3<Float>]
    ) {
        guard top > bottom else { return }
        let base = [
            SIMD2<Float>(centre.x - half, centre.y - half),
            SIMD2<Float>(centre.x + half, centre.y - half),
            SIMD2<Float>(centre.x + half, centre.y + half),
            SIMD2<Float>(centre.x - half, centre.y + half)
        ]
        var faces: [SIMD3<Float>] = []
        for index in 0..<4 {
            let p = base[index]
            let q = base[(index + 1) % 4]
            let a = SIMD3<Float>(p.x, top, p.y)
            let b = SIMD3<Float>(q.x, top, q.y)
            let c = SIMD3<Float>(q.x, bottom, q.y)
            let d = SIMD3<Float>(p.x, bottom, p.y)
            faces.append(contentsOf: [a, b, c, a, c, d])
        }
        pillars.append(contentsOf: faces)
        collision.append(contentsOf: faces)
    }

    /// A platform bridge (`man_made=bridge` polygon): one clean, dead-flat engineered slab.
    ///
    /// The slab deliberately has no height field of its own. An earlier attempt shaped it with
    /// ramp cones descending to every ground-connected corner, and the result was a lumpy circus
    /// tent (a 21-corner platform produced 19 overlapping cones). In the data 12 of 13 platforms
    /// are crossed by a linear bridge way, and it is that way — with its own ramps and approaches —
    /// which carries people onto the structure; the platform itself only needs to be a crisp slab
    /// at the deck level, on a row of piers, with its sides closed (solid embankment where it sits
    /// low, hanging skirt where it flies).
    private static func appendBridgeArea(
        _ area: UAVWorldBridgeArea,
        terrainHeight: (Float, Float) -> Float,
        buildings: [UAVWorldBuilding],
        deck: inout [SIMD3<Float>],
        sideCorners: inout [SIMD3<Float>],
        pillars: inout [SIMD3<Float>],
        collision: inout [SIMD3<Float>]
    ) {
        guard area.outerRing.count >= 3 else { return }
        let deckLevel = platformDeckLevel(area, terrainHeight: terrainHeight)

        var topCorners: [SIMD3<Float>] = []
        if area.holes.isEmpty,
           let indices = PolygonTriangulator.triangulate(area.outerRing) {
            // Exact ring edges — no grid jags or dropout holes on the common hole-free polygon.
            let vertices = area.outerRing.map { SIMD3<Float>($0.x, deckLevel, $0.y) }
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
                        let a = SIMD3<Float>(x, deckLevel, z)
                        let b = SIMD3<Float>(x + cell, deckLevel, z)
                        let c = SIMD3<Float>(x + cell, deckLevel, z + cell)
                        let d = SIMD3<Float>(x, deckLevel, z + cell)
                        topCorners.append(contentsOf: [a, c, b, a, d, c])
                    }
                    z += cell
                }
                x += cell
            }
        }
        deck.append(contentsOf: topCorners)
        collision.append(contentsOf: topCorners)

        for index in area.outerRing.indices {
            let current = area.outerRing[index]
            let next = area.outerRing[(index + 1) % area.outerRing.count]
            let groundCurrent = terrainHeight(current.x, current.y)
            let groundNext = terrainHeight(next.x, next.y)
            let bottomCurrent = deckLevel - groundCurrent < 1.2 ? groundCurrent - 0.3 : deckLevel - 0.75
            let bottomNext = deckLevel - groundNext < 1.2 ? groundNext - 0.3 : deckLevel - 0.75
            let a = SIMD3<Float>(current.x, deckLevel, current.y)
            let b = SIMD3<Float>(next.x, deckLevel, next.y)
            let c = SIMD3<Float>(next.x, bottomNext, next.y)
            let d = SIMD3<Float>(current.x, bottomCurrent, current.y)
            let faces = [a, b, c, a, c, d]
            sideCorners.append(contentsOf: faces)
            collision.append(contentsOf: faces)
        }

        // A pier row along the platform's principal axis — its structural spine — like a real
        // viaduct. The earlier greedy grid scan scattered piers anywhere inside the polygon,
        // including right at the visible front edge, where from the ground they read as mystery
        // columns standing on the bridge.
        let centroid = area.outerRing.reduce(SIMD2<Float>(repeating: 0), +)
            / Float(area.outerRing.count)
        var xx: Float = 0
        var xz: Float = 0
        var zz: Float = 0
        for point in area.outerRing {
            let delta = point - centroid
            xx += delta.x * delta.x
            xz += delta.x * delta.y
            zz += delta.y * delta.y
        }
        let angle = 0.5 * atan2(2 * xz, xx - zz)
        let axis = SIMD2<Float>(cos(angle), sin(angle))
        let projections = area.outerRing.map { simd_dot($0 - centroid, axis) }
        let axisMin = projections.min() ?? 0
        let axisMax = projections.max() ?? 0
        let inset: Float = 5
        let deckBottom = deckLevel - 0.75
        var along = axisMin + inset
        while along <= axisMax - inset {
            defer { along += 14 }
            let centre = centroid + axis * along
            guard pointInRing(centre, ring: area.outerRing),
                  !area.holes.contains(where: { pointInRing(centre, ring: $0) }) else { continue }
            let ground = terrainHeight(centre.x, centre.y)
            guard deckBottom - ground > 1.5 else { continue }
            guard !insideAnyBuilding(centre, buildings: buildings) else { continue }
            appendPillar(
                centre: centre,
                top: deckBottom + 0.1,
                bottom: ground - 0.3,
                half: 0.9,
                into: &pillars,
                collision: &collision
            )
        }
    }

    /// One deck level per platform: high enough to clear its whole footprint terrain, at least the
    /// clamped clearance above the lowest point. Shared by the platform mesh itself and by linear
    /// ways riding across it, so both agree on the slab surface.
    private static func platformDeckLevel(
        _ area: UAVWorldBridgeArea,
        terrainHeight: (Float, Float) -> Float
    ) -> Float {
        let sampled = area.outerRing.map { terrainHeight($0.x, $0.y) }
        // Clamp clearance the same way linear bridges do, so an over-tagged deck cannot float away.
        let clearance = min(max(area.clearanceMeters, 2.0), 9.0)
            + Float(max(0, area.layer - 1)) * 3.5
        return max(
            (sampled.max() ?? 0) + 0.2,
            (sampled.min() ?? 0) + clearance
        )
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

    /// Deterministic per-plant size and orientation. Shared by the model-clone path (to scale and
    /// yaw the `.usdz`) and the collision proxy, so the invisible collider always matches the tree
    /// the pilot sees. Seed-derived, never random, because the world is rebuilt reproducibly.
    private static func plantMetrics(
        kind: UAVWorldVegetationKind,
        seed: UInt64
    ) -> (height: Float, shrub: Bool, yaw: Float) {
        let variation = Float(seed & 0xffff) / 65_535
        let shrub = kind == .scrub
        let height: Float = shrub ? 2.0 + variation * 1.6 : 7.0 + variation * 8.0
        let yaw = Float((seed >> 24) & 0xff) / 255 * (.pi * 2)
        return (height, shrub, yaw)
    }

    /// Builds a hexagonal trunk-and-canopy plant. `emitVisual` draws it (procedural fallback for a
    /// missing model); collision is always emitted — it is the cheap proxy standing in for the
    /// `.usdz` foliage mesh when the model *is* present.
    private static func appendPlant(
        at position: SIMD2<Float>,
        seed: UInt64,
        ground: Float,
        height: Float,
        shrub: Bool,
        emitVisual: Bool,
        trunks: inout [SIMD3<Float>],
        canopies: inout [SIMD3<Float>],
        collision: inout [SIMD3<Float>]
    ) {
        let variation = Float(seed & 0xffff) / 65_535
        let trunkHeight = shrub ? height * 0.25 : height * 0.55
        let trunkRadius: Float = shrub ? 0.12 : 0.20 + variation * 0.08
        // Widen the collision canopy with the tree so a tall model's foliage still has a matching
        // volume to stop against, rather than the old fixed ~1.4 m cone under a 15 m pine.
        let canopyRadius: Float = shrub ? 1.1 : max(1.6, height * 0.16)
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
            if emitVisual { trunks.append(contentsOf: face) }
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
            if emitVisual { canopies.append(contentsOf: faces) }
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

    /// Every ground road sits at this one height above the terrain. Roads are kept perfectly
    /// coplanar on purpose — overlaps are resolved by `roadRenderingOrder` with depth writes off, not
    /// by stacking classes at different heights. The height band that did the latter cured the
    /// flicker but left visible cut-out steps where one class crossed another; coplanar + paint order
    /// cures both. The 10 cm lift keeps the strip clear of the terrain it decals onto — the road is
    /// draped (each edge vertex sampled on the terrain), but the terrain *mesh* between its grid
    /// corners is triangle-linear while the sampled funnel is bilinear, and on rough bare-earth
    /// cells that residual disagreement approaches a decimetre.
    private static let roadPlaneOffset: Float = 0.10

    /// Paint order for the coplanar road decals: lower classes first, higher classes over them, so a
    /// motorway reads as passing over the footway it crosses instead of the two z-fighting. Bridges
    /// no longer use this bucket (they are separate 3-D nodes), but the case stays for exhaustiveness.
    private static func roadRenderingOrder(_ key: RoadMaterialKey) -> Int {
        switch key {
        case .pedestrian: return 10
        case .track: return 11
        case .service: return 12
        case .street: return 13
        case .arterial: return 14
        case .motorway: return 15
        case .railway: return 16
        case .bridgeSide: return 12
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
