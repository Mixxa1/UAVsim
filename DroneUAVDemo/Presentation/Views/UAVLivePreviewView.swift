import SceneKit
import SwiftUI

/// Live, auto-framed, lit, slowly-rotating SceneKit preview of a single UAV, built from the exact
/// same procedural node factory used in-game (`UAVVisualFactory`) — guaranteed to match what you
/// fly, with zero new art assets. Deliberately much simpler than `DroneSceneViewRepresentable`:
/// no gestures, no camera control, no render-frame callbacks, no coupling to the main viewport's
/// performance-policy/quality-tier machinery. Cheap enough to embed dozens of instances in a
/// scrollable card grid.
struct UAVLivePreviewView: View {
    let profile: UAVProfile?
    var runtimeProfile: DroneModelProfile? = nil
    var isSpinning: Bool = true

    var body: some View {
        if let profile {
            UAVLivePreviewRepresentable(
                profile: profile,
                runtimeProfile: runtimeProfile,
                isSpinning: isSpinning)
        } else {
            Image(systemName: "questionmark.square.dashed")
                .font(.title2)
                .foregroundStyle(GroundControlPalette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct UAVLivePreviewRepresentable: NSViewRepresentable {
    let profile: UAVProfile
    let runtimeProfile: DroneModelProfile?
    let isSpinning: Bool

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling2X
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.preferredFramesPerSecond = 20
        view.rendersContinuously = false
        context.coordinator.apply(
            profile: profile, runtimeProfile: runtimeProfile,
            isSpinning: isSpinning, to: view)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.apply(
            profile: profile, runtimeProfile: runtimeProfile,
            isSpinning: isSpinning, to: nsView)
    }

    static func dismantleNSView(_ nsView: SCNView, coordinator: Coordinator) {
        // Release the GPU-side scene graph promptly once a card scrolls out of the grid.
        nsView.scene = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var loadedProfileID: String?
        private var rootNode: SCNNode?

        func apply(
            profile: UAVProfile,
            runtimeProfile: DroneModelProfile?,
            isSpinning: Bool,
            to view: SCNView
        ) {
            let visualID = runtimeProfile?.workbenchBuild.map {
                "\(runtimeProfile?.id ?? profile.id).\($0.revision)"
            } ?? profile.id
            if loadedProfileID != visualID {
                loadedProfileID = visualID
                let (scene, root) = runtimeProfile?.workbenchBuild == nil
                    ? UAVPreviewSceneBuilder.makeScene(for: profile)
                    : UAVPreviewSceneBuilder.makeScene(for: runtimeProfile!)
                view.scene = scene
                rootNode = root
            }

            guard let rootNode else { return }
            if isSpinning {
                if rootNode.action(forKey: "turntable") == nil {
                    let spin = SCNAction.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 16))
                    rootNode.runAction(spin, forKey: "turntable")
                }
            } else {
                rootNode.removeAction(forKey: "turntable")
            }
        }
    }
}

private enum UAVPreviewSceneBuilder {
    static func makeScene(for runtimeProfile: DroneModelProfile) -> (scene: SCNScene, root: SCNNode) {
        makeScene(model: DroneModelBuilder.build(profile: runtimeProfile))
    }

    static func makeScene(for profile: UAVProfile) -> (scene: SCNScene, root: SCNNode) {
        makeScene(model: UAVVisualFactory.build(profile: profile))
    }

    private static func makeScene(model: DroneVisualModel) -> (scene: SCNScene, root: SCNNode) {
        let scene = SCNScene()
        scene.rootNode.addChildNode(model.rootNode)

        let (center, size) = boundsInScene(of: model.rootNode)
        let radius = max(size.x, size.y, size.z, 0.05) * 0.5
        let fovRadians: Float = 40.0 * .pi / 180.0
        let distance = radius / tan(fovRadians / 2.0) * 1.7

        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.fieldOfView = 40.0
        camera.zNear = 0.01
        camera.zFar = 20.0
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(
            center.x + distance * 0.55,
            center.y + radius * 0.55,
            center.z + distance * 0.85
        )
        cameraNode.look(at: SCNVector3(center.x, center.y, center.z))
        scene.rootNode.addChildNode(cameraNode)

        let ambientNode = SCNNode()
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 380
        ambientLight.color = NSColor(calibratedRed: 0.80, green: 0.83, blue: 0.90, alpha: 1.0)
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        let keyNode = SCNNode()
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.intensity = 1100
        keyLight.castsShadow = false
        keyLight.color = NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.92, alpha: 1.0)
        keyNode.light = keyLight
        keyNode.eulerAngles = SCNVector3(-0.9, 0.7, 0.0)
        scene.rootNode.addChildNode(keyNode)

        return (scene, model.rootNode)
    }

    /// `DroneVisualModel.visualBoundsCenter`/`visualBoundsSize` are never actually populated by any
    /// `UAVVisualFactory` builder (all 9+ per-aircraft builders leave the struct's placeholder
    /// defaults), so real bounds are computed here directly from the node's geometry instead.
    private static func boundsInScene(of node: SCNNode) -> (center: SIMD3<Float>, size: SIMD3<Float>) {
        let (minB, maxB) = node.boundingBox
        let scale = Float(node.scale.x)
        let sizeLocal = SIMD3<Float>(
            Float(maxB.x - minB.x),
            Float(maxB.y - minB.y),
            Float(maxB.z - minB.z)
        )
        let centerLocal = SIMD3<Float>(
            Float((minB.x + maxB.x) * 0.5),
            Float((minB.y + maxB.y) * 0.5),
            Float((minB.z + maxB.z) * 0.5)
        )
        return (centerLocal * scale, sizeLocal * scale)
    }
}
