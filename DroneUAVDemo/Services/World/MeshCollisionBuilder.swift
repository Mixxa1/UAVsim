import Foundation
import simd

/// Extracts a collision triangle soup from a ContextCapture tile and caches it.
///
/// Separate from `ContextCaptureOBJLoader` because the needs are opposite: rendering wants
/// texture coordinates, materials and decoded JPEGs, while physics wants nothing but positions.
/// Reusing the render loader here would decode three quarters of a million triangles' worth of
/// imagery to throw all of it away.
enum MeshCollisionBuilder {

    /// Quadtree level the collision surface is taken from.
    ///
    /// L18 measured on the central Helsinki tile: 739k triangles, 25 MB, ~3.3 m average edge —
    /// a wall is reproduced to roughly half a metre, which is fine for an aircraft half a metre
    /// across and for a rangefinder reading. L17 halves the cost but doubles the edge length to
    /// about 5 m, which starts to show on facades; L19 more than doubles the memory for detail no
    /// sensor at flight range resolves.
    static let defaultLevel = 18

    private static let cacheMagic: UInt32 = 0x554D_4331  // "UMC1"

    struct BuildResult {
        let index: MeshCollisionIndex
        let triangleCount: Int
        let level: Int
        let buildSeconds: Double
        let loadedFromCache: Bool
    }

    /// Builds the index, reusing a cached triangle soup when one matching the level exists.
    static func build(
        index tileIndex: ContextCaptureTileIndex,
        level: Int = defaultLevel,
        originOffset: SIMD3<Double>,
        cacheURL: URL?,
        cellSize: Float = 12.0,
        progress: ((Int, Int) -> Void)? = nil
    ) -> BuildResult {
        let started = Date()

        if let cacheURL, let cached = readCache(at: cacheURL, level: level) {
            let collision = MeshCollisionIndex(triangleCorners: cached, cellSize: cellSize)
            return BuildResult(
                index: collision,
                triangleCount: cached.count / 3,
                level: level,
                buildSeconds: Date().timeIntervalSince(started),
                loadedFromCache: true
            )
        }

        var corners: [SIMD3<Float>] = []
        corners.reserveCapacity(2_400_000)

        let covering = tileIndex.covering(level: level)
        for (position, node) in covering.enumerated() {
            corners.append(contentsOf: triangles(of: node, originOffset: originOffset))
            if position % 64 == 0 { progress?(position, covering.count) }
        }
        progress?(covering.count, covering.count)

        if let cacheURL {
            writeCache(corners, level: level, to: cacheURL)
        }

        let collision = MeshCollisionIndex(triangleCorners: corners, cellSize: cellSize)
        return BuildResult(
            index: collision,
            triangleCount: corners.count / 3,
            level: level,
            buildSeconds: Date().timeIntervalSince(started),
            loadedFromCache: false
        )
    }

    /// Reads only `v` and `f` lines. Texture coordinates, materials and normals are skipped
    /// outright — the face parser takes the vertex index and discards everything after the slash.
    private static func triangles(
        of node: ContextCaptureTileIndex.Node,
        originOffset: SIMD3<Double>
    ) -> [SIMD3<Float>] {
        guard let data = try? Data(contentsOf: node.objectURL), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        // `enumerateLines` takes an escaping closure, so the accumulator is local and returned
        // rather than an `inout` parameter written through.
        var corners: [SIMD3<Float>] = []
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(2048)

        text.enumerateLines { line, _ in
            if line.hasPrefix("v ") {
                let parts = line.dropFirst(2).split(separator: " ")
                guard parts.count >= 3,
                      let x = Double(parts[0]),
                      let y = Double(parts[1]),
                      let z = Double(parts[2]) else { return }
                // Re-anchor in double precision, then swap OBJ's Z-up axes to the scene's Y-up,
                // matching `ContextCaptureOBJLoader` exactly — collision geometry that disagreed
                // with the visible surface by even a metre would be worse than none.
                let east = x + originOffset.x
                let north = y + originOffset.y
                let up = z + originOffset.z
                positions.append(SIMD3<Float>(Float(east), Float(up), Float(north)))
            } else if line.hasPrefix("f ") {
                let parts = line.dropFirst(2).split(separator: " ")
                guard parts.count >= 3 else { return }
                var triangle: [SIMD3<Float>] = []
                triangle.reserveCapacity(3)
                for part in parts.prefix(3) {
                    let field = part.prefix { $0 != "/" }
                    guard let raw = Int(field) else { return }
                    let vertex = raw - 1
                    guard vertex >= 0, vertex < positions.count else { return }
                    triangle.append(positions[vertex])
                }
                guard triangle.count == 3 else { return }
                // Winding is reversed for the same reason the render loader reverses it: swapping
                // two axes flips triangle orientation. Face normals are used to push contacts out,
                // so orientation has to be right here too.
                corners.append(triangle[0])
                corners.append(triangle[2])
                corners.append(triangle[1])
            }
        }

        return corners
    }

    // MARK: - Cache

    private static func readCache(at url: URL, level: Int) -> [SIMD3<Float>]? {
        guard let data = try? Data(contentsOf: url), data.count >= 12 else { return nil }

        return data.withUnsafeBytes { raw -> [SIMD3<Float>]? in
            guard let base = raw.baseAddress else { return nil }
            let magic = base.loadUnaligned(as: UInt32.self)
            let cachedLevel = base.loadUnaligned(fromByteOffset: 4, as: Int32.self)
            let count = base.loadUnaligned(fromByteOffset: 8, as: Int32.self)
            guard magic == cacheMagic, Int(cachedLevel) == level, count > 0 else { return nil }

            let expected = 12 + Int(count) * 3 * MemoryLayout<Float>.size
            guard data.count >= expected else { return nil }

            var corners = [SIMD3<Float>]()
            corners.reserveCapacity(Int(count))
            var offset = 12
            for _ in 0..<Int(count) {
                let x = base.loadUnaligned(fromByteOffset: offset, as: Float.self)
                let y = base.loadUnaligned(fromByteOffset: offset + 4, as: Float.self)
                let z = base.loadUnaligned(fromByteOffset: offset + 8, as: Float.self)
                corners.append(SIMD3<Float>(x, y, z))
                offset += 12
            }
            return corners
        }
    }

    private static func writeCache(_ corners: [SIMD3<Float>], level: Int, to url: URL) {
        var data = Data(capacity: 12 + corners.count * 12)
        withUnsafeBytes(of: cacheMagic) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(level)) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: Int32(corners.count)) { data.append(contentsOf: $0) }
        for corner in corners {
            withUnsafeBytes(of: corner.x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: corner.y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: corner.z) { data.append(contentsOf: $0) }
        }
        try? data.write(to: url)
    }
}
