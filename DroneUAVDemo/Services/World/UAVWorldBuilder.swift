import Foundation
import simd

/// What the user asked for: a named patch of the real world, at a chosen size.
struct UAVWorldBuildRequest: Sendable {
    let identifier: String
    let displayName: String
    let regionName: String
    let bounds: GeoBoundingBox
    /// Height of the geoid above the WGS84 ellipsoid here. About -32.7 m for New York.
    let geoidSeparationMeters: Double
    /// Ground elevation at the origin, MSL. Zero until a real elevation layer exists, which is
    /// acceptable for near-flat regions and openly wrong for hilly ones.
    let originAltitudeMetersMSL: Double

    init(
        identifier: String,
        displayName: String,
        regionName: String,
        bounds: GeoBoundingBox,
        geoidSeparationMeters: Double = 0.0,
        originAltitudeMetersMSL: Double = 0.0
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.regionName = regionName
        self.bounds = bounds
        self.geoidSeparationMeters = geoidSeparationMeters
        self.originAltitudeMetersMSL = originAltitudeMetersMSL
    }
}

/// Everything the build discarded or merged, and why.
///
/// Reported rather than logged: a world built from open data is only as trustworthy as its
/// rejects are understood, and "511 buildings became 498" is a question the user is entitled to
/// see answered without reading a console.
struct UAVWorldBuildDiagnostics: Sendable {
    var fetchedPerSource: [String: Int] = [:]
    var rejectedDegenerate = 0
    var rejectedSliver = 0
    var rejectedOutsideBounds = 0
    var mergedDuplicates = 0
    var accepted = 0
    /// Smallest footprint that survived, for sanity-checking the sliver threshold.
    var smallestAcceptedAreaSquareMeters: Float = .greatestFiniteMagnitude

    var summaryLine: String {
        "accepted=\(accepted) degenerate=\(rejectedDegenerate) sliver=\(rejectedSliver) "
            + "outside=\(rejectedOutsideBounds) merged=\(mergedDuplicates)"
    }
}

/// Area semantics that must survive the trip from OSM to a saved world.
///
/// A flat list of rings is not enough for real coastlines. A water multipolygon can contain dry
/// islands, while piers are separate OSM areas laid over the water and can themselves contain
/// openings. Keeping the four roles explicit prevents a renderer from flooding an island or drawing
/// water through a pier merely because all of them happen to be closed polygons.
struct UAVWorldWaterGeometry: Codable, Sendable {
    var outerRings: [[SIMD2<Float>]]
    var innerRings: [[SIMD2<Float>]]
    var landRings: [[SIMD2<Float>]]
    var landInnerRings: [[SIMD2<Float>]]
    /// Directed OSM coastline ways. OSM deliberately stores the sea as a line rather than a giant
    /// polygon: land is on the left of every segment and seawater is on the right. Keeping the
    /// direction lets the runtime recover Hudson River and New York Harbor instead of mistaking
    /// every place outside a `natural=water` river polygon for dry land.
    var coastlineSegments: [[SIMD2<Float>]]

    init(
        outerRings: [[SIMD2<Float>]],
        innerRings: [[SIMD2<Float>]],
        landRings: [[SIMD2<Float>]],
        landInnerRings: [[SIMD2<Float>]],
        coastlineSegments: [[SIMD2<Float>]] = []
    ) {
        self.outerRings = outerRings
        self.innerRings = innerRings
        self.landRings = landRings
        self.landInnerRings = landInnerRings
        self.coastlineSegments = coastlineSegments
    }

    private enum CodingKeys: String, CodingKey {
        case outerRings
        case innerRings
        case landRings
        case landInnerRings
        case coastlineSegments
    }

    /// Packages written before coastline support remain readable. They still render their stored
    /// river polygons; rebuilding the package adds the missing open-sea classification.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outerRings = try container.decode([[SIMD2<Float>]].self, forKey: .outerRings)
        innerRings = try container.decode([[SIMD2<Float>]].self, forKey: .innerRings)
        landRings = try container.decode([[SIMD2<Float>]].self, forKey: .landRings)
        landInnerRings = try container.decode([[SIMD2<Float>]].self, forKey: .landInnerRings)
        coastlineSegments = try container.decodeIfPresent(
            [[SIMD2<Float>]].self,
            forKey: .coastlineSegments
        ) ?? []
    }

    static let empty = UAVWorldWaterGeometry(
        outerRings: [],
        innerRings: [],
        landRings: [],
        landInnerRings: [],
        coastlineSegments: []
    )

    var isEmpty: Bool { outerRings.isEmpty && coastlineSegments.isEmpty }
}

