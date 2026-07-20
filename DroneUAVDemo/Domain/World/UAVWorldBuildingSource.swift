import Foundation

/// A building exactly as a source dataset described it: rings still in geographic coordinates,
/// metadata already lowered into this project's neutral vocabulary, nothing yet decided about
/// how it will be rendered or collided.
///
/// Keeping rings geographic at this stage is deliberate. Projection needs the world origin,
/// which is not chosen until every source has been queried and the real extent is known, so a
/// source that projected early would have to be re-projected or would silently pin the world to
/// its own idea of centre.
struct UAVWorldRawBuilding: Sendable {
    /// Ring 0 is the outer boundary; any further rings are holes. Rings are not closed — the
    /// first vertex is not repeated at the end.
    let rings: [[GeoCoordinate]]
    let record: UAVWorldBuildingSourceRecord
    /// Identifier within the source dataset, kept so a building in the simulator can be traced
    /// back to the record it came from.
    let featureIdentifier: String

    var outerRing: [GeoCoordinate] { rings.first ?? [] }
    var holes: [[GeoCoordinate]] { rings.count > 1 ? Array(rings.dropFirst()) : [] }
}

/// One provider of building geometry for a region.
///
/// This is the seam that makes the importer a constructor rather than a loader for one city.
/// OpenStreetMap covers the whole planet at variable quality; a national or municipal open-data
/// portal covers one jurisdiction at much higher quality. Both satisfy this protocol, and the
/// builder merges them by preferring the more accurate source where they overlap — so a region
/// with good government data gets near-survey fidelity, and everywhere else still gets a
/// flyable world.
protocol UAVWorldBuildingSource: Sendable {
    /// Attribution for whatever this source returns. Carried into the package manifest, because
    /// several of the licences involved (ODbL in particular) require it to travel with derived
    /// data.
    var attribution: UAVWorldAttribution { get }

    /// Rough quality ranking used when two sources cover the same building. Higher wins.
    /// Surveyed municipal data outranks crowd-sourced outlines.
    var fidelityRank: Int { get }

    func fetchBuildings(in bounds: GeoBoundingBox) async throws -> [UAVWorldRawBuilding]
}

enum UAVWorldImportError: LocalizedError {
    case invalidRegion
    case networkFailure(underlying: Error)
    case serviceRejected(statusCode: Int, message: String?)
    case malformedResponse(detail: String)
    case emptyResult
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidRegion:
            return L10n.s("world.import.error.invalid_region")
        case .networkFailure(let underlying):
            return L10n.f("world.import.error.network", underlying.localizedDescription)
        case .serviceRejected(let statusCode, let message):
            if let message, !message.isEmpty {
                return L10n.f("world.import.error.service_message", statusCode, message)
            }
            return L10n.f("world.import.error.service", statusCode)
        case .malformedResponse(let detail):
            return L10n.f("world.import.error.malformed", detail)
        case .emptyResult:
            return L10n.s("world.import.error.empty")
        case .cancelled:
            return L10n.s("world.import.error.cancelled")
        }
    }
}
