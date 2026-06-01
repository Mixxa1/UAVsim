import Foundation

struct CADCutRequest: Equatable {
    var targetBodyID: UUID
    var targetBodyGeometry: ExtrudedSolidParameters
    var entryFaceID: UUID
    var entryFaceOrigin: DesignVector3
    var entryFaceCenter: DesignVector3
    var entryFaceNormal: DesignVector3
    var entryFaceUAxis: DesignVector3
    var entryFaceVAxis: DesignVector3
    var entryFaceBounds: DesignFaceBounds
    var sourceSketchReference: SketchReference
    var profileType: CADCutV2ProfileType
    var profilePoints: [SketchPoint2D]
    var profileCenter: SketchPoint2D?
    var profileRadius: Double?
    var depthMode: DepthMode
    var depthMeters: Double
    var cutDirectionWorld: DesignVector3
    var sourceSketchID: UUID
    var sourceSketchName: String
    var selectedProfileID: UUID

    var entryFace: DesignPlanarFace {
        DesignPlanarFace(
            id: entryFaceID,
            name: "",
            assetID: targetBodyID,
            origin: entryFaceOrigin,
            normal: entryFaceNormal,
            uAxis: entryFaceUAxis,
            vAxis: entryFaceVAxis,
            bounds: entryFaceBounds
        )
    }

    var directionForSketchReference: ExtrudeDirection {
        let sketchNormal = normalVector(for: sourceSketchReference).normalized(fallback: .zAxis)
        return cutDirectionWorld.normalized(fallback: sketchNormal).dot(sketchNormal) >= 0
            ? .positiveNormal
            : .negativeNormal
    }

    func feature(id: UUID = UUID()) -> ExtrudedSolidBoxBlindCutFeature {
        ExtrudedSolidBoxBlindCutFeature(
            id: id,
            profileType: profileType,
            entryFaceID: entryFaceID,
            profilePoints: profilePoints,
            depthMeters: depthMeters,
            cutDirection: cutDirectionWorld.normalized(fallback: entryFaceNormal * -1),
            sourceSketchID: sourceSketchID,
            sourceSketchName: sourceSketchName,
            selectedProfileID: selectedProfileID,
            depthMode: depthMode,
            direction: directionForSketchReference
        )
    }

    static func inwardCutDirection(
        entryFaceNormal: DesignVector3,
        entryFaceCenter: DesignVector3,
        bodyWorldVertices: [DesignVector3]
    ) -> DesignVector3 {
        let n = entryFaceNormal.normalized(fallback: .zAxis)
        guard !bodyWorldVertices.isEmpty else { return n * -1 }

        let center = bodyWorldVertices.reduce(DesignVector3.zero, +) * (1.0 / Double(bodyWorldVertices.count))
        let toBody = center - entryFaceCenter

        return (toBody.dot(n) >= 0 ? n : n * -1).normalized(fallback: n * -1)
    }
}

enum CADCutGeometry {
    static let epsilon = 1e-6

    struct Bounds: Equatable {
        var min: DesignVector3
        var max: DesignVector3

        func intersects(_ other: Bounds, tolerance: Double = 1e-6) -> Bool {
            min.x <= other.max.x + tolerance && max.x + tolerance >= other.min.x
                && min.y <= other.max.y + tolerance && max.y + tolerance >= other.min.y
                && min.z <= other.max.z + tolerance && max.z + tolerance >= other.min.z
        }
    }

    static func bodyThickness(
        entryFaceCenter: DesignVector3,
        bodyWorldVertices: [DesignVector3],
        direction: DesignVector3
    ) -> Double? {
        let d = direction.normalized(fallback: .zAxis)
        let projections = bodyWorldVertices.map { ($0 - entryFaceCenter).dot(d) }
        guard projections.allSatisfy(\.isFinite),
              let maxProjection = projections.max(),
              maxProjection > epsilon else {
            return nil
        }
        return maxProjection
    }

    static func worldPoint(on face: DesignPlanarFace, local point: SketchPoint2D) -> DesignVector3 {
        face.origin + face.uAxis * point.u + face.vAxis * point.v
    }

