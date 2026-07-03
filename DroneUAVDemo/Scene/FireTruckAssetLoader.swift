import SceneKit

private enum FireTruckAssetConstants {
    static let resourceName = "Fire_Truck"
    static let resourceExtension = "usdz"
    static let nodeName = "scenario.fire_truck"
    static let defaultHeightMeters: Float = 3.0
}

/// Loads `Fire_Truck.usdz` as a static, purely decorative ground prop for the fire-response
/// scenario (parked near the fire zone — it has no hose/nozzle rigging, the UAV carries the
/// actual hose payload). Mirrors `ManAssetLoader`/`PineTreeAssetLoader`: lazy-cached template,
/// height normalization, graceful procedural fallback when the asset is missing.
final class FireTruckAssetLoader {
    static let shared = FireTruckAssetLoader()

    private var cachedTemplate: SCNNode?
    private var modelNativeHeight: Float = 1.0
    private var modelNativeMinY: Float = 0.0
    private var didAttemptLoad = false
    private var didWarnFailure = false

    private init() {}

    func makeTruckNode(
        targetHeightMeters: Float = FireTruckAssetConstants.defaultHeightMeters,
        yaw: Float = 0.0
    ) -> SCNNode {
        let height = max(0.5, targetHeightMeters)
        guard let template = loadTemplate() else {
            warnOnce()
            return makeProceduralTruck(targetHeightMeters: height, yaw: yaw)
        }

        let scale = height / max(modelNativeHeight, 0.001)
        let model = template.clone()
        model.scale = SCNVector3(scale, scale, scale)
        model.position = SCNVector3(0, -modelNativeMinY * scale, 0)

        let wrapper = SCNNode()
        wrapper.name = FireTruckAssetConstants.nodeName
        wrapper.eulerAngles = SCNVector3(0, yaw, 0)
        wrapper.addChildNode(model)
        enableShadowsRecursively(wrapper)
        return wrapper
    }

    private func loadTemplate() -> SCNNode? {
        if didAttemptLoad {
            return cachedTemplate
        }
        didAttemptLoad = true

        guard let url = Bundle.main.url(
            forResource: FireTruckAssetConstants.resourceName,
            withExtension: FireTruckAssetConstants.resourceExtension
        ) else {
            return nil
        }

        guard let scene = try? SCNScene(url: url, options: [
            .checkConsistency: false,
            .preserveOriginalTopology: false
        ]) else {
            return nil
        }

        let root = SCNNode()
        root.name = "fire_truck_template"
        for child in scene.rootNode.childNodes {
            root.addChildNode(child.clone())
        }
        enableShadowsRecursively(root)

        let (minBB, maxBB) = root.boundingBox
        let nativeHeight = Float(maxBB.y - minBB.y)
        modelNativeHeight = nativeHeight > 0.001 ? nativeHeight : 1.0
        modelNativeMinY = Float(minBB.y)
        print("[Scenario] Fire_Truck.usdz loaded: nativeHeight=\(modelNativeHeight) units (bounding box)")

        cachedTemplate = root
        return root
    }

    /// Minimal stand-in so the fire zone still reads as "responded to" when the USDZ asset is
    /// unavailable — a plain red box body on four dark wheels, purely cosmetic.
    private func makeProceduralTruck(targetHeightMeters: Float, yaw: Float) -> SCNNode {
        let wrapper = SCNNode()
        wrapper.name = FireTruckAssetConstants.nodeName
        wrapper.eulerAngles = SCNVector3(0, yaw, 0)

        let bodyMaterial = SCNMaterial()
        bodyMaterial.diffuse.contents = NSColor(calibratedRed: 0.72, green: 0.10, blue: 0.08, alpha: 1.0)
        bodyMaterial.roughness.contents = 0.5

        let bodyHeight = targetHeightMeters * 0.55
        let body = SCNBox(
            width: CGFloat(targetHeightMeters * 1.9),
            height: CGFloat(bodyHeight),
            length: CGFloat(targetHeightMeters * 0.75),
            chamferRadius: 0.05
        )
        body.firstMaterial = bodyMaterial
        let bodyNode = SCNNode(geometry: body)
        bodyNode.position = SCNVector3(0, targetHeightMeters * 0.32, 0)
        wrapper.addChildNode(bodyNode)

        let wheelMaterial = SCNMaterial()
        wheelMaterial.diffuse.contents = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        let wheelRadius = targetHeightMeters * 0.14
        for xSign: Float in [-1.0, 1.0] {
            for zOffset: Float in [-0.65, 0.65] {
                let wheel = SCNCylinder(radius: CGFloat(wheelRadius), height: CGFloat(wheelRadius * 0.5))
                wheel.firstMaterial = wheelMaterial
                let wheelNode = SCNNode(geometry: wheel)
                wheelNode.eulerAngles = SCNVector3(0, 0, Float.pi / 2.0)
                wheelNode.position = SCNVector3(
                    xSign * targetHeightMeters * 0.95,
                    wheelRadius,
                    zOffset * targetHeightMeters * 0.6
                )
                wrapper.addChildNode(wheelNode)
            }
        }

        enableShadowsRecursively(wrapper)
        return wrapper
    }

    private func warnOnce() {
        guard !didWarnFailure else { return }
        didWarnFailure = true
        print("[Scenario] Fire_Truck asset unavailable; using procedural truck fallback")
    }

    private func enableShadowsRecursively(_ node: SCNNode) {
        node.castsShadow = true
        for child in node.childNodes {
            enableShadowsRecursively(child)
        }
    }
}
