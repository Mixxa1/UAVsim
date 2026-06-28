import QuartzCore
import SceneKit
import simd

/// Render category bit reserved for thermal proxy geometry. The payload camera switches to this
/// (and only this) bit to show the thermal scene; every other camera must clear it.
enum ThermalRenderCategory {
    static let proxyBit = 1 << 8
}

/// Builds and colours a parallel set of false-colour "proxy" nodes for the environment, without
/// ever touching the real scene materials.
///
/// Each classifiable geometry node gets a **child** proxy: `geometry.copy()` (shares vertex
/// buffers — cheap) with a single `.constant`-lit `SCNMaterial` (immune to scene lighting and
/// shadows — the exact thing that used to make trunks read hot from specular highlights). The
/// proxy carries the `thermalProxy` category bit, so only the payload camera in thermal mode
/// renders it. Colour is recomputed on the CPU only when the context/palette/normalization
/// changes — never per pixel, never per frame.
final class ThermalProxyRenderer {

    private struct ProxyEntry {
        let node: SCNNode
        let materialClass: ThermalMaterialClass
        let variation: Double
        let rootName: String?
        var temperatureCelsius: Double
        var footprint: Double
        // The real model texture, desaturated to luminance — modulates the thermal colour so bark/
        // leaf/asphalt/building detail shows through. nil when the surface has no real texture
        // (e.g. the flat-colour ground) → procedural grain is used instead.
        let realTextureLuminance: NSImage?
        // Tiling for the multiply texture, derived from the real material so the thermal grain
        // sits at the right world scale (the ground tiles its texture heavily; objects don't).
        let multiplyTransform: SCNMatrix4
    }

    private weak var sceneRoot: SCNNode?
    private weak var groundNode: SCNNode?
    private weak var missionTargetNode: SCNNode?

    private var proxies: [ProxyEntry] = []
    private var proxyByID: [ObjectIdentifier: Int] = [:]   // proxy node id -> index in proxies
    private var builtRevision: UInt64 = .max
    private var builtGroundClass: ThermalMaterialClass?
    private var hasBuilt = false

    private let proxyName = "thermal.proxy"
    private let maxProxies = 5200

    // Roots that are safe to walk (never the whole scene graph — avoids camera rigs / debug /
    // UI markers / particle systems).
    private let environmentRootNames = [
        "environmentContainer",
        "environment.snowDecorations",
        "environment.abandonedCity.root"
    ]

    init(sceneRoot: SCNNode, groundNode: SCNNode) {
        self.sceneRoot = sceneRoot
        self.groundNode = groundNode
    }

    // MARK: - Lifecycle

    /// Drop all proxies; next presentation rebuilds. Call on environment/weather change.
    func invalidate() {
        for entry in proxies {
            entry.node.removeFromParentNode()
        }
        proxies.removeAll(keepingCapacity: true)
        proxyByID.removeAll(keepingCapacity: true)
        hasBuilt = false
        builtGroundClass = nil
    }

    /// Registers (or clears, when `nil`) the mission scenario's detectable target — e.g. the
    /// search-and-rescue person — so it gets a `.body`-class thermal proxy alongside the
    /// environment. Forces a rebuild so the target shows up on the next render.
    func setMissionTarget(_ node: SCNNode?) {
        missionTargetNode = node
        invalidate()
    }

    func clear() {
        invalidate()
        builtRevision = .max
    }

    // MARK: - Presentation

    /// Ensure proxies exist for the current environment, then recolour them for the given context.
    func updatePresentation(
        context: ThermalEnvironmentContext,
        palette: ThermalPalette,
        contrast: Double,
        brightness: Double,
        noiseAmount: Double,
        normalization: ThermalNormalizationState,
        groundClass: ThermalMaterialClass,
        environmentRevision: UInt64
    ) {
        ensureBuilt(groundClass: groundClass, environmentRevision: environmentRevision)
        recolor(
            context: context,
            palette: palette,
            contrast: contrast,
            brightness: brightness,
            noiseAmount: noiseAmount,
            normalization: normalization
        )
    }

