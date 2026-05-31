import Foundation

struct CADCutMeshBuildResult: Equatable {
    var mesh: CADSolidMeshSnapshot
    var diagnostics: CADSolidMeshDiagnostics
    var rebuildDiagnostics: CADCutMeshRebuildDiagnostics
}

struct CADCutMeshRebuildDiagnostics: Equatable {
    var throughAll: Bool
    var entryFaceRebuiltWithHole: Bool
    var exitFaceRebuiltWithHole: Bool
    var capFacesGenerated: Int
    var trianglesInsideEntryHole: Int
    var trianglesInsideExitHole: Int
    var suspectedOrphanPlugTriangles: Int
    var reversedNormalTriangles: Int
}

enum CADCutMeshRebuilder {
    private struct ResolvedCut {
        var feature: ExtrudedSolidBoxBlindCutFeature
        var entryFace: DesignPlanarFace
        var exitFace: DesignPlanarFace?
        var exitProfile: [SketchPoint2D]?
        var depthMeters: Double
        var direction: DesignVector3
    }

    private struct MeshWriter {
        var vertices: [DesignVector3] = []
        var triangles: [CADSolidTriangle] = []
        var reversedNormalTriangles = 0

        mutating func appendTriangle(
            _ a: DesignVector3,
            _ b: DesignVector3,
            _ c: DesignVector3,
            desiredNormal: DesignVector3
        ) {
            let normal = desiredNormal.normalized(fallback: .zAxis)
            guard a.isFinite, b.isFinite, c.isFinite, normal.isFinite else { return }
            let windingNormal = (b - a).cross(c - a)
            guard windingNormal.length > 1e-12 else { return }
            let base = vertices.count
            vertices += [a, b, c]
            if windingNormal.dot(normal) < 0 {
                reversedNormalTriangles += 1
                triangles.append(CADSolidTriangle(a: base, b: base + 2, c: base + 1))
            } else {
                triangles.append(CADSolidTriangle(a: base, b: base + 1, c: base + 2))
            }
        }

        mutating func appendQuad(
            _ a: DesignVector3,
            _ b: DesignVector3,
            _ c: DesignVector3,
            _ d: DesignVector3,
            desiredNormal: DesignVector3
        ) {
            appendTriangle(a, b, c, desiredNormal: desiredNormal)
            appendTriangle(a, c, d, desiredNormal: desiredNormal)
        }

        func snapshot() -> CADSolidMeshSnapshot {
            CADSolidMeshSnapshot(vertices: vertices, triangles: triangles)
        }
    }

    private struct RebuildCounters {
        var throughAll = false
        var entryFaceRebuiltWithHole = false
        var exitFaceRebuiltWithHole = false
        var capFacesGenerated = 0
        var trianglesInsideEntryHole = 0
        var trianglesInsideExitHole = 0
        var suspectedOrphanPlugTriangles = 0
        var reversedNormalTriangles = 0

        var diagnostics: CADCutMeshRebuildDiagnostics {
            CADCutMeshRebuildDiagnostics(
                throughAll: throughAll,
                entryFaceRebuiltWithHole: entryFaceRebuiltWithHole,
                exitFaceRebuiltWithHole: exitFaceRebuiltWithHole,
                capFacesGenerated: capFacesGenerated,
                trianglesInsideEntryHole: trianglesInsideEntryHole,
                trianglesInsideExitHole: trianglesInsideExitHole,
                suspectedOrphanPlugTriangles: suspectedOrphanPlugTriangles,
                reversedNormalTriangles: reversedNormalTriangles
            )
        }
    }