struct UAVWorldBuildResult: Sendable {
    let manifest: UAVWorldManifest
    let buildings: [UAVWorldBuilding]
    /// OSM water and the dry areas which cut it, all projected into local metres.
    let waterGeometry: UAVWorldWaterGeometry
    /// Every accepted OSM road, bridge and vegetation feature in the package bounds.
    let osmSurfaceFeatures: UAVWorldOSMSurfaceFeatures
    /// Ground relief, or nil when the elevation service could not be reached.
    let elevation: TerrariumElevationSource.Grid?
    let diagnostics: UAVWorldBuildDiagnostics
}

/// Turns raw source records into a finished, self-consistent world.
///
/// The order of operations matters and is not arbitrary: geometry is projected before anything
/// is measured or judged, because every threshold here is in metres and a decision made in
/// degrees would behave differently at different latitudes.
final class UAVWorldBuilder {
    /// Footprints smaller than this are digitisation noise, not obstacles — the real Lower
    /// Manhattan extract contains outlines as small as 2 m². Keeping them would add collision
    /// proxies a UAV can neither see nor meaningfully hit, at full per-object cost.
    static let minimumFootprintAreaSquareMeters: Float = 8.0

    /// Consecutive vertices closer together than this are collapsed. Duplicate and
    /// near-duplicate points are the usual cause of degenerate triangles downstream.
    static let minimumVertexSpacingMeters: Float = 0.01

    /// Source data is fetched slightly beyond the playable area so buildings on the edge are not
    /// clipped in half; anything whose centroid lands beyond this margin is dropped.
    static let boundsMarginMeters: Double = 120.0

    /// Coastline has to cross the complete visible square so its direction can classify the sea on
    /// every scanline. Whole waterfront footprints can reach farther than the building-centroid
    /// margin, hence the intentionally wider apron.
    static let waterBoundsMarginMeters: Double = 450.0

    let importerVersion: String

    init(importerVersion: String = "1.4.0") {
        self.importerVersion = importerVersion
    }

    // MARK: - Build