    /// Population of present classes (weighted by horizontal footprint) for normalization.
    func normalizationPopulation(
        groundClass: ThermalMaterialClass,
        environmentRevision: UInt64
    ) -> [(materialClass: ThermalMaterialClass, weight: Double)] {
        ensureBuilt(groundClass: groundClass, environmentRevision: environmentRevision)
        var weights: [ThermalMaterialClass: Double] = [:]
        for entry in proxies {
            weights[entry.materialClass, default: 0.0] += entry.footprint
        }
        return weights.map { (materialClass: $0.key, weight: $0.value) }
    }

    /// Center-of-frame probe result for a hit proxy node.
    func probe(node: SCNNode) -> (materialClass: ThermalMaterialClass, temperatureCelsius: Double, name: String?)? {
        guard let index = proxyByID[ObjectIdentifier(node)] else { return nil }
        let entry = proxies[index]
        return (entry.materialClass, entry.temperatureCelsius, entry.rootName)
    }

    func isProxyNode(_ node: SCNNode) -> Bool {
        proxyByID[ObjectIdentifier(node)] != nil
    }

    // MARK: - Build

    private func ensureBuilt(groundClass: ThermalMaterialClass, environmentRevision: UInt64) {
        if hasBuilt, builtRevision == environmentRevision, builtGroundClass == groundClass {
            return
        }
        invalidate()
        builtRevision = environmentRevision
        builtGroundClass = groundClass
        #if DEBUG
        let startTime = CACurrentMediaTime()
        build(groundClass: groundClass)
        let elapsedMs = (CACurrentMediaTime() - startTime) * 1000.0
        print("[Thermal] proxy rebuild: \(proxies.count) proxies in \(String(format: "%.1f", elapsedMs)) ms")
        #else
        build(groundClass: groundClass)
        #endif
        hasBuilt = true
    }

    private func build(groundClass: ThermalMaterialClass) {
        guard let sceneRoot else { return }

        // Ground first (one big proxy).
        if let groundNode, groundNode.geometry != nil {
            addProxy(
                for: groundNode,
                materialClass: groundClass,
                rootName: "ground",
                variation: 0.0
            )
        }

        for rootName in environmentRootNames {
            guard let root = findNode(named: rootName, under: sceneRoot) else { continue }
            for objectRoot in root.childNodes {
                if proxies.count >= maxProxies { return }
                buildObject(objectRoot)
            }
        }

        if let missionTargetNode {
            var geometryNodes: [SCNNode] = []
            collectGeometryNodes(missionTargetNode, into: &geometryNodes)
            for node in geometryNodes {
                addProxy(for: node, materialClass: .body, rootName: "mission.target.person", variation: 0.0)
            }
        }
    }

    /// Build proxies for one placed object (a tree / building / rock / etc. and its sub-meshes).
    private func buildObject(_ objectRoot: SCNNode) {
        if shouldExclude(objectRoot) { return }

        // Collect geometry-bearing descendants (including the root itself).
        var geometryNodes: [SCNNode] = []
        collectGeometryNodes(objectRoot, into: &geometryNodes)
        guard !geometryNodes.isEmpty else { return }

        let baseClass = baseClassForObject(objectRoot)
        let variation = variationFromWorldPosition(objectRoot.simdWorldPosition)

        // Trunk/roof disambiguation when an object has several sub-meshes but no per-mesh names.
        var trunkNode: SCNNode?
        var roofNode: SCNNode?
        if geometryNodes.count >= 2 {
            if baseClass == .foliage {
                trunkNode = lowestNode(geometryNodes)
            } else if baseClass == .building {
                roofNode = highestNode(geometryNodes)
            }
        }

        for node in geometryNodes {
            if proxies.count >= maxProxies { return }

            var cls = ThermalSurfaceClassifier.classify(node: node, contextHint: baseClass)
            if node === trunkNode, cls == .foliage { cls = .treeTrunk }
            if node === roofNode, cls == .building { cls = .roof }
            // A sub-mesh's own node/material name wins over contextHint by design (it's how
            // trunk/roof disambiguation above works) — but that backfires when an unrelated asset
            // reuses a generic word for an internal part name. Confirmed via live diagnostics:
            // Container_18_MB.usdz's main body sub-mesh is literally named "Wall" (a real asset
            // detail, not a thermal hint), which matches the building bucket's "wall" keyword
            // before the classifier ever reaches the (correct) "container" texture-filename token
            // — reading the whole container face as ЗДАНИЕ/building instead of metal. A metal
            // container's internal "wall"/"door" part is still metal, never masonry.
            if baseClass == .metal, cls == .building { cls = .metal }

            addProxy(
                for: node,
                materialClass: cls,
                rootName: objectRoot.name,
                variation: variation
            )
        }
    }

