import Foundation

enum CADCutValidator {
    static func validate(_ request: CADCutRequest, checkMesh: Bool = true) -> CADFeatureValidation {
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
        if existingCutsIntersect(request, bodyThickness: thickness) {
            return .cutIntersectsExistingVoidUnsupported
        }
        guard checkMesh else { return .valid }

        var resultBody = body
        resultBody.boxBlindCutFeatures.append(request.feature())
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

    private static func existingCutsIntersect(_ request: CADCutRequest, bodyThickness: Double) -> Bool {
        let body = request.targetBodyGeometry
        guard !body.boxBlindCutFeatures.isEmpty else { return false }
        let currentDepth = request.depthMode == .throughAll ? bodyThickness : request.depthMeters
        guard let currentBounds = CADCutGeometry.cutterBounds(
            entryFace: request.entryFace,
            profilePoints: request.profilePoints,
            direction: request.cutDirectionWorld,
            depthMeters: currentDepth
        ) else {
            return true
        }

        for feature in body.boxBlindCutFeatures {
            guard let entryFace = body.faces.first(where: { $0.id == feature.entryFaceID }) else {
                return true
            }
            let existingThickness = CADCutGeometry.bodyThickness(
                entryFaceCenter: entryFace.center,
                bodyWorldVertices: body.vertices(),
                direction: feature.cutDirection
            ) ?? feature.depthMeters
            let existingDepth = feature.depthMode == .throughAll ? existingThickness : feature.depthMeters
            guard let existingBounds = CADCutGeometry.cutterBounds(
                entryFace: entryFace,
                profilePoints: feature.profilePoints,
                direction: feature.cutDirection,
                depthMeters: existingDepth
            ) else {
                return true
            }
            if currentBounds.intersects(existingBounds) {
                return true
            }
        }
        return false
    }
}