    func build(
        request: UAVWorldBuildRequest,
        sources: [UAVWorldBuildingSource],
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> UAVWorldBuildResult {
        guard !sources.isEmpty else { throw UAVWorldImportError.invalidRegion }

        let origin = GeoOrigin(
            coordinate: GeoCoordinate(
                latitudeDegrees: request.bounds.centerCoordinate.latitudeDegrees,
                longitudeDegrees: request.bounds.centerCoordinate.longitudeDegrees,
                altitudeMetersMSL: request.originAltitudeMetersMSL
            ),
            geoidSeparationMeters: request.geoidSeparationMeters
        )

        var diagnostics = UAVWorldBuildDiagnostics()
        var accepted: [UAVWorldBuilding] = []
        var waterGeometry = UAVWorldWaterGeometry.empty
        var osmSurfaceFeatures = UAVWorldOSMSurfaceFeatures.empty
        var elevation: TerrariumElevationSource.Grid?
        var index = BuildingOverlapIndex()

        // Highest-fidelity source first, so a municipal survey claims a building before the
        // crowd-sourced outline of the same building can.
        let ordered = sources.sorted { $0.fidelityRank > $1.fidelityRank }
        let fetchBounds = request.bounds.expanded(byMeters: Self.boundsMarginMeters)

        // Relief, like water, is fetched but never fatal — a world with flat ground is still a
        // world, and losing the buildings because an elevation tile server was busy would not be.
        do {
            try Task.checkCancellation()
            progress?(L10n.s("world.build.stage.elevation"))
            let size = request.bounds.approximateSizeMeters()
            let halfSpan = Float(
                max(size.width, size.height) * 0.5 + Self.waterBoundsMarginMeters
            )
            let terrainBounds = request.bounds.expanded(byMeters: Self.waterBoundsMarginMeters)
            elevation = try await TerrariumElevationSource().fetchGrid(
                bounds: terrainBounds,
                origin: origin,
                halfSpanMeters: halfSpan
            )
        } catch is CancellationError {
            throw UAVWorldImportError.cancelled
        } catch {
            elevation = nil
        }

        // Water is fetched but never fatal. A district with no mapped water is completely ordinary,
        // and a failing water query must not cost the user the buildings they waited for.
        do {
            try Task.checkCancellation()
            progress?(L10n.s("world.build.stage.water"))
            // Coastline ways are linear and may be split just outside the selected square. Fetch a
            // wider apron than buildings so the directed coast still classifies every row of the
            // runtime's ground mesh, including complete waterfront buildings that cross the box.
            let waterBounds = request.bounds.expanded(byMeters: Self.waterBoundsMarginMeters)
            let geometry = try await OverpassWaterSource().fetchWaterGeometry(in: waterBounds)
            waterGeometry = UAVWorldWaterGeometry(
                outerRings: geometry.outerRings.map { project(ring: $0, origin: origin) },
                innerRings: geometry.innerRings.map { project(ring: $0, origin: origin) },
                landRings: geometry.landRings.map { project(ring: $0, origin: origin) },
                landInnerRings: geometry.landInnerRings.map { project(ring: $0, origin: origin) },
                coastlineSegments: geometry.coastlineSegments.map {
                    project(ring: $0, origin: origin)
                }
            )
            waterGeometry.outerRings.append(contentsOf: geometry.linearWaterways.compactMap {
                waterwayCorridor(
                    centerline: project(ring: $0.centerline, origin: origin),
                    widthMeters: $0.widthMeters
                )
            })
        } catch is CancellationError {
            throw UAVWorldImportError.cancelled
        } catch {
            waterGeometry = .empty
        }

        // Roads, bridges and vegetation are one optional OSM snapshot. This is deliberately a
        // feature-wide import rather than a list of landmarks: every matching way/relation/node in
        // the package bbox is projected, clipped and persisted under the same rules.
        do {
            try Task.checkCancellation()
            progress?(L10n.s("world.build.stage.osm_surface"))
            let raw = try await OverpassSurfaceFeatureSource().fetch(in: fetchBounds)
            let extent = fetchBounds.localExtent(relativeTo: origin)
            let minimum = SIMD2<Float>(Float(extent.minimum.x), Float(extent.minimum.y))
            let maximum = SIMD2<Float>(Float(extent.maximum.x), Float(extent.maximum.y))

            osmSurfaceFeatures.transport = raw.transport.flatMap { feature in
                let projected = project(ring: feature.centerline, origin: origin)
                return clippedPolylines(
                    projected,
                    minimum: minimum,
                    maximum: maximum
                ).enumerated().map { index, clipped in
                    UAVWorldTransportFeature(
                        sourceIdentifier: index == 0
                            ? feature.sourceIdentifier
                            : "\(feature.sourceIdentifier)/part-\(index)",
                        centerline: clipped,
                        kind: feature.kind,
                        widthMeters: feature.widthMeters,
                        surface: feature.surface,
                        isBridge: feature.isBridge,
                        layer: feature.layer,
                        clearanceMeters: feature.clearanceMeters
                    )
                }
            }

            osmSurfaceFeatures.vegetationAreas = raw.vegetationAreas.compactMap { feature in
                var outer = clippedPolygon(
                    project(ring: feature.outerRing, origin: origin),
                    minimum: minimum,
                    maximum: maximum
                )
                outer = conditionedAreaRing(outer, counterClockwise: true)
                guard outer.count >= 3, abs(signedAreaOf(outer)) >= 2 else { return nil }
                let holes = feature.holes.compactMap { hole -> [SIMD2<Float>]? in
                    let clipped = clippedPolygon(
                        project(ring: hole, origin: origin),
                        minimum: minimum,
                        maximum: maximum
                    )
                    let ring = conditionedAreaRing(clipped, counterClockwise: false)
                    return ring.count >= 3 ? ring : nil
                }
                return UAVWorldVegetationArea(
                    sourceIdentifier: feature.sourceIdentifier,
                    outerRing: outer,
                    holes: holes,
                    kind: feature.kind
                )
            }

            osmSurfaceFeatures.bridgeAreas = raw.bridgeAreas.compactMap { feature in
                var outer = clippedPolygon(
                    project(ring: feature.outerRing, origin: origin),
                    minimum: minimum,
                    maximum: maximum
                )
                outer = conditionedAreaRing(outer, counterClockwise: true)
                guard outer.count >= 3, abs(signedAreaOf(outer)) >= 2 else { return nil }
                let holes = feature.holes.compactMap { hole -> [SIMD2<Float>]? in
                    let clipped = clippedPolygon(
                        project(ring: hole, origin: origin),
                        minimum: minimum,
                        maximum: maximum
                    )
                    let ring = conditionedAreaRing(clipped, counterClockwise: false)
                    return ring.count >= 3 ? ring : nil
                }
                return UAVWorldBridgeArea(
                    sourceIdentifier: feature.sourceIdentifier,
                    outerRing: outer,
                    holes: holes,
                    layer: feature.layer,
                    clearanceMeters: feature.clearanceMeters
                )
            }

            osmSurfaceFeatures.trees = raw.trees.compactMap { tree in
                let local = origin.localMeters(of: tree.coordinate)
                let point = SIMD2<Float>(Float(local.x), Float(local.z))
                guard point.x >= minimum.x, point.x <= maximum.x,
                      point.y >= minimum.y, point.y <= maximum.y else {
                    return nil
                }
                return UAVWorldTree(
                    sourceIdentifier: tree.sourceIdentifier,
                    position: point,
                    kind: tree.kind
                )
            }
        } catch is CancellationError {
            throw UAVWorldImportError.cancelled
        } catch {
            // Buildings remain usable when Overpass rejects this larger optional query. The
            // missing layer is explicit in the manifest rather than represented by fake scenery.
            osmSurfaceFeatures = .empty
        }

        for source in ordered {
            try Task.checkCancellation()
            progress?(source.attribution.displayName)

            let raws = try await source.fetchBuildings(in: fetchBounds)
            diagnostics.fetchedPerSource[source.attribution.datasetIdentifier] = raws.count

            // Overpass returns any way *intersecting* the query box, so results reach well past
            // it — a pier or a bridge approach anchored inside the box can extend hundreds of
            // metres beyond. Buildings are kept if their centroid is within the fetch area;
            // beyond that they are decoration for a region the user did not ask for.
            let acceptanceExtent = fetchBounds.localExtent(relativeTo: origin)

            for raw in raws {
                guard let building = makeBuilding(
                    from: raw,
                    origin: origin,
                    datasetIdentifier: source.attribution.datasetIdentifier,
                    elevation: elevation,
                    diagnostics: &diagnostics
                ) else {
                    continue
                }

                let centroid = building.centroid
                guard Double(centroid.x) >= acceptanceExtent.minimum.x,
                      Double(centroid.x) <= acceptanceExtent.maximum.x,
                      Double(centroid.y) >= acceptanceExtent.minimum.y,
                      Double(centroid.y) <= acceptanceExtent.maximum.y else {
                    diagnostics.rejectedOutsideBounds += 1
                    continue
                }

                if index.containsDuplicate(of: building) {
                    diagnostics.mergedDuplicates += 1
                    continue
                }
                index.insert(building)
                accepted.append(building)
                diagnostics.accepted += 1
                diagnostics.smallestAcceptedAreaSquareMeters = min(
                    diagnostics.smallestAcceptedAreaSquareMeters,
                    abs(building.signedAreaSquareMeters)
                )
            }
        }

        guard !accepted.isEmpty else { throw UAVWorldImportError.emptyResult }

        let measuredCount = accepted.filter { $0.provenance.heightAccuracy == .measured }.count
        let statistics = UAVWorldStatistics(
            buildingCount: accepted.count,
            waterPolygonCount: waterGeometry.outerRings.count,
            roadSegmentCount: osmSurfaceFeatures.transport.count,
            vegetationCount: osmSurfaceFeatures.vegetationAreas.count
                + osmSurfaceFeatures.trees.count,
            bridgeCount: osmSurfaceFeatures.transport.filter(\.isBridge).count
                + osmSurfaceFeatures.bridgeAreas.count,
            measuredHeightFraction: Float(measuredCount) / Float(accepted.count)
        )

        var attributions = ordered.map(\.attribution)
        if (!waterGeometry.isEmpty || !osmSurfaceFeatures.isEmpty),
           !attributions.contains(where: { $0.datasetIdentifier == "osm" }) {
            attributions.append(OverpassBuildingSource.osmAttribution)
        }

        let manifest = UAVWorldManifest(
            identifier: request.identifier,
            displayName: request.displayName,
            regionName: request.regionName,
            origin: origin,
            bounds: request.bounds,
            layers: {
                var layers: Set<UAVWorldLayer> = [.buildings]
                if !waterGeometry.isEmpty { layers.insert(.water) }
                if elevation != nil { layers.insert(.terrain) }
                if !osmSurfaceFeatures.transport.isEmpty { layers.insert(.roads) }
                if osmSurfaceFeatures.transport.contains(where: \.isBridge)
                    || !osmSurfaceFeatures.bridgeAreas.isEmpty {
                    layers.insert(.bridges)
                }
                if !osmSurfaceFeatures.vegetationAreas.isEmpty
                    || !osmSurfaceFeatures.trees.isEmpty {
                    layers.insert(.vegetation)
                }
                return layers
            }(),
            attributions: attributions,
            importerVersion: importerVersion,
            statistics: statistics
        )

        return UAVWorldBuildResult(
            manifest: manifest,
            buildings: accepted,
            waterGeometry: waterGeometry,
            osmSurfaceFeatures: osmSurfaceFeatures,
            elevation: elevation,
            diagnostics: diagnostics
        )
    }

    // MARK: - Raw → building

    private func makeBuilding(
        from raw: UAVWorldRawBuilding,
        origin: GeoOrigin,
        datasetIdentifier: String,
        elevation: TerrariumElevationSource.Grid?,
        diagnostics: inout UAVWorldBuildDiagnostics
    ) -> UAVWorldBuilding? {
        var footprint = project(ring: raw.outerRing, origin: origin)
        footprint = collapsingNearDuplicates(footprint)
        // Redundant collinear points are common in crowd-sourced outlines and produce zero-area
        // roof triangles and duplicate wall quads. Removing them here means every consumer of
        // the footprint benefits, rather than each re-deriving the same conditioning.
        footprint = PolygonTriangulator.removingCollinearVertices(footprint)
        guard footprint.count >= 3 else {
            diagnostics.rejectedDegenerate += 1
            return nil
        }

        // Winding is normalised to counter-clockwise here, once, so every downstream consumer
        // (triangulation, wall extrusion, normal generation) can assume it rather than each
        // re-deriving it — and so a source with the opposite convention cannot produce
        // inside-out buildings.
        var signedArea = signedAreaOf(footprint)
        if signedArea < 0 {
            footprint.reverse()
            signedArea = -signedArea
        }

        guard signedArea >= Self.minimumFootprintAreaSquareMeters else {
            diagnostics.rejectedSliver += 1
            return nil
        }

        var holes: [[SIMD2<Float>]] = []
        for hole in raw.holes {
            var ring = PolygonTriangulator.removingCollinearVertices(
                collapsingNearDuplicates(project(ring: hole, origin: origin))
            )
            guard ring.count >= 3 else { continue }
            // Holes wind opposite to the outer ring, which is what point-in-polygon and
            // triangulation both expect.
            if signedAreaOf(ring) > 0 { ring.reverse() }
            holes.append(ring)
        }

        var record = raw.record
        record.footprintAreaSquareMeters = signedArea

        let resolvedHeight = UAVWorldBuildingClassifier.resolveHeight(for: record)
        let roofForm = UAVWorldBuildingClassifier.resolveRoofForm(for: record)
        let facadeClass = UAVWorldBuildingClassifier.resolveFacadeClass(
            for: record,
            resolvedHeightMeters: resolvedHeight.heightMeters
        )
        let confidence = UAVWorldBuildingClassifier.resolveConfidence(
            heightAccuracy: resolvedHeight.accuracy,
            record: record,
            footprintVertexCount: footprint.count
        )

        return UAVWorldBuilding(
            id: UUID(),
            footprint: footprint,
            holes: holes,
            // Stored at zero; seating is the runtime's job, not the importer's.
            //
            // This used to bake the DEM height at the footprint, but the stored grid is a raw surface
            // model, so the sample landed on a rooftop as often as on the ground and the bases came
            // out scattered from −6 to +13 m — which the constructor preview drew as buildings
            // floating and sinking at random. `OpenDataWorldRuntime` now re-seats every building on
            // the same bare-earth field it builds the terrain from, so a value baked here would only
            // be overwritten. Zero also makes the flat preview, which has no terrain, show the city
            // sitting cleanly on the ground.
            baseElevationMeters: 0.0,
            heightMeters: resolvedHeight.heightMeters,
            roofHeightMeters: UAVWorldBuildingClassifier.roofRiseMeters(
                form: roofForm,
                footprintAreaSquareMeters: signedArea
            ),
            roofForm: roofForm,
            facadeClass: facadeClass,
            levels: resolvedHeight.levels,
            yearBuilt: record.yearBuilt,
            name: record.name,
            provenance: UAVWorldProvenance(
                datasetIdentifier: datasetIdentifier,
                featureIdentifier: raw.featureIdentifier,
                heightAccuracy: resolvedHeight.accuracy,
                horizontalAccuracyMeters: nil,
                confidence: confidence
            )
        )
    }

    private func project(ring: [GeoCoordinate], origin: GeoOrigin) -> [SIMD2<Float>] {
        ring.map { coordinate in
            let local = origin.localMeters(of: coordinate)
            return SIMD2<Float>(Float(local.x), Float(local.z))
        }
    }

    private func collapsingNearDuplicates(_ ring: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard ring.count >= 2 else { return ring }
        let thresholdSquared = Self.minimumVertexSpacingMeters * Self.minimumVertexSpacingMeters
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(ring.count)
        for vertex in ring {
            if let last = result.last,
               simd_length_squared(vertex - last) < thresholdSquared {
                continue
            }
            result.append(vertex)
        }
        // The ring is implicitly closed, so the first and last must also not coincide.
        if result.count >= 2,
           let first = result.first,
           let last = result.last,
           simd_length_squared(last - first) < thresholdSquared {
            result.removeLast()
        }
        return result
    }

    private func signedAreaOf(_ ring: [SIMD2<Float>]) -> Float {
        guard ring.count >= 3 else { return 0 }
        var doubleArea: Float = 0
        for index in ring.indices {
            let current = ring[index]
            let next = ring[(index + 1) % ring.count]
            doubleArea += current.x * next.y - next.x * current.y
        }
        return doubleArea * 0.5
    }

    /// Converts a centre-line OSM waterway into one continuous bank-to-bank polygon.
    ///
    /// Interior normals use the chord through the neighbouring vertices, avoiding the gaps that
    /// independent per-segment rectangles leave at bends. Very sharp reversals fall back to the
    /// nearest valid segment direction rather than producing an unbounded mitre.
    private func waterwayCorridor(
        centerline: [SIMD2<Float>],
        widthMeters: Float
    ) -> [SIMD2<Float>]? {
        guard centerline.count >= 2, widthMeters >= 0.5 else { return nil }
        let halfWidth = widthMeters * 0.5
        var left: [SIMD2<Float>] = []
        var right: [SIMD2<Float>] = []
        left.reserveCapacity(centerline.count)
        right.reserveCapacity(centerline.count)

        for index in centerline.indices {
            let direction: SIMD2<Float>
            if index == 0 {
                direction = centerline[1] - centerline[0]
            } else if index == centerline.count - 1 {
                direction = centerline[index] - centerline[index - 1]
            } else {
                let chord = centerline[index + 1] - centerline[index - 1]
                direction = simd_length_squared(chord) > 0.000_001
                    ? chord
                    : centerline[index] - centerline[index - 1]
            }
            let length = simd_length(direction)
            guard length.isFinite, length > 0.001 else { continue }
            let normal = SIMD2<Float>(-direction.y, direction.x) / length * halfWidth
            left.append(centerline[index] + normal)
            right.append(centerline[index] - normal)
        }
        guard left.count >= 2, right.count == left.count else { return nil }
        return left + right.reversed()
    }

    private func conditionedAreaRing(
        _ input: [SIMD2<Float>],
        counterClockwise: Bool
    ) -> [SIMD2<Float>] {
        var ring = collapsingNearDuplicates(input)
        ring = PolygonTriangulator.removingCollinearVertices(ring)
        let area = signedAreaOf(ring)
        if (counterClockwise && area < 0) || (!counterClockwise && area > 0) {
            ring.reverse()
        }
        return ring
    }

    /// Sutherland–Hodgman clipping keeps very large OSM land-cover relations inside the package.
    private func clippedPolygon(
        _ polygon: [SIMD2<Float>],
        minimum: SIMD2<Float>,
        maximum: SIMD2<Float>
    ) -> [SIMD2<Float>] {
        guard polygon.count >= 3 else { return [] }
        var result = polygon
        if result.first == result.last { result.removeLast() }

        typealias Boundary = (
            inside: (SIMD2<Float>) -> Bool,
            intersect: (SIMD2<Float>, SIMD2<Float>) -> SIMD2<Float>
        )
        let boundaries: [Boundary] = [
            ({ $0.x >= minimum.x }, { a, b in
                let t = (minimum.x - a.x) / (b.x - a.x)
                return SIMD2<Float>(minimum.x, a.y + (b.y - a.y) * t)
            }),
            ({ $0.x <= maximum.x }, { a, b in
                let t = (maximum.x - a.x) / (b.x - a.x)
                return SIMD2<Float>(maximum.x, a.y + (b.y - a.y) * t)
            }),
            ({ $0.y >= minimum.y }, { a, b in
                let t = (minimum.y - a.y) / (b.y - a.y)
                return SIMD2<Float>(a.x + (b.x - a.x) * t, minimum.y)
            }),
            ({ $0.y <= maximum.y }, { a, b in
                let t = (maximum.y - a.y) / (b.y - a.y)
                return SIMD2<Float>(a.x + (b.x - a.x) * t, maximum.y)
            })
        ]

        for boundary in boundaries {
            guard !result.isEmpty else { break }
            let input = result
            result = []
            var previous = input.last!
            var previousInside = boundary.inside(previous)
            for current in input {
                let currentInside = boundary.inside(current)
                if currentInside != previousInside {
                    result.append(boundary.intersect(previous, current))
                }
                if currentInside { result.append(current) }
                previous = current
                previousInside = currentInside
            }
        }
        return result
    }

    /// Clips every line segment to the package rectangle and preserves all visible pieces.
    private func clippedPolylines(
        _ points: [SIMD2<Float>],
        minimum: SIMD2<Float>,
        maximum: SIMD2<Float>
    ) -> [[SIMD2<Float>]] {
        guard points.count >= 2 else { return [] }
        var result: [[SIMD2<Float>]] = []
        var current: [SIMD2<Float>] = []
        for index in 0..<(points.count - 1) {
            guard let segment = clippedSegment(
                points[index],
                points[index + 1],
                minimum: minimum,
                maximum: maximum
            ) else {
                if current.count >= 2 {
                    result.append(collapsingNearDuplicates(current))
                }
                current = []
                continue
            }
            if let last = current.last,
               simd_length_squared(last - segment.0) > 0.01 {
                if current.count >= 2 {
                    result.append(collapsingNearDuplicates(current))
                }
                current = [segment.0]
            } else if current.isEmpty {
                current = [segment.0]
            }
            current.append(segment.1)
        }
        if current.count >= 2 {
            result.append(collapsingNearDuplicates(current))
        }
        return result.filter { $0.count >= 2 }
    }

    private func clippedSegment(
        _ a: SIMD2<Float>,
        _ b: SIMD2<Float>,
        minimum: SIMD2<Float>,
        maximum: SIMD2<Float>
    ) -> (SIMD2<Float>, SIMD2<Float>)? {
        let delta = b - a
        var lower: Float = 0
        var upper: Float = 1
        let p = [-delta.x, delta.x, -delta.y, delta.y]
        let q = [
            a.x - minimum.x,
            maximum.x - a.x,
            a.y - minimum.y,
            maximum.y - a.y
        ]
        for index in 0..<4 {
            if abs(p[index]) < 0.000_001 {
                if q[index] < 0 { return nil }
            } else {
                let ratio = q[index] / p[index]
                if p[index] < 0 {
                    lower = max(lower, ratio)
                } else {
                    upper = min(upper, ratio)
                }
                if lower > upper { return nil }
            }
        }
        return (a + delta * lower, a + delta * upper)
    }
}

// MARK: - Duplicate detection

/// Uniform-grid index used to spot the same building arriving twice — from two sources, or twice
/// within one source.
///
/// This exists for the multi-source case that makes the importer a constructor rather than a
/// single-source loader: when a municipal dataset and OSM both describe a block, the
/// higher-fidelity record is inserted first and the second must be recognised as the same
/// building rather than stacked on top of it.
///
/// **Matching is by area overlap, not centroid proximity.** An earlier version compared centroid
/// distance against a fraction of the building's own width, and checking it against the real
/// Lower Manhattan extract showed it silently deleting ten genuine buildings: adjacent row
/// buildings on a Manhattan block sit 5–9 m apart centre-to-centre and are of similar size, which
/// is indistinguishable from a duplicate under that test. Measured across the extract, 5% of
/// buildings had a neighbour within one match radius — the test was operating at the same scale
/// as the city's actual building spacing, so it could not work at any threshold.
///
/// Overlap separates the two cases cleanly, because it keys on the property that actually
/// distinguishes them: two records of one building cover the same ground, while two neighbours
/// sharing a party wall cover almost none of each other's.
private struct BuildingOverlapIndex {
    private struct Cell: Hashable {
        let x: Int
        let z: Int
    }

