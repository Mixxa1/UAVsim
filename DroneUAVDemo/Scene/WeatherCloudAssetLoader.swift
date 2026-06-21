import SceneKit
import AppKit

private enum WeatherCloudConstants {
    static let skyCloudsResourceName = "Dubai_Clouds"
    // Fluffy_Cloud.usdz and Evanescent_Smoke.usdz were both tried as the fog/smog "envelope"
    // (a scaled-up volume the drone flies inside) and both failed for reasons specific to how
    // they were authored, not anything fixable by tuning opacity/material settings:
    //  - Evanescent_Smoke has no textures at all — just a few large, ~4%-opaque torus/cube
    //    outlines (a "volumetric" asset meant for a raymarched renderer). Verified by dumping
    //    every material's diffuse/transparent/emission content and rendering it both from
    //    outside and from inside via offscreen SCNRenderer snapshots — never reads as smoke.
    //  - Fluffy_Cloud has real texture and reads fine as a *cloud viewed from outside*, but its
    //    dense material is concentrated in a flat horizontal band (it's modeled to be viewed
    //    from below/the side, not stood inside of), so as an envelope it produced a sharp
    //    horizontal haze/clear boundary instead of surrounding the camera — and its 3 stacked
    //    ~450-tri duplicate layers (faking volume the same overlapping-translucency way) were
    //    the main FPS cost, which survived several rounds of opacity/layer-count tuning.
    // The envelope is a plain procedural SCNSphere instead — perfectly uniform in every
    // direction by construction, one shading pass instead of three, no USDZ load at all.
    static let resourceExtension = "usdz"
    static let modelSubdirectory = "Models/Environment/Weather"
    static let lightningResourceName = "3_Pack_of_Storm_Lightning"
    // The pack's 3 bolt variants are named th_bolt_0 / th_bolt_001_1 / th_bolt_002_2 in the
    // source file (confirmed by dumping the usdz's node hierarchy directly) — matching by prefix
    // finds all 3 regardless of the exact suffix.
    static let lightningBoltNamePrefix = "th_bolt"
}

/// Loads the sky-decoration cloud cluster (Dubai_Clouds) and builds the procedural fog/smog
/// "envelope" spheres that get scaled up around the drone so weather reads as ambient haze
/// the drone flies inside of, rather than a single floating cloud.
final class WeatherCloudAssetLoader {
    static let shared = WeatherCloudAssetLoader()

    private struct Template {
        let node: SCNNode
        let boundingRadius: Float
    }

    private struct LightningBoltTemplate {
        let node: SCNNode
        let nativeHeight: Float
    }

    private var cachedTemplates: [String: Template] = [:]
    private var attemptedNames: Set<String> = []
    private var warnedNames: Set<String> = []
    private var lightningBoltTemplates: [LightningBoltTemplate]?
    private var lightningLoadAttempted = false

    private init() {}

    /// `targetRadius` shrinks the cluster (native bounding radius ~1522 units) so its farthest
    /// cards stay inside the camera's `zFar` — at native scale, several of the 6 cards already
    /// sit beyond any reasonable draw distance and either never render or get hard-clipped
    /// mid-card by the far plane, which reads as a sharp "edge" cutting the cloud off.
    func makeSkyCloudsNode(offset: SCNVector3 = SCNVector3(0, 0, 0), yaw: Float = 0, targetRadius: Float? = nil) -> SCNNode? {
        guard let node = makeNode(named: WeatherCloudConstants.skyCloudsResourceName, nodeName: "weather.sky_clouds") else {
            return nil
        }
        applySkyCloudBillboarding(node)
        if let targetRadius {
            scaleToTemplateRadius(node, named: WeatherCloudConstants.skyCloudsResourceName, targetRadius: targetRadius)
        }
        node.position = offset
        node.eulerAngles = SCNVector3(0, yaw, 0)
        return node
    }

    private static let fogTintColor = NSColor(calibratedRed: 0.80, green: 0.82, blue: 0.85, alpha: 1.0)
    private static let smogTintColor = NSColor(calibratedRed: 0.40, green: 0.38, blue: 0.33, alpha: 1.0)

