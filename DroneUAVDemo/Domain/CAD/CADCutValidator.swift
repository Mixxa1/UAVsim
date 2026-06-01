import Foundation

enum CADCutValidator {
    static func validate(
        _ request: CADCutRequest,
        checkMesh: Bool = true,
        candidateFeature: ExtrudedSolidBoxBlindCutFeature? = nil
    ) -> CADFeatureValidation {
        let body = request.targetBodyGeometry
        guard request.targetBodyID == request.entryFace.assetID else { return .noCutTarget }
        guard body.holes.isEmpty,
              body.cutFeatures.isEmpty,
              isSupportedBoxLikeBody(body),
              !body.faces.isEmpty else {
            return .targetBodyNotSolid
        }
        guard request.entryFaceNormal.isFinite,
              request.entryFaceOrigin.isFinite,
              request.entryFaceCenter.isFinite,
              request.entryFaceUAxis.isFinite,
              request.entryFaceVAxis.isFinite,
              request.cutDirectionWorld.isFinite else {
            return .invalidSketchPlaneFrame
        }
        guard request.profileType == .rectangle || request.profileType == .circle else {
            return .unsupportedProfileForCutV2
        }
        guard request.depthMode == .distance || request.depthMode == .throughAll else {
            return .unsupportedDepthMode(request.depthMode)
        }
        guard request.depthMode == .throughAll || request.depthMeters > CADCutGeometry.epsilon else {
            return .invalidDepth
        }
        guard isValidProfile(request) else { return .invalidProfileLoop }
        guard profileIsInsideEntryFace(request) else { return .profileOutsideFace }
        guard let thickness = CADCutGeometry.bodyThickness(
            entryFaceCenter: request.entryFaceCenter,
            bodyWorldVertices: body.vertices(),
            direction: request.cutDirectionWorld
        ) else {
            return .cutToolDoesNotIntersectBody
        }
        if request.depthMode == .distance,
           request.depthMeters >= thickness - CADCutGeometry.epsilon {
            return .invalidDepth
        }
        let newCut = candidateFeature ?? request.feature()
        let multiCutValidation = CADMultiCutValidator.validate(
            baseBody: body,
            existingCuts: body.stableCutFeatures,
            newCut: newCut
        )
        guard multiCutValidation.isValid else { return multiCutValidation.validation }
        guard checkMesh else { return .valid }

        var resultBody = body
        resultBody.stableCutFeatures = multiCutValidation.candidateCuts
        resultBody.kernelVisualMesh = nil
        resultBody.kernelResultSolid = nil
        guard let build = CADCutMeshRebuilder.rebuildBodyMesh(
            bodyID: request.targetBodyID,
            bodyParams: resultBody
        ), !build.mesh.vertices.isEmpty, !build.mesh.triangles.isEmpty else {
            return .generatedMeshEmpty
        }
        return .valid
    }

    private static func isSupportedBoxLikeBody(_ body: ExtrudedSolidParameters) -> Bool {
        guard body.depthMeters.isFinite,
              body.depthMeters > CADCutGeometry.epsilon,
              body.profilePoints.count == 4,
              body.areaMeters2 > 1e-8,
              body.vertices().allSatisfy(\.isFinite) else {
            return false
        }
        guard let bounds = CADCutGeometry.profileBounds(body.profilePoints) else { return false }
        let boundsArea = max(bounds.maxU - bounds.minU, 0) * max(bounds.maxV - bounds.minV, 0)
        return abs(boundsArea - body.areaMeters2) <= max(body.areaMeters2, 1.0) * 1e-5
    }