    static func localPoint(on face: DesignPlanarFace, world point: DesignVector3) -> SketchPoint2D {
        let u = face.uAxis.normalized(fallback: .xAxis)
        let v = face.vAxis.normalized(fallback: .yAxis)
        let delta = point - face.origin
        return SketchPoint2D(u: delta.dot(u), v: delta.dot(v))
    }

    static func profileBounds(_ points: [SketchPoint2D]) -> (minU: Double, maxU: Double, minV: Double, maxV: Double)? {
        guard !points.isEmpty else { return nil }
        return (
            points.map(\.u).min() ?? 0,
            points.map(\.u).max() ?? 0,
            points.map(\.v).min() ?? 0,
            points.map(\.v).max() ?? 0
        )
    }

    static func profileCenter(_ points: [SketchPoint2D]) -> SketchPoint2D? {
        guard !points.isEmpty else { return nil }
        let count = Double(points.count)
        return SketchPoint2D(
            u: points.map(\.u).reduce(0, +) / count,
            v: points.map(\.v).reduce(0, +) / count
        )
    }

    static func circleMetrics(
        points: [SketchPoint2D],
        explicitCenter: SketchPoint2D?,
        explicitRadius: Double?
    ) -> (center: SketchPoint2D, radius: Double)? {
        if let center = explicitCenter,
           let radius = explicitRadius,
           center.u.isFinite,
           center.v.isFinite,
           radius.isFinite,
           radius > epsilon {
            return (center, radius)
        }
        guard let center = profileCenter(points) else { return nil }
        let radius = points.map { $0.distance(to: center) }.reduce(0, +) / Double(max(points.count, 1))
        guard radius.isFinite, radius > epsilon else { return nil }
        return (center, radius)
    }

    static func cutterBounds(
        entryFace: DesignPlanarFace,
        profilePoints: [SketchPoint2D],
        direction: DesignVector3,
        depthMeters: Double
    ) -> Bounds? {
        guard depthMeters.isFinite, depthMeters > epsilon else { return nil }
        let d = direction.normalized(fallback: entryFace.normal * -1)
        let entry = profilePoints.map { worldPoint(on: entryFace, local: $0) }
        let far = entry.map { $0 + d * depthMeters }
        let points = entry + far
        guard let first = points.first, first.isFinite else { return nil }
        var minPoint = first
        var maxPoint = first
        for point in points.dropFirst() {
            guard point.isFinite else { return nil }
            minPoint = DesignVector3(
                x: min(minPoint.x, point.x),
                y: min(minPoint.y, point.y),
                z: min(minPoint.z, point.z)
            )
            maxPoint = DesignVector3(
                x: max(maxPoint.x, point.x),
                y: max(maxPoint.y, point.y),
                z: max(maxPoint.z, point.z)
            )
        }
        return Bounds(min: minPoint, max: maxPoint)
    }
}

struct CADPlanarProfileUnionResult: Equatable {
    var succeeded: Bool
    var loops: [[SketchPoint2D]]
    var failureReason: String?
}

enum CADPlanarProfileRelation: Equatable {
    case separate
    case touching
    case intersecting

    var overlapsOrTouches: Bool {
        self != .separate
    }
}

enum CADPlanarProfileUnion {
    private enum SegmentRelation {
        case separate
        case touching
        case intersecting
    }

    private struct Segment2D {
        var a: SketchPoint2D
        var b: SketchPoint2D
    }

    private typealias Rect = (minU: Double, maxU: Double, minV: Double, maxV: Double)

    static let failureReason = "cad.cut_v2.reason.profile_union_failed"

