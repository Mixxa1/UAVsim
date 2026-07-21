import Foundation
import AppKit
import simd

/// Ground elevation from the public Terrarium terrain tiles.
///
/// Open vector data says nothing about the shape of the ground — OpenStreetMap maps what people
/// build, not what they build it on — so a world constructed from it is flat by construction. This
/// is the second source that fixes that.
///
/// Terrarium was chosen over the alternatives for one practical reason: it needs no API key.
/// OpenTopography and most national services require registration, which would put a signup between
/// the user and their first map. The tiles are global, derived from SRTM/NED/other national models,
/// and encode height in the pixel itself: `(R * 256 + G + B / 256) - 32768` metres. That encoding is
/// exact to 1/256 m, so decoding introduces no error worth mentioning next to the source's own
/// ~30 m horizontal sampling.
struct TerrariumElevationSource: Sendable {

    /// Height samples on a regular grid in the world's local metres.
    struct Grid: Sendable, Codable {
        let minimum: SIMD2<Float>
        let spacing: Float
        let columns: Int
        let rows: Int
        let heights: [Float]

        /// Bilinear sample. Outside the grid the nearest edge value is used rather than zero: an
        /// aircraft crossing the boundary should see the terrain flatten out, not fall off a cliff.
        func height(x: Float, z: Float) -> Float {
            guard columns > 1, rows > 1 else { return heights.first ?? 0 }
            let rawX = (x - minimum.x) / spacing
            let rawZ = (z - minimum.y) / spacing
            let fx: Float = min(max(rawX, 0), Float(columns - 1))
            let fz: Float = min(max(rawZ, 0), Float(rows - 1))
            let x0 = Int(fx)
            let z0 = Int(fz)
            let x1 = min(x0 + 1, columns - 1)
            let z1 = min(z0 + 1, rows - 1)
            let tx = fx - Float(x0)
            let tz = fz - Float(z0)
            let h00 = heights[z0 * columns + x0]
            let h10 = heights[z0 * columns + x1]
            let h01 = heights[z1 * columns + x0]
            let h11 = heights[z1 * columns + x1]
            let top = h00 * (1 - tx) + h10 * tx
            let bottom = h01 * (1 - tx) + h11 * tx
            return top * (1 - tz) + bottom * tz
        }

        var range: (minimum: Float, maximum: Float) {
            (heights.min() ?? 0, heights.max() ?? 0)
        }

        /// Strips buildings out of the elevation model, leaving the ground they stand on.
        ///
        /// SRTM and everything derived from it — Terrarium included — is a *surface* model, not a
        /// bare-earth one: it measures the top of whatever the radar hit, so in a dense city the
        /// skyline is baked into the terrain. Flown over Lower Manhattan that produced hills between
        /// the blocks and ridges driven straight through buildings, which is not a rendering fault —
        /// the data really does say the ground is up there.
        ///
        /// The filter is a morphological opening (erode, then dilate) preceded by a median pass.
        /// Opening deletes anything narrower than its window while leaving broad landforms intact,
        /// which is exactly the distinction wanted: a tower is narrow, a hill is not. The median pass
        /// runs first because opening alone would smear the isolated bathymetry pits *downward*
        /// instead of removing them.
        func bareEarth(windowCells: Int = 3) -> Grid {
            guard columns > 2, rows > 2, windowCells > 0 else { return self }
            let median = Self.filtered(heights, columns: columns, rows: rows, radius: 1) { $0.sorted()[$0.count / 2] }
            let eroded = Self.filtered(median, columns: columns, rows: rows, radius: windowCells) { $0.min() ?? 0 }
            let opened = Self.filtered(eroded, columns: columns, rows: rows, radius: windowCells) { $0.max() ?? 0 }
            // A final average takes the stair-steps off the opening without reintroducing structures.
            let smoothed = Self.filtered(opened, columns: columns, rows: rows, radius: 1) {
                $0.reduce(0, +) / Float($0.count)
            }
            return Grid(
                minimum: minimum,
                spacing: spacing,
                columns: columns,
                rows: rows,
                heights: smoothed
            )
        }

        private static func filtered(
            _ source: [Float],
            columns: Int,
            rows: Int,
            radius: Int,
            _ reduce: ([Float]) -> Float
        ) -> [Float] {
            var result = source
            var window: [Float] = []
            window.reserveCapacity((radius * 2 + 1) * (radius * 2 + 1))
            for row in 0..<rows {
                for column in 0..<columns {
                    window.removeAll(keepingCapacity: true)
                    for dz in -radius...radius {
                        let z = row + dz
                        guard z >= 0, z < rows else { continue }
                        for dx in -radius...radius {
                            let x = column + dx
                            guard x >= 0, x < columns else { continue }
                            window.append(source[z * columns + x])
                        }
                    }
                    result[row * columns + column] = reduce(window)
                }
            }
            return result
        }
    }

    private let session: URLSession
    private let zoom: Int

    /// Zoom 13 samples roughly every 15 m at mid latitudes — finer than the underlying elevation
    /// model actually resolves, and coarse enough that a square-kilometre district is a handful of
    /// tiles rather than a download.
    init(session: URLSession = .shared, zoom: Int = 13) {
        self.session = session
        self.zoom = zoom
    }

