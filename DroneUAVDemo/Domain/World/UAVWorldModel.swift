import Foundation
import simd

/// On-disk description of one imported patch of the real world.
///
/// A `.uavworld` package is self-contained and offline: everything needed to fly, collide,
/// sense and attribute the data is inside it. It is deliberately *not* tied to any one country
/// or provider — a region is defined by its bounding box and the set of source datasets that
/// happened to cover it, so the same pipeline builds Lower Manhattan from NYC open data and a
/// Baltic town from OSM alone, differing in fidelity rather than in code path.
struct UAVWorldManifest: Codable, Sendable {
    /// Bumped whenever the on-disk layout changes incompatibly. The loader refuses newer
    /// versions rather than misreading them.
    static let currentFormatVersion = 1

    let formatVersion: Int
    /// Stable identifier, also the package directory name (e.g. `lower-manhattan-2km`).
    let identifier: String
    /// What the user sees in the map picker (e.g. "New York — Lower Manhattan").
    let displayName: String
    /// Free-form region label for grouping ("New York, USA").
    let regionName: String

    /// Anchor tying every local coordinate in this package to the real Earth.
    let origin: GeoOrigin
    let bounds: GeoBoundingBox

    /// Which layers this package actually contains. A world built from OSM alone will have
    /// buildings and water but no real terrain relief, and the UI should say so plainly instead
    /// of implying a fidelity the data does not have.
    let layers: Set<UAVWorldLayer>

    /// Licence and credit for every dataset used. ODbL (OSM) requires attribution to be carried
    /// with derived data, so this is a functional field, not decoration.
    let attributions: [UAVWorldAttribution]

    let generatedAt: Date
    /// Version of the importer that produced the package, for reproducing or invalidating it.
    let importerVersion: String

    /// Summary counts, so the picker can describe a world without opening every layer file.
    let statistics: UAVWorldStatistics

    init(
        formatVersion: Int = UAVWorldManifest.currentFormatVersion,
        identifier: String,
        displayName: String,
        regionName: String,
        origin: GeoOrigin,
        bounds: GeoBoundingBox,
        layers: Set<UAVWorldLayer>,
        attributions: [UAVWorldAttribution],
        generatedAt: Date = Date(),
        importerVersion: String,
        statistics: UAVWorldStatistics
    ) {
        self.formatVersion = formatVersion
        self.identifier = identifier
        self.displayName = displayName
        self.regionName = regionName
        self.origin = origin
        self.bounds = bounds
        self.layers = layers
        self.attributions = attributions
        self.generatedAt = generatedAt
        self.importerVersion = importerVersion
        self.statistics = statistics
    }
}

enum UAVWorldLayer: String, Codable, Sendable, CaseIterable {
    case terrain
    case buildings
    case water
    case roads
    case vegetation
    case bridges
    case orthophoto
}

struct UAVWorldStatistics: Codable, Sendable {
    var buildingCount: Int = 0
    var waterPolygonCount: Int = 0
    var roadSegmentCount: Int = 0
    var vegetationCount: Int = 0
    var bridgeCount: Int = 0
    /// Share of buildings whose height came from a survey rather than an estimate — the single
    /// most useful one-number answer to "how real is this map".
    var measuredHeightFraction: Float = 0.0
}

/// Credit line for one source dataset, carried into the package and shown in the UI.
struct UAVWorldAttribution: Codable, Hashable, Sendable {
    /// Machine identifier used in `UAVWorldProvenance.datasetIdentifier`.
    let datasetIdentifier: String
    /// Human-readable name ("OpenStreetMap contributors").
    let displayName: String
    /// Licence short name ("ODbL 1.0", "Public Domain", "CC BY 4.0").
    let license: String
    let sourceURL: String?
}

// MARK: - Provenance

/// How a given height was arrived at. Distinguishing these is what separates a map that can
/// honestly claim engineering fidelity from one that merely looks plausible: a surveyed height
/// and a height guessed from a building's class are both a number, and only one is evidence.
enum UAVWorldHeightAccuracy: String, Codable, Sendable {
    /// Directly measured — LiDAR-derived model, or an explicit surveyed height tag.
    case measured
    /// Derived from a stated floor count times an assumed storey height.
    case derivedFromLevels
    /// Inferred from building class, neighbourhood context or a default. Visually reasonable,
    /// not trustworthy for clearance planning.
    case estimated

    var confidenceWeight: Float {
        switch self {
        case .measured:
            return 1.0
        case .derivedFromLevels:
            return 0.65
        case .estimated:
            return 0.3
        }
    }
}

struct UAVWorldProvenance: Codable, Hashable, Sendable {
    /// Matches a `UAVWorldAttribution.datasetIdentifier` in the manifest.
    let datasetIdentifier: String
    /// Identifier within that dataset (`way/34633854`, a BIN, a parcel id…), so a feature in the
    /// simulator can be traced back to the record it came from.
    let featureIdentifier: String
    let heightAccuracy: UAVWorldHeightAccuracy
    /// Horizontal positional accuracy of the footprint, in metres, when the source states one.
    let horizontalAccuracyMeters: Double?

