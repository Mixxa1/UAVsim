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

struct UAVWorldBuildResult: Sendable {
    let manifest: UAVWorldManifest
    let buildings: [UAVWorldBuilding]
    /// Closed water rings in local metres. Empty is a normal answer, not a failure.
    let waterRings: [[SIMD2<Float>]]
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

    let importerVersion: String

    init(importerVersion: String = "1.0.0") {
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
        var waterRings: [[SIMD2<Float>]] = []
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
            let halfSpan = Float(max(size.width, size.height) * 0.5) + 200
            elevation = try await TerrariumElevationSource().fetchGrid(
                bounds: request.bounds,
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
            let rings = try await OverpassWaterSource().fetchWaterRings(in: request.bounds)
            waterRings = rings.map { project(ring: $0, origin: origin) }
        } catch is CancellationError {
            throw UAVWorldImportError.cancelled
        } catch {
            waterRings = []
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
            measuredHeightFraction: Float(measuredCount) / Float(accepted.count)
        )

        let manifest = UAVWorldManifest(
            identifier: request.identifier,
            displayName: request.displayName,
            regionName: request.regionName,
            origin: origin,
            bounds: request.bounds,
            layers: {
                var layers: Set<UAVWorldLayer> = [.buildings]
                if !waterRings.isEmpty { layers.insert(.water) }
                if elevation != nil { layers.insert(.terrain) }
                return layers
            }(),
            attributions: ordered.map(\.attribution),
            importerVersion: importerVersion,
            statistics: statistics
        )

        return UAVWorldBuildResult(
            manifest: manifest,
            buildings: accepted,
            waterRings: waterRings,
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