    /// Builds a height grid covering `bounds`, expressed in the local frame of `origin`.
    func fetchGrid(
        bounds: GeoBoundingBox,
        origin: GeoOrigin,
        halfSpanMeters: Float,
        spacing: Float = 20.0
    ) async throws -> Grid {
        let tiles = Self.tiles(covering: bounds, zoom: zoom)
        guard !tiles.isEmpty, tiles.count <= 64 else {
            throw UAVWorldImportError.invalidRegion
        }

        var decoded: [TileKey: [Float]] = [:]
        for tile in tiles {
            decoded[tile] = try await fetchTile(tile)
        }

        let columns = max(2, Int((halfSpanMeters * 2 / spacing).rounded(.up)) + 1)
        let rows = columns
        let minimum = SIMD2<Float>(-halfSpanMeters, -halfSpanMeters)
        var heights = [Float](repeating: 0, count: columns * rows)

        for row in 0..<rows {
            for column in 0..<columns {
                let local = SIMD3<Float>(
                    minimum.x + Float(column) * spacing,
                    0,
                    minimum.y + Float(row) * spacing
                )
                let geo = origin.geographic(ofLocalPosition: local)
                heights[row * columns + column] = Self.sample(
                    latitude: geo.latitudeDegrees,
                    longitude: geo.longitudeDegrees,
                    zoom: zoom,
                    tiles: decoded
                )
            }
        }

        // Stored raw — bathymetry, buildings and all. The runtime is the single place that turns a
        // surface model into flyable bare earth, so a package built by any version reads the same
        // and the stored data stays an honest copy of the source.
        return Grid(
            minimum: minimum,
            spacing: spacing,
            columns: columns,
            rows: rows,
            heights: heights
        )
    }

    // MARK: - Tiles

    struct TileKey: Hashable, Sendable {
        let x: Int
        let y: Int
    }

    private static let tileSide = 256

    static func tileIndex(latitude: Double, longitude: Double, zoom: Int) -> (x: Double, y: Double) {
        let n = pow(2.0, Double(zoom))
        let latitudeRadians = latitude * .pi / 180
        let x = (longitude + 180) / 360 * n
        let y = (1 - log(tan(latitudeRadians) + 1 / cos(latitudeRadians)) / .pi) / 2 * n
        return (x, y)
    }

    private static func tiles(covering bounds: GeoBoundingBox, zoom: Int) -> [TileKey] {
        let topLeft = tileIndex(
            latitude: bounds.maximumLatitudeDegrees,
            longitude: bounds.minimumLongitudeDegrees,
            zoom: zoom
        )
        let bottomRight = tileIndex(
            latitude: bounds.minimumLatitudeDegrees,
            longitude: bounds.maximumLongitudeDegrees,
            zoom: zoom
        )
        var keys: [TileKey] = []
        for x in Int(floor(topLeft.x))...Int(floor(bottomRight.x)) {
            for y in Int(floor(topLeft.y))...Int(floor(bottomRight.y)) {
                keys.append(TileKey(x: x, y: y))
            }
        }
        return keys
    }

    private func fetchTile(_ key: TileKey) async throws -> [Float] {
        let url = URL(
            string: "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/\(zoom)/\(key.x)/\(key.y).png"
        )!
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw UAVWorldImportError.serviceRejected(statusCode: status, message: nil)
        }
        guard let heights = Self.decode(pngData: data) else {
            throw UAVWorldImportError.malformedResponse(detail: "terrarium tile")
        }
        return heights
    }

    /// `(R * 256 + G + B / 256) - 32768` metres, per the Terrarium specification.
    static func decode(pngData: Data) -> [Float]? {
        guard let image = NSImage(data: pngData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cgImage.width == tileSide, cgImage.height == tileSide else {
            return nil
        }

        var pixels = [UInt8](repeating: 0, count: tileSide * tileSide * 4)
        guard let context = CGContext(
            data: &pixels,
            width: tileSide,
            height: tileSide,
            bitsPerComponent: 8,
            bytesPerRow: tileSide * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: tileSide, height: tileSide))

        var heights = [Float](repeating: 0, count: tileSide * tileSide)
        for index in 0..<(tileSide * tileSide) {
            let r = Float(pixels[index * 4])
            let g = Float(pixels[index * 4 + 1])
            let b = Float(pixels[index * 4 + 2])
            heights[index] = (r * 256 + g + b / 256) - 32768
        }
        return heights
    }

    private static func sample(
        latitude: Double,
        longitude: Double,
        zoom: Int,
        tiles: [TileKey: [Float]]
    ) -> Float {
        let index = tileIndex(latitude: latitude, longitude: longitude, zoom: zoom)
        let key = TileKey(x: Int(floor(index.x)), y: Int(floor(index.y)))
        guard let tile = tiles[key] else { return 0 }
        let column = min(tileSide - 1, max(0, Int((index.x - floor(index.x)) * Double(tileSide))))
        let row = min(tileSide - 1, max(0, Int((index.y - floor(index.y)) * Double(tileSide))))
        return tile[row * tileSide + column]
    }
}