    static func rebuildBodyMesh(
        bodyID: UUID,
        bodyParams: ExtrudedSolidParameters
    ) -> CADCutMeshBuildResult? {
        _ = bodyID
        guard bodyParams.holes.isEmpty,
              bodyParams.cutFeatures.isEmpty,
              bodyParams.profilePoints.count == 4,
              !bodyParams.faces.isEmpty,
              bodyParams.vertices().allSatisfy(\.isFinite) else {
            return nil
        }

        guard let cuts = resolveCuts(in: bodyParams) else { return nil }
        var writer = MeshWriter()
        var counters = RebuildCounters()
        counters.throughAll = cuts.contains { $0.feature.depthMode == .throughAll }

        for face in bodyParams.faces {
            let entryCuts = cuts.filter { $0.entryFace.id == face.id }
            let exitCuts = cuts.filter { $0.exitFace?.id == face.id }
            let faceCuts = entryCuts + exitCuts
            guard faceCuts.count <= 1 else { return nil }

            if let cut = entryCuts.first {
                appendFace(face, cut: cut, profile: cut.feature.profilePoints, to: &writer)
                if cut.feature.depthMode == .throughAll {
                    counters.entryFaceRebuiltWithHole = true
                }
            } else if let cut = exitCuts.first, let exitProfile = cut.exitProfile {
                appendFace(face, cut: cut, profile: exitProfile, to: &writer)
                if cut.feature.depthMode == .throughAll {
                    counters.exitFaceRebuiltWithHole = true
                }
            } else {
                appendFullFace(face, to: &writer)
            }
        }

        for cut in cuts {
            appendInternalCutSurfaces(cut, to: &writer, counters: &counters)
        }

        counters.reversedNormalTriangles = writer.reversedNormalTriangles
        let mesh = removeThroughAllFacePlugTriangles(
            from: writer.snapshot(),
            cuts: cuts
        )
        countThroughAllFaceHoleViolations(in: mesh, cuts: cuts, counters: &counters)
        guard !mesh.vertices.isEmpty,
              !mesh.triangles.isEmpty,
              mesh.vertices.allSatisfy(\.isFinite) else {
            return nil
        }
        let rebuildDiagnostics = counters.diagnostics
        logRebuildDiagnostics(rebuildDiagnostics)
        return CADCutMeshBuildResult(
            mesh: mesh,
            diagnostics: CADSolidMeshValidator.diagnose(mesh),
            rebuildDiagnostics: rebuildDiagnostics
        )
    }

    private static func resolveCuts(in body: ExtrudedSolidParameters) -> [ResolvedCut]? {
        let bodyVertices = body.vertices()
        var resolved: [ResolvedCut] = []
        for feature in body.boxBlindCutFeatures {
            guard let entryFace = body.faces.first(where: { $0.id == feature.entryFaceID }),
                  feature.profileType == .rectangle || feature.profileType == .circle,
                  feature.depthMode == .distance || feature.depthMode == .throughAll else {
                return nil
            }
            let direction = feature.cutDirection.normalized(fallback: entryFace.normal * -1)
            guard let thickness = CADCutGeometry.bodyThickness(
                entryFaceCenter: entryFace.center,
                bodyWorldVertices: bodyVertices,
                direction: direction
            ) else {
                return nil
            }
            let depth = feature.depthMode == .throughAll
                ? thickness
                : min(feature.depthMeters, thickness - CADCutGeometry.epsilon)
            guard depth > CADCutGeometry.epsilon else { return nil }

            let exitFace: DesignPlanarFace?
            if feature.depthMode == .throughAll {
                guard let foundExitFace = findExitFace(
                    for: feature,
                    entryFace: entryFace,
                    body: body,
                    direction: direction,
                    depth: depth
                ) else {
                    return nil
                }
                exitFace = foundExitFace
            } else {
                exitFace = nil
            }
            let exitProfile = exitFace.map {
                projectProfile(feature.profilePoints, from: entryFace, to: $0, direction: direction, depth: depth)
            }
            let cut = ResolvedCut(
                feature: feature,
                entryFace: entryFace,
                exitFace: exitFace,
                exitProfile: exitProfile,
                depthMeters: depth,
                direction: direction
            )
            resolved.append(cut)
        }
        return resolved
    }

    private static func findExitFace(
        for feature: ExtrudedSolidBoxBlindCutFeature,
        entryFace: DesignPlanarFace,
        body: ExtrudedSolidParameters,
        direction: DesignVector3,
        depth: Double
    ) -> DesignPlanarFace? {
        _ = feature
        let expectedCenter = entryFace.center + direction * depth
        return body.faces
            .filter { $0.id != entryFace.id }
            .filter { $0.normal.normalized(fallback: .zAxis).dot(direction) > 0.995 }
            .min(by: {
                ($0.center - expectedCenter).length < ($1.center - expectedCenter).length
            })
    }

