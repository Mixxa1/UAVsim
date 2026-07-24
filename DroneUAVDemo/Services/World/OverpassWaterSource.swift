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

    /// Geographic OSM area roles before projection into the simulator's local metre grid.
    struct Geometry: Sendable {
        struct LinearWaterway: Sendable {
            let centerline: [GeoCoordinate]
            let widthMeters: Float
        }

        var outerRings: [[GeoCoordinate]] = []
        var innerRings: [[GeoCoordinate]] = []
        var landRings: [[GeoCoordinate]] = []
        var landInnerRings: [[GeoCoordinate]] = []
        var coastlineSegments: [[GeoCoordinate]] = []
        var linearWaterways: [LinearWaterway] = []
    }

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

    /// Closed water rings and the real OSM areas which cut them.
    ///
    /// Lower Manhattan demonstrates why the roles cannot be flattened. East River is one water
    /// multipolygon whose outer boundary is split among coastline ways, while Pier 11 and Pier 17
    /// are independent `man_made=pier` areas over that water. Treating every member as an outer ring
    /// produces the broken rectangular slivers from the screenshot; ignoring the piers leaves their
    /// buildings apparently standing in the river.
    func fetchWaterGeometry(in bounds: GeoBoundingBox) async throws -> Geometry {
        let data = try await execute(query: Self.waterQuery(
            bounds: bounds,
            timeoutSeconds: queryTimeoutSeconds
        ))
        let response = try JSONDecoder().decode(OverpassResponse.self, from: data)

        var result = Geometry()
        for element in response.elements {
            let tags = element.tags ?? [:]
            let isPier = tags["man_made"] == "pier"
            let isWater = tags["natural"] == "water"
                || tags["waterway"] == "riverbank"
                || tags["waterway"] == "dock"
                || tags["landuse"] == "reservoir"
            let isCoastline = tags["natural"] == "coastline"

            if element.type == "way", let points = element.geometry {
                if isCoastline, points.count >= 2 {
                    // Do not close this path. Direction is the data: OSM guarantees land on the
                    // left and sea on the right, including where a way continues outside our box.
                    result.coastlineSegments.append(Self.coordinates(from: points))
                }
                if let ring = Self.closedWayRing(from: points) {
                    if isPier {
                        result.landRings.append(ring)
                    } else if isWater {
                        result.outerRings.append(ring)
                    }
                }
                if Self.isLinearWaterway(tags: tags),
                   points.count >= 2,
                   tags["area"] != "yes",
                   Self.closedWayRing(from: points) == nil {
                    result.linearWaterways.append(.init(
                        centerline: Self.coordinates(from: points),
                        widthMeters: Self.waterwayWidth(tags: tags)
                    ))
                }
            }

            guard element.type == "relation", tags["type"] == "multipolygon",
                  isPier || isWater else { continue }

            // A multipolygon boundary is split across member ways. Only a complete stitched loop is
            // an area; closing an individual open member with a synthetic straight edge is precisely
            // what produced the square wedges along the old shoreline.
            let outerSegments = (element.members ?? [])
                .filter { $0.role == "outer" }
                .compactMap { $0.geometry }
                .filter { $0.count >= 2 }
            let innerSegments = (element.members ?? [])
                .filter { $0.role == "inner" }
                .compactMap { $0.geometry }
                .filter { $0.count >= 2 }
            let outers = Self.assembleClosedRings(from: outerSegments)
            let inners = Self.assembleClosedRings(from: innerSegments)

            if isPier {
                result.landRings.append(contentsOf: outers)
                result.landInnerRings.append(contentsOf: inners)
            } else {
                result.outerRings.append(contentsOf: outers)
                result.innerRings.append(contentsOf: inners)
            }
        }
        return result
    }

    /// `natural=water` covers lakes, ponds, rivers and harbours as filled areas; its multipolygon
    /// form carries the large rivers; `waterway=riverbank` covers the rest.
    ///
    /// `natural=coastline` is an oriented line, not an area. It is nevertheless essential here:
    /// OSM does not wrap the Atlantic, Hudson or New York Harbor in `natural=water` polygons. The
    /// rasteriser uses the tag's direction contract (land left, sea right) to fill the marine side.
    /// Piers are fetched in the same response so the water mask can subtract real mapped land.
    /// OSM permits an area pier to be a closed `man_made=pier` way without the redundant
    /// `area=yes` tag. The geometry parser below already rejects open ways as rings, so querying
    /// every pier preserves linear piers as lines while no longer missing closed areas such as
    /// Lower Manhattan's City Pier A.
    static func waterQuery(bounds: GeoBoundingBox, timeoutSeconds: Int) -> String {
        let box = bounds.overpassBoundsString
        return """
        [out:json][timeout:\(timeoutSeconds)];
        (
          way["natural"="water"](\(box));
          relation["natural"="water"]["type"="multipolygon"](\(box));
          way["waterway"="riverbank"](\(box));
          relation["waterway"="riverbank"]["type"="multipolygon"](\(box));
          way["waterway"="dock"](\(box));
          relation["waterway"="dock"]["type"="multipolygon"](\(box));
          way["landuse"="reservoir"](\(box));
          relation["landuse"="reservoir"]["type"="multipolygon"](\(box));
          way["waterway"~"^(river|canal|stream|tidal_channel|drain|ditch)$"](\(box));
          way["natural"="coastline"](\(box));
          way["man_made"="pier"](\(box));
          relation["man_made"="pier"]["type"="multipolygon"](\(box));
        );
        out geom;
        """
    }

    /// Stitches multipolygon member ways into closed rings by matching shared endpoints.
    ///
    /// Standard OSM ring assembly: grow one loop at a time, appending any remaining segment that
    /// continues the running end (in either direction), and close the loop when it meets its own
    /// start. A tolerance covers the tiny disagreement two projected copies of the same node can
    /// have; in OSM they are literally the same node, so exact matches are the norm.
    static func assembleClosedRings(
        from segments: [[OverpassPoint]]
    ) -> [[GeoCoordinate]] {
        func near(_ a: OverpassPoint, _ b: OverpassPoint) -> Bool {
            // Relation members share an OSM node and normally match exactly. Five centimetres still
            // tolerates JSON round-off without joining two distinct vertices on a dense waterfront.
            let meanLatitude = (a.lat + b.lat) * 0.5 * .pi / 180
            let north = (a.lat - b.lat) * 111_320
            let east = (a.lon - b.lon) * 111_320 * cos(meanLatitude)
            return north * north + east * east <= 0.05 * 0.05
        }

        var pending = segments
        var rings: [[GeoCoordinate]] = []

        while !pending.isEmpty {
            var loop = pending.removeLast()
            var extended = true
            while extended, !(loop.count > 3 && near(loop.first!, loop.last!)) {
                extended = false
                for index in pending.indices {
                    let segment = pending[index]
                    if near(segment.first!, loop.last!) {
                        loop.append(contentsOf: segment.dropFirst())
                    } else if near(segment.last!, loop.last!) {
                        loop.append(contentsOf: segment.reversed().dropFirst())
                    } else if near(segment.last!, loop.first!) {
                        loop.insert(contentsOf: segment.dropLast(), at: 0)
                    } else if near(segment.first!, loop.first!) {
                        loop.insert(contentsOf: segment.reversed().dropLast(), at: 0)
                    } else {
                        continue
                    }
                    pending.remove(at: index)
                    extended = true
                    break
                }
            }
            // `out geom` returns complete relation members even when the relation merely intersects
            // the requested box. An open result is therefore malformed/incomplete source data, not
            // an invitation to invent a diagonal shoreline across the map.
            if loop.count >= 4, near(loop.first!, loop.last!) {
                rings.append(Self.closedRing(from: loop))
            }
        }
        return rings
    }

    static func closedWayRing(from points: [OverpassPoint]) -> [GeoCoordinate]? {
        guard points.count >= 4, let first = points.first, let last = points.last,
              first.lat == last.lat, first.lon == last.lon else { return nil }
        return closedRing(from: points)
    }

    private static func coordinates(from points: [OverpassPoint]) -> [GeoCoordinate] {
        points.map {
            GeoCoordinate(latitudeDegrees: $0.lat, longitudeDegrees: $0.lon, altitudeMetersMSL: 0)
        }
    }

    private static func isLinearWaterway(tags: [String: String]) -> Bool {
        guard let waterway = tags["waterway"]?.lowercased() else { return false }
        return ["river", "canal", "stream", "tidal_channel", "drain", "ditch"].contains(waterway)
    }

    private static func waterwayWidth(tags: [String: String]) -> Float {
        if let width = parseMeters(tags["width"]), width >= 0.5 {
            return min(width, 200)
        }
        switch tags["waterway"]?.lowercased() {
        case "river": return 20
        case "canal": return 12
        case "tidal_channel": return 8
        case "stream": return 3
        case "drain": return 2
        default: return 1.5
        }
    }

    private static func parseMeters(_ raw: String?) -> Float? {
        guard var value = raw?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: ",", with: ".")
        let number = value.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        guard let parsed = Float(number), parsed.isFinite, parsed > 0 else { return nil }
        if value.contains("ft") || value.contains("'") { return parsed * 0.3048 }
        if value.contains("cm") { return parsed * 0.01 }
        return parsed
    }

    private static func closedRing(from points: [OverpassPoint]) -> [GeoCoordinate] {
        var ring = coordinates(from: points)
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

// MARK: - Roads, bridges and vegetation

/// All non-building OSM surface features needed by the generated world.
///
/// The transport/bridge and vegetation/tree extracts are intentionally separate. Both still cover
/// the complete bbox, while an overloaded public Overpass instance can no longer erase every
/// surface layer merely because one large category timed out.
struct OverpassSurfaceFeatureSource: Sendable {
    struct RawTransport: Sendable {
        let sourceIdentifier: String
        let centerline: [GeoCoordinate]
        let kind: UAVWorldTransportKind
        let widthMeters: Float
        let surface: String?
        let isBridge: Bool
        let layer: Int
        let clearanceMeters: Float
    }

    struct RawVegetationArea: Sendable {
        let sourceIdentifier: String
        let outerRing: [GeoCoordinate]
        let holes: [[GeoCoordinate]]
        let kind: UAVWorldVegetationKind
    }

    struct RawBridgeArea: Sendable {
        let sourceIdentifier: String
        let outerRing: [GeoCoordinate]
        let holes: [[GeoCoordinate]]
        let layer: Int
        let clearanceMeters: Float
    }

    struct RawTree: Sendable {
        let sourceIdentifier: String
        let coordinate: GeoCoordinate
        let kind: UAVWorldVegetationKind
    }

    struct Geometry: Sendable {
        var transport: [RawTransport] = []
        var bridgeAreas: [RawBridgeArea] = []
        var vegetationAreas: [RawVegetationArea] = []
        var trees: [RawTree] = []
    }

    private let endpoints: [URL]
    private let session: URLSession
    private let queryTimeoutSeconds: Int

    init(
        endpoints: [URL] = OverpassBuildingSource.defaultEndpoints,
        session: URLSession = .shared,
        queryTimeoutSeconds: Int = 120
    ) {
        self.endpoints = endpoints
        self.session = session
        self.queryTimeoutSeconds = queryTimeoutSeconds
    }

    func fetch(in bounds: GeoBoundingBox) async throws -> Geometry {
        var elements: [OverpassElement] = []
        var successfulRequestCount = 0
        var lastError: Error?
        for query in Self.queries(bounds: bounds, timeoutSeconds: queryTimeoutSeconds) {
            do {
                let data = try await execute(query: query)
                let response = try JSONDecoder().decode(OverpassResponse.self, from: data)
                elements.append(contentsOf: response.elements)
                successfulRequestCount += 1
            } catch is CancellationError {
                throw UAVWorldImportError.cancelled
            } catch UAVWorldImportError.cancelled {
                throw UAVWorldImportError.cancelled
            } catch {
                lastError = error
            }
        }
        guard successfulRequestCount > 0 else {
            throw lastError ?? UAVWorldImportError.malformedResponse(detail: "overpass surface")
        }

        let vegetationRelationMembers = Set(
            elements
                .filter {
                    $0.type == "relation"
                        && $0.tags?["type"] == "multipolygon"
                        && Self.vegetationKind(tags: $0.tags ?? [:]) != nil
                }
                .flatMap { ($0.members ?? []).map(\.ref) }
        )
        let bridgeRelationMembers = Set(
            elements
                .filter {
                    $0.type == "relation"
                        && $0.tags?["type"] == "multipolygon"
                        && $0.tags?["man_made"] == "bridge"
                }
                .flatMap { ($0.members ?? []).map(\.ref) }
        )

        var result = Geometry()
        for element in elements {
            let tags = element.tags ?? [:]
            let identifier = "\(element.type)/\(element.id)"

            if element.type == "way",
               let points = element.geometry,
               points.count >= 2,
               let kind = Self.transportKind(tags: tags) {
                result.transport.append(RawTransport(
                    sourceIdentifier: identifier,
                    centerline: Self.coordinates(from: points),
                    kind: kind,
                    widthMeters: Self.transportWidth(tags: tags, kind: kind),
                    surface: tags["surface"]?.lowercased(),
                    isBridge: Self.isBridge(tags: tags),
                    layer: Self.layer(tags: tags),
                    clearanceMeters: Self.bridgeClearance(tags: tags)
                ))
            }

            if tags["man_made"] == "bridge" {
                if element.type == "way" {
                    if !bridgeRelationMembers.contains(element.id),
                       let points = element.geometry,
                       let ring = OverpassWaterSource.closedWayRing(from: points) {
                        result.bridgeAreas.append(RawBridgeArea(
                            sourceIdentifier: identifier,
                            outerRing: ring,
                            holes: [],
                            layer: Self.layer(tags: tags),
                            clearanceMeters: Self.bridgeClearance(tags: tags)
                        ))
                    }
                } else if element.type == "relation", tags["type"] == "multipolygon" {
                    let members = element.members ?? []
                    let outers = OverpassWaterSource.assembleClosedRings(
                        from: members
                            .filter { $0.role == "outer" }
                            .compactMap(\.geometry)
                            .filter { $0.count >= 2 }
                    )
                    let inners = OverpassWaterSource.assembleClosedRings(
                        from: members
                            .filter { $0.role == "inner" }
                            .compactMap(\.geometry)
                            .filter { $0.count >= 2 }
                    )
                    for (index, outer) in outers.enumerated() {
                        result.bridgeAreas.append(RawBridgeArea(
                            sourceIdentifier: "\(identifier)/outer-\(index)",
                            outerRing: outer,
                            holes: inners.filter { Self.ring($0, liesInside: outer) },
                            layer: Self.layer(tags: tags),
                            clearanceMeters: Self.bridgeClearance(tags: tags)
                        ))
                    }
                }
            }

            if element.type == "node",
               tags["natural"] == "tree",
               let latitude = element.lat,
               let longitude = element.lon {
                result.trees.append(RawTree(
                    sourceIdentifier: identifier,
                    coordinate: GeoCoordinate(
                        latitudeDegrees: latitude,
                        longitudeDegrees: longitude
                    ),
                    kind: .forest
                ))
            }

            if element.type == "node",
               tags["natural"] == "shrub",
               let latitude = element.lat,
               let longitude = element.lon {
                result.trees.append(RawTree(
                    sourceIdentifier: identifier,
                    coordinate: GeoCoordinate(
                        latitudeDegrees: latitude,
                        longitudeDegrees: longitude
                    ),
                    kind: .scrub
                ))
            }

            if element.type == "way",
               tags["natural"] == "tree_row",
               let points = element.geometry,
               points.count >= 2 {
                let row = Self.coordinates(from: points)
                for (index, coordinate) in Self.samplesAlong(row, spacingMeters: 8).enumerated() {
                    result.trees.append(RawTree(
                        sourceIdentifier: "\(identifier)/tree-\(index)",
                        coordinate: coordinate,
                        kind: .forest
                    ))
                }
            }

            if element.type == "way",
               tags["barrier"] == "hedge",
               let points = element.geometry,
               points.count >= 2 {
                let row = Self.coordinates(from: points)
                for (index, coordinate) in Self.samplesAlong(row, spacingMeters: 3).enumerated() {
                    result.trees.append(RawTree(
                        sourceIdentifier: "\(identifier)/shrub-\(index)",
                        coordinate: coordinate,
                        kind: .scrub
                    ))
                }
            }

            guard let vegetationKind = Self.vegetationKind(tags: tags) else { continue }
            if element.type == "way" {
                // A member way and its parent relation describe the same area. Prefer the relation,
                // because only it carries the complete outer/inner topology.
                guard !vegetationRelationMembers.contains(element.id),
                      let points = element.geometry,
                      let ring = OverpassWaterSource.closedWayRing(from: points) else {
                    continue
                }
                result.vegetationAreas.append(RawVegetationArea(
                    sourceIdentifier: identifier,
                    outerRing: ring,
                    holes: [],
                    kind: vegetationKind
                ))
            } else if element.type == "relation", tags["type"] == "multipolygon" {
                let members = element.members ?? []
                let outers = OverpassWaterSource.assembleClosedRings(
                    from: members
                        .filter { $0.role == "outer" }
                        .compactMap(\.geometry)
                        .filter { $0.count >= 2 }
                )
                let inners = OverpassWaterSource.assembleClosedRings(
                    from: members
                        .filter { $0.role == "inner" }
                        .compactMap(\.geometry)
                        .filter { $0.count >= 2 }
                )
                for (index, outer) in outers.enumerated() {
                    result.vegetationAreas.append(RawVegetationArea(
                        sourceIdentifier: "\(identifier)/outer-\(index)",
                        outerRing: outer,
                        holes: inners.filter { Self.ring($0, liesInside: outer) },
                        kind: vegetationKind
                    ))
                }
            }
        }
        return result
    }

    static func queries(bounds: GeoBoundingBox, timeoutSeconds: Int) -> [String] {
        let box = bounds.overpassBoundsString
        return [
            """
            [out:json][timeout:\(timeoutSeconds)];
            (
              way["highway"](\(box));
              way["railway"]["bridge"](\(box));
              way["man_made"="bridge"](\(box));
              relation["man_made"="bridge"]["type"="multipolygon"](\(box));
            );
            out geom;
            """,
            """
            [out:json][timeout:\(timeoutSeconds)];
            (
              way["natural"="tree_row"](\(box));
              node["natural"="tree"](\(box));
              node["natural"="shrub"](\(box));
              way["barrier"="hedge"](\(box));
              way["landuse"~"^(forest|grass|meadow|orchard|vineyard|plant_nursery|flowerbed|recreation_ground)$"](\(box));
              relation["landuse"~"^(forest|grass|meadow|orchard|vineyard|plant_nursery|flowerbed|recreation_ground)$"]["type"="multipolygon"](\(box));
              way["natural"~"^(wood|scrub|grassland|heath|shrubbery)$"](\(box));
              relation["natural"~"^(wood|scrub|grassland|heath|shrubbery)$"]["type"="multipolygon"](\(box));
              way["leisure"~"^(park|garden)$"](\(box));
              relation["leisure"~"^(park|garden)$"]["type"="multipolygon"](\(box));
            );
            out geom;
            """
        ]
    }

    private static func transportKind(tags: [String: String]) -> UAVWorldTransportKind? {
        if let railway = tags["railway"]?.lowercased(),
           isBridge(tags: tags),
           !["abandoned", "disused", "razed", "construction", "proposed"].contains(railway) {
            return .railway
        }
        guard let highway = tags["highway"]?.lowercased(),
              !["construction", "proposed", "abandoned", "razed", "raceway"].contains(highway)
        else { return nil }
        switch highway {
        case "motorway", "motorway_link": return .motorway
        case "trunk", "trunk_link", "primary", "primary_link", "secondary",
             "secondary_link", "tertiary", "tertiary_link":
            return .arterial
        case "residential", "living_street", "unclassified": return .street
        case "service", "road": return .service
        case "track": return .track
        default: return .pedestrian
        }
    }

    private static func vegetationKind(tags: [String: String]) -> UAVWorldVegetationKind? {
        switch tags["landuse"]?.lowercased() {
        case "forest": return .forest
        case "grass", "flowerbed", "recreation_ground": return .grass
        case "meadow": return .meadow
        case "orchard", "vineyard", "plant_nursery": return .orchard
        default: break
        }
        switch tags["natural"]?.lowercased() {
        case "wood": return .forest
        case "scrub", "heath", "shrubbery": return .scrub
        case "grassland": return .meadow
        default: break
        }
        switch tags["leisure"]?.lowercased() {
        case "park", "garden": return .garden
        default: return nil
        }
    }

    private static func isBridge(tags: [String: String]) -> Bool {
        guard let value = tags["bridge"]?.lowercased() else {
            return tags["man_made"] == "bridge"
        }
        return !["no", "false", "0"].contains(value)
    }

    private static func layer(tags: [String: String]) -> Int {
        if let value = tags["layer"], let parsed = Int(value) { return parsed }
        return isBridge(tags: tags) ? 1 : 0
    }

    private static func bridgeClearance(tags: [String: String]) -> Float {
        parseMeters(tags["min_height"]) ?? 4.5
    }

    private static func transportWidth(
        tags: [String: String],
        kind: UAVWorldTransportKind
    ) -> Float {
        if let width = parseMeters(tags["width"]), width > 0.4 { return min(width, 40) }
        if let lanesText = tags["lanes"],
           let lanes = Float(lanesText.split(separator: ";").first ?? ""),
           lanes > 0 {
            return min(40, max(2.5, lanes * 3.2))
        }
        switch kind {
        case .motorway: return 12
        case .arterial: return 9
        case .street: return 6.5
        case .service: return 4.5
        case .pedestrian: return 2.2
        case .track: return 3
        case .railway: return 4
        }
    }

    private static func parseMeters(_ text: String?) -> Float? {
        guard var value = text?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: ",", with: ".")
        let number = value.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        guard let parsed = Float(number) else { return nil }
        if value.contains("ft") || value.contains("'") { return parsed * 0.3048 }
        if value.contains("cm") { return parsed * 0.01 }
        return parsed
    }

    private static func coordinates(from points: [OverpassPoint]) -> [GeoCoordinate] {
        points.map {
            GeoCoordinate(latitudeDegrees: $0.lat, longitudeDegrees: $0.lon)
        }
    }

    private static func samplesAlong(
        _ points: [GeoCoordinate],
        spacingMeters: Double
    ) -> [GeoCoordinate] {
        guard points.count >= 2 else { return points }
        var samples: [GeoCoordinate] = [points[0]]
        for index in 0..<(points.count - 1) {
            let a = points[index]
            let b = points[index + 1]
            let meanLatitude = (a.latitudeDegrees + b.latitudeDegrees) * 0.5 * .pi / 180
            let north = (b.latitudeDegrees - a.latitudeDegrees) * 111_320
            let east = (b.longitudeDegrees - a.longitudeDegrees) * 111_320 * cos(meanLatitude)
            let distance = hypot(north, east)
            let count = max(1, Int((distance / spacingMeters).rounded(.up)))
            for step in 1...count {
                let t = min(1, Double(step) / Double(count))
                samples.append(GeoCoordinate(
                    latitudeDegrees: a.latitudeDegrees
                        + (b.latitudeDegrees - a.latitudeDegrees) * t,
                    longitudeDegrees: a.longitudeDegrees
                        + (b.longitudeDegrees - a.longitudeDegrees) * t
                ))
            }
        }
        return samples
    }

    private static func ring(
        _ candidate: [GeoCoordinate],
        liesInside outer: [GeoCoordinate]
    ) -> Bool {
        guard let point = candidate.first, outer.count >= 3 else { return false }
        var inside = false
        var previous = outer.count - 1
        for index in outer.indices {
            let a = outer[index]
            let b = outer[previous]
            if (a.latitudeDegrees > point.latitudeDegrees)
                != (b.latitudeDegrees > point.latitudeDegrees) {
                let longitude = (b.longitudeDegrees - a.longitudeDegrees)
                    * (point.latitudeDegrees - a.latitudeDegrees)
                    / (b.latitudeDegrees - a.latitudeDegrees)
                    + a.longitudeDegrees
                if point.longitudeDegrees < longitude { inside.toggle() }
            }
            previous = index
        }
        return inside
    }

    private func execute(query: String) async throws -> Data {
        var lastError: Error?
        for endpoint in endpoints {
            try Task.checkCancellation()
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type"
            )
            request.setValue(
                "UAVsim/1.0 (flight simulator world importer)",
                forHTTPHeaderField: "User-Agent"
            )
            request.timeoutInterval = TimeInterval(queryTimeoutSeconds + 30)
            request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query)"
                .data(using: .utf8)
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 { return data }
                lastError = UAVWorldImportError.serviceRejected(statusCode: status, message: nil)
                if ![429, 503, 504].contains(status) { throw lastError! }
            } catch is CancellationError {
                throw UAVWorldImportError.cancelled
            } catch {
                lastError = error
            }
        }
        throw lastError ?? UAVWorldImportError.malformedResponse(detail: "overpass surface")
    }
}

