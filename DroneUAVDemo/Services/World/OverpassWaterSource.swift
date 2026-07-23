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
        var outerRings: [[GeoCoordinate]] = []
        var innerRings: [[GeoCoordinate]] = []
        var landRings: [[GeoCoordinate]] = []
        var landInnerRings: [[GeoCoordinate]] = []
        var coastlineSegments: [[GeoCoordinate]] = []
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
            let isWater = tags["natural"] == "water" || tags["waterway"] == "riverbank"
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
    /// Area piers are fetched in the same response so the water mask can subtract real mapped land.
    static func waterQuery(bounds: GeoBoundingBox, timeoutSeconds: Int) -> String {
        let box = bounds.overpassBoundsString
        return """
        [out:json][timeout:\(timeoutSeconds)];
        (
          way["natural"="water"](\(box));
          relation["natural"="water"]["type"="multipolygon"](\(box));
          way["waterway"="riverbank"](\(box));
          relation["waterway"="riverbank"]["type"="multipolygon"](\(box));
          way["natural"="coastline"](\(box));
          way["man_made"="pier"]["area"="yes"](\(box));
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
    private static func assembleClosedRings(from segments: [[OverpassPoint]]) -> [[GeoCoordinate]] {
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

    private static func closedWayRing(from points: [OverpassPoint]) -> [GeoCoordinate]? {
        guard points.count >= 4, let first = points.first, let last = points.last,
              first.lat == last.lat, first.lon == last.lon else { return nil }
        return closedRing(from: points)
    }

    private static func coordinates(from points: [OverpassPoint]) -> [GeoCoordinate] {
        points.map {
            GeoCoordinate(latitudeDegrees: $0.lat, longitudeDegrees: $0.lon, altitudeMetersMSL: 0)
        }
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

extension WaterSurfaceModel {

    /// Rasterises water polygons into the same mask the photogrammetric detector produces.
    ///
    /// Deliberately reuses `WaterSurfaceModel` unchanged rather than introducing a polygon-shaped
    /// second representation. Everything downstream — the immersion rule, the spawn search's refusal
    /// to start on water, the sinking wreck — already speaks this one, and a parallel type would have
    /// meant teaching all of them to speak two.
    /// - Parameters:
    ///   - geometry: role-preserving OSM water, islands and pier polygons.
    ///   - cellSize: 2 m by default. The visible mesh interpolates the boundary between cell centres,
    ///     so this resolves a shoreline to about a metre without turning a city into millions of
    ///     individual SceneKit nodes.
    ///   - denoise: removes isolated raster cells for ordinary water. Disable for an auxiliary mask
    ///     of mapped piers, where a one-cell-wide tip is intentional source geometry.
    ///   - excludedFootprints: optional hard exclusions for non-OSM callers. Imported buildings are
    ///     not passed here: only explicit OSM islands and pier areas are allowed to cut the sea.
    static func rasterizing(
        geometry: UAVWorldWaterGeometry,
        halfSpan: Float,
        level: Float,
        cellSize: Float = 2.0,
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
        cellSize: Float = 2.0,
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