    private static func projectProfile(
        _ profile: [SketchPoint2D],
        from entryFace: DesignPlanarFace,
        to exitFace: DesignPlanarFace,
        direction: DesignVector3,
        depth: Double
    ) -> [SketchPoint2D] {
        profile.map { point in
            let world = CADCutGeometry.worldPoint(on: entryFace, local: point) + direction * depth
            return CADCutGeometry.localPoint(on: exitFace, world: world)
        }
    }

    private static func appendFullFace(_ face: DesignPlanarFace, to writer: inout MeshWriter) {
        let b = face.bounds
        appendRect(
            face,
            minU: b.minU,
            maxU: b.maxU,
            minV: b.minV,
            maxV: b.maxV,
            normal: face.normal,
            to: &writer
        )
    }

    private static func appendFace(
        _ face: DesignPlanarFace,
        cut: ResolvedCut,
        profile: [SketchPoint2D],
        to writer: inout MeshWriter
    ) {
        switch cut.feature.profileType {
        case .rectangle:
            appendRectFaceWithRectHole(face, hole: profile, to: &writer)
        case .circle:
            appendRectFaceWithCircleHole(face, cut: cut, profile: profile, to: &writer)
        case .polygon, .unsupported:
            break
        }
    }

    private static func appendRectFaceWithRectHole(
        _ face: DesignPlanarFace,
        hole: [SketchPoint2D],
        to writer: inout MeshWriter
    ) {
        guard let h = CADCutGeometry.profileBounds(hole) else {
            appendFullFace(face, to: &writer)
            return
        }
        let b = face.bounds
        appendRect(face, minU: b.minU, maxU: h.minU, minV: b.minV, maxV: b.maxV, normal: face.normal, to: &writer)
        appendRect(face, minU: h.maxU, maxU: b.maxU, minV: b.minV, maxV: b.maxV, normal: face.normal, to: &writer)
        appendRect(face, minU: h.minU, maxU: h.maxU, minV: b.minV, maxV: h.minV, normal: face.normal, to: &writer)
        appendRect(face, minU: h.minU, maxU: h.maxU, minV: h.maxV, maxV: b.maxV, normal: face.normal, to: &writer)
    }

