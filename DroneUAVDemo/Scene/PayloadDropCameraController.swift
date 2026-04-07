import Foundation
import SceneKit
import simd

struct PayloadDropCameraTarget {
    let releaseID: UUID
    let position: SIMD3<Float>
}

final class PayloadDropCameraController {
    let anchorNode = SCNNode()
    let pitchNode = SCNNode()
    let cameraNode = SCNNode()

    private var focusedReleaseID: UUID?
    private var isPrimed = false

    init() {
        anchorNode.name = "payloadCameraAnchorNode"
        pitchNode.name = "payloadCameraPitchNode"
        cameraNode.name = "payloadCameraNode"
        anchorNode.addChildNode(pitchNode)
        pitchNode.addChildNode(cameraNode)
    }

    func setFocusReleaseID(_ releaseID: UUID?) {
        guard focusedReleaseID != releaseID else {
            return
        }
        focusedReleaseID = releaseID
        isPrimed = false
    }

    func updateCameraProperties(fov: Float, zNear: CGFloat) {
        cameraNode.camera?.fieldOfView = CGFloat(fov)
        cameraNode.camera?.zNear = zNear
    }

    func syncImmediate(target: PayloadDropCameraTarget, groundY: Float) {
        setFocusReleaseID(target.releaseID)
        applyTracking(target: target, groundY: groundY, hardSync: true)
    }

    func updateForRenderFrame(
        atTime _: TimeInterval,
        target: PayloadDropCameraTarget?,
        groundY: Float,
        isActive: Bool
    ) {
        guard isActive, let target else {
            isPrimed = false
            return
        }

        if focusedReleaseID != target.releaseID {
            setFocusReleaseID(target.releaseID)
        }

        applyTracking(target: target, groundY: groundY, hardSync: !isPrimed)
    }

    func reset() {
        focusedReleaseID = nil
        isPrimed = false
        anchorNode.simdPosition = .zero
        anchorNode.simdOrientation = simd_quatf()
        pitchNode.eulerAngles = SCNVector3(0.0, 0.0, 0.0)
        cameraNode.simdPosition = .zero
    }

    private func applyTracking(
        target: PayloadDropCameraTarget,
        groundY: Float,
        hardSync: Bool
    ) {
        var desiredCameraPosition = target.position + SIMD3<Float>(0.0, 0.30, 0.72)
        desiredCameraPosition.y = max(groundY + 0.22, desiredCameraPosition.y)

        let desiredOrientation = orientation(
            from: desiredCameraPosition,
            to: target.position + SIMD3<Float>(0.0, -0.02, 0.0)
        )

        anchorNode.simdPosition = hardSync
            ? desiredCameraPosition
            : simd_mix(anchorNode.simdPosition, desiredCameraPosition, SIMD3<Float>(repeating: 0.96))
        anchorNode.simdOrientation = hardSync
            ? desiredOrientation
            : simd_normalize(simd_slerp(anchorNode.simdOrientation, desiredOrientation, 0.72))
        pitchNode.eulerAngles.z = 0.0
        cameraNode.simdPosition = .zero
        isPrimed = true
    }

    private func orientation(
        from position: SIMD3<Float>,
        to target: SIMD3<Float>
    ) -> simd_quatf {
        let toTarget = target - position
        guard simd_length_squared(toTarget) > 0.000001 else {
            return simd_quatf()
        }

        let forward = simd_normalize(toTarget)
        let planarLength = max(0.0001, simd_length(SIMD2<Float>(forward.x, forward.z)))
        let yaw = simd_quatf(angle: atan2(forward.x, -forward.z), axis: SIMD3<Float>(0.0, 1.0, 0.0))
        let pitch = simd_quatf(angle: atan2(forward.y, planarLength), axis: SIMD3<Float>(1.0, 0.0, 0.0))
        return simd_normalize(yaw * pitch)
    }
}
