import Foundation

enum CADCutPreviewBuilder {
    static func buildPreview(_ request: CADCutRequest) -> CADFeaturePreviewState {
        CADFeaturePreviewState(
            operation: .cutRemoveMaterialV2,
            profilePoints: request.profilePoints,
            sourceReference: request.sourceSketchReference,
            targetBodyID: request.targetBodyID,
            selectedProfileID: request.selectedProfileID,
            depthMeters: previewDepthMeters(for: request),
            direction: request.directionForSketchReference,
            depthMode: request.depthMode,
            material: request.targetBodyGeometry.material,
            sourceSketchID: request.sourceSketchID,
            sourceSketchName: request.sourceSketchName
        )
    }

    static func previewDepthMeters(for request: CADCutRequest) -> Double {
        guard request.depthMode == .throughAll else { return request.depthMeters }
        let bodyVertices = request.targetBodyGeometry.vertices()
        let thickness = CADCutGeometry.bodyThickness(
            entryFaceCenter: request.entryFaceCenter,
            bodyWorldVertices: bodyVertices,
            direction: request.cutDirectionWorld
        ) ?? request.depthMeters
        let diagonal = bodyDiagonal(bodyVertices) ?? request.targetBodyGeometry.depthMeters
        return thickness + max(diagonal * 0.05, 0.005)
    }

    private static func bodyDiagonal(_ vertices: [DesignVector3]) -> Double? {
        guard let first = vertices.first else { return nil }
        var minPoint = first
        var maxPoint = first
        for vertex in vertices.dropFirst() {
            minPoint = DesignVector3(
                x: min(minPoint.x, vertex.x),
                y: min(minPoint.y, vertex.y),
                z: min(minPoint.z, vertex.z)
            )
            maxPoint = DesignVector3(
                x: max(maxPoint.x, vertex.x),
                y: max(maxPoint.y, vertex.y),
                z: max(maxPoint.z, vertex.z)
            )
        }
        return (maxPoint - minPoint).length
    }
}
