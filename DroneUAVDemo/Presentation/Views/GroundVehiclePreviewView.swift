import SceneKit
import SwiftUI

/// Uses the same asset and forward axis as the mission. The model is framed once; only a
/// user drag renders new frames, avoiding another continuous renderer in the setup screen.
struct GroundVehiclePreviewView: NSViewRepresentable {
    let model: GroundVehicleModel

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling2X
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = false
        view.rendersContinuously = false
        view.preferredFramesPerSecond = 20
        apply(to: view)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        if view.scene?.rootNode.name != model.rawValue { apply(to: view) }
    }

    private func apply(to view: SCNView) {
        let scene = SCNScene(); scene.rootNode.name = model.rawValue
        let visual = GroundVehicleVisual(model: model)
        scene.rootNode.addChildNode(visual.rootNode)
        let camera = SCNNode(); camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 42
        camera.simdPosition = SIMD3<Float>(10, 7, -13)
        camera.look(at: SCNVector3(0, 1.5, 0))
        scene.rootNode.addChildNode(camera)
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.intensity = 450; scene.rootNode.addChildNode(ambient)
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .directional
        key.light?.intensity = 1100; key.eulerAngles = SCNVector3(-0.6, -0.7, 0)
        scene.rootNode.addChildNode(key)
        view.scene = scene; view.pointOfView = camera
        view.defaultCameraController.target = SCNVector3(0, 1.5, 0)
    }

    static func dismantleNSView(_ view: SCNView, coordinator: ()) {
        view.isPlaying = false; view.scene = nil
    }
}