    static func relation(
        profileA: [SketchPoint2D],
        typeA: CADCutV2ProfileType,
        profileB: [SketchPoint2D],
        typeB: CADCutV2ProfileType,
        tolerance: Double = max(CADCutGeometry.epsilon * 10.0, 1e-6)
    ) -> CADPlanarProfileRelation {
        guard let loopA = normalizedLoopForRelation(profileA, type: typeA, tolerance: tolerance),
              let loopB = normalizedLoopForRelation(profileB, type: typeB, tolerance: tolerance) else {
            return .intersecting
        }
        guard let boundsA = CADCutGeometry.profileBounds(loopA),
              let boundsB = CADCutGeometry.profileBounds(loopB),
              boundsOverlapOrTouch(boundsA, boundsB, tolerance: tolerance) else {
            return .separate
        }

        var touching = false
        for indexA in loopA.indices {
            let nextA = (indexA + 1) % loopA.count
            for indexB in loopB.indices {
                let nextB = (indexB + 1) % loopB.count
                switch segmentRelation(
                    a: loopA[indexA],
                    b: loopA[nextA],
                    c: loopB[indexB],
                    d: loopB[nextB],
                    tolerance: tolerance
                ) {
                case .intersecting:
                    return .intersecting
                case .touching:
                    touching = true
                case .separate:
                    continue
                }
            }
        }

        if loopA.contains(where: { pointStrictlyInsidePolygon($0, polygon: loopB, tolerance: tolerance) })
            || loopB.contains(where: { pointStrictlyInsidePolygon($0, polygon: loopA, tolerance: tolerance) }) {
            return .intersecting
        }
        return touching ? .touching : .separate
    }

    static func profilesOverlapOrTouch(
        profileA: [SketchPoint2D],
        typeA: CADCutV2ProfileType,
        profileB: [SketchPoint2D],
        typeB: CADCutV2ProfileType,
        tolerance: Double = max(CADCutGeometry.epsilon * 10.0, 1e-6)
    ) -> Bool {
        relation(
            profileA: profileA,
            typeA: typeA,
            profileB: profileB,
            typeB: typeB,
            tolerance: tolerance
        ).overlapsOrTouches
    }

    static func union(
        loops rawLoops: [[SketchPoint2D]],
        tolerance: Double = max(CADCutGeometry.epsilon * 10.0, 1e-6)
    ) -> CADPlanarProfileUnionResult {
        let loops = rawLoops.compactMap { normalizedLoop($0, tolerance: tolerance) }
        guard loops.count == rawLoops.count, !loops.isEmpty else {
            return CADPlanarProfileUnionResult(succeeded: false, loops: [], failureReason: failureReason)
        }
        if let rects = exactRectangles(from: loops, tolerance: tolerance) {
            let unionLoops = rectangleUnion(rects, tolerance: tolerance)
            return validatedResult(loops: unionLoops, tolerance: tolerance)
        }
        let unionLoops = unionBoundaryLoops(loops, tolerance: tolerance)
        return validatedResult(loops: unionLoops, tolerance: tolerance)
    }

    private static func validatedResult(
        loops: [[SketchPoint2D]],
        tolerance: Double
    ) -> CADPlanarProfileUnionResult {
        let validLoops = loops.compactMap { normalizedLoop($0, tolerance: tolerance) }
            .filter { abs(DesignSketch.polygonSignedAreaMeters2($0)) > tolerance * tolerance }
        guard !validLoops.isEmpty else {
            return CADPlanarProfileUnionResult(succeeded: false, loops: [], failureReason: failureReason)
        }
        return CADPlanarProfileUnionResult(succeeded: true, loops: validLoops, failureReason: nil)
    }

    private static func exactRectangles(
        from loops: [[SketchPoint2D]],
        tolerance: Double
    ) -> [Rect]? {
        var rects: [Rect] = []
        for loop in loops {
            guard loop.count == 4,
                  let bounds = CADCutGeometry.profileBounds(loop) else {
                return nil
            }
            let pointsMatchRect = loop.allSatisfy { point in
                let onVertical = abs(point.u - bounds.minU) <= tolerance || abs(point.u - bounds.maxU) <= tolerance
                let onHorizontal = abs(point.v - bounds.minV) <= tolerance || abs(point.v - bounds.maxV) <= tolerance
                return onVertical && onHorizontal
            }
            guard pointsMatchRect,
                  bounds.maxU - bounds.minU > tolerance,
                  bounds.maxV - bounds.minV > tolerance else {
                return nil
            }
            rects.append(bounds)
        }
        return rects
    }