    private struct Entry {
        let minimum: SIMD2<Float>
        let maximum: SIMD2<Float>
    }

    /// Comfortably larger than any plausible building footprint, so a candidate and its match
    /// cannot land in cells further apart than the 3×3 neighbourhood scanned below.
    private let cellSize: Float = 120.0
    private var cells: [Cell: [Entry]] = [:]

    /// Intersection-over-union above which two footprints are considered the same building.
    /// Independently digitised outlines of one structure agree closely but never exactly; the
    /// true duplicate found in the real extract (Fulton Center, mapped once as a building and
    /// once as a station) scored 1.0, while the closest genuine neighbours scored below 0.1.
    /// The gap is wide enough that the exact threshold is not delicate.
    private static let overlapThreshold: Float = 0.6

    private func cell(for point: SIMD2<Float>) -> Cell {
        Cell(x: Int(floor(point.x / cellSize)), z: Int(floor(point.y / cellSize)))
    }

    mutating func insert(_ building: UAVWorldBuilding) {
        let bounds = building.planarBounds
        let entry = Entry(minimum: bounds.minimum, maximum: bounds.maximum)
        // Registered under every cell the footprint touches, so a building straddling a cell
        // boundary is still found from either side.
        for cellKey in cellsCovering(minimum: bounds.minimum, maximum: bounds.maximum) {
            cells[cellKey, default: []].append(entry)
        }
    }

