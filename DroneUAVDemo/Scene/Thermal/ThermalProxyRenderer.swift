import QuartzCore
import SceneKit
import simd

/// Render category bit reserved for thermal proxy geometry. The payload camera switches to this
/// (and only this) bit to show the thermal scene; every other camera must clear it.
enum ThermalRenderCategory {
    // Bit 8 belongs to the LiDAR point cloud; the thermal scene needs its own channel.
    static let proxyBit = 1 << 15
}

/// Builds and colours a parallel set of false-colour "proxy" nodes for the environment, without
/// ever touching the real scene materials.
///
/// Proxy geometry shares vertex buffers and is visible only to the thermal camera. Imported
/// surfaces retain their material slots and GPU imagery; discovery/construction is incremental.
final class ThermalProxyRenderer {

    private final class ProxyEntry {
        let node: SCNNode
        let materialClasses: [ThermalMaterialClass]
        let population: [ThermalMaterialClass: Double]
        let rootName: String?
        weak var source: SCNNode?
        let sourceID: ObjectIdentifier
        let importedMaterialKeys: [ThermalImportedSurfaceMaterials.Key]
        let isImported: Bool

        init(node: SCNNode, source: SCNNode,
             materialClasses: [ThermalMaterialClass], population: [ThermalMaterialClass: Double], rootName: String?,
             importedMaterialKeys: [ThermalImportedSurfaceMaterials.Key], isImported: Bool) {
            self.node = node
            self.source = source
            self.sourceID = ObjectIdentifier(source)
            self.materialClasses = materialClasses
            self.population = population
            self.rootName = rootName
            self.importedMaterialKeys = importedMaterialKeys
            self.isImported = isImported
        }
    }

    private weak var sceneRoot: SCNNode?
    private weak var groundNode: SCNNode?
    private weak var missionTargetNode: SCNNode?