    private static func rectangleUnion(
        _ rects: [Rect],
        tolerance: Double
    ) -> [[SketchPoint2D]] {
        guard !rects.isEmpty else { return [] }
        let xs = uniqueSortedValues(rects.flatMap { [$0.minU, $0.maxU] }, tolerance: tolerance)
        let ys = uniqueSortedValues(rects.flatMap { [$0.minV, $0.maxV] }, tolerance: tolerance)
        guard xs.count >= 2, ys.count >= 2 else { return [] }

        var occupied = Set<String>()
        func key(_ x: Int, _ y: Int) -> String { "\(x):\(y)" }
        for xIndex in 0..<(xs.count - 1) {
            for yIndex in 0..<(ys.count - 1) {
                let center = SketchPoint2D(
                    u: (xs[xIndex] + xs[xIndex + 1]) * 0.5,
                    v: (ys[yIndex] + ys[yIndex + 1]) * 0.5
                )
                if rects.contains(where: {
                    center.u >= $0.minU - tolerance
                        && center.u <= $0.maxU + tolerance
                        && center.v >= $0.minV - tolerance
                        && center.v <= $0.maxV + tolerance
                }) {
                    occupied.insert(key(xIndex, yIndex))
                }
            }
        }

        var segments: [Segment2D] = []
        for xIndex in 0..<(xs.count - 1) {
            for yIndex in 0..<(ys.count - 1) where occupied.contains(key(xIndex, yIndex)) {
                if !occupied.contains(key(xIndex, yIndex - 1)) {
                    segments.append(Segment2D(
                        a: SketchPoint2D(u: xs[xIndex], v: ys[yIndex]),
                        b: SketchPoint2D(u: xs[xIndex + 1], v: ys[yIndex])
                    ))
                }
                if !occupied.contains(key(xIndex + 1, yIndex)) {
                    segments.append(Segment2D(
                        a: SketchPoint2D(u: xs[xIndex + 1], v: ys[yIndex]),
                        b: SketchPoint2D(u: xs[xIndex + 1], v: ys[yIndex + 1])
                    ))
                }
                if !occupied.contains(key(xIndex, yIndex + 1)) {
                    segments.append(Segment2D(
                        a: SketchPoint2D(u: xs[xIndex + 1], v: ys[yIndex + 1]),
                        b: SketchPoint2D(u: xs[xIndex], v: ys[yIndex + 1])
                    ))
                }
                if !occupied.contains(key(xIndex - 1, yIndex)) {
                    segments.append(Segment2D(
                        a: SketchPoint2D(u: xs[xIndex], v: ys[yIndex + 1]),
                        b: SketchPoint2D(u: xs[xIndex], v: ys[yIndex])
                    ))
                }
            }
        }

        return weldSegmentsIntoLoops(segments, tolerance: tolerance)
    }

    private static func unionBoundaryLoops(
        _ polygons: [[SketchPoint2D]],
        tolerance: Double
    ) -> [[SketchPoint2D]] {
        var keptSegments: [Segment2D] = []
        for polygonIndex in polygons.indices {
            let polygon = polygons[polygonIndex]
            for index in polygon.indices {
                let next = (index + 1) % polygon.count
                let a = polygon[index]
                let b = polygon[next]
                var splits: [Double] = [0, 1]
                for otherIndex in polygons.indices where otherIndex != polygonIndex {
                    let other = polygons[otherIndex]
                    for otherEdge in other.indices {
                        let otherNext = (otherEdge + 1) % other.count
                        appendIntersectionParameters(
                            segmentA: a,
                            segmentB: b,
                            otherA: other[otherEdge],
                            otherB: other[otherNext],
                            tolerance: tolerance,
                            parameters: &splits
                        )
                    }
                }
                splits = uniqueSorted(splits, tolerance: tolerance)
                for splitIndex in 0..<(splits.count - 1) {
                    let t0 = splits[splitIndex]
                    let t1 = splits[splitIndex + 1]
                    guard t1 - t0 > tolerance else { continue }
                    let start = interpolate(a, b, t0)
                    let end = interpolate(a, b, t1)
                    let mid = interpolate(a, b, (t0 + t1) * 0.5)
                    let insideOther = polygons.indices.contains { otherIndex in
                        otherIndex != polygonIndex
                            && pointStrictlyInsidePolygon(mid, polygon: polygons[otherIndex], tolerance: tolerance)
                    }
                    if !insideOther {
                        keptSegments.append(Segment2D(a: start, b: end))
                    }
                }
            }
        }
        return weldSegmentsIntoLoops(keptSegments, tolerance: tolerance)
    }