    private static func appendRectFaceWithCircleHole(
        _ face: DesignPlanarFace,
        cut: ResolvedCut,
        profile: [SketchPoint2D],
        to writer: inout MeshWriter
    ) {
        guard let circle = CADCutGeometry.circleMetrics(
            points: profile,
            explicitCenter: cut.feature.profileType == .circle ? CADCutGeometry.profileCenter(profile) : nil,
            explicitRadius: nil
        ) else {
            appendFullFace(face, to: &writer)
            return
        }
        let c = circle.center
        let r = circle.radius
        let b = face.bounds
        let segmentCount = 64
        let step = (2.0 * Double.pi) / Double(segmentCount)

        func point(_ uv: SketchPoint2D) -> DesignVector3 {
            CADCutGeometry.worldPoint(on: face, local: uv)
        }

        func circlePoint(_ angle: Double) -> SketchPoint2D {
            SketchPoint2D(u: c.u + cos(angle) * r, v: c.v + sin(angle) * r)
        }

        func appendBand(from start: Double, to end: Double, side: Int) {
            var angle = start
            while angle < end - 1e-12 {
                let next = min(angle + step, end)
                let p0 = circlePoint(angle)
                let p1 = circlePoint(next)
                let o0: SketchPoint2D
                let o1: SketchPoint2D
                switch side {
                case 0:
                    o0 = SketchPoint2D(u: b.maxU, v: p0.v)
                    o1 = SketchPoint2D(u: b.maxU, v: p1.v)
                case 1:
                    o0 = SketchPoint2D(u: p0.u, v: b.maxV)
                    o1 = SketchPoint2D(u: p1.u, v: b.maxV)
                case 2:
                    o0 = SketchPoint2D(u: b.minU, v: p0.v)
                    o1 = SketchPoint2D(u: b.minU, v: p1.v)
                default:
                    o0 = SketchPoint2D(u: p0.u, v: b.minV)
                    o1 = SketchPoint2D(u: p1.u, v: b.minV)
                }
                writer.appendQuad(point(o0), point(o1), point(p1), point(p0), desiredNormal: face.normal)
                angle = next
            }
        }

        func appendCircleCorner(
            _ face: DesignPlanarFace,
            angle: Double,
            corner: SketchPoint2D,
            to writer: inout MeshWriter
        ) {
            let p = circlePoint(angle)
            let topOrBottom = SketchPoint2D(u: p.u, v: corner.v)
            let leftOrRight = SketchPoint2D(u: corner.u, v: p.v)
            writer.appendQuad(
                point(topOrBottom),
                point(corner),
                point(leftOrRight),
                point(p),
                desiredNormal: face.normal
            )
        }

        appendBand(from: -Double.pi / 4, to: Double.pi / 4, side: 0)
        appendBand(from: Double.pi / 4, to: 3 * Double.pi / 4, side: 1)
        appendBand(from: 3 * Double.pi / 4, to: 5 * Double.pi / 4, side: 2)
        appendBand(from: 5 * Double.pi / 4, to: 7 * Double.pi / 4, side: 3)

        appendCircleCorner(face, angle: Double.pi / 4, corner: SketchPoint2D(u: b.maxU, v: b.maxV), to: &writer)
        appendCircleCorner(face, angle: 3 * Double.pi / 4, corner: SketchPoint2D(u: b.minU, v: b.maxV), to: &writer)
        appendCircleCorner(face, angle: 5 * Double.pi / 4, corner: SketchPoint2D(u: b.minU, v: b.minV), to: &writer)
        appendCircleCorner(face, angle: 7 * Double.pi / 4, corner: SketchPoint2D(u: b.maxU, v: b.minV), to: &writer)
    }

    private static func appendRect(
        _ face: DesignPlanarFace,
        minU: Double,
        maxU: Double,
        minV: Double,
        maxV: Double,
        normal: DesignVector3,
        to writer: inout MeshWriter
    ) {
        guard maxU - minU > CADCutGeometry.epsilon,
              maxV - minV > CADCutGeometry.epsilon else {
            return
        }
        let p0 = CADCutGeometry.worldPoint(on: face, local: SketchPoint2D(u: minU, v: minV))
        let p1 = CADCutGeometry.worldPoint(on: face, local: SketchPoint2D(u: maxU, v: minV))
        let p2 = CADCutGeometry.worldPoint(on: face, local: SketchPoint2D(u: maxU, v: maxV))
        let p3 = CADCutGeometry.worldPoint(on: face, local: SketchPoint2D(u: minU, v: maxV))
        writer.appendQuad(p0, p1, p2, p3, desiredNormal: normal)
    }

    private static func appendInternalCutSurfaces(
        _ cut: ResolvedCut,
        to writer: inout MeshWriter,
        counters: inout RebuildCounters
    ) {
        let entryFace = cut.entryFace
        let entryLoop = cut.feature.profilePoints
        let bottomLoop = entryLoop.map {
            CADCutGeometry.worldPoint(on: entryFace, local: $0) + cut.direction * cut.depthMeters
        }
        let entryWorldLoop = entryLoop.map {
            CADCutGeometry.worldPoint(on: entryFace, local: $0)
        }

        switch cut.feature.profileType {
        case .rectangle:
            appendLoopWalls(entry: entryWorldLoop, far: bottomLoop, center: cutCenter(cut), to: &writer)
            if cut.feature.depthMode == .distance {
                appendPolygonCap(bottomLoop, normal: cut.direction * -1, to: &writer)
                counters.capFacesGenerated += max(bottomLoop.count - 2, 0)
            }
        case .circle:
            appendLoopWalls(entry: entryWorldLoop, far: bottomLoop, center: cutCenter(cut), to: &writer)
            if cut.feature.depthMode == .distance {
                appendPolygonCap(bottomLoop, normal: cut.direction * -1, to: &writer)
                counters.capFacesGenerated += max(bottomLoop.count - 2, 0)
            }
        case .polygon, .unsupported:
            break
        }
    }