    /// Reuses the same Dubai_Clouds geometry/billboarding/zFar-safe scaling as the regular sky
    /// decoration, just tinted dark for thunderclouds. `tintColor`/`opacity` differ per call so
    /// several instances can read as "varying density" (some lighter/thinner, some near-black
    /// and dense) rather than one uniform grey sky. Deep-copies materials before tinting —
    /// `node.clone()` shares the cached template's actual `SCNMaterial` instances, so without
    /// this every other clone of Dubai_Clouds (including the plain, untinted sky decoration)
    /// would pick up whatever tint was set here too. That exact bug already happened once with
    /// the fog/smog envelope sharing Fluffy_Cloud's material (see project memory) — not repeating
    /// it here now that Dubai_Clouds is shared between two different visual roles.
    func makeStormCloudNode(offset: SCNVector3, yaw: Float, targetRadius: Float, tintColor: NSColor, opacity: Float) -> SCNNode? {
        guard let node = makeNode(named: WeatherCloudConstants.skyCloudsResourceName, nodeName: "weather.storm_cloud") else {
            return nil
        }
        applySkyCloudBillboarding(node)
        deepCopyMaterials(node)
        applyTint(node, color: tintColor)
        scaleToTemplateRadius(node, named: WeatherCloudConstants.skyCloudsResourceName, targetRadius: targetRadius)
        node.position = offset
        node.eulerAngles = SCNVector3(0, yaw, 0)
        node.opacity = CGFloat(opacity)
        return node
    }

    private func deepCopyMaterials(_ node: SCNNode) {
        if let geometry = node.geometry, let geometryCopy = geometry.copy() as? SCNGeometry {
            geometryCopy.materials = geometry.materials.map { $0.copy() as! SCNMaterial }
            node.geometry = geometryCopy
        }
        for child in node.childNodes {
            deepCopyMaterials(child)
        }
    }

    private func applyTint(_ node: SCNNode, color: NSColor) {
        if let geometry = node.geometry {
            for material in geometry.materials {
                material.multiply.contents = color
            }
        }
        for child in node.childNodes {
            applyTint(child, color: color)
        }
    }

    /// Picks a random one of the pack's 3 bolt variants and scales it (non-uniformly — see
    /// `horizontalScaleFactor`) so its native ~4.5-unit height matches `targetHeight`. Materials
    /// are shared across clones (no per-instance tint/deep-copy, unlike `makeStormCloudNode`)
    /// since every strike should look like the same glowing bolt, just placed and sized
    /// differently — there's no per-instance visual property that needs isolating here.
    func makeLightningBoltNode(targetHeight: Float, horizontalScaleFactor: Float = 0.55) -> SCNNode? {
        guard let templates = loadLightningBoltTemplates(), let chosen = templates.randomElement() else {
            warnOnce(WeatherCloudConstants.lightningResourceName)
            return nil
        }
        let node = chosen.node.clone()
        node.name = "weather.lightning_bolt"
        let verticalScale = CGFloat(targetHeight / chosen.nativeHeight)
        node.scale = SCNVector3(verticalScale * CGFloat(horizontalScaleFactor), verticalScale, verticalScale * CGFloat(horizontalScaleFactor))
        return node
    }

    /// Each `th_bolt_*` node's own geometry already sits with its base near local Y=0 and its
    /// tip near local Y=nativeHeight (confirmed by dumping the asset's per-node bounding boxes
    /// directly) — so cloning just that node, without recentering, places the bolt's base at
    /// whatever world position the caller assigns and lets it extend straight upward from there.
    private func loadLightningBoltTemplates() -> [LightningBoltTemplate]? {
        if let cached = lightningBoltTemplates {
            return cached
        }
        if lightningLoadAttempted {
            return nil
        }
        lightningLoadAttempted = true

        guard let url = bundleURL(resourceName: WeatherCloudConstants.lightningResourceName) else {
            return nil
        }
        guard let scene = try? SCNScene(url: url, options: [
            .checkConsistency: false,
            .preserveOriginalTopology: false
        ]) else {
            return nil
        }

        let boltNodes = lightningBoltWrapperNodes(in: scene.rootNode)
        guard !boltNodes.isEmpty else {
            return nil
        }

        let templates = boltNodes.map { boltNode -> LightningBoltTemplate in
            let detached = boltNode.clone()
            sanitize(detached)
            let (minBB, maxBB) = detached.boundingBox
            let height = max(0.001, Float(maxBB.y - minBB.y))
            return LightningBoltTemplate(node: detached, nativeHeight: height)
        }
        lightningBoltTemplates = templates
        return templates
    }

