import AppKit
import SceneKit
import SwiftUI
import simd

/// A deliberately isolated renderer for the Workbench library cards.
///
/// The editor scene has a physical bench, HDR-like workshop lighting and camera
/// constraints that are useful at full size. Reusing those presentation choices
/// in an 89-point-tall card used to turn the preview shadow catcher into a white
/// rectangle and reduced long, flat parts to a few pixels. This view only shares
/// component geometry with the editor; framing, light and material adaptation are
/// tuned as a small neutral product photograph.
struct WorkbenchPartPreview: NSViewRepresentable {
    var frame: WorkbenchFrameSpec?
    var component: WorkbenchComponentSpec?

    final class Coordinator {
        var representedKey: String?
    }

    init(frame: WorkbenchFrameSpec) {
        self.frame = frame
        component = nil
    }

    init(component: WorkbenchComponentSpec) {
        frame = nil
        self.component = component
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.layer?.isOpaque = false
        view.backgroundColor = .clear
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        applyScene(to: view)
        context.coordinator.representedKey = identityKey
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        guard context.coordinator.representedKey != identityKey else { return }
        applyScene(to: nsView)
        context.coordinator.representedKey = identityKey
    }

    private func applyScene(to view: SCNView) {
        let scene = WorkbenchLibraryPreviewSceneFactory.makeScene(
            cacheKey: identityKey,
            frame: frame,
            component: component)
        view.scene = scene
        view.pointOfView = scene.rootNode.childNode(
            withName: WorkbenchLibraryPreviewSceneFactory.cameraName,
            recursively: false)
    }

    private var identityKey: String {
        if let frame { return "frame.\(frame.id).\(frame.hashValue)" }
        if let component { return "component.\(component.id).\(component.hashValue)" }
        return "empty"
    }
}

/// Scene construction lives outside the large interactive Workbench
/// representable so thumbnail tuning cannot accidentally move the aircraft,
/// workshop camera, table or engineering mounting layout.
enum WorkbenchLibraryPreviewSceneFactory {
    static let cameraName = "workbench.library-preview.camera"

    private static let cardAspectRatio: Float = 1.86
    private static let modelCache: NSCache<NSString, SCNNode> = {
        let cache = NSCache<NSString, SCNNode>()
        cache.countLimit = 180
        cache.totalCostLimit = 14_000
        return cache
    }()

    static func makeScene(
        cacheKey: String,
        frame: WorkbenchFrameSpec?,
        component: WorkbenchComponentSpec?
    ) -> SCNScene {
        let scene = SCNScene()
        // A genuinely transparent scene lets the card's dark inset be the only
        // background. In particular, do not add a floor/shadow-catcher plane:
        // SceneKit composited its texture alpha as a luminous white rectangle.
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = studioEnvironment
        scene.lightingEnvironment.intensity = 0.13

        let key = cacheKey as NSString
        let model: SCNNode
        if let cached = modelCache.object(forKey: key) {
            model = cached.clone()
        } else {
            model = frame.map { WorkbenchModelBuilder.previewNode(for: $0) }
                ?? component.map { WorkbenchModelBuilder.previewNode(for: $0) }
                ?? SCNNode()
            adaptMaterials(in: model)
            modelCache.setObject(
                model.clone(),
                forKey: key,
                cost: geometryCount(in: model) + 1)
        }
        scene.rootNode.addChildNode(model)

        let bounds = safeBounds(of: model)
        let center = (bounds.minimum + bounds.maximum) * 0.5
        let direction = previewDirection(for: component)
        let layout = cameraLayout(
            bounds: bounds,
            center: center,
            direction: direction)

        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(layout.orthographicScale)
        camera.zNear = 0.001
        camera.zFar = Double(layout.distance * 4 + 2)
        camera.wantsHDR = false
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.62
        camera.bloomIntensity = 0
        camera.screenSpaceAmbientOcclusionIntensity = 0

        let cameraNode = SCNNode()
        cameraNode.name = cameraName
        cameraNode.camera = camera
        cameraNode.simdPosition = center + direction * layout.distance
        cameraNode.look(at: SCNVector3(center.x, center.y, center.z))
        scene.rootNode.addChildNode(cameraNode)

        addLight(
            to: scene,
            name: "preview.key",
            color: NSColor(deviceRed: 0.95, green: 0.91, blue: 0.84, alpha: 1),
            intensity: 68,
            position: center + SIMD3<Float>(-layout.distance, layout.distance, layout.distance * 0.72),
            target: center)
        addLight(
            to: scene,
            name: "preview.fill",
            color: NSColor(deviceRed: 0.68, green: 0.77, blue: 0.88, alpha: 1),
            intensity: 18,
            position: center + SIMD3<Float>(layout.distance, layout.distance * 0.28, layout.distance * 0.45),
            target: center)
        addLight(
            to: scene,
            name: "preview.rim",
            color: NSColor(deviceRed: 0.74, green: 0.80, blue: 0.88, alpha: 1),
            intensity: 24,
            position: center + SIMD3<Float>(layout.distance * 0.42, layout.distance * 0.72, -layout.distance),
            target: center)

        let ambient = SCNNode()
        ambient.name = "preview.ambient"
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = NSColor(deviceRed: 0.59, green: 0.63, blue: 0.68, alpha: 1)
        ambient.light?.intensity = 17
        scene.rootNode.addChildNode(ambient)
        return scene
    }

    private struct Bounds {
        var minimum: SIMD3<Float>
        var maximum: SIMD3<Float>
    }

    private struct CameraLayout {
        var orthographicScale: Float
        var distance: Float
    }