    private static func cutCenter(_ cut: ResolvedCut) -> DesignVector3 {
        let center = CADCutGeometry.profileCenter(cut.feature.profilePoints) ?? .zero
        return CADCutGeometry.worldPoint(on: cut.entryFace, local: center) + cut.direction * (cut.depthMeters * 0.5)
    }

    private static func appendLoopWalls(
        entry: [DesignVector3],
        far: [DesignVector3],
        center: DesignVector3,
        to writer: inout MeshWriter
    ) {
        guard entry.count == far.count, entry.count >= 3 else { return }
        for index in entry.indices {
            let next = (index + 1) % entry.count
            let mid = (entry[index] + entry[next] + far[index] + far[next]) * 0.25
            let normal = (center - mid).normalized(fallback: .zAxis)
            writer.appendQuad(
                entry[index],
                far[index],
                far[next],
                entry[next],
                desiredNormal: normal
            )
        }
    }

    private static func appendPolygonCap(
        _ points: [DesignVector3],
        normal: DesignVector3,
        to writer: inout MeshWriter
    ) {
        guard points.count >= 3 else { return }
        for index in 1..<(points.count - 1) {
            writer.appendTriangle(points[0], points[index], points[index + 1], desiredNormal: normal)
        }
    }

    private static func removeThroughAllFacePlugTriangles(
        from mesh: CADSolidMeshSnapshot,
        cuts: [ResolvedCut]
    ) -> CADSolidMeshSnapshot {
        var triangles = mesh.triangles
        for cut in cuts where cut.feature.depthMode == .throughAll {
            triangles = triangles.filter { triangle in
                guard let entry = triangleHoleTest(
                    triangle,
                    mesh: mesh,
                    face: cut.entryFace,
                    profile: cut.feature.profilePoints,
                    profileType: cut.feature.profileType
                ) else {
                    return true
                }
                return !entry.suspectedPlug
            }

            guard let exitFace = cut.exitFace,
                  let exitProfile = cut.exitProfile else {
                continue
            }
            triangles = triangles.filter { triangle in
                guard let exit = triangleHoleTest(
                    triangle,
                    mesh: mesh,
                    face: exitFace,
                    profile: exitProfile,
                    profileType: cut.feature.profileType
                ) else {
                    return true
                }
                return !exit.suspectedPlug
            }
        }
        return CADSolidMeshSnapshot(vertices: mesh.vertices, triangles: triangles)
    }

    private static func countThroughAllFaceHoleViolations(
        in mesh: CADSolidMeshSnapshot,
        cuts: [ResolvedCut],
        counters: inout RebuildCounters
    ) {
        for cut in cuts where cut.feature.depthMode == .throughAll {
            for triangle in mesh.triangles {
                if let entry = triangleHoleTest(
                    triangle,
                    mesh: mesh,
                    face: cut.entryFace,
                    profile: cut.feature.profilePoints,
                    profileType: cut.feature.profileType
                ) {
                    if entry.centroidInsideHole {
                        counters.trianglesInsideEntryHole += 1
                    }
                    if entry.suspectedPlug {
                        counters.suspectedOrphanPlugTriangles += 1
                    }
                }

                guard let exitFace = cut.exitFace,
                      let exitProfile = cut.exitProfile,
                      let exit = triangleHoleTest(
                        triangle,
                        mesh: mesh,
                        face: exitFace,
                        profile: exitProfile,
                        profileType: cut.feature.profileType
                      ) else {
                    continue
                }
                if exit.centroidInsideHole {
                    counters.trianglesInsideExitHole += 1
                }
                if exit.suspectedPlug {
                    counters.suspectedOrphanPlugTriangles += 1
                }
            }
        }
    }

