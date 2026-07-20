import Foundation
import simd

/// Ear-clipping triangulation for simple polygons in the XZ plane.
///
/// Building roofs are arbitrary n-gons — the real Lower Manhattan extract averages 13 vertices
/// per footprint and reaches well beyond that — so a fan or quad assumption produces visibly
/// wrong, self-overlapping roofs on any non-convex block. Ear clipping handles concave outlines
/// correctly, needs no external dependency, and at these vertex counts its O(n²) behaviour is
/// irrelevant.
///
/// Input must be a *simple* polygon (no self-intersections) wound counter-clockwise, which is
/// what `UAVWorldBuilder` guarantees. Self-intersecting rings are not repaired here; they are
/// detected as failure and reported, so a bad footprint yields no roof rather than a scrambled
/// one.
enum PolygonTriangulator {
    /// Triangulates a counter-clockwise ring, returning index triples into the original array.
    /// Returns `nil` if the polygon could not be fully triangulated, which in practice means it
    /// was self-intersecting or degenerate.
    /// Indices refer to the array passed in, so callers wanting collinear vertices removed must
    /// apply `removingCollinearVertices` first and triangulate the result.
    static func triangulate(_ polygon: [SIMD2<Float>]) -> [Int]? {
        guard polygon.count >= 3 else { return nil }
        if polygon.count == 3 { return [0, 1, 2] }

        // Reject self-intersecting rings up front. Ear clipping has no defined behaviour on
        // them and will emit overlapping, inverted triangles instead of failing.
        guard isSimple(polygon) else { return nil }

        // Work on an index list so the returned triples refer to the caller's vertices.
        var remaining = Array(polygon.indices)
        var triangles: [Int] = []
        triangles.reserveCapacity((polygon.count - 2) * 3)

        // Each successful clip removes one vertex, so the loop cannot need more passes than
        // there are vertices. The counter is a hard stop against a malformed polygon spinning
        // forever — a real risk with crowd-sourced geometry.
        var guardCounter = 0
        let guardLimit = polygon.count * polygon.count + 16

        while remaining.count > 3 {
            guardCounter += 1
            if guardCounter > guardLimit { return nil }

            var clipped = false
            for position in remaining.indices {
                let previousIndex = remaining[(position + remaining.count - 1) % remaining.count]
                let currentIndex = remaining[position]
                let nextIndex = remaining[(position + 1) % remaining.count]

                let previous = polygon[previousIndex]
                let current = polygon[currentIndex]
                let next = polygon[nextIndex]

                // A vertex is an ear when it is convex and no other vertex of the polygon lies
                // inside the triangle it forms.
                guard isConvex(previous: previous, current: current, next: next) else { continue }

                var containsOther = false
                for candidateIndex in remaining
                where candidateIndex != previousIndex
                    && candidateIndex != currentIndex
                    && candidateIndex != nextIndex {
                    if pointInTriangle(
                        polygon[candidateIndex],
                        previous,
                        current,
                        next
                    ) {
                        containsOther = true
                        break
                    }
                }
                guard !containsOther else { continue }

                triangles.append(contentsOf: [previousIndex, currentIndex, nextIndex])
                remaining.remove(at: position)
                clipped = true
                break
            }

            // No ear found in a full pass: the polygon is not simple, so bail rather than
            // emitting garbage.
            if !clipped { return nil }
        }

        triangles.append(contentsOf: remaining)
        return triangles
    }

    /// Cross product sign for a counter-clockwise polygon. Positive means the corner turns left,
    /// i.e. the vertex is convex.
    private static func isConvex(
        previous: SIMD2<Float>,
        current: SIMD2<Float>,
        next: SIMD2<Float>
    ) -> Bool {
        let a = current - previous
        let b = next - current
        return (a.x * b.y - a.y * b.x) > 0
    }

