import Foundation
import simd

/// Spatial index over the photogrammetric mesh, answering the questions physics and sensors ask.
///
/// The mesh carries no semantics — no buildings, no ground, no roofs, just a textured surface —
/// so every physical question reduces to geometry against triangles. Three queries cover
/// everything the simulator needs: what is directly below a point (terrain and rooftop height),
/// what a ray hits (rangefinder, LiDAR, camera focus, radio line of sight), and whether a sphere
/// overlaps the surface (the aircraft itself).
///
/// **Why a uniform XZ grid rather than a BVH.** A city is thin in Y and wide in XZ, so a 2D grid
/// separates it almost as well as a tree while being far simpler to build, verify and traverse.
/// Downward queries — by far the most frequent, since every tick asks for ground clearance —
/// become a single cell lookup. Arbitrary rays walk cells with a 2D DDA. If measurement later
/// shows long grazing rays dominating, a BVH is a drop-in replacement behind these same three
/// methods.
struct MeshCollisionIndex {

    struct Hit {
        let distance: Float
        let point: SIMD3<Float>
        let normal: SIMD3<Float>
        let triangleIndex: Int
    }

    /// Flat triangle corners: triangle `i` occupies `[3i, 3i+1, 3i+2]`.
    private let corners: [SIMD3<Float>]
    /// Per-triangle face normals, precomputed — they are needed on every hit and recomputing
    /// them costs a cross product and a normalise inside the inner loop.
    private let normals: [SIMD3<Float>]

    private let cellSize: Float
    private let minimumXZ: SIMD2<Float>
    private let columns: Int
    private let rows: Int
    /// Compressed-sparse-row layout: cell `c` owns `cellTriangles[cellStarts[c]..<cellStarts[c+1]]`.
    /// One flat allocation instead of tens of thousands of small arrays.
    private let cellStarts: [Int32]
    private let cellTriangles: [Int32]