    private static func triangleHoleTest(
        _ triangle: CADSolidTriangle,
        mesh: CADSolidMeshSnapshot,
        face: DesignPlanarFace,
        profile: [SketchPoint2D],
        profileType: CADCutV2ProfileType
    ) -> (centroidInsideHole: Bool, suspectedPlug: Bool)? {
        guard triangle.a >= 0, triangle.a < mesh.vertices.count,
              triangle.b >= 0, triangle.b < mesh.vertices.count,
              triangle.c >= 0, triangle.c < mesh.vertices.count else {
            return nil
        }
        let world = [
            mesh.vertices[triangle.a],
            mesh.vertices[triangle.b],
            mesh.vertices[triangle.c]
        ]
        let normal = face.normal.normalized(fallback: .zAxis)
        let planeTolerance = max(CADCutGeometry.epsilon * 10.0, 1e-5)
        guard world.allSatisfy({ abs(($0 - face.center).dot(normal)) <= planeTolerance }) else {
            return nil
        }

        let local = world.map { CADCutGeometry.localPoint(on: face, world: $0) }
        let centroid = SketchPoint2D(
            u: (local[0].u + local[1].u + local[2].u) / 3.0,
            v: (local[0].v + local[1].v + local[2].v) / 3.0
        )
        let holeCenter = CADCutGeometry.profileCenter(profile) ?? centroid
        let centroidInside = pointIsStrictlyInsideHole(centroid, profile: profile, profileType: profileType)
        let centerCovered = pointInTriangle(holeCenter, local[0], local[1], local[2])
        let vertexInside = local.contains {
            pointIsStrictlyInsideHole($0, profile: profile, profileType: profileType)
        }
        return (
            centroidInsideHole: centroidInside,
            suspectedPlug: centroidInside || centerCovered || vertexInside
        )
    }

    private static func pointIsStrictlyInsideHole(
        _ point: SketchPoint2D,
        profile: [SketchPoint2D],
        profileType: CADCutV2ProfileType
    ) -> Bool {
        switch profileType {
        case .rectangle:
            guard let bounds = CADCutGeometry.profileBounds(profile) else { return false }
            return point.u > bounds.minU + CADCutGeometry.epsilon
                && point.u < bounds.maxU - CADCutGeometry.epsilon
                && point.v > bounds.minV + CADCutGeometry.epsilon
                && point.v < bounds.maxV - CADCutGeometry.epsilon
        case .circle:
            guard let circle = CADCutGeometry.circleMetrics(
                points: profile,
                explicitCenter: CADCutGeometry.profileCenter(profile),
                explicitRadius: nil
            ) else {
                return false
            }
            return point.distance(to: circle.center) < circle.radius - CADCutGeometry.epsilon
        case .polygon, .unsupported:
            return false
        }
    }

    private static func pointInTriangle(
        _ point: SketchPoint2D,
        _ a: SketchPoint2D,
        _ b: SketchPoint2D,
        _ c: SketchPoint2D
    ) -> Bool {
        let denominator = (b.v - c.v) * (a.u - c.u) + (c.u - b.u) * (a.v - c.v)
        guard abs(denominator) > 1e-12 else { return false }
        let alpha = ((b.v - c.v) * (point.u - c.u) + (c.u - b.u) * (point.v - c.v)) / denominator
        let beta = ((c.v - a.v) * (point.u - c.u) + (a.u - c.u) * (point.v - c.v)) / denominator
        let gamma = 1.0 - alpha - beta
        let tolerance = 1e-7
        return alpha >= -tolerance && beta >= -tolerance && gamma >= -tolerance
    }

    private static func logRebuildDiagnostics(_ diagnostics: CADCutMeshRebuildDiagnostics) {
        print(
            "CAD Cut V1 Mesh Rebuild: " +
            "throughAll=\(diagnostics.throughAll) " +
            "entryFaceRebuiltWithHole=\(diagnostics.entryFaceRebuiltWithHole) " +
            "exitFaceRebuiltWithHole=\(diagnostics.exitFaceRebuiltWithHole) " +
            "capFacesGenerated=\(diagnostics.capFacesGenerated) " +
            "trianglesInsideEntryHole=\(diagnostics.trianglesInsideEntryHole) " +
            "trianglesInsideExitHole=\(diagnostics.trianglesInsideExitHole) " +
            "suspectedOrphanPlugTriangles=\(diagnostics.suspectedOrphanPlugTriangles) " +
            "reversedNormalTriangles=\(diagnostics.reversedNormalTriangles)"
        )
    }
}