    private func addProxy(
        for node: SCNNode,
        materialClass: ThermalMaterialClass,
        rootName: String?,
        variation: Double
    ) {
        guard let geometry = node.geometry else { return }

        // Resolve the real model texture (desaturated) BEFORE copying — gives genuine surface
        // detail. The ground's diffuse is a flat colour, so it falls back to procedural grain.
        let realDiffuse = node.geometry?.firstMaterial?.diffuse
        let realLuminance = ThermalRealTexture.luminance(for: realDiffuse)
        let transform = multiplyTransform(forRealDiffuse: realDiffuse, usesRealTexture: realLuminance != nil)

        let copy = geometry.copy() as! SCNGeometry
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.contents = NSColor.gray
        material.locksAmbientWithDiffuse = true
        copy.materials = [material]

        let proxy = SCNNode(geometry: copy)
        proxy.name = proxyName
        proxy.categoryBitMask = ThermalRenderCategory.proxyBit
        proxy.castsShadow = false
        node.addChildNode(proxy)

        let footprint = horizontalFootprint(of: node)
        let entry = ProxyEntry(
            node: proxy,
            materialClass: materialClass,
            variation: variation,
            rootName: rootName,
            temperatureCelsius: 16.0,
            footprint: footprint,
            realTextureLuminance: realLuminance,
            multiplyTransform: transform
        )
        proxyByID[ObjectIdentifier(proxy)] = proxies.count
        proxies.append(entry)
    }

    /// Tiling for the proxy multiply channel. Real textures keep the model's own UV transform.
    /// Procedural grain on a heavily-tiled surface (the ground) is scaled down from the real tile
    /// rate so the grain reads as medium patches, not invisible micro-noise.
    private func multiplyTransform(forRealDiffuse diffuse: SCNMaterialProperty?, usesRealTexture: Bool) -> SCNMatrix4 {
        let realTransform = diffuse?.contentsTransform ?? SCNMatrix4Identity
        if usesRealTexture {
            return realTransform
        }
        let scaleX = realTransform.m11
        if scaleX > 2.0 {
            let scaled = scaleX * 0.2
            return SCNMatrix4MakeScale(scaled, scaled, 1.0)
        }
        return SCNMatrix4Identity
    }

    // MARK: - Recolor

    private func recolor(
        context: ThermalEnvironmentContext,
        palette: ThermalPalette,
        contrast: Double,
        brightness: Double,
        noiseAmount: Double,
        normalization: ThermalNormalizationState
    ) {
        for index in proxies.indices {
            let entry = proxies[index]
            let temperature = ThermalMaterialModel.apparentTemperature(
                for: entry.materialClass,
                context: context,
                variation: entry.variation
            )
            proxies[index].temperatureCelsius = temperature

            let color = ThermalPaletteMapper.color(
                forTemperature: temperature,
                displayMin: normalization.displayMinCelsius,
                displayMax: normalization.displayMaxCelsius,
                palette: palette,
                contrast: contrast,
                brightness: brightness
            )

            guard let material = entry.node.geometry?.firstMaterial else { continue }
            material.diffuse.contents = color

            // Real model texture (luminance) when the surface has one, else procedural grain.
            let multiplyImage = entry.realTextureLuminance
                ?? ThermalVariationTexture.texture(for: entry.materialClass, noiseAmount: noiseAmount)
            if let multiplyImage {
                material.multiply.contents = multiplyImage
                material.multiply.contentsTransform = entry.multiplyTransform
                material.multiply.wrapS = .repeat
                material.multiply.wrapT = .repeat
                // The noise slider dials how strongly the real texture shades; procedural grain
                // already bakes the amount in, so it stays at full strength.
                material.multiply.intensity = entry.realTextureLuminance != nil
                    ? (0.45 + 0.55 * min(1.0, max(0.0, noiseAmount)))
                    : 1.0
            } else {
                material.multiply.contents = nil
            }
        }
    }