    private static func normalizedLoopForRelation(
        _ points: [SketchPoint2D],
        type: CADCutV2ProfileType,
        tolerance: Double
    ) -> [SketchPoint2D]? {
        switch type {
        case .rectangle, .circle, .polygon:
            return normalizedLoop(points, tolerance: tolerance)
        case .unsupported:
            return nil
        }
    }

    private static func boundsOverlapOrTouch(
        _ lhs: Rect,
        _ rhs: Rect,
        tolerance: Double
    ) -> Bool {
        lhs.minU <= rhs.maxU + tolerance
            && lhs.maxU + tolerance >= rhs.minU
            && lhs.minV <= rhs.maxV + tolerance
            && lhs.maxV + tolerance >= rhs.minV
    }

    private static func segmentRelation(
        a: SketchPoint2D,
        b: SketchPoint2D,
        c: SketchPoint2D,
        d: SketchPoint2D,
        tolerance: Double
    ) -> SegmentRelation {
        let rU = b.u - a.u
        let rV = b.v - a.v
        let sU = d.u - c.u
        let sV = d.v - c.v
        let denominator = rU * sV - rV * sU
        let lengthA2 = rU * rU + rV * rV
        guard lengthA2 > tolerance * tolerance else { return .separate }

        if abs(denominator) > tolerance * tolerance {
            let qU = c.u - a.u
            let qV = c.v - a.v
            let t = (qU * sV - qV * sU) / denominator
            let u = (qU * rV - qV * rU) / denominator
            guard t >= -tolerance, t <= 1 + tolerance, u >= -tolerance, u <= 1 + tolerance else {
                return .separate
            }
            let interiorA = t > tolerance && t < 1 - tolerance
            let interiorB = u > tolerance && u < 1 - tolerance
            return interiorA && interiorB ? .intersecting : .touching
        }

        guard distanceFromPoint(c, toSegmentA: a, b: b) <= tolerance
                || distanceFromPoint(d, toSegmentA: a, b: b) <= tolerance
                || distanceFromPoint(a, toSegmentA: c, b: d) <= tolerance else {
            return .separate
        }

        let t0 = parameter(of: c, onA: a, b: b)
        let t1 = parameter(of: d, onA: a, b: b)
        let overlapStart = max(min(t0, t1), 0)
        let overlapEnd = min(max(t0, t1), 1)
        guard overlapEnd >= overlapStart - tolerance else { return .separate }
        return .touching
    }

    private static func appendIntersectionParameters(
        segmentA a: SketchPoint2D,
        segmentB b: SketchPoint2D,
        otherA c: SketchPoint2D,
        otherB d: SketchPoint2D,
        tolerance: Double,
        parameters: inout [Double]
    ) {
        let rU = b.u - a.u
        let rV = b.v - a.v
        let sU = d.u - c.u
        let sV = d.v - c.v
        let denominator = rU * sV - rV * sU
        if abs(denominator) > tolerance * tolerance {
            let qU = c.u - a.u
            let qV = c.v - a.v
            let t = (qU * sV - qV * sU) / denominator
            let u = (qU * rV - qV * rU) / denominator
            if t >= -tolerance, t <= 1 + tolerance, u >= -tolerance, u <= 1 + tolerance {
                parameters.append(min(max(t, 0), 1))
            }
            return
        }

        if distanceFromPoint(c, toSegmentA: a, b: b) <= tolerance {
            parameters.append(parameter(of: c, onA: a, b: b))
        }
        if distanceFromPoint(d, toSegmentA: a, b: b) <= tolerance {
            parameters.append(parameter(of: d, onA: a, b: b))
        }
    }

