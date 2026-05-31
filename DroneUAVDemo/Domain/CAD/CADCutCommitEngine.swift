import Foundation

struct CADCutCommitResult: Equatable {
    var bodyParams: ExtrudedSolidParameters
    var feature: ExtrudedSolidBoxBlindCutFeature
    var mesh: CADSolidMeshSnapshot
    var diagnostics: CADSolidMeshDiagnostics
    var rebuildDiagnostics: CADCutMeshRebuildDiagnostics
    var multiCutValidation: CADMultiCutValidationResult
}

enum CADCutCommitEngine {
    static func commit(_ request: CADCutRequest) -> Result<CADCutCommitResult, CADFeatureValidation> {
        let feature = request.feature()
        let validation = CADCutValidator.validate(request, candidateFeature: feature)
        guard validation.isValid else { return .failure(validation) }

        let multiCutValidation = CADMultiCutValidator.validate(
            baseBody: request.targetBodyGeometry,
            existingCuts: request.targetBodyGeometry.stableCutFeatures,
            newCut: feature
        )
        guard multiCutValidation.isValid else { return .failure(multiCutValidation.validation) }

        var resultParams = request.targetBodyGeometry
        resultParams.stableCutFeatures = multiCutValidation.candidateCuts
        resultParams.kernelResultSolid = nil
        resultParams.kernelVisualMesh = nil
        resultParams.refreshFaces(assetID: request.targetBodyID)

        guard let build = CADCutMeshRebuilder.rebuildBodyMesh(
            bodyID: request.targetBodyID,
            bodyParams: resultParams
        ) else {
            return .failure(.generatedMeshEmpty)
        }

        resultParams.kernelVisualMesh = build.mesh
        resultParams.featureRecord = CADFeatureRecord(
            featureID: feature.id,
            operation: .cutRemoveMaterialV2,
            sourceSketchID: request.sourceSketchID,
            sourceSketchName: request.sourceSketchName,
            depthMeters: feature.depthMeters,
            direction: feature.direction,
            depthMode: feature.depthMode,
            timestamp: Date()
        )

        return .success(CADCutCommitResult(
            bodyParams: resultParams,
            feature: feature,
            mesh: build.mesh,
            diagnostics: build.diagnostics,
            rebuildDiagnostics: build.rebuildDiagnostics,
            multiCutValidation: multiCutValidation
        ))
    }
}
