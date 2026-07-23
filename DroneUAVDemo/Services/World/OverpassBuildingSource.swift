import Foundation

/// Building geometry from OpenStreetMap, via the Overpass API.
///
/// OSM is the baseline source for every region on Earth, which is exactly what a
/// world-constructor needs: it will never match a national LiDAR survey, but it is the only
/// dataset that covers everywhere under one schema and one licence. Where a better municipal
/// source exists, `UAVWorldBuildingSource.fidelityRank` lets the builder prefer it and fall
/// back to OSM for whatever it does not cover.
///
/// Data is © OpenStreetMap contributors, ODbL 1.0. That licence follows the data into any
/// derived package, which is why `attribution` is part of the protocol rather than a UI detail.
final class OverpassBuildingSource: UAVWorldBuildingSource {
    /// Public Overpass instances, tried in order. The primary endpoint is frequently at
    /// capacity and answers 429/504 under load, and a single-endpoint importer fails far more
    /// often than the data availability actually warrants.
    static let defaultEndpoints: [URL] = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
        URL(string: "https://overpass.osm.ch/api/interpreter")!
    ]

    private let endpoints: [URL]
    private let session: URLSession
    private let queryTimeoutSeconds: Int

    let attribution = UAVWorldAttribution(
        datasetIdentifier: "osm",
        displayName: "OpenStreetMap contributors",
        license: "ODbL 1.0",
        sourceURL: "https://www.openstreetmap.org/copyright"
    )

    /// Lowest rank: crowd-sourced outlines with highly variable height coverage.
    let fidelityRank = 10

    init(
        endpoints: [URL] = OverpassBuildingSource.defaultEndpoints,
        session: URLSession = .shared,
        queryTimeoutSeconds: Int = 90
    ) {
        self.endpoints = endpoints
        self.session = session
        self.queryTimeoutSeconds = queryTimeoutSeconds
    }

    // MARK: - Fetch

    func fetchBuildings(in bounds: GeoBoundingBox) async throws -> [UAVWorldRawBuilding] {
        let query = Self.buildingQuery(bounds: bounds, timeoutSeconds: queryTimeoutSeconds)
        let data = try await execute(query: query)

        let response: OverpassResponse
        do {
            response = try JSONDecoder().decode(OverpassResponse.self, from: data)
        } catch {
            throw UAVWorldImportError.malformedResponse(detail: error.localizedDescription)
        }

        let buildings = response.elements.compactMap(Self.makeRawBuilding)
        guard !buildings.isEmpty else {
            throw UAVWorldImportError.emptyResult
        }
        return buildings
    }

    /// `out geom` inlines each way's coordinates in the response, which avoids a second pass to
    /// resolve node references — at the cost of a larger payload. For the tile sizes this
    /// importer handles that trade is clearly worth it.
    static func buildingQuery(bounds: GeoBoundingBox, timeoutSeconds: Int) -> String {
        let box = bounds.overpassBoundsString
        return """
        [out:json][timeout:\(timeoutSeconds)];
        (
          way["building"](\(box));
          relation["building"]["type"="multipolygon"](\(box));
        );
        out geom;
        """
    }

    private func execute(query: String) async throws -> Data {
        var lastError: Error = UAVWorldImportError.networkFailure(
            underlying: URLError(.unknown)
        )

        for endpoint in endpoints {
            try Task.checkCancellation()

            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)"
                .data(using: .utf8)
            request.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type"
            )
            // Overpass asks clients to identify themselves; anonymous bulk traffic gets
            // throttled first.
            request.setValue("UAVsim/1.0 (flight simulator world importer)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = TimeInterval(queryTimeoutSeconds + 30)

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastError = UAVWorldImportError.malformedResponse(detail: "non-HTTP response")
                    continue
                }
                if http.statusCode == 200 {
                    return data
                }
                // 429 (rate limited) and 504 (query timed out server-side) are the endpoint
                // being busy rather than the request being wrong, so another mirror is worth
                // trying. Anything else is reported as-is.
                let message = String(data: data.prefix(400), encoding: .utf8)
                lastError = UAVWorldImportError.serviceRejected(
                    statusCode: http.statusCode,
                    message: message
                )
                if http.statusCode != 429 && http.statusCode != 504 && http.statusCode != 503 {
                    throw lastError
                }
            } catch is CancellationError {
                throw UAVWorldImportError.cancelled
            } catch let error as UAVWorldImportError {
                throw error
            } catch {
                lastError = UAVWorldImportError.networkFailure(underlying: error)
            }
        }

        throw lastError
    }

    // MARK: - Element → raw building

    static func makeRawBuilding(from element: OverpassElement) -> UAVWorldRawBuilding? {
        let rings: [[GeoCoordinate]]

        switch element.type {
        case "way":
            guard let geometry = element.geometry else { return nil }
            let ring = closedRing(from: geometry)
            guard ring.count >= 3 else { return nil }
            rings = [ring]

        case "relation":
            // Multipolygon buildings: outer rings define the shape, inner rings are courtyards.
            // Overpass returns each member's geometry separately and a large building may be
            // split across several outer ways; stitching those into continuous rings is real
            // work, so for now the largest single outer member is used and the rest ignored.
            // That under-represents a handful of complex blocks rather than dropping them.
            guard let members = element.members else { return nil }
            let outers = members
                .filter { $0.role == "outer" }
                .compactMap { $0.geometry.map(closedRing) }
                .filter { $0.count >= 3 }
            guard let largestOuter = outers.max(by: { approximateRingSpan($0) < approximateRingSpan($1) })
            else { return nil }

            let inners = members
                .filter { $0.role == "inner" }
                .compactMap { $0.geometry.map(closedRing) }
                .filter { $0.count >= 3 }
            rings = [largestOuter] + inners

        default:
            return nil
        }

        let tags = element.tags ?? [:]
        // `building=no` explicitly marks a footprint that is not a building.
        guard let buildingTag = tags["building"], buildingTag != "no" else { return nil }
        // Some OSM sculptures carry `building=yes` solely to give renderers a closed 3D outline.
        // Extruding those as occupied masonry produces a conspicuous fake building. The American
        // Merchant Mariners' Memorial is the local example: it is a bronze sinking-vessel
        // composition in the harbour, explicitly tagged `memorial=statue`.
        guard tags["memorial"] != "statue",
              tags["artwork_type"] != "sculpture" else {
            return nil
        }

        let record = UAVWorldBuildingSourceRecord(
            useClass: normalizedUseClass(buildingTag: buildingTag, tags: tags),
            claddingMaterial: normalizedMaterial(tags: tags),
            levels: parseLevels(tags["building:levels"]),
            yearBuilt: parseYear(tags["start_date"] ?? tags["building:start_date"]),
            statedHeightMeters: parseHeight(tags["height"] ?? tags["building:height"]),
            // Filled in by the builder once the ring is projected; area in degrees is
            // meaningless and using it here would silently mis-scale every estimate.
            footprintAreaSquareMeters: 0.0,
            name: tags["name"],
            roofShape: tags["roof:shape"]
        )

        return UAVWorldRawBuilding(
            rings: rings,
            record: record,
            featureIdentifier: "\(element.type)/\(element.id)"
        )
    }

    /// OSM closed ways repeat the first node as the last; the simulator's rings are implicitly
    /// closed, so the duplicate is dropped.
    private static func closedRing(from points: [OverpassPoint]) -> [GeoCoordinate] {
        var coordinates = points.map {
            GeoCoordinate(latitudeDegrees: $0.lat, longitudeDegrees: $0.lon)
        }
        if let first = coordinates.first, let last = coordinates.last,
           abs(first.latitudeDegrees - last.latitudeDegrees) < 1e-12,
           abs(first.longitudeDegrees - last.longitudeDegrees) < 1e-12 {
            coordinates.removeLast()
        }
        return coordinates
    }

    /// Cheap degree-space extent, used only to compare candidate rings against each other.
    private static func approximateRingSpan(_ ring: [GeoCoordinate]) -> Double {
        guard !ring.isEmpty else { return 0.0 }
        let latitudes = ring.map(\.latitudeDegrees)
        let longitudes = ring.map(\.longitudeDegrees)
        let latitudeSpan = (latitudes.max() ?? 0) - (latitudes.min() ?? 0)
        let longitudeSpan = (longitudes.max() ?? 0) - (longitudes.min() ?? 0)
        return latitudeSpan * longitudeSpan
    }

    // MARK: - Tag parsing

    /// OSM height values are notoriously inconsistent: bare metres, an explicit unit, or
    /// imperial feet-and-inches notation. Misreading `115'` as 115 metres would put a
    /// thirty-five-metre building three times too tall, so units are handled explicitly rather
    /// than by grabbing the leading number.
    static func parseHeight(_ raw: String?) -> Float? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !text.isEmpty else {
            return nil
        }

        // Feet-and-inches: 115'6" or 115'
        if text.contains("'") {
            let parts = text.split(separator: "'", omittingEmptySubsequences: false)
            let feet = Float(parts.first?.trimmingCharacters(in: .whitespaces) ?? "") ?? 0
            var inches: Float = 0
            if parts.count > 1 {
                let inchText = parts[1].replacingOccurrences(of: "\"", with: "")
                    .trimmingCharacters(in: .whitespaces)
                inches = Float(inchText) ?? 0
            }
            let meters = (feet * 12.0 + inches) * 0.0254
            return meters > 0 ? meters : nil
        }

        var isFeet = false
        for suffix in ["ft", "feet", "foot"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
            isFeet = true
            break
        }
        if !isFeet {
            for suffix in ["m", "meter", "meters", "metre", "metres"] where text.hasSuffix(suffix) {
                text = String(text.dropLast(suffix.count))
                break
            }
        }

        text = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Float(text), value.isFinite, value > 0 else { return nil }
        return isFeet ? value * 0.3048 : value
    }

    /// Levels are usually a plain integer, occasionally a semicolon-separated set for a building
    /// with sections of differing height. The maximum is taken, since it bounds the silhouette.
    static func parseLevels(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let candidates = raw.split(whereSeparator: { $0 == ";" || $0 == "," })
            .compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
        guard let maximum = candidates.max() else { return nil }
        let rounded = Int(maximum.rounded())
        return (rounded > 0 && rounded < 250) ? rounded : nil
    }

    /// `start_date` follows a loose OSM date convention: a bare year, an ISO-ish prefix, a
    /// century code (`C19`), or a range (`1920..1930`).
    static func parseYear(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !raw.isEmpty else {
            return nil
        }

        // Century notation: C19 means the 1800s.
        if raw.hasPrefix("C"), let century = Int(raw.dropFirst()), century > 0, century <= 21 {
            return (century - 1) * 100 + 50
        }

        // Range: take the earlier bound, which is when construction began.
        if raw.contains("..") {
            let parts = raw.components(separatedBy: "..")
            if let first = parts.first, let year = Int(first.prefix(4)) {
                return plausibleYear(year)
            }
        }

        // Leading four-digit year, covering both "1931" and "1931-05-01".
        let prefix = raw.prefix(4)
        if let year = Int(prefix) {
            return plausibleYear(year)
        }
        return nil
    }

    private static func plausibleYear(_ year: Int) -> Int? {
        (year > 1000 && year <= 2100) ? year : nil
    }

    static func normalizedMaterial(tags: [String: String]) -> String? {
        let raw = tags["building:facade:material"]
            ?? tags["building:material"]
            ?? tags["material"]
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return nil
        }
        // Take the first of a multi-valued tag; the classifier wants a single dominant hint.
        return raw.split(separator: ";").first.map(String.init)
    }

    /// Lowers the open-ended `building=*` vocabulary into the neutral use classes the
    /// classifier understands. `building=yes` carries no information, so other tags are
    /// consulted before giving up.
    static func normalizedUseClass(buildingTag: String, tags: [String: String]) -> String? {
        let value = buildingTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if value != "yes" && value != "building" {
            switch value {
            case "apartments", "residential", "house", "detached", "terrace", "bungalow",
                 "dormitory", "semidetached_house":
                return value == "semidetached_house" ? "house" : value
            case "commercial", "office", "retail", "supermarket", "kiosk", "hotel":
                return value == "supermarket" || value == "kiosk" ? "retail" : value
            case "industrial", "warehouse", "factory", "hangar", "manufacture":
                return value == "manufacture" || value == "factory" ? "industrial" : value
            case "church", "cathedral", "chapel", "mosque", "synagogue", "temple":
                return value == "cathedral" ? "cathedral" : "church"
            case "school", "university", "college", "kindergarten":
                return "school"
            case "hospital", "clinic":
                return "hospital"
            case "garage", "garages", "carport", "shed", "hut", "roof":
                return value == "garages" ? "garage" : value
            case "civic", "government", "public", "museum", "train_station":
                return value == "museum" ? "museum" : "civic"
            default:
                return value
            }
        }

        // `building=yes` — fall back to whatever functional tag is present.
        if tags["shop"] != nil { return "retail" }
        if tags["office"] != nil { return "office" }
        if let amenity = tags["amenity"] {
            switch amenity {
            case "school", "university", "college", "kindergarten": return "school"
            case "hospital", "clinic", "doctors": return "hospital"
            case "place_of_worship": return "church"
            default: break
            }
        }
        if tags["industrial"] != nil || tags["man_made"] == "works" { return "industrial" }
        return nil
    }
}

// MARK: - Overpass response model

struct OverpassResponse: Decodable, Sendable {
    let elements: [OverpassElement]
}

struct OverpassElement: Decodable, Sendable {
    let type: String
    let id: Int64
    let tags: [String: String]?
    let geometry: [OverpassPoint]?
    let members: [OverpassMember]?
}

struct OverpassPoint: Decodable, Sendable {
    let lat: Double
    let lon: Double
}

struct OverpassMember: Decodable, Sendable {
    let type: String
    let ref: Int64
    let role: String
    let geometry: [OverpassPoint]?
}