    private static func isValidProfile(_ request: CADCutRequest) -> Bool {
        switch request.profileType {
        case .rectangle:
            guard request.profilePoints.count == 4,
                  let bounds = CADCutGeometry.profileBounds(request.profilePoints) else {
                return false
            }
            let width = bounds.maxU - bounds.minU
            let height = bounds.maxV - bounds.minV
            let area = abs(DesignSketch.polygonSignedAreaMeters2(request.profilePoints))
            return width > 0.0005
                && height > 0.0005
                && area > 1e-8
                && abs(width * height - area) <= max(area, 1.0) * 1e-5
        case .circle:
            guard request.profilePoints.count >= 48,
                  let circle = CADCutGeometry.circleMetrics(
                      points: request.profilePoints,
                      explicitCenter: request.profileCenter,
                      explicitRadius: request.profileRadius
                  ) else {
                return false
            }
            return circle.radius > 0.0005
        case .polygon, .unsupported:
            return false
        }
    }

    private static func profileIsInsideEntryFace(_ request: CADCutRequest) -> Bool {
        let b = request.entryFaceBounds
        let tolerance = CADCutGeometry.epsilon
        switch request.profileType {
        case .rectangle:
            guard let bounds = CADCutGeometry.profileBounds(request.profilePoints) else { return false }
            return bounds.minU > b.minU + tolerance
                && bounds.maxU < b.maxU - tolerance
                && bounds.minV > b.minV + tolerance
                && bounds.maxV < b.maxV - tolerance
        case .circle:
            guard let circle = CADCutGeometry.circleMetrics(
                points: request.profilePoints,
                explicitCenter: request.profileCenter,
                explicitRadius: request.profileRadius
            ) else {
                return false
            }
            return circle.center.u - circle.radius > b.minU + tolerance
                && circle.center.u + circle.radius < b.maxU - tolerance
                && circle.center.v - circle.radius > b.minV + tolerance
                && circle.center.v + circle.radius < b.maxV - tolerance
        case .polygon, .unsupported:
            return false
        }
    }
}

struct CADMultiCutValidationResult: Equatable {
    var validation: CADFeatureValidation
    var candidateCuts: [ExtrudedSolidBoxBlindCutFeature]
    var candidateCutID: UUID
    var affectedEntryFaceID: UUID
    var affectedExitFaceID: UUID?
    var cutsOnEntryFace: Int
    var cutsOnExitFace: Int
    var committedCutsCount: Int
    var reason: String?

    var isValid: Bool { validation.isValid }
}

enum CADMultiCutValidator {
    static let intersectingCutUnsupportedReason = "cad.cut_v2.reason.intersecting_cut_unsupported"

    private struct SurfaceCut {
        var cutID: UUID
        var faceID: UUID
        var profileType: CADCutV2ProfileType
        var profilePoints: [SketchPoint2D]
        var isExit: Bool
    }

    private typealias ProfileBounds = (minU: Double, maxU: Double, minV: Double, maxV: Double)

