import SceneKit

private enum WaterStationConstants {
    static let resourceName = "Water_Gallon"
    static let resourceExtension = "usdz"
    static let nodeName = "agri.water_station.gallon"
    static let defaultHeightMeters: Float = 1.05
}

/// Loads `Water_Gallon.usdz` — the refill point of the agricultural spraying mission.
///
/// Same contract as `ManAssetLoader`: cached template, height normalisation, origin at the base
/// so the caller places it straight on the ground, and a procedural stand-in when the asset is
/// missing (the refill mechanic must stay flyable even without art).
final class WaterStationAssetLoader {
    static let shared = WaterStationAssetLoader()

    private var cachedTemplate: SCNNode?
    private var modelNativeHeight: Float = 1.0
    private var modelNativeMinY: Float = 0.0
    private var didAttemptLoad = false
    private var didWarnFailure = false

    private init() {}

    func makeGallonNode(
        targetHeightMeters: Float = WaterStationConstants.defaultHeightMeters,
        yaw: Float = 0.0
    ) -> SCNNode {
        let height = max(0.2, targetHeightMeters)
        guard let template = loadTemplate() else {
            warnOnce()
            return makeProceduralGallon(targetHeightMeters: height, yaw: yaw)
        }

        let scale = height / max(modelNativeHeight, 0.001)
        let model = template.clone()
        model.scale = SCNVector3(scale, scale, scale)
        model.position = SCNVector3(0, -modelNativeMinY * scale, 0)

        let wrapper = SCNNode()
        wrapper.name = WaterStationConstants.nodeName
        wrapper.eulerAngles = SCNVector3(0, yaw, 0)
        wrapper.addChildNode(model)
        enableShadows(wrapper)
        return wrapper
    }

    private func loadTemplate() -> SCNNode? {
        if didAttemptLoad {
            return cachedTemplate
        }
        didAttemptLoad = true

        guard let url = Bundle.main.url(
            forResource: WaterStationConstants.resourceName,
            withExtension: WaterStationConstants.resourceExtension
        ),
        let scene = try? SCNScene(url: url, options: [
            .checkConsistency: false,
            .preserveOriginalTopology: false
        ]) else {
            return nil
        }

        let root = SCNNode()
        root.name = "water_gallon_template"
        for child in scene.rootNode.childNodes {
            root.addChildNode(child.clone())
        }

        let (minBB, maxBB) = root.boundingBox
        let nativeHeight = Float(maxBB.y - minBB.y)
        modelNativeHeight = nativeHeight > 0.001 ? nativeHeight : 1.0
        modelNativeMinY = Float(minBB.y)
        print("[Agri] Water_Gallon.usdz loaded: nativeHeight=\(modelNativeHeight) units (bounding box)")

        cachedTemplate = root
        return root
    }

    private func makeProceduralGallon(targetHeightMeters: Float, yaw: Float) -> SCNNode {
        let wrapper = SCNNode()
        wrapper.name = WaterStationConstants.nodeName
        wrapper.eulerAngles = SCNVector3(0, yaw, 0)

        let body = SCNBox(
            width: CGFloat(targetHeightMeters * 0.55),
            height: CGFloat(targetHeightMeters),
            length: CGFloat(targetHeightMeters * 0.55),
            chamferRadius: CGFloat(targetHeightMeters * 0.08)
        )
        body.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.16, green: 0.38, blue: 0.72, alpha: 1.0)
        let bodyNode = SCNNode(geometry: body)
        bodyNode.position = SCNVector3(0, targetHeightMeters * 0.5, 0)
        wrapper.addChildNode(bodyNode)
        enableShadows(wrapper)
        return wrapper
    }

    private func warnOnce() {
        guard !didWarnFailure else { return }
        didWarnFailure = true
        print("[Agri] Water gallon asset unavailable; using procedural refill-station prop")
    }

    private func enableShadows(_ node: SCNNode) {
        node.enumerateHierarchy { child, _ in
            child.castsShadow = true
        }
    }
}
