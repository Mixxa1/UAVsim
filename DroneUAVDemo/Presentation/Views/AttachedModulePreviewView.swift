import SceneKit
import SwiftUI

/// A slowly turning view of the module itself, for the picker.
///
/// The same geometry the mission mounts under the aircraft — built by `InterceptMissionScene` —
/// rather than an icon standing in for it. What the operator sees in the menu is the object that
/// ends up on the aircraft.
struct AttachedModulePreviewView: View {
    let shape: AttachedModuleShape

    var body: some View {
        AttachedModulePreviewRepresentable(shape: shape)
    }
}

private struct AttachedModulePreviewRepresentable: NSViewRepresentable {
    let shape: AttachedModuleShape

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling2X
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.preferredFramesPerSecond = 20
        view.rendersContinuously = false
        context.coordinator.apply(shape: shape, to: view)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.apply(shape: shape, to: nsView)
    }

    static func dismantleNSView(_ nsView: SCNView, coordinator: Coordinator) {
        // Let go of the GPU-side scene as soon as the card leaves the screen.
        nsView.scene = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var loadedShape: AttachedModuleShape?
        private var turntable: SCNNode?

        func apply(shape: AttachedModuleShape, to view: SCNView) {
            if loadedShape != shape {
                loadedShape = shape
                let (scene, node) = Self.makeScene(for: shape)
                view.scene = scene
                turntable = node
            }
            guard let turntable, turntable.action(forKey: "turntable") == nil else { return }
            turntable.runAction(
                .repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 14)),
                forKey: "turntable"
            )
        }

        /// Frames the module by its own size, so a long slug and a compact charge both fill the
        /// card instead of one of them being a speck.
        private static func makeScene(for shape: AttachedModuleShape) -> (SCNScene, SCNNode) {
            let scene = SCNScene()
            let turntable = SCNNode()
            turntable.addChildNode(InterceptMissionScene.makeModuleNode(shape: shape))
            scene.rootNode.addChildNode(turntable)

            let size = shape.sizeMeters
            let extent = max(size.x, max(size.y, size.z))
            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.zNear = 0.01
            camera.camera?.fieldOfView = 34
            camera.simdPosition = SIMD3<Float>(extent * 1.5, extent * 1.1, extent * 2.6)
            camera.look(at: SCNVector3Zero, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
            scene.rootNode.addChildNode(camera)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 900
            key.simdPosition = SIMD3<Float>(extent * 2, extent * 3, extent * 2)
            key.look(at: SCNVector3Zero, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
            scene.rootNode.addChildNode(key)

            let fill = SCNNode()
            fill.light = SCNLight()
            fill.light?.type = .ambient
            fill.light?.intensity = 320
            scene.rootNode.addChildNode(fill)

            return (scene, turntable)
        }
    }
}
