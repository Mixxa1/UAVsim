import Foundation
import simd

struct MountedCADPayload: Codable, Hashable, Identifiable {
    struct Rotation: Codable, Hashable {
        var axisX: Double
        var axisY: Double
        var axisZ: Double
        var angleRad: Double

        var quaternion: simd_quatf {
            let axis = SIMD3<Float>(Float(axisX), Float(axisY), Float(axisZ))
            let length = simd_length(axis)
            guard length.isFinite, length > 0.000001, angleRad.isFinite else {
                return simd_quatf()
            }
            return simd_quatf(angle: Float(angleRad), axis: axis / length)
        }

        var isFinite: Bool {
            axisX.isFinite && axisY.isFinite && axisZ.isFinite && angleRad.isFinite
        }
    }

    struct CollisionProxy: Codable, Hashable {
        var type: String
        var center: CodableVector3D
        var size: CodableVector3D
        var source: String
        var valid: Bool

        var hasUsableBounds: Bool {
            valid && size.x > 0.0 && size.y > 0.0 && size.z > 0.0
        }
    }

    struct VisualMesh: Codable, Hashable {
        var valid: Bool
        var vertices: [Double]
        var indices: [UInt32]

        var isRenderable: Bool {
            valid && vertices.count >= 9 && vertices.count % 3 == 0 && indices.count >= 3 && indices.count % 3 == 0
        }
    }

    struct MountValidationResult: Codable, Hashable {
        var isValid: Bool
        var snapError: Double
        var errors: [String]
        var warnings: [String]
    }

    var id: String
    var partID: String
    var partFileURL: String
    var partName: String
    var sourceUAVPartManifestID: String
    var massKg: Double
    var centerOfMassLocal: CodableVector3D
    var boundingWidth: Double
    var boundingHeight: Double
    var boundingDepth: Double
    var boundingBoxMin: CodableVector3D
    var boundingBoxMax: CodableVector3D
    var dragPenalty: Double
    var structuralRating: Double
    var materialID: String
    var materialPreviewColor: String
    var payloadAttachmentPointID: String
    var payloadAttachmentPointName: String?
    var uavMountPointID: String
    var uavMountPointName: String?
    var localPositionOnUAV: CodableVector3D
    var localRotationOnUAV: Rotation
    var userRotationOffset: CodableVector3D
    var userPositionOffset: CodableVector3D
    var visualPreviewMode: String
    var visualMesh: VisualMesh?
    var collisionProxy: CollisionProxy
    var mountValidationResult: MountValidationResult
    var createdAt: String

    var boundsValid: Bool {
        boundingWidth > 0.0 && boundingHeight > 0.0 && boundingDepth > 0.0
    }

    var transformIsFinite: Bool {
        localPositionOnUAV.isFinite && localRotationOnUAV.isFinite && userRotationOffset.isFinite
    }

    var hasRenderableVisual: Bool {
        visualMesh?.isRenderable == true || boundsValid
    }

    func approximateCenterOfMassOnUAV() -> SIMD3<Float> {
        let localCOM = centerOfMassLocal.simdFloat
        return localPositionOnUAV.simdFloat + localRotationOnUAV.quaternion.act(localCOM)
    }

    func runtimeWarningKeys(maxPayloadMass: Float?) -> [String] {
        var keys: [String] = []
        if let maxPayloadMass, maxPayloadMass > 0.001, Float(massKg) / maxPayloadMass > 0.80 {
            keys.append("cad.payload.runtime.high_mass_warning")
        }
        if simd_length(SIMD2<Float>(approximateCenterOfMassOnUAV().x, approximateCenterOfMassOnUAV().z)) > 0.18 {
            keys.append("cad.payload.runtime.com_warning")
        }
        if visualMesh?.isRenderable != true {
            keys.append("cad.payload.runtime.visual_missing")
        }
        return keys
    }
}

extension CodableVector3D {
    var isFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