extension WaterSurfaceModel {

    /// Rasterises water polygons into the same mask the photogrammetric detector produces.
    ///
    /// Deliberately reuses `WaterSurfaceModel` unchanged rather than introducing a polygon-shaped
    /// second representation. Everything downstream — the immersion rule, the spawn search's refusal
    /// to start on water, the sinking wreck — already speaks this one, and a parallel type would have
    /// meant teaching all of them to speak two.
    /// - Parameters:
    ///   - geometry: role-preserving OSM water, islands and pier polygons.
    ///   - cellSize: 1 m by default. The visible mesh interpolates the boundary between cell centres,
    ///     resolving the shoreline to roughly half a metre. Its fully wet interior is coalesced into
    ///     larger quads by `WaterSurfaceGeometryFactory`, so this precision is spent at the coast
    ///     rather than on millions of redundant open-water triangles.
    ///   - denoise: removes isolated raster cells for ordinary water. Disable for an auxiliary mask
    ///     of mapped piers, where a one-cell-wide tip is intentional source geometry.
    ///   - excludedFootprints: optional hard exclusions for non-OSM callers. Imported buildings are
    ///     not passed here: only explicit OSM islands and pier areas are allowed to cut the sea.
    static func rasterizing(
        geometry: UAVWorldWaterGeometry,
        halfSpan: Float,
        level: Float,
        cellSize: Float = 1.0,
        denoise: Bool = true,
        excludedFootprints: [[SIMD2<Float>]] = []
    ) -> WaterSurfaceModel? {
        guard !geometry.isEmpty, halfSpan > 0, cellSize > 0 else { return nil }

        let minimum = SIMD2<Float>(-halfSpan, -halfSpan)
        let columns = max(1, Int((halfSpan * 2 / cellSize).rounded(.up)))
        let rows = columns
        var mask = rasterizedUnion(
            rings: geometry.outerRings,
            minimum: minimum,
            cellSize: cellSize,
            columns: columns,
            rows: rows
        )
        let coastlineWater = rasterizedCoastlineWater(
            segments: geometry.coastlineSegments,
            minimum: minimum,
            cellSize: cellSize,
            columns: columns,
            rows: rows
        )
        for index in mask.indices where coastlineWater[index] {
            mask[index] = true
        }
        let waterHoles = rasterizedUnion(
            rings: geometry.innerRings,
            minimum: minimum,
            cellSize: cellSize,
            columns: columns,
            rows: rows
        )
        let mappedLand = rasterizedUnion(
            rings: geometry.landRings,
            minimum: minimum,
            cellSize: cellSize,
            columns: columns,
            rows: rows
        )
        let mappedLandHoles = rasterizedUnion(
            rings: geometry.landInnerRings,
            minimum: minimum,
            cellSize: cellSize,
            columns: columns,
            rows: rows
        )
        let buildings = rasterizedUnion(
            rings: excludedFootprints,
            minimum: minimum,
            cellSize: cellSize,
            columns: columns,
            rows: rows
        )

        // Remember why a cell is dry. The smoothing pass may close a one-cell raster pinhole, but it
        // must never paint water back over an OSM island, a pier, or a building footprint.
        var hardLand = [Bool](repeating: false, count: mask.count)
        for index in mask.indices {
            let pierDeck = mappedLand[index] && !mappedLandHoles[index]
            hardLand[index] = waterHoles[index] || pierDeck || buildings[index]
            if hardLand[index] {
                mask[index] = false
            }
        }

        // Gentle de-noise: a cell isolated from its own kind is almost always rasterisation grit at
        // the water's edge, not real geography. A water cell with at most one water neighbour becomes
        // land; a land cell nearly surrounded by water becomes water. This clears single-cell specks
        // and fills pinholes — the "unnatural" edge — without moving the coastline itself, since any
        // cell with real neighbours on its own side is left untouched.
        var cleaned = mask
        if denoise {
            for row in 0..<rows {
                for column in 0..<columns {
                    var waterNeighbours = 0
                    for dz in -1...1 {
                        for dx in -1...1 where !(dx == 0 && dz == 0) {
                            let z = row + dz, x = column + dx
                            guard z >= 0, z < rows, x >= 0, x < columns else { continue }
                            if mask[z * columns + x] { waterNeighbours += 1 }
                        }
                    }
                    let index = row * columns + column
                    if mask[index], waterNeighbours <= 1 {
                        cleaned[index] = false
                    } else if !mask[index], !hardLand[index], waterNeighbours >= 7 {
                        cleaned[index] = true
                    }
                }
            }
        }

        guard cleaned.contains(true) else { return nil }
        return WaterSurfaceModel(
            level: level,
            minimum: minimum,
            cellSize: cellSize,
            columns: columns,
            rows: rows,
            mask: cleaned
        )
    }

