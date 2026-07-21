import Foundation
import simd

/// Water bodies from OpenStreetMap, via the Overpass API.
///
/// A separate source from the building importer rather than an extra clause in its query, because
/// the two have genuinely different failure modes: a district with no mapped water is completely
/// normal and must not read as a failed import, while a district with no buildings almost certainly
/// means the query or the bounds are wrong.
///
/// This exists because the photogrammetric path infers water from the *shape of the ground* — a
/// large flat area near the lowest elevation — which works on a measured mesh and cannot work at all
/// on open vector data, where the ground is a plane by construction. Here the answer is authoritative
/// instead of inferred: OSM says which polygons are water.
struct OverpassWaterSource: Sendable {

    private let endpoints: [URL]
    private let session: URLSession
    private let queryTimeoutSeconds: Int

    init(
        endpoints: [URL] = OverpassBuildingSource.defaultEndpoints,
        session: URLSession = .shared,
        queryTimeoutSeconds: Int = 90
    ) {
        self.endpoints = endpoints
        self.session = session
        self.queryTimeoutSeconds = queryTimeoutSeconds
    }

    /// Closed rings of water, in geographic coordinates. Empty means "no water here", which is a
    /// perfectly good answer.
    func fetchWaterRings(in bounds: GeoBoundingBox) async throws -> [[GeoCoordinate]] {
        let data = try await execute(query: Self.waterQuery(
            bounds: bounds,
            timeoutSeconds: queryTimeoutSeconds
        ))
        let response = try JSONDecoder().decode(OverpassResponse.self, from: data)

        var rings: [[GeoCoordinate]] = []
        for element in response.elements {
            if let geometry = element.geometry {
                rings.append(Self.closedRing(from: geometry))
            }
            // A multipolygon's outer members carry the shape; inner members are islands, which are
            // deliberately ignored — an island inside a lake is land the aircraft can land on, and
            // treating it as water would be worse than treating the lake as slightly too large.
            for member in element.members ?? [] where member.role == "outer" {
                guard let geometry = member.geometry else { continue }
                rings.append(Self.closedRing(from: geometry))
            }
        }
        return rings.filter { $0.count >= 4 }
    }

    /// `natural=water` covers lakes, ponds and reservoirs; `waterway=riverbank` and `water=river`
    /// cover the wide rivers that a UAV would actually ditch in. Narrow `waterway=stream` lines are
    /// deliberately left out: they have no area, and rasterising a line into a metre-scale mask
    /// would drown aircraft over ditches that a person could step across.
    static func waterQuery(bounds: GeoBoundingBox, timeoutSeconds: Int) -> String {
        let box = bounds.overpassBoundsString
        return """
        [out:json][timeout:\(timeoutSeconds)];
        (
          way["natural"="water"](\(box));
          relation["natural"="water"]["type"="multipolygon"](\(box));
          way["waterway"="riverbank"](\(box));
          way["natural"="coastline"](\(box));
        );
        out geom;
        """
    }

    private static func closedRing(from points: [OverpassPoint]) -> [GeoCoordinate] {
        var ring = points.map {
            GeoCoordinate(latitudeDegrees: $0.lat, longitudeDegrees: $0.lon, altitudeMetersMSL: 0)
        }
        if let first = ring.first, let last = ring.last,
           first.latitudeDegrees != last.latitudeDegrees
            || first.longitudeDegrees != last.longitudeDegrees {
            ring.append(first)
        }
        return ring
    }

    private func execute(query: String) async throws -> Data {
        var lastError: Error?
        for endpoint in endpoints {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)"
                .data(using: .utf8)
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    lastError = UAVWorldImportError.serviceRejected(statusCode: status, message: nil)
                    continue
                }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError ?? UAVWorldImportError.malformedResponse(detail: "overpass water")
    }
}

extension WaterSurfaceModel {

    /// Rasterises water polygons into the same mask the photogrammetric detector produces.
    ///
    /// Deliberately reuses `WaterSurfaceModel` unchanged rather than introducing a polygon-shaped
    /// second representation. Everything downstream — the immersion rule, the spawn search's refusal
    /// to start on water, the sinking wreck — already speaks this one, and a parallel type would have
    /// meant teaching all of them to speak two.
    static func rasterizing(
        rings: [[SIMD2<Float>]],
        halfSpan: Float,
        level: Float,
        cellSize: Float = 4.0
    ) -> WaterSurfaceModel? {
        guard !rings.isEmpty, halfSpan > 0 else { return nil }

        let minimum = SIMD2<Float>(-halfSpan, -halfSpan)
        let columns = max(1, Int((halfSpan * 2 / cellSize).rounded(.up)))
        let rows = columns
        var mask = [Bool](repeating: false, count: columns * rows)

        for column in 0..<columns {
            for row in 0..<rows {
                // Cell centre, so a cell counts as water when its middle is inside a polygon rather
                // than when it merely touches one.
                let point = SIMD2<Float>(
                    minimum.x + (Float(column) + 0.5) * cellSize,
                    minimum.y + (Float(row) + 0.5) * cellSize
                )
                if rings.contains(where: { Self.contains(ring: $0, point: point) }) {
                    mask[row * columns + column] = true
                }
            }
        }

        guard mask.contains(true) else { return nil }
        return WaterSurfaceModel(
            level: level,
            minimum: minimum,
            cellSize: cellSize,
            columns: columns,
            rows: rows,
            mask: mask
        )
    }

    /// Even-odd ray crossing. Chosen over winding number because OSM ring orientation is not
    /// dependable, and even-odd does not care.
    private static func contains(ring: [SIMD2<Float>], point: SIMD2<Float>) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.y > point.y) != (b.y > point.y) {
                let t = (point.y - a.y) / (b.y - a.y)
                if point.x < a.x + t * (b.x - a.x) { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}
