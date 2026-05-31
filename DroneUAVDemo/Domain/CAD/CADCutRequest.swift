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
