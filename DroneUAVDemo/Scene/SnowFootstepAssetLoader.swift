import SceneKit

final class SnowFootstepAssetLoader {
    static let shared = SnowFootstepAssetLoader()

    // XZ footprint of the raw asset (max of width/depth) in scene units
    private(set) var naturalFootprint: Float = 1.0
    private var cachedTemplate: SCNNode?
    private var didAttemptLoad = false

    private init() {}

    // scale is a world-space multiplier applied on top of size-normalization inside buildSnowDecorations.
    func makeFootstepNode(scale: Float = 1.0, yaw: Float = 0.0) -> SCNNode? {
        guard let template = loadTemplate() else { return nil }

        let s = CGFloat(scale)
        let node = template.clone()
        node.name = "environment.snow_footstep"
        node.scale = SCNVector3(s, s, s)
        node.eulerAngles = SCNVector3(0, yaw, 0)
        node.position.y = 0.0
        return node
    }

    private func loadTemplate() -> SCNNode? {
        if didAttemptLoad { return cachedTemplate }
        didAttemptLoad = true

        guard let url = Bundle.main.url(
            forResource: "Snow_foot_step",
            withExtension: "usdz"
        ),
        let scene = try? SCNScene(url: url, options: [
            .checkConsistency: false,
            .preserveOriginalTopology: false
        ]) else {
            print("[Environment] Snow_foot_step.usdz not found; snow footsteps will be skipped")
            return nil
        }

        let root = SCNNode()
        root.name = "snow_footstep_template"
        for child in scene.rootNode.childNodes {
            root.addChildNode(child.clone())
        }

        let (minBB, maxBB) = root.boundingBox
        let w = Float(maxBB.x - minBB.x)
        let d = Float(maxBB.z - minBB.z)
        let footprint = max(w, d)
        naturalFootprint = footprint > 0.001 ? footprint : 1.0
        print("[Environment] Snow_foot_step.usdz loaded: footprint=\(naturalFootprint) units")

        cachedTemplate = root
        return root
    }
}