    private var proxies: [ProxyEntry] = []
    private var proxyByID: [ObjectIdentifier: ProxyEntry] = [:]
    private var populationWeights: [ThermalMaterialClass: Double] = [:]
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
        "environment.abandonedCity.root",
        "environment.charge-damage"
    ]
    private weak var importedRoot: SCNNode?
    private var importedGeometryIDs: Set<ObjectIdentifier> = []
    private var importedTraversal: [SCNNode] = []
    private var lastImportedScan: CFTimeInterval = -.infinity
    private var pruneCursor = 0
    private let importedMaterials = ThermalImportedSurfaceMaterials()
    private var lastPresentation: Presentation?

    private struct Presentation: Equatable {
        let context: ThermalEnvironmentContext
        let palette: ThermalPalette
        let contrast: Double
        let brightness: Double
        let noise: Double
        let normalization: ThermalNormalizationState
    }

    var hasPendingImportedGeometry: Bool { !importedTraversal.isEmpty || importedMaterials.hasPendingUniformUpdates }
    var importedGeometryCount: Int { importedGeometryIDs.count }
    var importedMaterialCount: Int { importedMaterials.count }
    var importedUniformUpdateCount: Int { importedMaterials.uniformUpdateCount }
    private(set) var lastImportedVisitCount = 0

    init(sceneRoot: SCNNode, groundNode: SCNNode, importedRoot: SCNNode? = nil) {
        self.sceneRoot = sceneRoot
        self.groundNode = groundNode
        self.importedRoot = importedRoot
    }

    func setImportedRoot(_ root: SCNNode?) {
        importedRoot = root
        invalidate()
    }

    // MARK: - Lifecycle

    /// Drop all proxies; next presentation rebuilds. Call on environment/weather change.
    func invalidate() {
        for entry in proxies {
            entry.node.removeFromParentNode()
        }
        proxies.removeAll(keepingCapacity: true)
        proxyByID.removeAll(keepingCapacity: true)
        populationWeights.removeAll(keepingCapacity: true)
        hasBuilt = false
        builtGroundClass = nil
        importedGeometryIDs.removeAll()
        importedTraversal.removeAll(keepingCapacity: true)
        lastImportedScan = -.infinity
        pruneCursor = 0
        importedMaterials.clear()
        lastPresentation = nil
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
        environmentRevision: UInt64,
        now: CFTimeInterval = CACurrentMediaTime()
    ) {
        ensureBuilt(groundClass: groundClass, environmentRevision: environmentRevision)
        updateImportedWorld(now: now)
        recolor(
            context: context,
            palette: palette,
            contrast: contrast,
            brightness: brightness,
            noiseAmount: noiseAmount,
            normalization: normalization
        )
    }

    /// Coarse material population, independent of where the camera is looking.
    func normalizationPopulation(
        groundClass: ThermalMaterialClass,
        environmentRevision: UInt64
    ) -> [(materialClass: ThermalMaterialClass, weight: Double)] {
        ensureBuilt(groundClass: groundClass, environmentRevision: environmentRevision)
        return populationWeights.map { (materialClass: $0.key, weight: $0.value) }
    }

    /// Center-of-frame probe result for a hit proxy node.
    func probe(node: SCNNode, geometryIndex: Int = 0, normal: SIMD3<Double> = SIMD3(0, 1, 0),
               view: SIMD3<Double> = SIMD3(0, 1, 0), distance: Double = 0)
        -> (materialClass: ThermalMaterialClass, temperatureCelsius: Double, name: String?)? {
        guard let entry = proxyByID[ObjectIdentifier(node)], let presentation = lastPresentation else { return nil }
        var cls = entry.materialClasses[max(0, geometryIndex) % entry.materialClasses.count]
        if cls == .building && normal.y > 0.85 { cls = .roof }
        let temperature = ThermalMaterialModel.apparentSurfaceTemperature(for: cls,
            context: presentation.context, normal: normal, view: view, distance: distance)
        return (cls, temperature, entry.rootName)
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
        if let groundNode, groundNode.geometry != nil, !groundNode.isHidden {
            addProxy(
                for: groundNode,
                materialClass: groundClass,
                rootName: "ground"
            )
        }

        // Mission target BEFORE the environment loop: it's the single most important thermal
        // object (the whole point of the search), so it must never be starved by the proxy budget.
        // The environment loop's `proxies.count >= maxProxies` early-return used to drop the target
        // entirely once tree counts grew large enough to exhaust `maxProxies` first — that's why
        // the person vanished from thermal after the forest-density work.
        if let missionTargetNode {
            var geometryNodes: [SCNNode] = []
            collectGeometryNodes(missionTargetNode, into: &geometryNodes)
            for node in geometryNodes {
                addProxy(for: node, materialClass: .body, rootName: "mission.target.person")
            }
        }

        for rootName in environmentRootNames {
            guard let root = findNode(named: rootName, under: sceneRoot) else { continue }
            for objectRoot in root.childNodes {
                if proxies.count >= maxProxies { return }
                buildObject(objectRoot)
            }
        }
    }

    /// At most 96 node visits / 32 new geometries / 4 ms per presentation. Newly streamed tiles
    /// are picked up by a periodic traversal, without two full scene walks on each refresh.
    private func updateImportedWorld(now: CFTimeInterval) {
        lastImportedVisitCount = 0
        guard let root = importedRoot else { return }
        let deadline = CACurrentMediaTime() + 0.004
        var removedIDs: Set<ObjectIdentifier> = []
        for _ in 0..<min(64, proxies.count) {
            if pruneCursor >= proxies.count { pruneCursor = 0 }
            let entry = proxies[pruneCursor]
            pruneCursor += 1
            if entry.isImported, !isAttached(entry.source, to: root) {
                importedGeometryIDs.remove(entry.sourceID)
                proxyByID.removeValue(forKey: ObjectIdentifier(entry.node))
                for (cls, weight) in entry.population { populationWeights[cls, default: 0] -= weight }
                entry.importedMaterialKeys.forEach { importedMaterials.release($0) }
                entry.node.removeFromParentNode()
                removedIDs.insert(ObjectIdentifier(entry))
            }
            if CACurrentMediaTime() >= deadline { break }
        }
        if !removedIDs.isEmpty {
            proxies.removeAll { removedIDs.contains(ObjectIdentifier($0)) }
            pruneCursor = min(pruneCursor, proxies.count)
        }
        if importedTraversal.isEmpty, now - lastImportedScan >= 0.5 {
            lastImportedScan = now
            importedTraversal = [root]
        }
        var added = 0
        while lastImportedVisitCount < 96, added < 32, CACurrentMediaTime() < deadline,
              let node = importedTraversal.popLast() {
            lastImportedVisitCount += 1
            guard !shouldExclude(node), isAttached(node, to: root) else { continue }
            // A flat city root can have thousands of children; don't copy that array every tick.
            importedTraversal.append(contentsOf: node.childNodes.reversed())
            guard node.geometry != nil, !importedGeometryIDs.contains(ObjectIdentifier(node)),
                  proxies.count < maxProxies else { continue }
            importedGeometryIDs.insert(ObjectIdentifier(node))
            let cls = ThermalSurfaceClassifier.classify(node: node)
            addProxy(for: node, materialClass: cls, rootName: node.name, imported: true)
            added += 1
        }
    }

    private func isAttached(_ source: SCNNode?, to root: SCNNode) -> Bool {
        var ancestor = source
        while let node = ancestor {
            if node === root { return root.parent != nil }
            ancestor = node.parent
        }
        return false
    }

    /// Build proxies for one placed object (a tree / building / rock / etc. and its sub-meshes).
    private func buildObject(_ objectRoot: SCNNode) {
        if shouldExclude(objectRoot) { return }

        // Collect geometry-bearing descendants (including the root itself).
        var geometryNodes: [SCNNode] = []
        collectGeometryNodes(objectRoot, into: &geometryNodes)
        guard !geometryNodes.isEmpty else { return }

        let baseClass = baseClassForObject(objectRoot)

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
                rootName: objectRoot.name
            )
        }
    }

    private func addProxy(
        for node: SCNNode,
        materialClass: ThermalMaterialClass,
        rootName: String?,
        imported: Bool = false
    ) {
        guard let geometry = node.geometry else { return }

        let copy = geometry.copy() as! SCNGeometry
        var importedMaterialKeys: [ThermalImportedSurfaceMaterials.Key] = []
        var materialClasses: [ThermalMaterialClass] = []
        var population: [ThermalMaterialClass: Double] = [:]
        let sources = geometry.materials.isEmpty ? [SCNMaterial()] : geometry.materials
        copy.materials = sources.map { source in
            let cls = materialClass == .body ? .body
                : (ThermalSurfaceClassifier.override(for: node)
                    ?? ThermalSurfaceClassifier.classify(material: source, fallback: materialClass))
            let (key, material) = importedMaterials.acquire(source: source, materialClass: cls)
            importedMaterialKeys.append(key)
            materialClasses.append(cls)
            let weight = 1.0 / Double(sources.count)
            population[cls, default: 0] += weight
            if cls == .building {
                // Upward fragments and glazing are represented in the possible scene range,
                // even when an imported building stores all faces in one material slot.
                population[.roof, default: 0] += weight * 0.20
                if source.name?.hasPrefix("world.facade.") == true {
                    population[.glass, default: 0] += weight * 0.30
                }
            }
            return material
        }

        let proxy = SCNNode(geometry: copy)
        proxy.name = proxyName
        proxy.categoryBitMask = ThermalRenderCategory.proxyBit
        proxy.castsShadow = false
        node.addChildNode(proxy)

        let entry = ProxyEntry(
            node: proxy,
            source: node,
            materialClasses: materialClasses,
            population: population,
            rootName: rootName,
            importedMaterialKeys: importedMaterialKeys,
            isImported: imported
        )
        for (cls, weight) in population { populationWeights[cls, default: 0] += weight }
        proxyByID[ObjectIdentifier(proxy)] = entry
        proxies.append(entry)
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
        importedMaterials.update(context: context, palette: palette, normalization: normalization,
                                 contrast: contrast, brightness: brightness, noise: noiseAmount)
        let presentation = Presentation(context: context, palette: palette, contrast: contrast,
            brightness: brightness, noise: noiseAmount, normalization: normalization)
        lastPresentation = presentation
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
        if node.isHidden { return true }
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