    static func validate(
        baseBody: ExtrudedSolidParameters,
        existingCuts: [ExtrudedSolidBoxBlindCutFeature],
        newCut: ExtrudedSolidBoxBlindCutFeature
    ) -> CADMultiCutValidationResult {
        let candidateCuts = existingCuts + [newCut]

        func result(
            _ validation: CADFeatureValidation,
            reason: String? = nil,
            existingSurfaces: [SurfaceCut] = [],
            newSurfaces: [SurfaceCut] = []
        ) -> CADMultiCutValidationResult {
            let exitFaceID = newSurfaces.first(where: { $0.isExit })?.faceID
            let cutsOnEntryFace = existingSurfaces.filter { $0.faceID == newCut.entryFaceID }.count + 1
            let cutsOnExitFace = exitFaceID.map { id in
                existingSurfaces.filter { $0.faceID == id }.count + 1
            } ?? 0
            return CADMultiCutValidationResult(
                validation: validation,
                candidateCuts: candidateCuts,
                candidateCutID: newCut.id,
                affectedEntryFaceID: newCut.entryFaceID,
                affectedExitFaceID: exitFaceID,
                cutsOnEntryFace: cutsOnEntryFace,
                cutsOnExitFace: cutsOnExitFace,
                committedCutsCount: validation.isValid ? candidateCuts.count : existingCuts.count,
                reason: reason ?? validation.messageKey
            )
        }

        guard baseBody.holes.isEmpty,
              baseBody.cutFeatures.isEmpty,
              isSupportedBoxLikeBody(baseBody),
              !baseBody.faces.isEmpty else {
            return result(.targetBodyNotSolid)
        }
        guard newCut.profileType == .rectangle || newCut.profileType == .circle else {
            return result(.unsupportedProfileForCutV2)
        }
        guard newCut.depthMode == .distance || newCut.depthMode == .throughAll else {
            return result(.unsupportedDepthMode(newCut.depthMode))
        }
        guard isValidProfile(newCut) else {
            return result(.invalidProfileLoop)
        }
        guard let entryFace = baseBody.faces.first(where: { $0.id == newCut.entryFaceID }) else {
            return result(.sketchNotOnFace)
        }
        guard profileIsInsideFace(newCut, face: entryFace) else {
            return result(.profileOutsideFace)
        }
        guard let newDepth = resolvedDepth(for: newCut, entryFace: entryFace, body: baseBody) else {
            return result(.cutToolDoesNotIntersectBody)
        }
        if newCut.depthMode == .distance,
           newDepth >= bodyThickness(for: newCut, entryFace: entryFace, body: baseBody) - CADCutGeometry.epsilon {
            return result(.invalidDepth)
        }

        var existingSurfaces: [SurfaceCut] = []
        for cut in existingCuts {
            guard let surfaces = surfaceCuts(for: cut, body: baseBody) else {
                return result(
                    .cutIntersectsExistingVoidUnsupported,
                    reason: intersectingCutUnsupportedReason,
                    existingSurfaces: existingSurfaces
                )
            }
            existingSurfaces += surfaces
        }
        guard let newSurfaces = surfaceCuts(for: newCut, body: baseBody) else {
            return result(
                .cutIntersectsExistingVoidUnsupported,
                reason: intersectingCutUnsupportedReason,
                existingSurfaces: existingSurfaces
            )
        }

        for newSurface in newSurfaces {
            for existingSurface in existingSurfaces where existingSurface.faceID == newSurface.faceID {
                guard !profilesOverlapOrTouch(newSurface, existingSurface) else {
                    return result(
                        .cutIntersectsExistingVoidUnsupported,
                        reason: intersectingCutUnsupportedReason,
                        existingSurfaces: existingSurfaces,
                        newSurfaces: newSurfaces
                    )
                }
            }
        }

        guard let newBounds = CADCutGeometry.cutterBounds(
            entryFace: entryFace,
            profilePoints: newCut.profilePoints,
            direction: newCut.cutDirection,
            depthMeters: newDepth
        ) else {
            return result(
                .cutIntersectsExistingVoidUnsupported,
                reason: intersectingCutUnsupportedReason,
                existingSurfaces: existingSurfaces,
                newSurfaces: newSurfaces
            )
        }

        for existingCut in existingCuts {
            guard let existingEntryFace = baseBody.faces.first(where: { $0.id == existingCut.entryFaceID }),
                  let existingDepth = resolvedDepth(for: existingCut, entryFace: existingEntryFace, body: baseBody),
                  let existingBounds = CADCutGeometry.cutterBounds(
                    entryFace: existingEntryFace,
                    profilePoints: existingCut.profilePoints,
                    direction: existingCut.cutDirection,
                    depthMeters: existingDepth
                  ) else {
                return result(
                    .cutIntersectsExistingVoidUnsupported,
                    reason: intersectingCutUnsupportedReason,
                    existingSurfaces: existingSurfaces,
                    newSurfaces: newSurfaces
                )
            }
            if newBounds.intersects(existingBounds, tolerance: CADCutGeometry.epsilon) {
                return result(
                    .cutIntersectsExistingVoidUnsupported,
                    reason: intersectingCutUnsupportedReason,
                    existingSurfaces: existingSurfaces,
                    newSurfaces: newSurfaces
                )
            }
        }

        return result(
            .valid,
            existingSurfaces: existingSurfaces,
            newSurfaces: newSurfaces
        )
    }

