import Foundation

struct CADCutCommitResult: Equatable {
    var bodyParams: ExtrudedSolidParameters
    var feature: ExtrudedSolidBoxBlindCutFeature
    var mesh: CADSolidMeshSnapshot
    var diagnostics: CADSolidMeshDiagnostics
}

enum CADCutCommitEngine {
    static func commit(_ request: CADCutRequest) -> Result<CADCutCommitResult, CADFeatureValidation> {
        let validation = CADCutValidator.validate(request)
        guard validation.isValid else { return .failure(validation) }

        let feature = request.feature()
        var resultParams = request.targetBodyGeometry
        resultParams.boxBlindCutFeatures.append(feature)
        resultParams.kernelResultSolid = nil
        resultParams.kernelVisualMesh = nil

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
            diagnostics: build.diagnostics
        ))
    }
}
