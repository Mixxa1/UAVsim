import SceneKit

private enum ManAssetConstants {
    static let resourceName = "Man"
    static let resourceExtension = "usdz"
    static let nodeName = "scenario.person"
    static let defaultHeightMeters: Float = 1.8
}

/// Loads `Man.usdz` for mission scenarios (search-and-rescue target).
/// Mirrors `PineTreeAssetLoader`: lazy-cached template, height normalization,
/// graceful procedural fallback when the asset is missing.
///
/// The returned node's origin sits at the figure's feet (ground level), so callers
/// place it directly at the ground position without computing a vertical offset.
final class ManAssetLoader {
    static let shared = ManAssetLoader()

    private var cachedTemplate: SCNNode?
    private var modelNativeHeight: Float = 1.0
    private var modelNativeMinY: Float = 0.0
    private var didAttemptLoad = false
    private var didWarnFailure = false

    private init() {}

    func makePersonNode(
        targetHeightMeters: Float = ManAssetConstants.defaultHeightMeters,
        yaw: Float = 0.0
    ) -> SCNNode {
        let height = max(0.3, targetHeightMeters)
        guard let template = loadTemplate() else {
            warnOnce()
            return makeProceduralPerson(targetHeightMeters: height, yaw: yaw)
        }

        let scale = height / max(modelNativeHeight, 0.001)
        let model = template.clone()
        model.scale = SCNVector3(scale, scale, scale)
        // Lift the scaled model so its lowest point (feet) sits on the wrapper origin.
        model.position = SCNVector3(0, -modelNativeMinY * scale, 0)

        let wrapper = SCNNode()
        wrapper.name = ManAssetConstants.nodeName
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
            forResource: ManAssetConstants.resourceName,
            withExtension: ManAssetConstants.resourceExtension
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
        root.name = "man_template"
        for child in scene.rootNode.childNodes {
            root.addChildNode(child.clone())
        }
        enableShadowsRecursively(root)

        let (minBB, maxBB) = root.boundingBox
        let nativeHeight = Float(maxBB.y - minBB.y)
        modelNativeHeight = nativeHeight > 0.001 ? nativeHeight : 1.0
        modelNativeMinY = Float(minBB.y)
        print("[Scenario] Man.usdz loaded: nativeHeight=\(modelNativeHeight) units (bounding box)")

        cachedTemplate = root
        return root
    }

    /// Minimal stand-in so a scenario still has a visible, detectable target when the
    /// USDZ asset is unavailable (keeps detection/raycast logic exercisable).
    private func makeProceduralPerson(targetHeightMeters: Float, yaw: Float) -> SCNNode {
        let wrapper = SCNNode()
        wrapper.name = ManAssetConstants.nodeName
        wrapper.eulerAngles = SCNVector3(0, yaw, 0)

        let bodyHeight = targetHeightMeters * 0.62
        let body = SCNCapsule(capRadius: CGFloat(targetHeightMeters * 0.13), height: CGFloat(bodyHeight))
        body.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.78, green: 0.34, blue: 0.22, alpha: 1.0)
        let bodyNode = SCNNode(geometry: body)
        bodyNode.position = SCNVector3(0, targetHeightMeters * 0.40, 0)

        let head = SCNSphere(radius: CGFloat(targetHeightMeters * 0.12))
        head.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.86, green: 0.66, blue: 0.52, alpha: 1.0)
        let headNode = SCNNode(geometry: head)
        headNode.position = SCNVector3(0, targetHeightMeters * 0.84, 0)

        wrapper.addChildNode(bodyNode)
        wrapper.addChildNode(headNode)
        enableShadowsRecursively(wrapper)
        return wrapper
    }

    private func warnOnce() {
        guard !didWarnFailure else { return }
        didWarnFailure = true
        print("[Scenario] Man asset unavailable; using procedural person fallback")
    }

    private func enableShadowsRecursively(_ node: SCNNode) {
        node.castsShadow = true
        node.geometry?.materials.forEach { $0.isDoubleSided = true }
        for child in node.childNodes {
            enableShadowsRecursively(child)
        }
    }
}