    private static func isSupportedBoxLikeBody(_ body: ExtrudedSolidParameters) -> Bool {
        guard body.depthMeters.isFinite,
              body.depthMeters > CADCutGeometry.epsilon,
              body.profilePoints.count == 4,
              body.areaMeters2 > 1e-8,
              body.vertices().allSatisfy(\.isFinite),
              let bounds = CADCutGeometry.profileBounds(body.profilePoints) else {
            return false
        }
        let boundsArea = max(bounds.maxU - bounds.minU, 0) * max(bounds.maxV - bounds.minV, 0)
        return abs(boundsArea - body.areaMeters2) <= max(body.areaMeters2, 1.0) * 1e-5
    }

    private static func isValidProfile(_ cut: ExtrudedSolidBoxBlindCutFeature) -> Bool {
        switch cut.profileType {
        case .rectangle:
            guard cut.profilePoints.count == 4,
                  let bounds = CADCutGeometry.profileBounds(cut.profilePoints) else {
                return false
            }
            let width = bounds.maxU - bounds.minU
            let height = bounds.maxV - bounds.minV
            let area = abs(DesignSketch.polygonSignedAreaMeters2(cut.profilePoints))
            return width > 0.0005
                && height > 0.0005
                && area > 1e-8
                && abs(width * height - area) <= max(area, 1.0) * 1e-5
        case .circle:
            guard cut.profilePoints.count >= 48,
                  let circle = CADCutGeometry.circleMetrics(
                    points: cut.profilePoints,
                    explicitCenter: CADCutGeometry.profileCenter(cut.profilePoints),
                    explicitRadius: nil
                  ) else {
                return false
            }
            return circle.radius > 0.0005
        case .polygon, .unsupported:
            return false
        }
    }

    private static func profileIsInsideFace(
        _ cut: ExtrudedSolidBoxBlindCutFeature,
        face: DesignPlanarFace
    ) -> Bool {
        let tolerance = CADCutGeometry.epsilon
        guard let bounds = profileBounds(for: cut) else { return false }
        return bounds.minU > face.bounds.minU + tolerance
            && bounds.maxU < face.bounds.maxU - tolerance
            && bounds.minV > face.bounds.minV + tolerance
            && bounds.maxV < face.bounds.maxV - tolerance
    }

    private static func bodyThickness(
        for cut: ExtrudedSolidBoxBlindCutFeature,
        entryFace: DesignPlanarFace,
        body: ExtrudedSolidParameters
    ) -> Double {
        CADCutGeometry.bodyThickness(
            entryFaceCenter: entryFace.center,
            bodyWorldVertices: body.vertices(),
            direction: cut.cutDirection
        ) ?? 0
    }

    private static func resolvedDepth(
        for cut: ExtrudedSolidBoxBlindCutFeature,
        entryFace: DesignPlanarFace,
        body: ExtrudedSolidParameters
    ) -> Double? {
        let thickness = bodyThickness(for: cut, entryFace: entryFace, body: body)
        guard thickness > CADCutGeometry.epsilon else { return nil }
        switch cut.depthMode {
        case .throughAll:
            return thickness
        case .distance:
            guard cut.depthMeters.isFinite,
                  cut.depthMeters > CADCutGeometry.epsilon,
                  cut.depthMeters < thickness - CADCutGeometry.epsilon else {
                return nil
            }
            return cut.depthMeters
        case .upToObject, .upToNearestFace:
            return nil
        }
    }

