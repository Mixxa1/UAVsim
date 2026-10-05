import SceneKit
import SwiftUI

/// Live, auto-framed, lit, slowly-rotating SceneKit preview of a single UAV, built through the
/// exact same node factory used in-game (`UAVVisualFactory`, which serves the authored USDZ
/// airframe when one exists and its procedural silhouette otherwise) — so the card is guaranteed
/// to show what you actually fly. Deliberately much simpler than `DroneSceneViewRepresentable`:
/// no gestures, no camera control, no render-frame callbacks, no coupling to the main viewport's
/// performance-policy/quality-tier machinery. Catalogue assets load on a dedicated serial queue;
/// only visible cards own a rendering clock; dismantling a card stops its animation immediately.
struct UAVLivePreviewView: View {
    let profile: UAVProfile?
    var runtimeProfile: DroneModelProfile? = nil
    var isSpinning: Bool = true
    @State private var isReady = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let profile {
            ZStack {
                UAVLivePreviewRepresentable(
                    profile: profile,
                    runtimeProfile: runtimeProfile,
                    isSpinning: isSpinning && !reduceMotion,
                    onLoad: { isReady = true })
                if !isReady {
                    ProgressView().controlSize(.small).allowsHitTesting(false)
                }
            }
            .onChange(of: profile.id) { _, _ in isReady = false }
        } else {
            Image(systemName: "questionmark.square.dashed")
                .font(.title2)
                .foregroundStyle(GroundControlPalette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private final class UAVPreviewSCNView: SCNView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

private struct UAVLivePreviewRepresentable: NSViewRepresentable {
    let profile: UAVProfile
    let runtimeProfile: DroneModelProfile?
    let isSpinning: Bool
    let onLoad: () -> Void

    func makeNSView(context: Context) -> SCNView {
        let view = UAVPreviewSCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling2X
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.preferredFramesPerSecond = 20
        view.rendersContinuously = false
        view.onLayout = { [weak view, weak coordinator = context.coordinator] in
            guard let view else { return }
            coordinator?.frameCamera(in: view)
        }
        context.coordinator.apply(
            profile: profile, runtimeProfile: runtimeProfile,
            isSpinning: isSpinning, onLoad: onLoad, to: view)
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        context.coordinator.apply(
            profile: profile, runtimeProfile: runtimeProfile,
            isSpinning: isSpinning, onLoad: onLoad, to: nsView)
    }

    static func dismantleNSView(_ nsView: SCNView, coordinator: Coordinator) {
        // Release the GPU-side scene graph promptly once a card scrolls out of the grid.
        coordinator.invalidate()
        (nsView as? UAVPreviewSCNView)?.onLayout = nil
        nsView.isPlaying = false
        nsView.rendersContinuously = false
        nsView.scene = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var loadedProfileID: String?
        private var rootNode: SCNNode?
        private var requestID = UUID()
        private var wantsSpin = false
        private var loadingWork: DispatchWorkItem?
        private var framedViewport: CGSize?
        private static let loadingQueue = DispatchQueue(label: "uavsim.preview.models", qos: .userInitiated)

        func invalidate() {
            requestID = UUID()
            loadingWork?.cancel()
            loadingWork = nil
            rootNode?.removeAllActions()
            rootNode = nil
            framedViewport = nil
        }

        func apply(
            profile: UAVProfile,
            runtimeProfile: DroneModelProfile?,
            isSpinning: Bool,
            onLoad: @escaping () -> Void,
            to view: SCNView
        ) {
            let visualID = runtimeProfile?.workbenchBuild.map {
                "\(runtimeProfile?.id ?? profile.id).\($0.revision)"
            } ?? profile.id
            wantsSpin = isSpinning
            if loadedProfileID != visualID {
                loadedProfileID = visualID
                invalidate()
                let request = requestID
                view.isPlaying = false
                view.rendersContinuously = false
                view.scene = nil
                if let runtimeProfile, runtimeProfile.workbenchBuild != nil {
                    let (scene, root) = UAVPreviewSceneBuilder.makeScene(for: runtimeProfile)
                    view.scene = scene
                    rootNode = root
                    DispatchQueue.main.async { [weak self] in
                        guard self?.requestID == request else { return }
                        onLoad()
                    }
                } else {
                    // USDZ parsing and material copies can take longer than a scroll frame. A
                    // serial queue also bounds memory when many new cards enter the viewport.
                    let work = DispatchWorkItem { [weak self, weak view] in
                        let (scene, root) = autoreleasepool {
                            UAVPreviewSceneBuilder.makeScene(for: profile)
                        }
                        DispatchQueue.main.async { [weak self, weak view] in
                            guard let self, let view, self.requestID == request else { return }
                            self.loadingWork = nil
                            view.scene = scene
                            self.rootNode = root
                            self.updateSpin(in: view)
                            onLoad()
                        }
                    }
                    loadingWork = work
                    Self.loadingQueue.async(execute: work)
                }
            }
            updateSpin(in: view)
        }

        private func updateSpin(in view: SCNView) {
            guard let rootNode else { return }
            frameCamera(in: view)
            if wantsSpin {
                if rootNode.action(forKey: "turntable") == nil {
                    let spin = SCNAction.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 16))
                    rootNode.runAction(spin, forKey: "turntable")
                }
            } else {
                rootNode.removeAction(forKey: "turntable")
            }
            view.rendersContinuously = wantsSpin
            view.isPlaying = wantsSpin
        }

        func frameCamera(in view: SCNView) {
            guard let rootNode, view.bounds.width > 0, view.bounds.height > 0,
                  framedViewport != view.bounds.size else { return }
            framedViewport = view.bounds.size
            UAVPreviewSceneBuilder.frameCamera(in: view, root: rootNode)
        }
    }
}

private enum UAVPreviewSceneBuilder {
    // The catalogue renderer has its own templates, confined to the serial preview queue.
    // The simulation's mutable asset cache is never accessed from that queue.
    private static let assets = UAVModelAssetLibrary(
        directory: Bundle.main.url(forResource: UAVModelAssetConstants.bundleFolder, withExtension: nil))

