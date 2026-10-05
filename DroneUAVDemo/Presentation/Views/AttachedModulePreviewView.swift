import SceneKit
import SwiftUI
import simd

/// A slowly turning view of the module itself, for the picker.
///
/// The same geometry the mission mounts under the aircraft — built by `InterceptMissionScene` —
/// rather than an icon standing in for it. What the operator sees in the menu is the object that
/// ends up on the aircraft.
struct AttachedModulePreviewView: View {
    let shape: AttachedModuleShape
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AttachedModulePreviewRepresentable(shape: shape, rotates: !reduceMotion)
    }
}

private struct AttachedModulePreviewRepresentable: NSViewRepresentable {
    let shape: AttachedModuleShape
    let rotates: Bool

    func makeNSView(context: Context) -> SCNView {
        let view = ModulePreviewSCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling2X
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.preferredFramesPerSecond = 20
        view.rendersContinuously = false
        context.coordinator.apply(shape: shape, rotates: rotates, to: view)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.apply(shape: shape, rotates: rotates, to: nsView)
    }

    static func dismantleNSView(_ nsView: SCNView, coordinator: Coordinator) {
        // Let go of the GPU-side scene as soon as the card leaves the screen.
        nsView.isPlaying = false
        nsView.rendersContinuously = false
        nsView.scene = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var loadedShape: AttachedModuleShape?
        private var turntable: SCNNode?

        func apply(shape: AttachedModuleShape, rotates: Bool, to view: SCNView) {
            if loadedShape != shape {
                loadedShape = shape
                let (scene, node, radius) = Self.makeScene(for: shape)
                view.scene = scene
                view.pointOfView = scene.rootNode.childNode(withName: "module.preview.camera", recursively: false)
                (view as? ModulePreviewSCNView)?.moduleRadius = radius
                turntable = node
            }
            view.isPlaying = rotates
            view.rendersContinuously = rotates
            if !rotates {
                turntable?.removeAction(forKey: "turntable")
                return
            }
            guard let turntable, turntable.action(forKey: "turntable") == nil else { return }
            turntable.runAction(
                .repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 14)),
                forKey: "turntable"
            )
        }

        /// Frames the module by its own size, so a long slug and a compact charge both fill the
        /// card instead of one of them being a speck.
        private static func makeScene(for shape: AttachedModuleShape) -> (SCNScene, SCNNode, Float) {
            let scene = SCNScene()
            let turntable = SCNNode()
            let module = InterceptMissionScene.makeModuleNode(shape: shape)
            // Compute bounds once, before the new scene is attached to a renderer.
            let (lower, upper) = module.boundingBox
            let size = SIMD3<Float>(Float(upper.x - lower.x), Float(upper.y - lower.y), Float(upper.z - lower.z))
            module.simdPosition = -SIMD3<Float>(Float(upper.x + lower.x), Float(upper.y + lower.y), Float(upper.z + lower.z)) * 0.5
            let radius = max(0.025, simd_length(size) * 0.5)
            turntable.addChildNode(module)
            scene.rootNode.addChildNode(turntable)

            let extent = max(size.x, max(size.y, size.z))
            let camera = SCNNode()
            camera.name = "module.preview.camera"
            camera.camera = SCNCamera()
            camera.camera?.zNear = 0.01
            camera.camera?.fieldOfView = 34
            camera.camera?.projectionDirection = .vertical
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

            return (scene, turntable, radius)
        }
    }
}

private final class ModulePreviewSCNView: SCNView {
    var moduleRadius: Float = 0.25 { didSet { frameCamera() } }

    override func layout() {
        super.layout()
        frameCamera()
    }

    private func frameCamera() {
        guard bounds.width > 0, bounds.height > 0, let node = pointOfView, let camera = node.camera else { return }
        let aspect = max(0.1, Float(bounds.width / bounds.height))
        let verticalAngle: Float = 17 * .pi / 180
        let horizontalAngle = atan(tan(verticalAngle) * aspect)
        let distance = moduleRadius * 1.12 / sin(min(verticalAngle, horizontalAngle))
        node.simdPosition = simd_normalize(SIMD3<Float>(1.5, 1.1, 2.6)) * distance
        node.look(at: SCNVector3Zero)
        camera.zNear = Double(max(0.005, distance * 0.02))
        camera.zFar = Double(max(5, distance * 4))
    }
}