    private func lightningBoltWrapperNodes(in node: SCNNode) -> [SCNNode] {
        if let name = node.name, name.hasPrefix(WeatherCloudConstants.lightningBoltNamePrefix) {
            return [node]
        }
        var result: [SCNNode] = []
        for child in node.childNodes {
            result.append(contentsOf: lightningBoltWrapperNodes(in: child))
        }
        return result
    }

    func makeFogEnvelopeNode(targetRadius: Float) -> SCNNode? {
        makeEnvelopeSphere(radius: targetRadius, tint: Self.fogTintColor, name: "weather.fog_envelope")
    }

    func makeSmogEnvelopeNode(targetRadius: Float) -> SCNNode? {
        makeEnvelopeSphere(radius: targetRadius, tint: Self.smogTintColor, name: "weather.smog_envelope")
    }

    /// A perfectly uniform sphere centered on the drone reads the same in every direction by
    /// construction — no horizontal-only bias, no overlapping duplicate layers to shade. Single
    /// sided (`cullMode = .front`, the camera is always inside this radius) at `.constant`
    /// lighting, which is safe here only because this is a fresh flat-color material with no
    /// PBR-dependent alpha behavior to break (that's what made `.constant` invisible on
    /// Fluffy_Cloud's own material — verified that failure doesn't reproduce on a plain
    /// material via an isolated offscreen render before relying on it here).
    private func makeEnvelopeSphere(radius: Float, tint: NSColor, name: String) -> SCNNode {
        let sphere = SCNSphere(radius: CGFloat(radius))
        let material = SCNMaterial()
        material.diffuse.contents = tint
        material.lightingModel = .constant
        material.writesToDepthBuffer = false
        material.isDoubleSided = false
        material.cullMode = .front
        sphere.materials = [material]
        sphere.firstMaterial?.readsFromDepthBuffer = true

        let node = SCNNode(geometry: sphere)
        node.name = name
        node.castsShadow = false
        return node
    }

    private func scaleToTemplateRadius(_ node: SCNNode, named resourceName: String, targetRadius: Float) {
        guard let template = cachedTemplates[resourceName] else { return }
        let scale = CGFloat(targetRadius / template.boundingRadius)
        node.scale = SCNVector3(scale, scale, scale)
    }

    private func makeNode(named resourceName: String, nodeName: String) -> SCNNode? {
        guard let template = loadTemplate(named: resourceName) else {
            warnOnce(resourceName)
            return nil
        }
        let node = template.node.clone()
        node.name = nodeName
        return node
    }

