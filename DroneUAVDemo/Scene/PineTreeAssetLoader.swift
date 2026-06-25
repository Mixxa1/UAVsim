import SceneKit

private enum PineTreeConstants {
    static let resourceName = "Pine_Tree"
    static let resourceExtension = "usdz"
    static let nodeName = "environment.pine_tree"
}

final class PineTreeAssetLoader {
    static let shared = PineTreeAssetLoader()

    private var cachedTemplate: SCNNode?
    private var modelNativeHeight: Float = 1.0
    private var didAttemptLoad = false
    private var didWarnFailure = false

    private init() {}

    func makeTreeNode(targetHeightMeters: Float, yaw: Float) -> SCNNode? {
        guard let template = loadTemplate() else {
            warnOnce()
            return nil
        }
        let scale = targetHeightMeters / max(modelNativeHeight, 0.001)
        let node = template.clone()
        node.scale = SCNVector3(scale, scale, scale)
        node.eulerAngles = SCNVector3(0, yaw, 0)
        node.name = PineTreeConstants.nodeName
        enableShadowsRecursively(node)
        return node
    }

    private func loadTemplate() -> SCNNode? {
        if didAttemptLoad {
            return cachedTemplate
        }
        didAttemptLoad = true

        guard let url = Bundle.main.url(
            forResource: PineTreeConstants.resourceName,
            withExtension: PineTreeConstants.resourceExtension
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
        root.name = "pine_tree_template"
        for child in scene.rootNode.childNodes {
            root.addChildNode(child.clone())
        }
        enableShadowsRecursively(root)

        let (minBB, maxBB) = root.boundingBox
        let nativeHeight = Float(maxBB.y - minBB.y)
        modelNativeHeight = nativeHeight > 0.001 ? nativeHeight : 1.0
        print("[Environment] Pine_Tree.usdz loaded: nativeHeight=\(modelNativeHeight) units (bounding box)")

        cachedTemplate = root
        return root
    }

    private func warnOnce() {
        guard !didWarnFailure else { return }
        didWarnFailure = true
        print("[Environment] Pine Tree asset unavailable; using procedural tree fallback")
    }

    private func enableShadowsRecursively(_ node: SCNNode) {
        node.castsShadow = true
        node.geometry?.materials.forEach { $0.isDoubleSided = true }
        for child in node.childNodes {
            enableShadowsRecursively(child)
        }
    }
}