    let bounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)

    var triangleCount: Int { normals.count }
    var memoryFootprintBytes: Int {
        corners.count * MemoryLayout<SIMD3<Float>>.stride
            + normals.count * MemoryLayout<SIMD3<Float>>.stride
            + cellStarts.count * 4
            + cellTriangles.count * 4
    }

    // MARK: - Build

    /// - Parameter cellSize: grid resolution in metres. Around 12 m keeps a typical cell to a few
    ///   dozen triangles at the collision level, which is the point where cell-walking overhead
    ///   and per-cell triangle tests balance.
    init(
        triangleCorners: [SIMD3<Float>],
        cellSize: Float = 12.0
    ) {
        precondition(triangleCorners.count % 3 == 0, "corners must come in triples")

        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for corner in triangleCorners {
            minimum = simd_min(minimum, corner)
            maximum = simd_max(maximum, corner)
        }
        if triangleCorners.isEmpty {
            minimum = .zero
            maximum = .zero
        }

        self.corners = triangleCorners
        self.bounds = (minimum, maximum)
        self.cellSize = max(cellSize, 0.5)
        self.minimumXZ = SIMD2<Float>(minimum.x, minimum.z)

        let triangleCount = triangleCorners.count / 3
        var normals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 1, 0), count: triangleCount)
        for index in 0..<triangleCount {
            let a = triangleCorners[index * 3]
            let b = triangleCorners[index * 3 + 1]
            let c = triangleCorners[index * 3 + 2]
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            normals[index] = length > 1e-9 ? cross / length : SIMD3<Float>(0, 1, 0)
        }
        self.normals = normals

        let width = max(maximum.x - minimum.x, 0.001)
        let depth = max(maximum.z - minimum.z, 0.001)
        let columns = max(1, Int((width / self.cellSize).rounded(.up)))
        let rows = max(1, Int((depth / self.cellSize).rounded(.up)))
        self.columns = columns
        self.rows = rows

        // Two passes: count per cell, then fill. Counting first means the CSR arrays are sized
        // exactly and never reallocated, which matters at three quarters of a million triangles.
        var counts = [Int32](repeating: 0, count: columns * rows + 1)
        var spans: [(Int, Int, Int, Int)] = []
        spans.reserveCapacity(triangleCount)

        for index in 0..<triangleCount {
            let a = triangleCorners[index * 3]
            let b = triangleCorners[index * 3 + 1]
            let c = triangleCorners[index * 3 + 2]
            let lowX = min(a.x, b.x, c.x), highX = max(a.x, b.x, c.x)
            let lowZ = min(a.z, b.z, c.z), highZ = max(a.z, b.z, c.z)

            let columnStart = Self.clampIndex((lowX - minimum.x) / self.cellSize, limit: columns)
            let columnEnd = Self.clampIndex((highX - minimum.x) / self.cellSize, limit: columns)
            let rowStart = Self.clampIndex((lowZ - minimum.z) / self.cellSize, limit: rows)
            let rowEnd = Self.clampIndex((highZ - minimum.z) / self.cellSize, limit: rows)
            spans.append((columnStart, columnEnd, rowStart, rowEnd))

            for row in rowStart...rowEnd {
                for column in columnStart...columnEnd {
                    counts[row * columns + column + 1] += 1
                }
            }
        }

        for cell in 1..<counts.count {
            counts[cell] += counts[cell - 1]
        }
        self.cellStarts = counts

        var cursor = counts
        var triangles = [Int32](repeating: 0, count: Int(counts[counts.count - 1]))
        for index in 0..<triangleCount {
            let (columnStart, columnEnd, rowStart, rowEnd) = spans[index]
            for row in rowStart...rowEnd {
                for column in columnStart...columnEnd {
                    let cell = row * columns + column
                    triangles[Int(cursor[cell])] = Int32(index)
                    cursor[cell] += 1
                }
            }
        }
        self.cellTriangles = triangles
    }

    private static func clampIndex(_ value: Float, limit: Int) -> Int {
        Swift.min(Swift.max(Int(value), 0), limit - 1)
    }

    // MARK: - Ground / surface height

    /// Height of the highest surface directly below `position`, or `nil` when nothing is there.
    ///
    /// This is the query the flight model needs every tick, and in a city it is genuinely
    /// ambiguous: above a bridge the answer should be the bridge deck, below it the water. Taking
    /// the first surface encountered on the way *down from the given altitude* resolves that
    /// correctly without needing to know what a bridge is.
    func surfaceHeight(x: Float, z: Float, startingFrom altitude: Float) -> Float? {
        let origin = SIMD3<Float>(x, altitude, z)
        guard let hit = raycast(
            origin: origin,
            direction: SIMD3<Float>(0, -1, 0),
            maxDistance: altitude - bounds.minimum.y + 10.0
        ) else {
            return nil
        }
        return hit.point.y
    }

    /// Highest surface anywhere in the column, ignoring altitude — used for spawn placement and
    /// for "how tall is the thing at this spot".
    func highestSurface(x: Float, z: Float) -> Float? {
        surfaceHeight(x: x, z: z, startingFrom: bounds.maximum.y + 10.0)
    }

    // MARK: - Raycast

    /// Nearest intersection along a ray.
    ///
    /// Walks the XZ grid with a 2D DDA and tests only the triangles in the cells crossed. The
    /// early exit matters: once a hit is found inside a cell, cells beyond the hit distance can
    /// be abandoned, so a rangefinder pointed at a nearby wall costs almost nothing regardless of
    /// how far the ray would otherwise reach.
    func raycast(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        maxDistance: Float
    ) -> Hit? {
        guard maxDistance > 0, triangleCount > 0 else { return nil }
        let lengthSquared = simd_length_squared(direction)
        guard lengthSquared > 1e-12 else { return nil }
        let ray = direction / lengthSquared.squareRoot()

        // Clip against the index's own bounds first; a ray starting far outside would otherwise
        // walk thousands of empty cells to reach the city.
        guard let (entry, exit) = clipToBounds(origin: origin, direction: ray, maxDistance: maxDistance)
        else { return nil }

        var best: Hit?
        var bestDistance = exit

        let startPoint = origin + ray * entry
        var column = Self.clampIndex((startPoint.x - minimumXZ.x) / cellSize, limit: columns)
        var row = Self.clampIndex((startPoint.z - minimumXZ.y) / cellSize, limit: rows)

        let stepX = ray.x > 0 ? 1 : (ray.x < 0 ? -1 : 0)
        let stepZ = ray.z > 0 ? 1 : (ray.z < 0 ? -1 : 0)

        // Distance along the ray to the next cell boundary in each axis, and the distance
        // between successive boundaries.
        var nextBoundaryX = Float.greatestFiniteMagnitude
        var deltaX = Float.greatestFiniteMagnitude
        if stepX != 0 {
            let boundary = minimumXZ.x + Float(column + (stepX > 0 ? 1 : 0)) * cellSize
            nextBoundaryX = entry + (boundary - startPoint.x) / ray.x
            deltaX = cellSize / abs(ray.x)
        }
        var nextBoundaryZ = Float.greatestFiniteMagnitude
        var deltaZ = Float.greatestFiniteMagnitude
        if stepZ != 0 {
            let boundary = minimumXZ.y + Float(row + (stepZ > 0 ? 1 : 0)) * cellSize
            nextBoundaryZ = entry + (boundary - startPoint.z) / ray.z
            deltaZ = cellSize / abs(ray.z)
        }

        while true {
            testCell(
                column: column,
                row: row,
                origin: origin,
                direction: ray,
                limit: &bestDistance,
                best: &best
            )

            let advance = min(nextBoundaryX, nextBoundaryZ)
            if advance > bestDistance || advance > exit { break }

            if nextBoundaryX < nextBoundaryZ {
                column += stepX
                nextBoundaryX += deltaX
            } else {
                row += stepZ
                nextBoundaryZ += deltaZ
            }
            guard column >= 0, column < columns, row >= 0, row < rows else { break }
        }

        return best
    }

    private func testCell(
        column: Int,
        row: Int,
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        limit: inout Float,
        best: inout Hit?
    ) {
        let cell = row * columns + column
        guard cell >= 0, cell + 1 < cellStarts.count else { return }
        let start = Int(cellStarts[cell])
        let end = Int(cellStarts[cell + 1])
        guard start < end else { return }

        for slot in start..<end {
            let triangle = Int(cellTriangles[slot])
            guard let distance = intersect(
                triangle: triangle,
                origin: origin,
                direction: direction,
                limit: limit
            ) else { continue }
            limit = distance
            best = Hit(
                distance: distance,
                point: origin + direction * distance,
                normal: normals[triangle],
                triangleIndex: triangle
            )
        }
    }

    /// Möller–Trumbore, double-sided.
    ///
    /// Double-sided deliberately: a photogrammetric surface has no reliable inside or outside, and
    /// a UAV that ends up within a reconstructed volume must still be stopped by the far wall
    /// rather than passing through a back-face.
    private func intersect(
        triangle: Int,
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        limit: Float
    ) -> Float? {
        let a = corners[triangle * 3]
        let b = corners[triangle * 3 + 1]
        let c = corners[triangle * 3 + 2]

        let edge1 = b - a
        let edge2 = c - a
        let pvec = simd_cross(direction, edge2)
        let determinant = simd_dot(edge1, pvec)
        guard abs(determinant) > 1e-9 else { return nil }

        let inverse = 1.0 / determinant
        let tvec = origin - a
        let u = simd_dot(tvec, pvec) * inverse
        guard u >= -1e-6, u <= 1.0 + 1e-6 else { return nil }

        let qvec = simd_cross(tvec, edge1)
        let v = simd_dot(direction, qvec) * inverse
        guard v >= -1e-6, u + v <= 1.0 + 1e-6 else { return nil }

        let distance = simd_dot(edge2, qvec) * inverse
        guard distance > 1e-4, distance < limit else { return nil }
        return distance
    }

    /// Ray-versus-index-bounds, returning the entry and exit distances along the ray.
    private func clipToBounds(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        maxDistance: Float
    ) -> (Float, Float)? {
        var entry: Float = 0
        var exit = maxDistance

        for axis in 0..<3 {
            let start = origin[axis]
            let slope = direction[axis]
            let low = bounds.minimum[axis] - 0.001
            let high = bounds.maximum[axis] + 0.001

            if abs(slope) < 1e-9 {
                if start < low || start > high { return nil }
                continue
            }
            var near = (low - start) / slope
            var far = (high - start) / slope
            if near > far { swap(&near, &far) }
            entry = max(entry, near)
            exit = min(exit, far)
            if entry > exit { return nil }
        }
        return (entry, exit)
    }

    // MARK: - Sphere overlap

    /// Deepest penetration of a sphere into the surface, or `nil` when clear.
    ///
    /// Returns the contact point and the direction that separates them, which is what an impact
    /// response needs — not merely a yes/no. Sampling every triangle in the covered cells rather
    /// than stopping at the first contact matters at a corner, where the shallowest contact would
    /// push the aircraft straight into the adjoining wall.
    func sphereContact(center: SIMD3<Float>, radius: Float) -> (point: SIMD3<Float>, normal: SIMD3<Float>, depth: Float)? {
        guard radius > 0, triangleCount > 0 else { return nil }
        guard center.x >= bounds.minimum.x - radius, center.x <= bounds.maximum.x + radius,
              center.y >= bounds.minimum.y - radius, center.y <= bounds.maximum.y + radius,
              center.z >= bounds.minimum.z - radius, center.z <= bounds.maximum.z + radius else {
            return nil
        }

        let columnStart = Self.clampIndex((center.x - radius - minimumXZ.x) / cellSize, limit: columns)
        let columnEnd = Self.clampIndex((center.x + radius - minimumXZ.x) / cellSize, limit: columns)
        let rowStart = Self.clampIndex((center.z - radius - minimumXZ.y) / cellSize, limit: rows)
        let rowEnd = Self.clampIndex((center.z + radius - minimumXZ.y) / cellSize, limit: rows)

        var deepest: (point: SIMD3<Float>, normal: SIMD3<Float>, depth: Float)?
        var seen = Set<Int32>()

        for row in rowStart...rowEnd {
            for column in columnStart...columnEnd {
                let cell = row * columns + column
                guard cell + 1 < cellStarts.count else { continue }
                for slot in Int(cellStarts[cell])..<Int(cellStarts[cell + 1]) {
                    let triangle = cellTriangles[slot]
                    // A triangle spanning several cells is stored in each of them.
                    guard seen.insert(triangle).inserted else { continue }

                    let index = Int(triangle)
                    let closest = closestPointOnTriangle(
                        point: center,
                        a: corners[index * 3],
                        b: corners[index * 3 + 1],
                        c: corners[index * 3 + 2]
                    )
                    let offset = center - closest
                    let distance = simd_length(offset)
                    guard distance < radius else { continue }

                    let depth = radius - distance
                    if depth > (deepest?.depth ?? 0) {
                        // Push out along the surface normal, flipped to face the sphere — the
                        // triangle's own winding cannot be trusted on a reconstructed surface.
                        var normal = normals[index]
                        if distance > 1e-6, simd_dot(offset, normal) < 0 { normal = -normal }
                        deepest = (closest, normal, depth)
                    }
                }
            }
        }
        return deepest
    }

    private func closestPointOnTriangle(
        point: SIMD3<Float>,
        a: SIMD3<Float>,
        b: SIMD3<Float>,
        c: SIMD3<Float>
    ) -> SIMD3<Float> {
        let ab = b - a
        let ac = c - a
        let ap = point - a

        let d1 = simd_dot(ab, ap)
        let d2 = simd_dot(ac, ap)
        if d1 <= 0 && d2 <= 0 { return a }

        let bp = point - b
        let d3 = simd_dot(ab, bp)
        let d4 = simd_dot(ac, bp)
        if d3 >= 0 && d4 <= d3 { return b }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0 && d1 >= 0 && d3 <= 0 {
            return a + ab * (d1 / (d1 - d3))
        }

        let cp = point - c
        let d5 = simd_dot(ab, cp)
        let d6 = simd_dot(ac, cp)
        if d6 >= 0 && d5 <= d6 { return c }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0 && d2 >= 0 && d6 <= 0 {
            return a + ac * (d2 / (d2 - d6))
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 {
            return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6)))
        }

        let denominator = 1.0 / (va + vb + vc)
        return a + ab * (vb * denominator) + ac * (vc * denominator)
    }
}