    /// Compatibility for callers which have a simple list of filled polygons (for example the
    /// elevation probe). New OSM imports use the role-preserving overload above.
    static func rasterizing(
        rings: [[SIMD2<Float>]],
        halfSpan: Float,
        level: Float,
        cellSize: Float = 1.0,
        denoise: Bool = true,
        excludedFootprints: [[SIMD2<Float>]] = []
    ) -> WaterSurfaceModel? {
        rasterizing(
            geometry: UAVWorldWaterGeometry(
                outerRings: rings,
                innerRings: [],
                landRings: [],
                landInnerRings: []
            ),
            halfSpan: halfSpan,
            level: level,
            cellSize: cellSize,
            denoise: denoise,
            excludedFootprints: excludedFootprints
        )
    }

    /// Scan-converts polygon interiors at cell centres.
    ///
    /// The previous implementation ran a full point-in-polygon test for every cell. East River's
    /// 1,400-vertex boundary made that roughly a billion edge tests at a two-metre grid. A scanline
    /// sees each edge only on the rows it crosses, preserves the same even-odd rule, and turns the
    /// complete river into one contiguous mask in a fraction of that work.
    private static func rasterizedUnion(
        rings: [[SIMD2<Float>]],
        minimum: SIMD2<Float>,
        cellSize: Float,
        columns: Int,
        rows: Int
    ) -> [Bool] {
        var result = [Bool](repeating: false, count: columns * rows)
        guard columns > 0, rows > 0 else { return result }

        for ring in rings where ring.count >= 3 {
            let minY = ring.lazy.map(\.y).min() ?? minimum.y
            let maxY = ring.lazy.map(\.y).max() ?? minimum.y
            let firstRow = max(0, Int(ceil((minY - minimum.y) / cellSize - 0.5)))
            let lastRow = min(rows - 1, Int(floor((maxY - minimum.y) / cellSize - 0.5)))
            guard firstRow <= lastRow else { continue }

            for row in firstRow...lastRow {
                let y = minimum.y + (Float(row) + 0.5) * cellSize
                var crossings: [Float] = []
                crossings.reserveCapacity(16)
                var previous = ring[ring.count - 1]
                for current in ring {
                    if (current.y > y) != (previous.y > y) {
                        let fraction = (y - current.y) / (previous.y - current.y)
                        crossings.append(current.x + fraction * (previous.x - current.x))
                    }
                    previous = current
                }
                crossings.sort()

                var crossing = 0
                while crossing + 1 < crossings.count {
                    let left = crossings[crossing]
                    let right = crossings[crossing + 1]
                    let firstColumn = max(
                        0,
                        Int(ceil((left - minimum.x) / cellSize - 0.5))
                    )
                    let endColumn = min(
                        columns,
                        Int(ceil((right - minimum.x) / cellSize - 0.5))
                    )
                    if firstColumn < endColumn {
                        for column in firstColumn..<endColumn {
                            result[row * columns + column] = true
                        }
                    }
                    crossing += 2
                }
            }
        }
        return result
    }

