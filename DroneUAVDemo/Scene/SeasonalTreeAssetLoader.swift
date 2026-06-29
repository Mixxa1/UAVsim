import SceneKit

enum SeasonalTreeVisualKind {
    case regularPine
    case snowBlueSpruce
}

final class SeasonalTreeAssetLoader {
    static let shared = SeasonalTreeAssetLoader()

    private var cachedSpruceTemplate: SCNNode?
    private var spruceNativeHeight: Float = 1.0
    // Local-space Y of the mesh bottom (unscaled). Negative when the base is below local origin.
    private var spruceBaseY: Float = 0.0
    private var didAttemptSpruceLoad = false
    private var didWarnSpruceFailure = false

    private init() {}

    func makeTreeNode(
        kind: SeasonalTreeVisualKind,
        targetHeightMeters: Float,
        yaw: Float
    ) -> SCNNode? {
        switch kind {
        case .regularPine:
            return PineTreeAssetLoader.shared.makeTreeNode(
                targetHeightMeters: targetHeightMeters,
                yaw: yaw
            )
        case .snowBlueSpruce:
            return makeSpruceNode(targetHeightMeters: targetHeightMeters, yaw: yaw)
        }
    }

    private func makeSpruceNode(targetHeightMeters: Float, yaw: Float) -> SCNNode? {
        guard let template = loadSpruceTemplate() else {
            warnOnce()
            return nil
        }

        let height = spruceNativeHeight > 0.001 ? spruceNativeHeight : 1.0
        let scale = Float(targetHeightMeters / height)

        // Wrap in a pivot so EnvironmentObjectFactory can set pivot.position = groundPos
        // while the inner mesh is lifted by –baseY×scale, placing its bottom exactly at y=0.
        let inner = template.clone()
        inner.scale = SCNVector3(CGFloat(scale), CGFloat(scale), CGFloat(scale))
        inner.eulerAngles = SCNVector3(0, yaw, 0)
        inner.position.y = CGFloat(-spruceBaseY * scale)

        let pivot = SCNNode()
        pivot.name = "environment.snow_blue_spruce"
        pivot.addChildNode(inner)
        enableShadowsRecursively(pivot)
        return pivot
    }

    private func loadSpruceTemplate() -> SCNNode? {
        if didAttemptSpruceLoad { return cachedSpruceTemplate }
        didAttemptSpruceLoad = true

        guard let url = Bundle.main.url(
            forResource: "Colorado_Blue_Spruce_Koster",
            withExtension: "usdz"
        ),
        let scene = try? SCNScene(url: url, options: [
            .checkConsistency: false,
            .preserveOriginalTopology: false
        ]) else {
            print("[Environment] Colorado_Blue_Spruce_Koster.usdz not found; spruce will fall back to pine")
            return nil
        }

        let root = SCNNode()
        root.name = "spruce_template"
        for child in scene.rootNode.childNodes {
            root.addChildNode(child.clone())
        }
        enableShadowsRecursively(root)

        let (minBB, maxBB) = root.boundingBox
        let h = Float(maxBB.y - minBB.y)
        spruceNativeHeight = h > 0.001 ? h : 1.0
        spruceBaseY = Float(minBB.y)
        print("[Environment] Colorado_Blue_Spruce_Koster.usdz loaded: nativeHeight=\(spruceNativeHeight) baseY=\(spruceBaseY)")

        cachedSpruceTemplate = root
        return root
    }

    private func warnOnce() {
        guard !didWarnSpruceFailure else { return }
        didWarnSpruceFailure = true
        print("[Environment] Blue Spruce asset unavailable; no snow tree will be placed")
    }

    private func enableShadowsRecursively(_ node: SCNNode) {
        node.castsShadow = true
        // Single-sided foliage: forcing isDoubleSided=true rendered both faces of every (often
        // alpha-tested, overlapping) foliage surface — ~2x the fragment/fill work per tree, the
        // dominant constant GPU/overdraw cost at the current 3000-tree forest density (and the
        // reason removing shadows changed nothing — fill, not the shadow pass, was the heat). The
        // canopy is viewed from outside, so back-faces add cost without adding visible cover.
        node.geometry?.materials.forEach { $0.isDoubleSided = false }
        for child in node.childNodes {
            enableShadowsRecursively(child)
        }
    }
}