    /// Barycentric containment, **inclusive of the boundary**.
    ///
    /// The inclusivity is the whole point and was originally got wrong. With an exclusive test,
    /// a vertex lying exactly on a candidate ear's edge counts as outside, the ear is clipped
    /// anyway, and that vertex is stranded on the wrong side — which later forces an inverted
    /// triangle. A plain L-shaped footprint reproduces it: clipping the corner at (0,0) puts
    /// (10,10) exactly on the hypotenuse x+y=20, and the triangulation ends with a −50 m²
    /// triangle. Signed areas still summed correctly because the inverted triangle cancelled the
    /// double-covered region, so it is invisible to any check that does not test each triangle's
    /// own winding.
    private static func pointInTriangle(
        _ point: SIMD2<Float>,
        _ a: SIMD2<Float>,
        _ b: SIMD2<Float>,
        _ c: SIMD2<Float>
    ) -> Bool {
        let v0 = c - a
        let v1 = b - a
        let v2 = point - a

        let dot00 = simd_dot(v0, v0)
        let dot01 = simd_dot(v0, v1)
        let dot02 = simd_dot(v0, v2)
        let dot11 = simd_dot(v1, v1)
        let dot12 = simd_dot(v1, v2)

        let denominator = dot00 * dot11 - dot01 * dot01
        guard abs(denominator) > 1e-12 else { return false }

        let inverse = 1.0 / denominator
        let u = (dot11 * dot02 - dot01 * dot12) * inverse
        let v = (dot00 * dot12 - dot01 * dot02) * inverse
        let epsilon: Float = 1e-6
        return u >= -epsilon && v >= -epsilon && (u + v) <= (1.0 + epsilon)
    }

    // MARK: - Ring conditioning

    /// Removes vertices that lie on the straight line between their neighbours.
    ///
    /// Crowd-sourced footprints carry many redundant collinear points, and every one of them is
    /// a zero-area triangle waiting to be emitted — seven appeared across the real Lower
    /// Manhattan extract. They render as nothing, add collision-mesh triangles with no surface,
    /// and, now that boundary-touching vertices correctly block ears, they also make the
    /// clipper's job harder for no benefit.
    ///
    /// `toleranceMeters` is the perpendicular distance below which a vertex is considered to lie
    /// on its neighbours' line — 1 cm, far finer than any source's positional accuracy.
    static func removingCollinearVertices(
        _ ring: [SIMD2<Float>],
        toleranceMeters: Float = 0.01
    ) -> [SIMD2<Float>] {
        guard ring.count > 3 else { return ring }

        var result: [SIMD2<Float>] = []
        result.reserveCapacity(ring.count)

        for index in ring.indices {
            let previous = result.last ?? ring[(index + ring.count - 1) % ring.count]
            let current = ring[index]
            let next = ring[(index + 1) % ring.count]

            let incoming = current - previous
            let outgoing = next - current
            let incomingLength = simd_length(incoming)
            let outgoingLength = simd_length(outgoing)
            guard incomingLength > 1e-6, outgoingLength > 1e-6 else { continue }

            // Perpendicular distance from `current` to the line through previous→next.
            let span = next - previous
            let spanLength = simd_length(span)
            guard spanLength > 1e-6 else { continue }
            let cross = span.x * (current.y - previous.y) - span.y * (current.x - previous.x)
            let distance = abs(cross) / spanLength

            if distance > toleranceMeters {
                result.append(current)
            }
        }

        // Never reduce below a triangle: if a ring collapses entirely it was degenerate, and the
        // caller's own minimum-vertex guard should reject it rather than this returning junk.
        return result.count >= 3 ? result : ring
    }

    /// True when no two non-adjacent edges of the ring cross.
    ///
    /// Ear clipping is only defined for simple polygons; given a self-intersecting one it
    /// happily emits overlapping and inverted triangles rather than failing. A bow-tie returns
    /// a +50/−50 pair, which is exactly the kind of silently-wrong geometry a UAV would then be
    /// asked to collide against. O(n²) over rings of at most a few hundred vertices is nothing.
    static func isSimple(_ ring: [SIMD2<Float>]) -> Bool {
        let count = ring.count
        guard count >= 4 else { return count == 3 }

        for i in 0..<count {
            let a1 = ring[i]
            let a2 = ring[(i + 1) % count]
            for j in (i + 1)..<count {
                // Skip edges sharing a vertex — they always "touch" at that vertex.
                if j == i { continue }
                if (j + 1) % count == i { continue }
                if j == (i + 1) % count { continue }

                let b1 = ring[j]
                let b2 = ring[(j + 1) % count]
                if segmentsIntersect(a1, a2, b1, b2) { return false }
            }
        }
        return true
    }