    /// Fills the marine side of directed OSM coastline ways.
    ///
    /// On every horizontal row, a north-going coast changes from land to water as X increases;
    /// a south-going coast changes from water to land. Sorting those crossings reconstructs all
    /// channels and islands without inventing a closing edge across the query box. Rows which miss
    /// the coast completely are uniform; one nearest-segment side test determines whether that
    /// entire row is sea or land.
    private static func rasterizedCoastlineWater(
        segments: [[SIMD2<Float>]],
        minimum: SIMD2<Float>,
        cellSize: Float,
        columns: Int,
        rows: Int
    ) -> [Bool] {
        var result = [Bool](repeating: false, count: columns * rows)
        guard !segments.isEmpty, columns > 0, rows > 0 else { return result }

        var crossingsByRow = [[(x: Float, waterToRight: Bool)]](
            repeating: [],
            count: rows
        )

        for path in segments where path.count >= 2 {
            var start = path[0]
            for end in path.dropFirst() {
                let deltaY = end.y - start.y
                guard abs(deltaY) > 0.000_001 else {
                    start = end
                    continue
                }

                let lowY = min(start.y, end.y)
                let highY = max(start.y, end.y)
                let firstRow = max(0, Int(ceil((lowY - minimum.y) / cellSize - 0.5)))
                let lastRow = min(rows - 1, Int(floor((highY - minimum.y) / cellSize - 0.5)))
                if firstRow <= lastRow {
                    for row in firstRow...lastRow {
                        let y = minimum.y + (Float(row) + 0.5) * cellSize
                        guard (start.y > y) != (end.y > y) else { continue }
                        let fraction = (y - start.y) / deltaY
                        let x = start.x + fraction * (end.x - start.x)
                        crossingsByRow[row].append((x: x, waterToRight: deltaY > 0))
                    }
                }
                start = end
            }
        }

        func nearestCoastHasWaterOnRight(of point: SIMD2<Float>) -> Bool? {
            var bestDistanceSquared = Float.greatestFiniteMagnitude
            var answer: Bool?
            for path in segments where path.count >= 2 {
                var start = path[0]
                for end in path.dropFirst() {
                    let direction = end - start
                    let lengthSquared = simd_length_squared(direction)
                    guard lengthSquared > 0.000_001 else {
                        start = end
                        continue
                    }
                    let fraction = max(
                        0,
                        min(1, simd_dot(point - start, direction) / lengthSquared)
                    )
                    let closest = start + direction * fraction
                    let distanceSquared = simd_length_squared(point - closest)
                    if distanceSquared < bestDistanceSquared {
                        bestDistanceSquared = distanceSquared
                        let side = direction.x * (point.y - start.y)
                            - direction.y * (point.x - start.x)
                        answer = side < 0
                    }
                    start = end
                }
            }
            return answer
        }

        for row in 0..<rows {
            var crossings = crossingsByRow[row]
            crossings.sort { $0.x < $1.x }

            if crossings.isEmpty {
                let probe = SIMD2<Float>(
                    minimum.x + cellSize * 0.5,
                    minimum.y + (Float(row) + 0.5) * cellSize
                )
                if nearestCoastHasWaterOnRight(of: probe) == true {
                    let start = row * columns
                    for column in 0..<columns {
                        result[start + column] = true
                    }
                }
                continue
            }

            var water = !crossings[0].waterToRight
            var crossingIndex = 0
            for column in 0..<columns {
                let x = minimum.x + (Float(column) + 0.5) * cellSize
                while crossingIndex < crossings.count, crossings[crossingIndex].x <= x {
                    water = crossings[crossingIndex].waterToRight
                    crossingIndex += 1
                }
                result[row * columns + column] = water
            }
        }

        return result
    }
}