    private static func safeBounds(of model: SCNNode) -> Bounds {
        let raw = model.boundingBox
        let minimum = SIMD3<Float>(Float(raw.min.x), Float(raw.min.y), Float(raw.min.z))
        let maximum = SIMD3<Float>(Float(raw.max.x), Float(raw.max.y), Float(raw.max.z))
        guard minimum.x.isFinite, minimum.y.isFinite, minimum.z.isFinite,
              maximum.x.isFinite, maximum.y.isFinite, maximum.z.isFinite else {
            return Bounds(
                minimum: SIMD3<Float>(repeating: -0.015),
                maximum: SIMD3<Float>(repeating: 0.015))
        }
        return Bounds(minimum: minimum, maximum: maximum)
    }

    /// Orthographic scale is based on the bounds projected into the actual
    /// camera basis rather than on the 3D diagonal. Long propellers, wings,
    /// antennae and landing legs therefore use the available card area.
    private static func cameraLayout(
        bounds: Bounds,
        center: SIMD3<Float>,
        direction: SIMD3<Float>
    ) -> CameraLayout {
        let forward = -simd_normalize(direction)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = simd_normalize(simd_cross(right, forward))
        var halfWidth: Float = 0
        var halfHeight: Float = 0
        for x in [bounds.minimum.x, bounds.maximum.x] {
            for y in [bounds.minimum.y, bounds.maximum.y] {
                for z in [bounds.minimum.z, bounds.maximum.z] {
                    let offset = SIMD3<Float>(x, y, z) - center
                    halfWidth = max(halfWidth, abs(simd_dot(offset, right)))
                    halfHeight = max(halfHeight, abs(simd_dot(offset, up)))
                }
            }
        }
        let visibleHalfHeight = max(halfHeight, halfWidth / cardAspectRatio, 0.006)
        let size = bounds.maximum - bounds.minimum
        let longestSide = max(size.x, size.y, size.z, 0.025)
        return CameraLayout(
            orthographicScale: visibleHalfHeight * 1.16,
            distance: max(longestSide * 3.2, 0.22))
    }

    private static func previewDirection(
        for component: WorkbenchComponentSpec?
    ) -> SIMD3<Float> {
        let raw: SIMD3<Float>
        switch component?.kind {
        case .propeller:
            // Propellers are almost planar in X/Z; a high angle reveals their
            // blade count and pitch instead of showing only a hairline edge.
            raw = SIMD3<Float>(0.50, 1.40, 0.74)
        case .landingGear:
            raw = SIMD3<Float>(0.78, 0.48, 1.12)
        case .camera:
            // The physical lens points toward +Z.
            raw = SIMD3<Float>(0.48, 0.42, 1.32)
        case .esc, .flightController, .receiver, .gps, .sensor:
            raw = SIMD3<Float>(0.66, 0.98, 1.04)
        case .battery, .payload, .servo, .motor:
            raw = SIMD3<Float>(0.74, 0.72, 1.10)
        case .none:
            raw = SIMD3<Float>(0.70, 0.82, 1.12)
        }
        return simd_normalize(raw)
    }

    private static func addLight(
        to scene: SCNScene,
        name: String,
        color: NSColor,
        intensity: CGFloat,
        position: SIMD3<Float>,
        target: SIMD3<Float>
    ) {
        let node = SCNNode()
        node.name = name
        node.light = SCNLight()
        node.light?.type = .directional
        node.light?.color = color
        node.light?.intensity = intensity
        node.light?.castsShadow = false
        node.simdPosition = position
        node.look(at: SCNVector3(target.x, target.y, target.z))
        scene.rootNode.addChildNode(node)
    }

    private static func adaptMaterials(in root: SCNNode) {
        func adapt(_ geometry: SCNGeometry?) {
            guard let geometry else { return }
            // Nodes cloned from the cache may share geometry. Give this preview
            // its own material objects so roughness changes never leak back into
            // the editor or simulation assembly.
            geometry.materials = geometry.materials.map { original in
                let material = (original.copy() as? SCNMaterial) ?? original
                material.diffuse.intensity = min(material.diffuse.intensity, 0.86)
                material.reflective.intensity = min(material.reflective.intensity, 0.24)
                material.normal.intensity = min(material.normal.intensity, 0.78)
                guard material.lightingModel != .constant else { return material }

                material.lightingModel = .physicallyBased
                material.emission.contents = NSColor.black
                let metalness = (material.metalness.contents as? NSNumber)?.floatValue ?? 0.04
                let authoredRoughness = (material.roughness.contents as? NSNumber)?.floatValue ?? 0.52
                // Tiny polished faces otherwise collapse into a single white
                // specular patch. The assembled model keeps its authored values;
                // only the UI thumbnail receives this readability floor.
                let roughnessFloor: Float = metalness > 0.45 ? 0.28 : 0.46
                material.roughness.contents = NSNumber(value: max(authoredRoughness, roughnessFloor))
                return material
            }
        }

        adapt(root.geometry)
        root.enumerateChildNodes { child, _ in adapt(child.geometry) }
    }

    private static func geometryCount(in root: SCNNode) -> Int {
        var count = root.geometry == nil ? 0 : 1
        root.enumerateChildNodes { node, _ in
            if node.geometry != nil { count += 1 }
        }
        return count
    }

    /// A low-dynamic-range studio gradient gives metals a readable reflection
    /// without adding a visible environment or a clipped rectangular softbox.
    private static let studioEnvironment: NSImage = {
        let size = NSSize(width: 96, height: 48)
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(colors: [
            NSColor(deviceRed: 0.22, green: 0.24, blue: 0.27, alpha: 1),
            NSColor(deviceRed: 0.46, green: 0.49, blue: 0.53, alpha: 1),
            NSColor(deviceRed: 0.18, green: 0.20, blue: 0.23, alpha: 1),
        ])
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: -18)
        image.unlockFocus()
        return image
    }()
}
