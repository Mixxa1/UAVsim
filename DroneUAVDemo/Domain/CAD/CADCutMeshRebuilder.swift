import Foundation

struct CADCutMeshBuildResult: Equatable {
    var mesh: CADSolidMeshSnapshot
    var diagnostics: CADSolidMeshDiagnostics
    var rebuildDiagnostics: CADCutMeshRebuildDiagnostics
}

struct CADCutMeshRebuildDiagnostics: Equatable {
    var throughAll: Bool
    var totalCutCount: Int
    var affectedFaceCount: Int
    var cutsGroupedByFace: [String]
    var depthMode: DepthMode?
    var entryFaceID: UUID?
    var exitFaceID: UUID?
    var affectedFaceID: UUID?
    var entryLoopVertexCount: Int
    var exitLoopVertexCount: Int
    var holeCountOnFace: Int
    var holeTypesOnFace: [String]
    var sameFaceTriangulationPassed: Bool
    var holeIntersectionDetected: Bool
    var holeTouchDetected: Bool
    var cutVolumeIntersectionDetected: Bool
    var unsupportedIntersectingCutDetected: Bool
    var sameFaceOverlapGroupCount: Int
    var mergedProfileLoopCount: Int
    var unionFailureCount: Int
    var trianglesInsideMergedHole: Int
    var crossFaceIntersectionBlocked: Bool
    var entryFaceRebuiltWithHole: Bool
    var exitFaceRebuiltWithHole: Bool
    var capFacesGenerated: Int
    var orphanTriangleCount: Int
    var nonCoplanarFaceTriangleCount: Int
    var trianglesCrossingBetweenHoles: Int
    var trianglesOutsideFace: Int
    var trianglesInsideEntryHole: Int
    var trianglesInsideExitHole: Int
    var trianglesInsideAnyHole: Int
    var oldFullFaceRetained: Bool
    var oldFullEntryFaceKept: Bool
    var oldFullExitFaceKept: Bool
    var suspectedOrphanPlugTriangles: Int
    var reversedNormalTriangles: Int
    var committedCutsCount: Int
    var candidateCutID: UUID?
    var affectedEntryFaceID: UUID?
    var affectedExitFaceID: UUID?
    var cutsOnEntryFace: Int
    var cutsOnExitFace: Int
    var multiCutValidationPassed: Bool
    var multiCutValidationReason: String?
    var transientPreviewNodeCount: Int
}

enum CADCutMeshRebuilder {
    private struct ResolvedCut {
        var feature: ExtrudedSolidBoxBlindCutFeature
        var entryFace: DesignPlanarFace
        var exitFace: DesignPlanarFace?
        var exitProfile: [SketchPoint2D]?
        var farWorldLoop: [DesignVector3]
        var depthMeters: Double
        var direction: DesignVector3
        var isUnionResult: Bool
    }

    private struct FaceHole {
        var cutID: UUID
        var profileType: CADCutV2ProfileType
        var profile: [SketchPoint2D]
    }

    private struct ResolveResult {
        var cuts: [ResolvedCut]
        var originalCutCount: Int
        var sameFaceOverlapGroupCount: Int
        var mergedProfileLoopCount: Int
        var unionFailureCount: Int
    }

    private typealias UVBounds = (minU: Double, maxU: Double, minV: Double, maxV: Double)

    private struct SameFaceHoleValidation {
        var isValid = true
        var intersectionDetected = false
        var touchDetected = false
    }

    private struct SameFaceTriangulationStats {
        var passed = true
        var trianglesCrossingBetweenHoles = 0
        var trianglesOutsideFace = 0
        var trianglesInsideAnyHole = 0
    }

    private struct HoleStripInterval {
        var leftBottom: Double
        var rightBottom: Double
        var leftTop: Double
        var rightTop: Double
        var leftMid: Double
        var rightMid: Double
    }

    private struct SurfaceValidationResult {
        var orphanTriangleCount = 0
        var nonCoplanarFaceTriangleCount = 0
        var trianglesOutsideFace = 0
        var oldFullEntryFaceKept = false
        var oldFullExitFaceKept = false

        var isValid: Bool {
            orphanTriangleCount == 0
                && nonCoplanarFaceTriangleCount == 0
                && !oldFullEntryFaceKept
                && !oldFullExitFaceKept
        }
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
        var totalCutCount = 0
        var affectedFaceCount = 0
        var cutsGroupedByFace: [String] = []
        var depthMode: DepthMode?
        var entryFaceID: UUID?
        var exitFaceID: UUID?
        var affectedFaceID: UUID?
        var entryLoopVertexCount = 0
        var exitLoopVertexCount = 0
        var holeCountOnFace = 0
        var holeTypesOnFace: [String] = []
        var sameFaceTriangulationPassed = true
        var holeIntersectionDetected = false
        var holeTouchDetected = false
        var cutVolumeIntersectionDetected = false
        var unsupportedIntersectingCutDetected = false
        var sameFaceOverlapGroupCount = 0
        var mergedProfileLoopCount = 0
        var unionFailureCount = 0
        var trianglesInsideMergedHole = 0
        var crossFaceIntersectionBlocked = false
        var entryFaceRebuiltWithHole = false
        var exitFaceRebuiltWithHole = false
        var capFacesGenerated = 0
        var orphanTriangleCount = 0
        var nonCoplanarFaceTriangleCount = 0
        var trianglesCrossingBetweenHoles = 0
        var trianglesOutsideFace = 0
        var trianglesInsideEntryHole = 0
        var trianglesInsideExitHole = 0
        var trianglesInsideAnyHole = 0
        var oldFullEntryFaceKept = false
        var oldFullExitFaceKept = false
        var suspectedOrphanPlugTriangles = 0
        var reversedNormalTriangles = 0
        var committedCutsCount = 0
        var candidateCutID: UUID?
        var affectedEntryFaceID: UUID?
        var affectedExitFaceID: UUID?
        var cutsOnEntryFace = 0
        var cutsOnExitFace = 0
        var multiCutValidationPassed = true
        var multiCutValidationReason: String?
        var transientPreviewNodeCount = 0

