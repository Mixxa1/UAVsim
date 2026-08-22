import SceneKit
import SwiftUI

/// Lightweight SceneKit turntable for payloads. The preview deliberately uses
/// `PayloadVisualFactory`, the same procedural models mounted on the aircraft in the simulation,
/// so the catalog never drifts away from the in-flight visual.
struct PayloadLivePreviewView: NSViewRepresentable {
    let configuration: PayloadConfiguration
    var isSpinning: Bool = false
    var allowsCameraControl: Bool = false

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
        view.preferredFramesPerSecond = isSpinning ? 24 : 15
        view.rendersContinuously = false
        view.allowsCameraControl = allowsCameraControl
        view.setAccessibilityLabel(configuration.resolvedName)
        context.coordinator.apply(
            configuration: configuration,
            isSpinning: isSpinning,
            allowsCameraControl: allowsCameraControl,
            to: view
        )
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.apply(
            configuration: configuration,
            isSpinning: isSpinning,
            allowsCameraControl: allowsCameraControl,
            to: view
        )
    }

    static func dismantleNSView(_ view: SCNView, coordinator: Coordinator) {
        view.scene = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var loadedConfiguration: PayloadConfiguration?
        private var turntableNode: SCNNode?

        func apply(
            configuration: PayloadConfiguration,
            isSpinning: Bool,
            allowsCameraControl: Bool,
            to view: SCNView
        ) {
            if loadedConfiguration != configuration {
                loadedConfiguration = configuration
                let preview = PayloadPreviewSceneBuilder.makeScene(configuration: configuration)
                view.scene = preview.scene
                view.pointOfView = preview.camera
                turntableNode = preview.turntable
            }

            view.allowsCameraControl = allowsCameraControl
            view.preferredFramesPerSecond = isSpinning ? 24 : 15
            view.setAccessibilityLabel(configuration.resolvedName)

            guard let turntableNode else { return }
            if isSpinning {
                if turntableNode.action(forKey: "payload-turntable") == nil {
                    turntableNode.runAction(
                        .repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 14)),
                        forKey: "payload-turntable"
                    )
                }
            } else {
                turntableNode.removeAction(forKey: "payload-turntable")
            }
        }
    }
}

private enum PayloadPreviewSceneBuilder {
    struct Preview {
        let scene: SCNScene
        let camera: SCNNode
        let turntable: SCNNode
    }

    static func makeScene(configuration: PayloadConfiguration) -> Preview {
        let scene = SCNScene()
        let model = PayloadVisualFactory.build(configuration: configuration)
        let turntable = SCNNode()
        turntable.name = "payloadPreviewTurntable"
        scene.rootNode.addChildNode(turntable)
        turntable.addChildNode(model)

        let (minBounds, maxBounds) = model.boundingBox
        let center = SIMD3<Float>(
            Float((minBounds.x + maxBounds.x) * 0.5),
            Float((minBounds.y + maxBounds.y) * 0.5),
            Float((minBounds.z + maxBounds.z) * 0.5)
        )
        let size = SIMD3<Float>(
            Float(maxBounds.x - minBounds.x),
            Float(maxBounds.y - minBounds.y),
            Float(maxBounds.z - minBounds.z)
        )
        model.simdPosition = -center
        turntable.eulerAngles.y = -0.34

        let radius = max(size.x, size.y, size.z, 0.06) * 0.5

        let fieldOfView: Float = 34.0
        let fieldOfViewRadians = fieldOfView * .pi / 180.0
        let distance = radius / tan(fieldOfViewRadians * 0.5) * 1.72

        let cameraNode = SCNNode()
        cameraNode.name = "payloadPreviewCamera"
        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(fieldOfView)
        camera.zNear = 0.005
        camera.zFar = 50.0
        camera.wantsHDR = true
        camera.bloomIntensity = 0
        camera.exposureOffset = 0.08
        camera.wantsExposureAdaptation = false
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(distance * 0.48, distance * 0.30, distance)
        cameraNode.look(at: SCNVector3(0, -radius * 0.05, 0))
        scene.rootNode.addChildNode(cameraNode)

        addLighting(to: scene)
        return Preview(scene: scene, camera: cameraNode, turntable: turntable)
    }

    private static func addLighting(to scene: SCNScene) {
        let ambientNode = SCNNode()
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 430
        ambient.color = NSColor(calibratedWhite: 0.76, alpha: 1.0)
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let keyNode = SCNNode()
        let key = SCNLight()
        key.type = .directional
        key.intensity = 1_180
        key.color = NSColor(calibratedWhite: 0.96, alpha: 1.0)
        key.castsShadow = false
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.82, 0.62, 0.08)
        scene.rootNode.addChildNode(keyNode)

        let rimNode = SCNNode()
        let rim = SCNLight()
        rim.type = .directional
        rim.intensity = 470
        rim.color = NSColor(calibratedWhite: 0.72, alpha: 1.0)
        rimNode.light = rim
        rimNode.eulerAngles = SCNVector3(-0.35, -2.25, 0.0)
        scene.rootNode.addChildNode(rimNode)
    }
}