    private static func segmentsIntersect(
        _ p1: SIMD2<Float>,
        _ p2: SIMD2<Float>,
        _ p3: SIMD2<Float>,
        _ p4: SIMD2<Float>
    ) -> Bool {
        func orientation(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Int {
            let value = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            if value > 1e-9 { return 1 }
            if value < -1e-9 { return -1 }
            return 0
        }

        func onSegment(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ point: SIMD2<Float>) -> Bool {
            point.x >= min(a.x, b.x) - 1e-9 && point.x <= max(a.x, b.x) + 1e-9
                && point.y >= min(a.y, b.y) - 1e-9 && point.y <= max(a.y, b.y) + 1e-9
        }

        let o1 = orientation(p1, p2, p3)
        let o2 = orientation(p1, p2, p4)
        let o3 = orientation(p3, p4, p1)
        let o4 = orientation(p3, p4, p2)

        if o1 != o2 && o3 != o4 { return true }

        // Collinear overlap counts as an intersection: two edges lying along each other means
        // the ring doubles back on itself.
        if o1 == 0 && onSegment(p1, p2, p3) { return true }
        if o2 == 0 && onSegment(p1, p2, p4) { return true }
        if o3 == 0 && onSegment(p3, p4, p1) { return true }
        if o4 == 0 && onSegment(p3, p4, p2) { return true }

        return false
    }

    // MARK: - Oriented bounding box

    /// Minimum-area oriented bounding box, via rotating calipers over the convex hull.
    ///
    /// Roof ridges must follow the building's own long axis, not the world axes — a gabled roof
    /// on a block rotated 30° off north looks obviously wrong if its ridge runs east-west. This
    /// returns the axis a ridge should follow along with the box's extent.
    struct OrientedBounds {
        let center: SIMD2<Float>
        /// Unit vector along the longer side.
        let longAxis: SIMD2<Float>
        let longExtent: Float
        let shortExtent: Float
    }

    static func orientedBounds(of polygon: [SIMD2<Float>]) -> OrientedBounds? {
        let hull = convexHull(of: polygon)
        guard hull.count >= 3 else { return nil }

        var best: OrientedBounds?
        var bestArea = Float.greatestFiniteMagnitude

        // The minimum-area rectangle always shares an edge with the convex hull, so only the
        // hull's own edge directions need testing.
        for index in hull.indices {
            let edge = hull[(index + 1) % hull.count] - hull[index]
            let length = simd_length(edge)
            guard length > 1e-6 else { continue }
            let axis = edge / length
            let perpendicular = SIMD2<Float>(-axis.y, axis.x)

            var minimumAlong = Float.greatestFiniteMagnitude
            var maximumAlong = -Float.greatestFiniteMagnitude
            var minimumAcross = Float.greatestFiniteMagnitude
            var maximumAcross = -Float.greatestFiniteMagnitude

            for vertex in hull {
                let along = simd_dot(vertex, axis)
                let across = simd_dot(vertex, perpendicular)
                minimumAlong = min(minimumAlong, along)
                maximumAlong = max(maximumAlong, along)
                minimumAcross = min(minimumAcross, across)
                maximumAcross = max(maximumAcross, across)
            }

            let extentAlong = maximumAlong - minimumAlong
            let extentAcross = maximumAcross - minimumAcross
            let area = extentAlong * extentAcross
            guard area < bestArea else { continue }
            bestArea = area

            let centerAlong = (minimumAlong + maximumAlong) * 0.5
            let centerAcross = (minimumAcross + maximumAcross) * 0.5
            let center = axis * centerAlong + perpendicular * centerAcross

            if extentAlong >= extentAcross {
                best = OrientedBounds(
                    center: center,
                    longAxis: axis,
                    longExtent: extentAlong,
                    shortExtent: extentAcross
                )
            } else {
                best = OrientedBounds(
                    center: center,
                    longAxis: perpendicular,
                    longExtent: extentAcross,
                    shortExtent: extentAlong
                )
            }
        }

        return best
    }

    /// Andrew's monotone chain. Returns hull vertices counter-clockwise.
    static func convexHull(of points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard points.count >= 3 else { return points }
        let sorted = points.sorted {
            $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x
        }

        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [SIMD2<Float>] = []
        for point in sorted {
            while lower.count >= 2,
                  cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }

        var upper: [SIMD2<Float>] = []
        for point in sorted.reversed() {
            while upper.count >= 2,
                  cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }

        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }
}