    private static func weldSegmentsIntoLoops(
        _ segments: [Segment2D],
        tolerance: Double
    ) -> [[SketchPoint2D]] {
        var remaining = segments
        var loops: [[SketchPoint2D]] = []
        while let first = remaining.first {
            remaining.removeFirst()
            var loop = [first.a, first.b]
            var extended = true
            while extended {
                extended = false
                guard let tail = loop.last else { break }
                if tail.distance(to: loop[0]) <= tolerance {
                    loop[loop.count - 1] = loop[0]
                    break
                }
                if let index = remaining.firstIndex(where: {
                    $0.a.distance(to: tail) <= tolerance || $0.b.distance(to: tail) <= tolerance
                }) {
                    let segment = remaining.remove(at: index)
                    loop.append(segment.a.distance(to: tail) <= tolerance ? segment.b : segment.a)
                    extended = true
                }
            }
            if let normalized = normalizedLoop(loop, tolerance: tolerance) {
                loops.append(normalized)
            }
        }
        return loops
    }

    private static func normalizedLoop(
        _ points: [SketchPoint2D],
        tolerance: Double
    ) -> [SketchPoint2D]? {
        var result: [SketchPoint2D] = []
        for point in points where point.u.isFinite && point.v.isFinite {
            if result.last?.distance(to: point) ?? .infinity > tolerance {
                result.append(point)
            }
        }
        if result.count > 1, result[0].distance(to: result[result.count - 1]) <= tolerance {
            result.removeLast()
        }
        guard result.count >= 3,
              abs(DesignSketch.polygonSignedAreaMeters2(result)) > tolerance * tolerance else {
            return nil
        }
        if DesignSketch.polygonSignedAreaMeters2(result) < 0 {
            result.reverse()
        }
        return result
    }

    private static func uniqueSorted(_ values: [Double], tolerance: Double) -> [Double] {
        values
            .map { min(max($0, 0), 1) }
            .sorted()
            .reduce(into: []) { result, value in
                if result.last.map({ abs($0 - value) > tolerance }) ?? true {
                    result.append(value)
                }
            }
    }

    private static func uniqueSortedValues(_ values: [Double], tolerance: Double) -> [Double] {
        values
            .filter(\.isFinite)
            .sorted()
            .reduce(into: []) { result, value in
                if result.last.map({ abs($0 - value) > tolerance }) ?? true {
                    result.append(value)
                }
            }
    }

    private static func interpolate(_ a: SketchPoint2D, _ b: SketchPoint2D, _ t: Double) -> SketchPoint2D {
        SketchPoint2D(u: a.u + (b.u - a.u) * t, v: a.v + (b.v - a.v) * t)
    }

    private static func parameter(of point: SketchPoint2D, onA a: SketchPoint2D, b: SketchPoint2D) -> Double {
        let du = b.u - a.u
        let dv = b.v - a.v
        let len2 = du * du + dv * dv
        guard len2 > 1e-18 else { return 0 }
        return ((point.u - a.u) * du + (point.v - a.v) * dv) / len2
    }

    private static func pointStrictlyInsidePolygon(
        _ point: SketchPoint2D,
        polygon: [SketchPoint2D],
        tolerance: Double
    ) -> Bool {
        if polygon.indices.contains(where: {
            let next = ($0 + 1) % polygon.count
            return distanceFromPoint(point, toSegmentA: polygon[$0], b: polygon[next]) <= tolerance
        }) {
            return false
        }
        return pointInPolygon(point, polygon: polygon, tolerance: tolerance)
    }

    private static func pointInPolygon(
        _ point: SketchPoint2D,
        polygon: [SketchPoint2D],
        tolerance: Double
    ) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let pi = polygon[i]
            let pj = polygon[j]
            if distanceFromPoint(point, toSegmentA: pi, b: pj) <= tolerance {
                return true
            }
            if (pi.v > point.v) != (pj.v > point.v) {
                let x = (pj.u - pi.u) * (point.v - pi.v) / (pj.v - pi.v) + pi.u
                if point.u < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    private static func distanceFromPoint(
        _ point: SketchPoint2D,
        toSegmentA a: SketchPoint2D,
        b: SketchPoint2D
    ) -> Double {
        point.distance(to: closestPointOnSegment(from: point, segA: a, segB: b))
    }
}