    private static func surfaceCuts(
        for cut: ExtrudedSolidBoxBlindCutFeature,
        body: ExtrudedSolidParameters
    ) -> [SurfaceCut]? {
        guard let entryFace = body.faces.first(where: { $0.id == cut.entryFaceID }),
              profileIsInsideFace(cut, face: entryFace) else {
            return nil
        }
        var surfaces = [
            SurfaceCut(
                cutID: cut.id,
                faceID: entryFace.id,
                profileType: cut.profileType,
                profilePoints: cut.profilePoints,
                isExit: false
            )
        ]
        guard cut.depthMode == .throughAll else { return surfaces }
        guard let depth = resolvedDepth(for: cut, entryFace: entryFace, body: body),
              let exitFace = exitFace(for: cut, entryFace: entryFace, body: body, depth: depth),
              let exitProfile = projectProfile(cut.profilePoints, from: entryFace, to: exitFace, direction: cut.cutDirection),
              profileIsInsideFace(
                ExtrudedSolidBoxBlindCutFeature(
                    id: cut.id,
                    profileType: cut.profileType,
                    entryFaceID: exitFace.id,
                    profilePoints: exitProfile,
                    depthMeters: cut.depthMeters,
                    cutDirection: cut.cutDirection,
                    sourceSketchID: cut.sourceSketchID,
                    sourceSketchName: cut.sourceSketchName,
                    selectedProfileID: cut.selectedProfileID,
                    depthMode: cut.depthMode,
                    direction: cut.direction
                ),
                face: exitFace
              ) else {
            return nil
        }
        surfaces.append(
            SurfaceCut(
                cutID: cut.id,
                faceID: exitFace.id,
                profileType: cut.profileType,
                profilePoints: exitProfile,
                isExit: true
            )
        )
        return surfaces
    }

    private static func exitFace(
        for cut: ExtrudedSolidBoxBlindCutFeature,
        entryFace: DesignPlanarFace,
        body: ExtrudedSolidParameters,
        depth: Double
    ) -> DesignPlanarFace? {
        let direction = cut.cutDirection.normalized(fallback: entryFace.normal * -1)
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
        direction: DesignVector3
    ) -> [SketchPoint2D]? {
        let d = direction.normalized(fallback: entryFace.normal * -1)
        let exitNormal = exitFace.normal.normalized(fallback: d)
        let denominator = d.dot(exitNormal)
        guard denominator > 1e-6 else { return nil }

        var projected: [SketchPoint2D] = []
        for point in profile {
            let world = CADCutGeometry.worldPoint(on: entryFace, local: point)
            let distance = (exitFace.origin - world).dot(exitNormal) / denominator
            guard distance.isFinite, distance > CADCutGeometry.epsilon else { return nil }
            projected.append(CADCutGeometry.localPoint(on: exitFace, world: world + d * distance))
        }
        return projected
    }

    private static func profilesOverlapOrTouch(
        _ lhs: SurfaceCut,
        _ rhs: SurfaceCut,
        tolerance: Double = CADCutGeometry.epsilon
    ) -> Bool {
        guard lhs.cutID != rhs.cutID,
              let lhsBounds = profileBounds(profileType: lhs.profileType, points: lhs.profilePoints),
              let rhsBounds = profileBounds(profileType: rhs.profileType, points: rhs.profilePoints) else {
            return true
        }
        return lhsBounds.minU <= rhsBounds.maxU + tolerance
            && lhsBounds.maxU + tolerance >= rhsBounds.minU
            && lhsBounds.minV <= rhsBounds.maxV + tolerance
            && lhsBounds.maxV + tolerance >= rhsBounds.minV
    }

    private static func profileBounds(for cut: ExtrudedSolidBoxBlindCutFeature) -> ProfileBounds? {
        profileBounds(profileType: cut.profileType, points: cut.profilePoints)
    }

    private static func profileBounds(
        profileType: CADCutV2ProfileType,
        points: [SketchPoint2D]
    ) -> ProfileBounds? {
        switch profileType {
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
        case .rectangle:
            return CADCutGeometry.profileBounds(points)
        case .polygon, .unsupported:
            return nil
        }
    }
}