        var diagnostics: CADCutMeshRebuildDiagnostics {
            CADCutMeshRebuildDiagnostics(
                throughAll: throughAll,
                totalCutCount: totalCutCount,
                affectedFaceCount: affectedFaceCount,
                cutsGroupedByFace: cutsGroupedByFace,
                depthMode: depthMode,
                entryFaceID: entryFaceID,
                exitFaceID: exitFaceID,
                affectedFaceID: affectedFaceID,
                entryLoopVertexCount: entryLoopVertexCount,
                exitLoopVertexCount: exitLoopVertexCount,
                holeCountOnFace: holeCountOnFace,
                holeTypesOnFace: holeTypesOnFace,
                sameFaceTriangulationPassed: sameFaceTriangulationPassed,
                holeIntersectionDetected: holeIntersectionDetected,
                holeTouchDetected: holeTouchDetected,
                cutVolumeIntersectionDetected: cutVolumeIntersectionDetected,
                unsupportedIntersectingCutDetected: unsupportedIntersectingCutDetected,
                sameFaceOverlapGroupCount: sameFaceOverlapGroupCount,
                mergedProfileLoopCount: mergedProfileLoopCount,
                unionFailureCount: unionFailureCount,
                trianglesInsideMergedHole: trianglesInsideMergedHole,
                crossFaceIntersectionBlocked: crossFaceIntersectionBlocked,
                entryFaceRebuiltWithHole: entryFaceRebuiltWithHole,
                exitFaceRebuiltWithHole: exitFaceRebuiltWithHole,
                capFacesGenerated: capFacesGenerated,
                orphanTriangleCount: orphanTriangleCount,
                nonCoplanarFaceTriangleCount: nonCoplanarFaceTriangleCount,
                trianglesCrossingBetweenHoles: trianglesCrossingBetweenHoles,
                trianglesOutsideFace: trianglesOutsideFace,
                trianglesInsideEntryHole: trianglesInsideEntryHole,
                trianglesInsideExitHole: trianglesInsideExitHole,
                trianglesInsideAnyHole: trianglesInsideAnyHole,
                oldFullFaceRetained: oldFullEntryFaceKept || oldFullExitFaceKept,
                oldFullEntryFaceKept: oldFullEntryFaceKept,
                oldFullExitFaceKept: oldFullExitFaceKept,
                suspectedOrphanPlugTriangles: suspectedOrphanPlugTriangles,
                reversedNormalTriangles: reversedNormalTriangles,
                committedCutsCount: committedCutsCount,
                candidateCutID: candidateCutID,
                affectedEntryFaceID: affectedEntryFaceID,
                affectedExitFaceID: affectedExitFaceID,
                cutsOnEntryFace: cutsOnEntryFace,
                cutsOnExitFace: cutsOnExitFace,
                multiCutValidationPassed: multiCutValidationPassed,
                multiCutValidationReason: multiCutValidationReason,
                transientPreviewNodeCount: transientPreviewNodeCount
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

        guard let resolve = resolveCuts(in: bodyParams) else { return nil }
        let cuts = resolve.cuts
        var writer = MeshWriter()
        var counters = RebuildCounters()
        counters.throughAll = cuts.contains { $0.feature.depthMode == .throughAll }
        counters.totalCutCount = resolve.originalCutCount
        counters.sameFaceOverlapGroupCount = resolve.sameFaceOverlapGroupCount
        counters.mergedProfileLoopCount = resolve.mergedProfileLoopCount
        counters.unionFailureCount = resolve.unionFailureCount
        counters.depthMode = cuts.last?.feature.depthMode
        counters.entryFaceID = cuts.last?.entryFace.id
        counters.exitFaceID = cuts.last?.exitFace?.id
        counters.entryLoopVertexCount = cuts.last?.feature.profilePoints.count ?? 0
        counters.exitLoopVertexCount = cuts.last?.exitProfile?.count ?? 0
        counters.committedCutsCount = resolve.originalCutCount
        counters.candidateCutID = cuts.last?.feature.id
        counters.affectedEntryFaceID = cuts.last?.entryFace.id
        counters.affectedExitFaceID = cuts.last?.exitFace?.id
        if let entryFaceID = counters.affectedEntryFaceID {
            counters.cutsOnEntryFace = cuts.filter { $0.entryFace.id == entryFaceID }.count
        }
        if let exitFaceID = counters.affectedExitFaceID {
            counters.cutsOnExitFace = cuts.filter { $0.exitFace?.id == exitFaceID }.count
        }

        var holesByFace: [UUID: [FaceHole]] = [:]
        for cut in cuts {
            holesByFace[cut.entryFace.id, default: []].append(
                FaceHole(
                    cutID: cut.feature.id,
                    profileType: cut.feature.profileType,
                    profile: cut.feature.profilePoints
                )
            )
            if let exitFace = cut.exitFace,
               let exitProfile = cut.exitProfile {
                holesByFace[exitFace.id, default: []].append(
                    FaceHole(
                        cutID: cut.feature.id,
                        profileType: cut.feature.profileType,
                        profile: exitProfile
                    )
                )
            }
        }
        counters.affectedFaceCount = holesByFace.count
        counters.cutsGroupedByFace = bodyParams.faces.compactMap { face in
            guard let holes = holesByFace[face.id], !holes.isEmpty else { return nil }
            return "\(face.id.uuidString):\(holes.count)"
        }

        for face in bodyParams.faces {
            let entryCuts = cuts.filter { $0.entryFace.id == face.id }
            let exitCuts = cuts.filter { $0.exitFace?.id == face.id }

            if let holes = holesByFace[face.id], !holes.isEmpty {
                guard appendFace(face, holes: holes, to: &writer, counters: &counters) else {
                    logRebuildDiagnostics(counters.diagnostics)
                    return nil
                }
                if !entryCuts.isEmpty {
                    counters.entryFaceRebuiltWithHole = true
                }
                if !exitCuts.isEmpty {
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
        countFaceHoleViolations(in: mesh, cuts: cuts, counters: &counters)
        let surfaceValidation = validateGeneratedSurfaces(in: mesh, cuts: cuts, bodyFaces: bodyParams.faces)
        counters.orphanTriangleCount = surfaceValidation.orphanTriangleCount
        counters.nonCoplanarFaceTriangleCount = surfaceValidation.nonCoplanarFaceTriangleCount
        counters.trianglesOutsideFace += surfaceValidation.trianglesOutsideFace
        counters.oldFullEntryFaceKept = surfaceValidation.oldFullEntryFaceKept
        counters.oldFullExitFaceKept = surfaceValidation.oldFullExitFaceKept
        if counters.throughAll, counters.capFacesGenerated != 0 {
            counters.orphanTriangleCount += counters.capFacesGenerated
        }
        guard !mesh.vertices.isEmpty,
              !mesh.triangles.isEmpty,
              mesh.vertices.allSatisfy(\.isFinite),
              surfaceValidation.isValid,
              (!counters.throughAll || counters.capFacesGenerated == 0),
              counters.sameFaceTriangulationPassed,
              !counters.holeIntersectionDetected,
              !counters.holeTouchDetected,
              counters.trianglesCrossingBetweenHoles == 0,
              counters.trianglesOutsideFace == 0,
              counters.trianglesInsideEntryHole == 0,
              counters.trianglesInsideExitHole == 0,
              counters.trianglesInsideMergedHole == 0 else {
            logRebuildDiagnostics(counters.diagnostics)
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

    private static func resolveCuts(in body: ExtrudedSolidParameters) -> ResolveResult? {
        let bodyVertices = body.vertices()
        var resolved: [ResolvedCut] = []
        var overlapGroupCount = 0
        var mergedLoopCount = 0
        var unionFailureCount = 0

        let orderedEntryFaceIDs = body.boxBlindCutFeatures.reduce(into: [UUID]()) { result, feature in
            if !result.contains(feature.entryFaceID) {
                result.append(feature.entryFaceID)
            }
        }

        for entryFaceID in orderedEntryFaceIDs {
            let faceCuts = body.boxBlindCutFeatures.filter { $0.entryFaceID == entryFaceID }
            for group in overlappingGroups(cuts: faceCuts) {
                guard let first = group.first else { continue }
                if group.count == 1 {
                    guard let cut = resolveCut(
                        feature: first,
                        body: body,
                        bodyVertices: bodyVertices,
                        isUnionResult: false
                    ) else {
                        return nil
                    }
                    resolved.append(cut)
                    continue
                }

                overlapGroupCount += 1
                guard let unionFeatures = unionFeatures(for: group, body: body) else {
                    unionFailureCount += 1
                    return nil
                }
                mergedLoopCount += unionFeatures.count
                for unionFeature in unionFeatures {
                    guard let cut = resolveCut(
                        feature: unionFeature,
                        body: body,
                        bodyVertices: bodyVertices,
                        isUnionResult: true
                    ) else {
                        return nil
                    }
                    resolved.append(cut)
                }
            }
        }

        return ResolveResult(
            cuts: resolved,
            originalCutCount: body.boxBlindCutFeatures.count,
            sameFaceOverlapGroupCount: overlapGroupCount,
            mergedProfileLoopCount: mergedLoopCount,
            unionFailureCount: unionFailureCount
        )
    }

    private static func resolveCut(
        feature: ExtrudedSolidBoxBlindCutFeature,
        body: ExtrudedSolidParameters,
        bodyVertices: [DesignVector3],
        isUnionResult: Bool
    ) -> ResolvedCut? {
            guard let entryFace = body.faces.first(where: { $0.id == feature.entryFaceID }),
                  feature.profileType == .rectangle || feature.profileType == .circle || feature.profileType == .polygon,
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
            let exitProfile: [SketchPoint2D]?
            let farWorldLoop: [DesignVector3]
            if feature.depthMode == .throughAll {
                guard let exit = findExitFace(
                    for: feature,
                    entryFace: entryFace,
                    body: body,
                    direction: direction
                ) else {
                    return nil
                }
                exitFace = exit.face
                exitProfile = exit.profile
                farWorldLoop = exit.profile.map {
                    CADCutGeometry.worldPoint(on: exit.face, local: $0)
                }
            } else {
                exitFace = nil
                exitProfile = nil
                farWorldLoop = feature.profilePoints.map {
                    CADCutGeometry.worldPoint(on: entryFace, local: $0) + direction * depth
                }
            }
            let cut = ResolvedCut(
                feature: feature,
                entryFace: entryFace,
                exitFace: exitFace,
                exitProfile: exitProfile,
                farWorldLoop: farWorldLoop,
                depthMeters: depth,
                direction: direction,
                isUnionResult: isUnionResult
            )
            return cut
    }

    private static func unionFeatures(
        for cuts: [ExtrudedSolidBoxBlindCutFeature],
        body: ExtrudedSolidParameters
    ) -> [ExtrudedSolidBoxBlindCutFeature]? {
        guard let first = cuts.first,
              let entryFace = body.faces.first(where: { $0.id == first.entryFaceID }) else {
            return nil
        }
        for cut in cuts {
            guard cut.entryFaceID == first.entryFaceID,
                  cut.depthMode == first.depthMode,
                  cut.cutDirection.normalized(fallback: entryFace.normal * -1)
                    .dot(first.cutDirection.normalized(fallback: entryFace.normal * -1)) > 0.999 else {
                return nil
            }
            if first.depthMode == .distance,
               abs(cut.depthMeters - first.depthMeters) > max(CADCutGeometry.epsilon * 10.0, 1e-6) {
                return nil
            }
        }

        let union = CADPlanarProfileUnion.union(
            loops: cuts.map(\.profilePoints),
            tolerance: max(CADCutGeometry.epsilon * 10.0, 1e-6)
        )
        guard union.succeeded, !union.loops.isEmpty else { return nil }

        return union.loops.enumerated().map { index, loop in
            ExtrudedSolidBoxBlindCutFeature(
                id: index == 0 ? first.id : UUID(),
                profileType: .polygon,
                entryFaceID: first.entryFaceID,
                profilePoints: loop,
                depthMeters: first.depthMeters,
                cutDirection: first.cutDirection,
                sourceSketchID: first.sourceSketchID,
                sourceSketchName: first.sourceSketchName,
                selectedProfileID: first.selectedProfileID,
                depthMode: first.depthMode,
                direction: first.direction
            )
        }
    }

    private static func overlappingGroups(
        cuts: [ExtrudedSolidBoxBlindCutFeature]
    ) -> [[ExtrudedSolidBoxBlindCutFeature]] {
        guard !cuts.isEmpty else { return [] }
        let tolerance = max(CADCutGeometry.epsilon * 10.0, 1e-6)
        var visited = Set<UUID>()
        var groups: [[ExtrudedSolidBoxBlindCutFeature]] = []
        for cut in cuts where !visited.contains(cut.id) {
            var group: [ExtrudedSolidBoxBlindCutFeature] = []
            var queue = [cut]
            visited.insert(cut.id)
            while let current = queue.popLast() {
                group.append(current)
                for other in cuts where !visited.contains(other.id) {
                    guard CADPlanarProfileUnion.profilesOverlapOrTouch(
                        profileA: current.profilePoints,
                        typeA: current.profileType,
                        profileB: other.profilePoints,
                        typeB: other.profileType,
                        tolerance: tolerance
                    ) else {
                        continue
                    }
                    visited.insert(other.id)
                    queue.append(other)
                }
            }
            groups.append(group)
        }
        return groups
    }

    private static func findExitFace(
        for feature: ExtrudedSolidBoxBlindCutFeature,
        entryFace: DesignPlanarFace,
        body: ExtrudedSolidParameters,
        direction: DesignVector3
    ) -> (face: DesignPlanarFace, profile: [SketchPoint2D])? {
        let entryCenter = CADCutGeometry.profileCenter(feature.profilePoints).map {
            CADCutGeometry.worldPoint(on: entryFace, local: $0)
        } ?? entryFace.center
        return body.faces
            .filter { $0.id != entryFace.id }
            .filter { $0.normal.normalized(fallback: .zAxis).dot(direction) > 0.995 }
            .compactMap { face -> (face: DesignPlanarFace, profile: [SketchPoint2D], distance: Double)? in
                guard let profile = projectProfile(
                    feature.profilePoints,
                    from: entryFace,
                    to: face,
                    direction: direction
                ) else {
                    return nil
                }
                let exitNormal = face.normal.normalized(fallback: direction)
                let distance = (face.origin - entryCenter).dot(exitNormal) / direction.dot(exitNormal)
                guard distance.isFinite, distance > CADCutGeometry.epsilon else { return nil }
                let hole = FaceHole(
                    cutID: feature.id,
                    profileType: feature.profileType,
                    profile: profile
                )
                guard let bounds = bounds(for: hole),
                      bounds.minU > face.bounds.minU + CADCutGeometry.epsilon,
                      bounds.maxU < face.bounds.maxU - CADCutGeometry.epsilon,
                      bounds.minV > face.bounds.minV + CADCutGeometry.epsilon,
                      bounds.maxV < face.bounds.maxV - CADCutGeometry.epsilon else {
                    return nil
                }
                return (face, profile, distance)
            }
            .min(by: {
                $0.distance < $1.distance
            })
            .map { (face: $0.face, profile: $0.profile) }
    }

    private static func projectProfile(
        _ profile: [SketchPoint2D],
        from entryFace: DesignPlanarFace,
        to exitFace: DesignPlanarFace,
        direction: DesignVector3
    ) -> [SketchPoint2D]? {
        let d = direction.normalized(fallback: entryFace.normal * -1)
        let exitNormal = exitFace.normal.normalized(fallback: d)
        let denominator = d.dot(exitNormal)
        guard denominator > CADCutGeometry.epsilon else { return nil }

        var projected: [SketchPoint2D] = []
        for point in profile {
            let world = CADCutGeometry.worldPoint(on: entryFace, local: point)
            let distance = (exitFace.origin - world).dot(exitNormal) / denominator
            guard distance.isFinite, distance > CADCutGeometry.epsilon else { return nil }
            projected.append(CADCutGeometry.localPoint(on: exitFace, world: world + d * distance))
        }
        return projected
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

    @discardableResult
    private static func appendFace(
        _ face: DesignPlanarFace,
        holes: [FaceHole],
        to writer: inout MeshWriter,
        counters: inout RebuildCounters
    ) -> Bool {
        guard !holes.isEmpty else {
            appendFullFace(face, to: &writer)
            return true
        }
        counters.affectedFaceID = face.id
        counters.holeCountOnFace = max(counters.holeCountOnFace, holes.count)
        if holes.count >= counters.holeTypesOnFace.count {
            counters.holeTypesOnFace = holes.map(\.profileType.rawValue)
        }
        if holes.count == 1, holes[0].profileType != .polygon {
            return appendSingleHoleFace(face, hole: holes[0], to: &writer)
        }

        let validation = validateSameFaceHoles(face: face, holes: holes)
        counters.holeIntersectionDetected = counters.holeIntersectionDetected || validation.intersectionDetected
        counters.holeTouchDetected = counters.holeTouchDetected || validation.touchDetected
        guard validation.isValid else {
            counters.sameFaceTriangulationPassed = false
            return false
        }

        let stats = appendMultiHoleFaceByHorizontalSweep(face, holes: holes, to: &writer)
        counters.sameFaceTriangulationPassed = counters.sameFaceTriangulationPassed && stats.passed
        counters.trianglesCrossingBetweenHoles += stats.trianglesCrossingBetweenHoles
        counters.trianglesOutsideFace += stats.trianglesOutsideFace
        counters.trianglesInsideAnyHole += stats.trianglesInsideAnyHole
        return stats.passed
    }

    private static func validateSameFaceHoles(
        face: DesignPlanarFace,
        holes: [FaceHole]
    ) -> SameFaceHoleValidation {
        var result = SameFaceHoleValidation()
        let tolerance = max(CADCutGeometry.epsilon * 10.0, 1e-6)
        var holeBoundsList: [UVBounds] = []

        for hole in holes {
            guard hole.profile.count >= 3,
                  hole.profile.allSatisfy({ $0.u.isFinite && $0.v.isFinite }),
                  abs(DesignSketch.polygonSignedAreaMeters2(hole.profile)) > 1e-12,
                  let holeBounds = bounds(for: hole),
                  holeBounds.minU > face.bounds.minU + tolerance,
                  holeBounds.maxU < face.bounds.maxU - tolerance,
                  holeBounds.minV > face.bounds.minV + tolerance,
                  holeBounds.maxV < face.bounds.maxV - tolerance else {
                result.isValid = false
                return result
            }
            holeBoundsList.append(holeBounds)
        }

        for lhsIndex in holeBoundsList.indices {
            for rhsIndex in holeBoundsList.indices where rhsIndex > lhsIndex {
                let lhs = holes[lhsIndex]
                let rhs = holes[rhsIndex]
                let relation = CADPlanarProfileUnion.relation(
                    profileA: lhs.profile,
                    typeA: lhs.profileType,
                    profileB: rhs.profile,
                    typeB: rhs.profileType,
                    tolerance: tolerance
                )
                switch relation {
                case .separate:
                    continue
                case .touching:
                    result.isValid = false
                    result.touchDetected = true
                case .intersecting:
                    result.isValid = false
                    result.intersectionDetected = true
                }
            }
        }

        return result
    }

    private static func bounds(for hole: FaceHole) -> UVBounds? {
        profileBounds(profileType: hole.profileType, points: hole.profile)
    }

    private static func profileBounds(
        profileType: CADCutV2ProfileType,
        points: [SketchPoint2D]
    ) -> UVBounds? {
        switch profileType {
        case .rectangle:
            return CADCutGeometry.profileBounds(points)
        case .circle:
            guard let circle = CADCutGeometry.circleMetrics(
                points: points,
                explicitCenter: CADCutGeometry.profileCenter(points),
                explicitRadius: nil
            ) else {
                return nil
            }
            return (
                minU: circle.center.u - circle.radius,
                maxU: circle.center.u + circle.radius,
                minV: circle.center.v - circle.radius,
                maxV: circle.center.v + circle.radius
            )
        case .polygon:
            return CADCutGeometry.profileBounds(points)
        case .unsupported:
            return nil
        }
    }

    private static func appendMultiHoleFaceByHorizontalSweep(
        _ face: DesignPlanarFace,
        holes: [FaceHole],
        to writer: inout MeshWriter
    ) -> SameFaceTriangulationStats {
        var stats = SameFaceTriangulationStats()
        let tolerance = max(CADCutGeometry.epsilon * 10.0, 1e-6)
        var yLevels = [face.bounds.minV, face.bounds.maxV]
        for hole in holes {
            yLevels += hole.profile.map(\.v)
        }
        yLevels = uniqueSortedValues(yLevels, tolerance: tolerance)
            .filter { $0 >= face.bounds.minV - tolerance && $0 <= face.bounds.maxV + tolerance }
        guard yLevels.count >= 2 else {
            stats.passed = false
            return stats
        }

        for index in 0..<(yLevels.count - 1) {
            let bottom = max(yLevels[index], face.bounds.minV)
            let top = min(yLevels[index + 1], face.bounds.maxV)
            guard top - bottom > tolerance else { continue }

            var intervals: [HoleStripInterval] = []
            for hole in holes {
                guard let holeIntervals = stripIntervals(
                    for: hole,
                    bottom: bottom,
                    top: top,
                    tolerance: tolerance
                ) else {
                    stats.passed = false
                    return stats
                }
                intervals += holeIntervals
            }
            intervals.sort { $0.leftMid < $1.leftMid }
            for pairIndex in 0..<(max(intervals.count - 1, 0)) {
                if intervals[pairIndex].rightMid + tolerance >= intervals[pairIndex + 1].leftMid {
                    stats.trianglesCrossingBetweenHoles += 1
                    stats.passed = false
                    return stats
                }
            }

            var currentBottom = face.bounds.minU
            var currentTop = face.bounds.minU
            for interval in intervals {
                appendSweepGap(
                    face,
                    bottom: bottom,
                    top: top,
                    leftBottom: currentBottom,
                    rightBottom: interval.leftBottom,
                    leftTop: currentTop,
                    rightTop: interval.leftTop,
                    holes: holes,
                    to: &writer,
                    stats: &stats
                )
                currentBottom = interval.rightBottom
                currentTop = interval.rightTop
            }
            appendSweepGap(
                face,
                bottom: bottom,
                top: top,
                leftBottom: currentBottom,
                rightBottom: face.bounds.maxU,
                leftTop: currentTop,
                rightTop: face.bounds.maxU,
                holes: holes,
                to: &writer,
                stats: &stats
            )
            guard stats.passed else { return stats }
        }

        return stats
    }

    private static func stripIntervals(
        for hole: FaceHole,
        bottom: Double,
        top: Double,
        tolerance: Double
    ) -> [HoleStripInterval]? {
        let mid = (bottom + top) * 0.5
        let loop = hole.profile
        guard loop.count >= 3 else { return nil }

        var intersections: [(bottom: Double, top: Double, mid: Double)] = []
        for index in loop.indices {
            let a = loop[index]
            let b = loop[(index + 1) % loop.count]
            let minV = min(a.v, b.v)
            let maxV = max(a.v, b.v)
            guard maxV - minV > tolerance,
                  minV < mid,
                  maxV > mid else {
                continue
            }
            intersections.append((
                bottom: xOnSegment(a, b, atY: bottom),
                top: xOnSegment(a, b, atY: top),
                mid: xOnSegment(a, b, atY: mid)
            ))
        }

        guard !intersections.isEmpty else { return [] }
        guard intersections.count.isMultiple(of: 2) else { return nil }
        intersections.sort { $0.mid < $1.mid }

        var intervals: [HoleStripInterval] = []
        for index in stride(from: 0, to: intersections.count, by: 2) {
            let left = intersections[index]
            let right = intersections[index + 1]
            guard right.mid >= left.mid - tolerance else { return nil }
            intervals.append(HoleStripInterval(
                leftBottom: min(left.bottom, right.bottom),
                rightBottom: max(left.bottom, right.bottom),
                leftTop: min(left.top, right.top),
                rightTop: max(left.top, right.top),
                leftMid: left.mid,
                rightMid: right.mid
            ))
        }
        return intervals
    }

    private static func xOnSegment(
        _ a: SketchPoint2D,
        _ b: SketchPoint2D,
        atY y: Double
    ) -> Double {
        let denominator = b.v - a.v
        guard abs(denominator) > 1e-12 else { return a.u }
        let t = min(max((y - a.v) / denominator, 0.0), 1.0)
        return a.u + (b.u - a.u) * t
    }

    private static func appendSweepGap(
        _ face: DesignPlanarFace,
        bottom: Double,
        top: Double,
        leftBottom: Double,
        rightBottom: Double,
        leftTop: Double,
        rightTop: Double,
        holes: [FaceHole],
        to writer: inout MeshWriter,
        stats: inout SameFaceTriangulationStats
    ) {
        let midWidth = ((rightBottom + rightTop) - (leftBottom + leftTop)) * 0.5
        guard midWidth > max(CADCutGeometry.epsilon * 10.0, 1e-6) else { return }

        let p0 = SketchPoint2D(u: leftBottom, v: bottom)
        let p1 = SketchPoint2D(u: rightBottom, v: bottom)
        let p2 = SketchPoint2D(u: rightTop, v: top)
        let p3 = SketchPoint2D(u: leftTop, v: top)
        appendSweepTriangle(p0, p1, p2, face: face, holes: holes, to: &writer, stats: &stats)
        appendSweepTriangle(p0, p2, p3, face: face, holes: holes, to: &writer, stats: &stats)
    }

    private static func appendSweepTriangle(
        _ a: SketchPoint2D,
        _ b: SketchPoint2D,
        _ c: SketchPoint2D,
        face: DesignPlanarFace,
        holes: [FaceHole],
        to writer: inout MeshWriter,
        stats: inout SameFaceTriangulationStats
    ) {
        let area = abs((b.u - a.u) * (c.v - a.v) - (b.v - a.v) * (c.u - a.u)) * 0.5
        guard area > 1e-12 else { return }
        let tolerance = max(CADCutGeometry.epsilon * 10.0, 1e-6)
        guard pointIsInsideFaceBounds(a, face: face, tolerance: tolerance),
              pointIsInsideFaceBounds(b, face: face, tolerance: tolerance),
              pointIsInsideFaceBounds(c, face: face, tolerance: tolerance) else {
            stats.trianglesOutsideFace += 1
            stats.passed = false
            return
        }

        let centroid = SketchPoint2D(
            u: (a.u + b.u + c.u) / 3.0,
            v: (a.v + b.v + c.v) / 3.0
        )
        if holes.contains(where: { pointIsStrictlyInsideHole(centroid, profile: $0.profile, profileType: $0.profileType) }) {
            stats.trianglesInsideAnyHole += 1
            stats.passed = false
            return
        }

        writer.appendTriangle(
            CADCutGeometry.worldPoint(on: face, local: a),
            CADCutGeometry.worldPoint(on: face, local: b),
            CADCutGeometry.worldPoint(on: face, local: c),
            desiredNormal: face.normal
        )
    }

    private static func pointIsInsideFaceBounds(
        _ point: SketchPoint2D,
        face: DesignPlanarFace,
        tolerance: Double
    ) -> Bool {
        point.u >= face.bounds.minU - tolerance
            && point.u <= face.bounds.maxU + tolerance
            && point.v >= face.bounds.minV - tolerance
            && point.v <= face.bounds.maxV + tolerance
    }

    private static func uniqueSortedValues(
        _ values: [Double],
        tolerance: Double
    ) -> [Double] {
        values
            .filter(\.isFinite)
            .sorted()
            .reduce(into: [Double]()) { result, value in
                guard let last = result.last else {
                    result.append(value)
                    return
                }
                if abs(value - last) > tolerance {
                    result.append(value)
                }
            }
    }

    private static func appendSingleHoleFace(
        _ face: DesignPlanarFace,
        hole: FaceHole,
        to writer: inout MeshWriter
    ) -> Bool {
        switch hole.profileType {
        case .rectangle:
            appendRectFaceWithRectHole(face, hole: hole.profile, to: &writer)
            return true
        case .circle:
            appendRectFaceWithCircleHole(face, profile: hole.profile, to: &writer)
            return true
        case .polygon, .unsupported:
            return false
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
        profile: [SketchPoint2D],
        to writer: inout MeshWriter
    ) {
        guard let circle = CADCutGeometry.circleMetrics(
            points: profile,
            explicitCenter: CADCutGeometry.profileCenter(profile),
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
        let bottomLoop = cut.farWorldLoop
        let entryWorldLoop = entryLoop.map {
            CADCutGeometry.worldPoint(on: entryFace, local: $0)
        }

        switch cut.feature.profileType {
        case .rectangle, .circle, .polygon:
            appendLoopWalls(
                entry: entryWorldLoop,
                far: bottomLoop,
                profile: entryLoop,
                entryFace: entryFace,
                fallbackCenter: cutCenter(cut),
                to: &writer
            )
            if cut.feature.depthMode == .distance {
                appendPolygonCap(
                    profile: cut.feature.profilePoints,
                    worldLoop: bottomLoop,
                    normal: cut.direction * -1,
                    to: &writer
                )
                counters.capFacesGenerated += max(bottomLoop.count - 2, 0)
            }
        case .unsupported:
            break
        }
    }

    private static func cutCenter(_ cut: ResolvedCut) -> DesignVector3 {
        let entryWorldLoop = cut.feature.profilePoints.map {
            CADCutGeometry.worldPoint(on: cut.entryFace, local: $0)
        }
        let allPoints = entryWorldLoop + cut.farWorldLoop
        guard !allPoints.isEmpty else { return cut.entryFace.center + cut.direction * (cut.depthMeters * 0.5) }
        return allPoints.reduce(DesignVector3.zero, +) * (1.0 / Double(allPoints.count))
    }

    private static func appendLoopWalls(
        entry: [DesignVector3],
        far: [DesignVector3],
        profile: [SketchPoint2D],
        entryFace: DesignPlanarFace,
        fallbackCenter center: DesignVector3,
        to writer: inout MeshWriter
    ) {
        guard entry.count == far.count,
              entry.count == profile.count,
              entry.count >= 3 else { return }
        let windingSign = DesignSketch.polygonSignedAreaMeters2(profile) >= 0 ? 1.0 : -1.0
        let uAxis = entryFace.uAxis.normalized(fallback: .xAxis)
        let vAxis = entryFace.vAxis.normalized(fallback: .yAxis)
        for index in entry.indices {
            let next = (index + 1) % entry.count
            let edgeU = profile[next].u - profile[index].u
            let edgeV = profile[next].v - profile[index].v
            let mid = (entry[index] + entry[next] + far[index] + far[next]) * 0.25
            let localInteriorNormal = (uAxis * (-edgeV) + vAxis * edgeU) * windingSign
            let normal = localInteriorNormal.normalized(fallback: (center - mid).normalized(fallback: .zAxis))
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
        profile: [SketchPoint2D],
        worldLoop points: [DesignVector3],
        normal: DesignVector3,
        to writer: inout MeshWriter
    ) {
        guard points.count == profile.count,
              points.count >= 3 else {
            return
        }
        let triangles = earClipTriangulate(profile)
        guard !triangles.isEmpty else { return }
        for triangle in triangles {
            writer.appendTriangle(
                points[triangle.a],
                points[triangle.b],
                points[triangle.c],
                desiredNormal: normal
            )
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

    private static func countFaceHoleViolations(
        in mesh: CADSolidMeshSnapshot,
        cuts: [ResolvedCut],
        counters: inout RebuildCounters
    ) {
        for cut in cuts {
            for triangle in mesh.triangles {
                if let entry = triangleHoleTest(
                    triangle,
                    mesh: mesh,
                    face: cut.entryFace,
                    profile: cut.feature.profilePoints,
                    profileType: cut.feature.profileType
                ) {
                    if entry.centroidInsideHole {
                        counters.trianglesInsideAnyHole += 1
                    }
                    if entry.centroidInsideHole {
                        counters.trianglesInsideEntryHole += 1
                        if cut.isUnionResult {
                            counters.trianglesInsideMergedHole += 1
                        }
                    }
                    if cut.feature.depthMode == .throughAll, entry.suspectedPlug {
                        counters.suspectedOrphanPlugTriangles += 1
                    }
                }

                guard cut.feature.depthMode == .throughAll,
                      let exitFace = cut.exitFace,
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
                    counters.trianglesInsideAnyHole += 1
                    counters.trianglesInsideExitHole += 1
                    if cut.isUnionResult {
                        counters.trianglesInsideMergedHole += 1
                    }
                }
                if exit.suspectedPlug {
                    counters.suspectedOrphanPlugTriangles += 1
                }
            }
        }
    }

    private static func validateGeneratedSurfaces(
        in mesh: CADSolidMeshSnapshot,
        cuts: [ResolvedCut],
        bodyFaces: [DesignPlanarFace]
    ) -> SurfaceValidationResult {
        var result = SurfaceValidationResult()
        let tolerance = max(CADCutGeometry.epsilon * 10.0, 1e-5)

        for triangle in mesh.triangles {
            guard let vertices = triangleVertices(triangle, mesh: mesh),
                  vertices.allSatisfy(\.isFinite),
                  triangleArea(vertices) > 1e-12 else {
                result.orphanTriangleCount += 1
                continue
            }

            if let face = bodyFaces.first(where: { triangleIsCoplanar(vertices, with: $0, tolerance: tolerance) }) {
                validateFaceTriangle(
                    triangle,
                    mesh: mesh,
                    face: face,
                    cuts: cuts,
                    result: &result
                )
                continue
            }

            if cuts.contains(where: { triangleMatchesInternalWall(vertices, for: $0, tolerance: tolerance) }) {
                continue
            }

            if cuts.contains(where: { triangleMatchesBlindCap(vertices, for: $0, tolerance: tolerance) }) {
                continue
            }

            if triangleTouchesMultipleBodyPlanes(vertices, faces: bodyFaces, tolerance: tolerance) {
                result.nonCoplanarFaceTriangleCount += 1
            }
            result.orphanTriangleCount += 1
        }

        return result
    }

    private static func validateFaceTriangle(
        _ triangle: CADSolidTriangle,
        mesh: CADSolidMeshSnapshot,
        face: DesignPlanarFace,
        cuts: [ResolvedCut],
        result: inout SurfaceValidationResult
    ) {
        if let vertices = triangleVertices(triangle, mesh: mesh) {
            let tolerance = max(CADCutGeometry.epsilon * 10.0, 1e-5)
            let local = vertices.map { CADCutGeometry.localPoint(on: face, world: $0) }
            if local.contains(where: { !pointIsInsideFaceBounds($0, face: face, tolerance: tolerance) }) {
                result.trianglesOutsideFace += 1
            }
        }

        for cut in cuts where cut.entryFace.id == face.id {
            guard let test = triangleHoleTest(
                triangle,
                mesh: mesh,
                face: face,
                profile: cut.feature.profilePoints,
                profileType: cut.feature.profileType
            ) else {
                continue
            }
            if test.suspectedPlug {
                result.oldFullEntryFaceKept = true
                result.orphanTriangleCount += 1
            }
        }

        for cut in cuts where cut.exitFace?.id == face.id {
            guard let exitProfile = cut.exitProfile,
                  let test = triangleHoleTest(
                    triangle,
                    mesh: mesh,
                    face: face,
                    profile: exitProfile,
                    profileType: cut.feature.profileType
                  ) else {
                continue
            }
            if test.suspectedPlug {
                result.oldFullExitFaceKept = true
                result.orphanTriangleCount += 1
            }
        }
    }

    private static func triangleVertices(
        _ triangle: CADSolidTriangle,
        mesh: CADSolidMeshSnapshot
    ) -> [DesignVector3]? {
        guard triangle.a >= 0, triangle.a < mesh.vertices.count,
              triangle.b >= 0, triangle.b < mesh.vertices.count,
              triangle.c >= 0, triangle.c < mesh.vertices.count else {
            return nil
        }
        return [
            mesh.vertices[triangle.a],
            mesh.vertices[triangle.b],
            mesh.vertices[triangle.c],
        ]
    }

    private static func triangleArea(_ vertices: [DesignVector3]) -> Double {
        guard vertices.count == 3 else { return 0 }
        return (vertices[1] - vertices[0]).cross(vertices[2] - vertices[0]).length * 0.5
    }

    private static func triangleIsCoplanar(
        _ vertices: [DesignVector3],
        with face: DesignPlanarFace,
        tolerance: Double
    ) -> Bool {
        let normal = face.normal.normalized(fallback: .zAxis)
        return vertices.allSatisfy { abs(($0 - face.center).dot(normal)) <= tolerance }
    }

    private static func triangleTouchesMultipleBodyPlanes(
        _ vertices: [DesignVector3],
        faces: [DesignPlanarFace],
        tolerance: Double
    ) -> Bool {
        let memberships = vertices.map { vertex in
            Set(faces.compactMap { face -> UUID? in
                let normal = face.normal.normalized(fallback: .zAxis)
                return abs((vertex - face.center).dot(normal)) <= tolerance ? face.id : nil
            })
        }
        let union = memberships.reduce(into: Set<UUID>()) { partial, entry in
            partial.formUnion(entry)
        }
        guard union.count > 1 else { return false }
        return faces.first(where: { face in
            memberships.allSatisfy { $0.contains(face.id) }
        }) == nil
    }

    private static func triangleMatchesInternalWall(
        _ vertices: [DesignVector3],
        for cut: ResolvedCut,
        tolerance: Double
    ) -> Bool {
        guard vertices.count == 3 else { return false }
        let direction = cut.direction.normalized(fallback: cut.entryFace.normal * -1)
        return vertices.allSatisfy { vertex in
            let delta = vertex - cut.entryFace.origin
            let distance = delta.dot(direction)
            guard distance >= -tolerance,
                  distance <= cut.depthMeters + tolerance else {
                return false
            }
            let local = CADCutGeometry.localPoint(on: cut.entryFace, world: vertex - direction * distance)
            return pointIsOnProfileBoundary(
                local,
                profile: cut.feature.profilePoints,
                profileType: cut.feature.profileType,
                tolerance: tolerance
            )
        }
    }

    private static func triangleMatchesBlindCap(
        _ vertices: [DesignVector3],
        for cut: ResolvedCut,
        tolerance: Double
    ) -> Bool {
        guard cut.feature.depthMode == .distance,
              vertices.count == 3 else {
            return false
        }
        let direction = cut.direction.normalized(fallback: cut.entryFace.normal * -1)
        let allOnCapPlane = vertices.allSatisfy { vertex in
            abs((vertex - cut.entryFace.origin).dot(direction) - cut.depthMeters) <= tolerance
        }
        guard allOnCapPlane else { return false }
        let centroid = (vertices[0] + vertices[1] + vertices[2]) * (1.0 / 3.0)
        let projectedCentroid = CADCutGeometry.localPoint(
            on: cut.entryFace,
            world: centroid - direction * cut.depthMeters
        )
        return pointIsInsideOrOnHole(
            projectedCentroid,
            profile: cut.feature.profilePoints,
            profileType: cut.feature.profileType,
            tolerance: tolerance
        )
    }

    private static func pointIsOnProfileBoundary(
        _ point: SketchPoint2D,
        profile: [SketchPoint2D],
        profileType: CADCutV2ProfileType,
        tolerance: Double
    ) -> Bool {
        switch profileType {
        case .rectangle:
            guard let bounds = CADCutGeometry.profileBounds(profile) else { return false }
            let withinU = point.u >= bounds.minU - tolerance && point.u <= bounds.maxU + tolerance
            let withinV = point.v >= bounds.minV - tolerance && point.v <= bounds.maxV + tolerance
            let onU = abs(point.u - bounds.minU) <= tolerance || abs(point.u - bounds.maxU) <= tolerance
            let onV = abs(point.v - bounds.minV) <= tolerance || abs(point.v - bounds.maxV) <= tolerance
            return withinU && withinV && (onU || onV)
        case .circle:
            guard let circle = CADCutGeometry.circleMetrics(
                points: profile,
                explicitCenter: CADCutGeometry.profileCenter(profile),
                explicitRadius: nil
            ) else {
                return false
            }
            return abs(point.distance(to: circle.center) - circle.radius) <= max(tolerance, circle.radius * 0.01)
        case .polygon:
            return profile.indices.contains { index in
                let next = (index + 1) % profile.count
                return point.distance(to: closestPointOnSegment(
                    from: point,
                    segA: profile[index],
                    segB: profile[next]
                )) <= tolerance
            }
        case .unsupported:
            return false
        }
    }

    private static func pointIsInsideOrOnHole(
        _ point: SketchPoint2D,
        profile: [SketchPoint2D],
        profileType: CADCutV2ProfileType,
        tolerance: Double
    ) -> Bool {
        if pointIsStrictlyInsideHole(point, profile: profile, profileType: profileType) {
            return true
        }
        return pointIsOnProfileBoundary(point, profile: profile, profileType: profileType, tolerance: tolerance)
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
        case .polygon:
            guard !pointIsOnProfileBoundary(
                point,
                profile: profile,
                profileType: profileType,
                tolerance: CADCutGeometry.epsilon
            ) else {
                return false
            }
            return pointInPolygon(point, polygon: profile)
        case .unsupported:
            return false
        }
    }

    private static func pointInPolygon(_ point: SketchPoint2D, polygon: [SketchPoint2D]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let pi = polygon[i]
            let pj = polygon[j]
            if (pi.v > point.v) != (pj.v > point.v) {
                let x = (pj.u - pi.u) * (point.v - pi.v) / (pj.v - pi.v) + pi.u
                if point.u < x { inside.toggle() }
            }
            j = i
        }
        return inside
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

    private static func earClipTriangulate(_ points: [SketchPoint2D]) -> [CADSolidTriangle] {
        guard points.count >= 3 else { return [] }
        var indices = DesignSketch.polygonSignedAreaMeters2(points) >= 0
            ? Array(points.indices)
            : Array(points.indices.reversed())
        var triangles: [CADSolidTriangle] = []
        var guardCount = 0

        while indices.count > 3, guardCount < points.count * points.count {
            guardCount += 1
            var clipped = false
            for localIndex in indices.indices {
                let prev = indices[(localIndex + indices.count - 1) % indices.count]
                let current = indices[localIndex]
                let next = indices[(localIndex + 1) % indices.count]
                guard isConvex(points[prev], points[current], points[next]) else { continue }
                let containsPoint = indices.contains { candidate in
                    candidate != prev && candidate != current && candidate != next
                        && pointInTriangle(points[candidate], points[prev], points[current], points[next])
                }
                guard !containsPoint else { continue }
                triangles.append(CADSolidTriangle(a: prev, b: current, c: next))
                indices.remove(at: localIndex)
                clipped = true
                break
            }
            if !clipped { break }
        }

        if indices.count == 3 {
            triangles.append(CADSolidTriangle(a: indices[0], b: indices[1], c: indices[2]))
        }
        return triangles
    }

    private static func isConvex(_ a: SketchPoint2D, _ b: SketchPoint2D, _ c: SketchPoint2D) -> Bool {
        ((b.u - a.u) * (c.v - a.v) - (b.v - a.v) * (c.u - a.u)) > 1e-14
    }

    private static func logRebuildDiagnostics(_ diagnostics: CADCutMeshRebuildDiagnostics) {
        print(
            "CAD Cut V1 Mesh Rebuild: " +
            "throughAll=\(diagnostics.throughAll) " +
            "totalCuts=\(diagnostics.totalCutCount) " +
            "totalCutCount=\(diagnostics.totalCutCount) " +
            "affectedFaceCount=\(diagnostics.affectedFaceCount) " +
            "cutsGroupedByFace=\(diagnostics.cutsGroupedByFace.joined(separator: ",")) " +
            "depthMode=\(diagnostics.depthMode?.rawValue ?? "nil") " +
            "entryFaceID=\(diagnostics.entryFaceID?.uuidString ?? "nil") " +
            "exitFaceID=\(diagnostics.exitFaceID?.uuidString ?? "nil") " +
            "affectedFaceID=\(diagnostics.affectedFaceID?.uuidString ?? "nil") " +
            "entryLoopVertexCount=\(diagnostics.entryLoopVertexCount) " +
            "exitLoopVertexCount=\(diagnostics.exitLoopVertexCount) " +
            "holeCountOnFace=\(diagnostics.holeCountOnFace) " +
            "holeTypesOnFace=\(diagnostics.holeTypesOnFace.joined(separator: ",")) " +
            "sameFaceTriangulationPassed=\(diagnostics.sameFaceTriangulationPassed) " +
            "holeIntersectionDetected=\(diagnostics.holeIntersectionDetected) " +
            "holeTouchDetected=\(diagnostics.holeTouchDetected) " +
            "cutVolumeIntersectionDetected=\(diagnostics.cutVolumeIntersectionDetected) " +
            "unsupportedIntersectingCutDetected=\(diagnostics.unsupportedIntersectingCutDetected) " +
            "sameFaceOverlapGroupCount=\(diagnostics.sameFaceOverlapGroupCount) " +
            "mergedProfileLoopCount=\(diagnostics.mergedProfileLoopCount) " +
            "unionFailureCount=\(diagnostics.unionFailureCount) " +
            "trianglesInsideMergedHole=\(diagnostics.trianglesInsideMergedHole) " +
            "crossFaceIntersectionBlocked=\(diagnostics.crossFaceIntersectionBlocked) " +
            "entryFaceRebuiltWithHole=\(diagnostics.entryFaceRebuiltWithHole) " +
            "exitFaceRebuiltWithHole=\(diagnostics.exitFaceRebuiltWithHole) " +
            "capFacesGenerated=\(diagnostics.capFacesGenerated) " +
            "orphanTriangleCount=\(diagnostics.orphanTriangleCount) " +
            "nonCoplanarFaceTriangleCount=\(diagnostics.nonCoplanarFaceTriangleCount) " +
            "trianglesCrossingBetweenHoles=\(diagnostics.trianglesCrossingBetweenHoles) " +
            "trianglesOutsideFace=\(diagnostics.trianglesOutsideFace) " +
            "trianglesInsideEntryHole=\(diagnostics.trianglesInsideEntryHole) " +
            "trianglesInsideExitHole=\(diagnostics.trianglesInsideExitHole) " +
            "trianglesInsideAnyHole=\(diagnostics.trianglesInsideAnyHole) " +
            "oldFullFaceRetained=\(diagnostics.oldFullFaceRetained) " +
            "oldFullEntryFaceKept=\(diagnostics.oldFullEntryFaceKept) " +
            "oldFullExitFaceKept=\(diagnostics.oldFullExitFaceKept) " +
            "suspectedOrphanPlugTriangles=\(diagnostics.suspectedOrphanPlugTriangles) " +
            "reversedNormalTriangles=\(diagnostics.reversedNormalTriangles) " +
            "committedCutsCount=\(diagnostics.committedCutsCount) " +
            "candidateCutID=\(diagnostics.candidateCutID?.uuidString ?? "nil") " +
            "affectedEntryFaceID=\(diagnostics.affectedEntryFaceID?.uuidString ?? "nil") " +
            "affectedExitFaceID=\(diagnostics.affectedExitFaceID?.uuidString ?? "nil") " +
            "cutsOnEntryFace=\(diagnostics.cutsOnEntryFace) " +
            "cutsOnExitFace=\(diagnostics.cutsOnExitFace) " +
            "multiCutValidation=\(diagnostics.multiCutValidationPassed ? "passed" : "blocked") " +
            "multiCutValidationReason=\(diagnostics.multiCutValidationReason ?? "none") " +
            "transientPreviewNodeCount=\(diagnostics.transientPreviewNodeCount)"
        )
    }
}