    func containsDuplicate(of building: UAVWorldBuilding) -> Bool {
        let bounds = building.planarBounds
        for cellKey in cellsCovering(minimum: bounds.minimum, maximum: bounds.maximum) {
            guard let candidates = cells[cellKey] else { continue }
            for candidate in candidates {
                let overlap = intersectionOverUnion(
                    aMinimum: bounds.minimum,
                    aMaximum: bounds.maximum,
                    bMinimum: candidate.minimum,
                    bMaximum: candidate.maximum
                )
                if overlap >= Self.overlapThreshold {
                    return true
                }
            }
        }
        return false
    }

    private func cellsCovering(minimum: SIMD2<Float>, maximum: SIMD2<Float>) -> [Cell] {
        let lower = cell(for: minimum)
        let upper = cell(for: maximum)
        var result: [Cell] = []
        for x in lower.x...upper.x {
            for z in lower.z...upper.z {
                result.append(Cell(x: x, z: z))
            }
        }
        return result
    }

    /// Axis-aligned-bounds IoU. A footprint-exact polygon intersection would be stricter, but
    /// bounds are enough to separate "same building" from "neighbouring building" by a wide
    /// margin, and cost a few comparisons instead of a clipping pass over every candidate pair.
    private func intersectionOverUnion(
        aMinimum: SIMD2<Float>,
        aMaximum: SIMD2<Float>,
        bMinimum: SIMD2<Float>,
        bMaximum: SIMD2<Float>
    ) -> Float {
        let overlapMinimum = simd_max(aMinimum, bMinimum)
        let overlapMaximum = simd_min(aMaximum, bMaximum)
        let overlapExtent = overlapMaximum - overlapMinimum
        guard overlapExtent.x > 0, overlapExtent.y > 0 else { return 0 }

        let intersection = overlapExtent.x * overlapExtent.y
        let aExtent = aMaximum - aMinimum
        let bExtent = bMaximum - bMinimum
        let union = aExtent.x * aExtent.y + bExtent.x * bExtent.y - intersection
        guard union > 0.0001 else { return 0 }
        return intersection / union
    }
}