    /// Overall 0…1 trust in this feature. Kept as a stored value rather than recomputed, because
    /// importers can lower it for reasons the height accuracy alone does not capture (a
    /// self-intersecting footprint that had to be repaired, a record flagged as provisional).
    let confidence: Float
}

// MARK: - Buildings

/// The shape of a roof, which at UAV altitudes matters more to recognisability than any facade
/// detail — an operator identifies a block from above by its roofline.
enum UAVWorldRoofForm: String, Codable, Sendable {
    case flat
    case gabled
    case hipped
    case pyramidal
    case domed
    case skillion
    case mansard

    /// Whether the form needs a separate roof height beyond the wall height.
    var hasRaisedProfile: Bool {
        self != .flat
    }
}

/// Broad construction class, resolved on import from whatever metadata the source offers, and
/// consumed by the procedural facade material system. This is the seam where "we have real
/// geometry but no photographic facades" is turned into something that still reads as the right
/// city: the class drives window rhythm, material and colour, so a prewar brick walk-up and a
/// glass tower are visibly different buildings even though neither carries a photograph.
enum UAVWorldFacadeClass: String, Codable, Sendable, CaseIterable {
    case brickPrewar
    case stoneMasonry
    case concretePostwar
    case glassCurtainWall
    case metalPanel
    case stucco
    case industrial
    case residentialLowRise
    case unknown
}

/// One building, in local metres relative to the package origin.
///
/// Footprints are stored already projected rather than as lat/lon, because the package is bound
/// to one origin anyway and projecting several hundred thousand vertices at load time would be
/// pure waste. The trade-off is that a package cannot be re-anchored without reprojection.
struct UAVWorldBuilding: Codable, Sendable {
    let id: UUID
    /// Outer footprint ring, counter-clockwise, in local metres on the XZ plane. Not closed —
    /// the last vertex does not repeat the first.
    let footprint: [SIMD2<Float>]
    /// Inner rings (courtyards, light wells). Usually empty.
    let holes: [[SIMD2<Float>]]

    /// Ground elevation at the footprint, in local metres (Y). Separate from height so a
    /// building on a slope sits correctly once real terrain exists.
    let baseElevationMeters: Float
    /// Wall height above `baseElevationMeters`, to the eaves.
    let heightMeters: Float
    /// Additional rise from eaves to ridge for non-flat roofs.
    let roofHeightMeters: Float
    let roofForm: UAVWorldRoofForm

    let facadeClass: UAVWorldFacadeClass
    let levels: Int?
    let yearBuilt: Int?
    /// Named landmarks, so a mission can reference "Woolworth Building" rather than a UUID.
    let name: String?

    let provenance: UAVWorldProvenance

    /// Total height from ground to the highest point — what clearance planning and the radio
    /// obstruction model both need.
    var totalHeightMeters: Float {
        heightMeters + (roofForm.hasRaisedProfile ? roofHeightMeters : 0.0)
    }

    var roofElevationMeters: Float {
        baseElevationMeters + heightMeters
    }

    /// Planar centroid of the outer ring, area-weighted. Used for placement, spatial indexing
    /// and as the anchor for the building's scene node.
    var centroid: SIMD2<Float> {
        guard footprint.count >= 3 else {
            return footprint.first ?? SIMD2<Float>(0, 0)
        }
        var doubleArea: Float = 0.0
        var accumulated = SIMD2<Float>(0, 0)
        for index in footprint.indices {
            let current = footprint[index]
            let next = footprint[(index + 1) % footprint.count]
            let cross = current.x * next.y - next.x * current.y
            doubleArea += cross
            accumulated += (current + next) * cross
        }
        // Degenerate (zero-area or self-cancelling) rings fall back to the vertex average
        // rather than dividing by zero.
        guard abs(doubleArea) > 1e-6 else {
            let sum = footprint.reduce(SIMD2<Float>(0, 0), +)
            return sum / Float(footprint.count)
        }
        return accumulated / (3.0 * doubleArea)
    }

    /// Signed area of the outer ring; positive when counter-clockwise. Importers use the sign to
    /// normalise winding, and the magnitude to reject slivers.
    var signedAreaSquareMeters: Float {
        guard footprint.count >= 3 else { return 0.0 }
        var doubleArea: Float = 0.0
        for index in footprint.indices {
            let current = footprint[index]
            let next = footprint[(index + 1) % footprint.count]
            doubleArea += current.x * next.y - next.x * current.y
        }
        return doubleArea * 0.5
    }

    /// Axis-aligned planar bounds, for the spatial index and for cheap frustum rejection.
    var planarBounds: (minimum: SIMD2<Float>, maximum: SIMD2<Float>) {
        var minimum = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var maximum = SIMD2<Float>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        for vertex in footprint {
            minimum = simd_min(minimum, vertex)
            maximum = simd_max(maximum, vertex)
        }
        return (minimum, maximum)
    }
}