    /// Builds `root -> centered(-modelCenter) -> [original children]` so the model's own
    /// centroid sits at `root`'s local origin. Because the recenter offset lives on a *child*
    /// of root, it scales correctly along with whatever `root.scale` the caller applies later —
    /// recentering directly on root itself would not, since a node's own position is translation
    /// applied after its own scale, not affected by it.
    private func loadTemplate(named resourceName: String) -> Template? {
        if let cached = cachedTemplates[resourceName] {
            return cached
        }
        if attemptedNames.contains(resourceName) {
            return nil
        }
        attemptedNames.insert(resourceName)

        guard let url = bundleURL(resourceName: resourceName) else {
            return nil
        }

        guard let scene = try? SCNScene(url: url, options: [
            .checkConsistency: false,
            .preserveOriginalTopology: false
        ]) else {
            return nil
        }

        let centered = SCNNode()
        centered.name = "\(resourceName)_centered"
        for child in scene.rootNode.childNodes {
            centered.addChildNode(child.clone())
        }
        sanitize(centered)

        let (minBB, maxBB) = centered.boundingBox
        let size = SCNVector3(maxBB.x - minBB.x, maxBB.y - minBB.y, maxBB.z - minBB.z)
        guard Float(size.x).isFinite, Float(size.y).isFinite, Float(size.z).isFinite else {
            return nil
        }
        let radius = Float(max(size.x, max(size.y, size.z))) * 0.5
        let center = SCNVector3((minBB.x + maxBB.x) * 0.5, (minBB.y + maxBB.y) * 0.5, (minBB.z + maxBB.z) * 0.5)
        centered.position = SCNVector3(-center.x, -center.y, -center.z)

        let root = SCNNode()
        root.name = "\(resourceName)_template"
        root.addChildNode(centered)

        let template = Template(node: root, boundingRadius: radius > 0.001 ? radius : 1.0)
        cachedTemplates[resourceName] = template
        return template
    }

    private func sanitize(_ node: SCNNode) {
        node.physicsBody = nil
        node.camera = nil
        node.light = nil
        node.castsShadow = false
        node.particleSystems?.forEach { node.removeParticleSystem($0) }
        for child in node.childNodes {
            sanitize(child)
        }
    }

    /// Each `cloud_NN` in Dubai_Clouds is a flat, fixed-orientation card authored to be viewed
    /// from roughly one direction. With no billboarding, turning or tilting the drone eventually
    /// lines the view up edge-on with a card, where its soft alpha-faded silhouette degenerates
    /// into a hard, near-invisible thin line (the texture itself fades cleanly — confirmed by
    /// extracting its alpha channel — the cutoff only appears edge-on). A free-axes billboard
    /// keeps every card facing the camera from any angle, including pitch (looking up/down at a
    /// cloud), not just yaw — a Y-only billboard left pitch-angle edge-on views unfixed, which is
    /// what was still showing a hard edge.
    ///
    /// The `cloud_NN` nodes sit several levels deep under USDZ import wrapper groups (scene ->
    /// Meshes -> Sketchfab_model -> ... -> RootNode -> cloud_01..cloud_06), not as direct children
    /// of the recenter wrapper — billboarding the wrong (outer) node previously rotated the whole
    /// ~3km cluster as one rigid body, which could swing enough of its bulk around the camera to
    /// look like a dark dome. Matching by the exact `cloud_NN` name finds the real per-cloud nodes
    /// regardless of import wrapper depth.
    private func applySkyCloudBillboarding(_ node: SCNNode) {
        for cloud in cloudWrapperNodes(in: node) {
            let billboard = SCNBillboardConstraint()
            cloud.constraints = [billboard]
        }
    }

    private func cloudWrapperNodes(in node: SCNNode) -> [SCNNode] {
        var result: [SCNNode] = []
        if let name = node.name, isCloudWrapperName(name) {
            result.append(node)
            return result
        }
        for child in node.childNodes {
            result.append(contentsOf: cloudWrapperNodes(in: child))
        }
        return result
    }

    private func isCloudWrapperName(_ name: String) -> Bool {
        guard name.hasPrefix("cloud_") else { return false }
        let suffix = name.dropFirst("cloud_".count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    private func bundleURL(resourceName: String) -> URL? {
        Bundle.main.url(
            forResource: resourceName,
            withExtension: WeatherCloudConstants.resourceExtension,
            subdirectory: WeatherCloudConstants.modelSubdirectory
        ) ?? Bundle.main.url(
            forResource: resourceName,
            withExtension: WeatherCloudConstants.resourceExtension
        )
    }

    private func warnOnce(_ resourceName: String) {
        guard !warnedNames.contains(resourceName) else { return }
        warnedNames.insert(resourceName)
        print("[Weather] \(resourceName).usdz unavailable; cloud/smog visual skipped")
    }
}