    // MARK: - Classification helpers

    private func baseClassForObject(_ node: SCNNode) -> ThermalMaterialClass {
        if let forced = ThermalSurfaceClassifier.override(for: node) { return forced }
        if let name = node.name, let cls = ThermalSurfaceClassifier.classifyToken(name) {
            return cls
        }
        return ThermalSurfaceClassifier.classify(node: node, contextHint: .generic)
    }

    private func collectGeometryNodes(_ node: SCNNode, into result: inout [SCNNode]) {
        if shouldExclude(node) { return }
        if node.geometry != nil, node.name != proxyName {
            result.append(node)
        }
        for child in node.childNodes {
            collectGeometryNodes(child, into: &result)
        }
    }

    private func shouldExclude(_ node: SCNNode) -> Bool {
        if node.name == proxyName { return true }
        guard let name = node.name?.lowercased() else { return false }
        let blocked = ["collision", "collider", "placeholder_hidden", "debug", "_proxy", "boundary_signal", "capture_sphere"]
        return blocked.contains { name.contains($0) }
    }

    // MARK: - Geometry helpers

    private func lowestNode(_ nodes: [SCNNode]) -> SCNNode? {
        nodes.min { centerY($0) < centerY($1) }
    }

    private func highestNode(_ nodes: [SCNNode]) -> SCNNode? {
        nodes.max { centerY($0) < centerY($1) }
    }

    /// World-space Y of the node's own anchor point. Deliberately avoids `node.boundingBox`:
    /// on a dense city building (hundreds of sub-meshes per asset), calling it this many times
    /// synchronously while the live SCNView is concurrently rendering the same scene graph hits
    /// severe contention on an internal SceneKit lock — confirmed live via Xcode's debugger, the
    /// thread sat in `__psynch_mutexwait` inside `SCNBoundingVolume.boundingBox.getter` indefinitely
    /// on the city map. `simdWorldPosition` is pure transform-chain math (no bounding-volume
    /// computation, no lock) and is already used elsewhere in this file without issue. It isn't the
    /// exact mesh center, but for "which sibling sits lowest/highest" disambiguation, each sub-
    /// mesh's own anchor ordering matches its visual position closely enough.
    private func centerY(_ node: SCNNode) -> Float {
        node.simdWorldPosition.y
    }

    /// Coarse population weight, intentionally NOT area-accurate — see `centerY`'s note on why
    /// `node.boundingBox` is unsafe to call this many times here. A flat per-proxy weight still
    /// lets denser classes (more sub-meshes) dominate the percentile appropriately.
    private func horizontalFootprint(of node: SCNNode) -> Double {
        1.0
    }

    private func variationFromWorldPosition(_ position: SIMD3<Float>) -> Double {
        let xi = Int64((Double(position.x) * 3.137).rounded())
        let zi = Int64((Double(position.z) * 2.917).rounded())
        var h = UInt64(bitPattern: xi &* 0x9E37_79B9 &+ zi &* 0x85EB_CA77)
        h ^= h >> 29
        h = h &* 0xBF58_476D_1CE4_E5B9
        h ^= h >> 32
        // 0...1 -> -1...1
        return (Double(h >> 11) * (1.0 / 9_007_199_254_740_992.0)) * 2.0 - 1.0
    }

    private func findNode(named name: String, under root: SCNNode) -> SCNNode? {
        if root.name == name { return root }
        for child in root.childNodes {
            if let found = findNode(named: name, under: child) {
                return found
            }
        }
        return nil
    }
}