    static func makeScene(for runtimeProfile: DroneModelProfile) -> (scene: SCNScene, root: SCNNode) {
        makeScene(model: DroneModelBuilder.build(profile: runtimeProfile))
    }

    static func makeScene(for profile: UAVProfile) -> (scene: SCNScene, root: SCNNode) {
        makeScene(model: UAVVisualFactory.build(profile: profile, assetLibrary: assets))
    }

    private static func makeScene(model: DroneVisualModel) -> (scene: SCNScene, root: SCNNode) {
        let scene = SCNScene()
        let turntable = SCNNode()
        turntable.name = "preview.turntable"
        turntable.addChildNode(model.rootNode)
        let (center, size) = boundsInScene(of: turntable)
        // Rotate around the visual centre, including authored models with an offset origin.
        model.rootNode.position = SCNVector3(Float(model.rootNode.position.x) - center.x,
                                            Float(model.rootNode.position.y) - center.y,
                                            Float(model.rootNode.position.z) - center.z)
        scene.rootNode.addChildNode(turntable)

        let cameraNode = SCNNode()
        cameraNode.name = "preview.camera"
        let camera = SCNCamera()
        camera.fieldOfView = 40.0
        camera.projectionDirection = .vertical
        cameraNode.camera = camera
        frameCamera(cameraNode, size: size, viewport: CGSize(width: 360, height: 240))
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

        return (scene, turntable)
    }

    static func frameCamera(in view: SCNView, root: SCNNode) {
        guard let camera = view.scene?.rootNode.childNode(withName: "preview.camera", recursively: false) else { return }
        frameCamera(camera, size: boundsInScene(of: root).size, viewport: view.bounds.size)
        view.pointOfView = camera
    }

    private static func frameCamera(_ node: SCNNode, size: SIMD3<Float>, viewport: CGSize) {
        guard let camera = node.camera else { return }
        let aspect = max(0.1, Float(viewport.width / max(viewport.height, 1)))
        let verticalAngle: Float = 20 * .pi / 180
        let horizontalAngle = atan(tan(verticalAngle) * aspect)
        let elevation: Float = 25 * .pi / 180
        let radius = max(0.025, hypot(size.x, size.z) * 0.5)
        let halfHeight = max(0.01, size.y * 0.5)
        // Bound the cylinder swept by a full turn against both sides of the camera frustum.
        let verticalDistance = max(
            radius * sin(elevation + verticalAngle) + halfHeight * cos(elevation + verticalAngle),
            radius * abs(sin(elevation - verticalAngle)) + halfHeight * cos(elevation - verticalAngle)
        ) / sin(verticalAngle)
        let horizontalDistance = (radius * hypot(cos(horizontalAngle), cos(elevation) * sin(horizontalAngle))
                                  + halfHeight * sin(elevation) * sin(horizontalAngle)) / sin(horizontalAngle)
        let distance = max(verticalDistance, horizontalDistance) * 1.10
        let azimuth: Float = 35 * .pi / 180
        node.position = SCNVector3(distance * cos(elevation) * sin(azimuth),
                                  distance * sin(elevation),
                                  distance * cos(elevation) * cos(azimuth))
        node.look(at: SCNVector3Zero)
        camera.zNear = Double(max(0.01, distance * 0.02))
        camera.zFar = Double(max(20, distance * 4))
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
