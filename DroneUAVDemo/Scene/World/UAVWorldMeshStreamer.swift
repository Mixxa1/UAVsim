import SceneKit
import simd

/// Keeps a photogrammetric mesh on screen at the right detail, loading and unloading as the
/// camera moves.
///
/// Threading is the delicate part and is deliberately rigid: selection is pure arithmetic and
/// runs wherever `update` is called, geometry loading runs on a background queue, and the scene
/// graph is only ever touched on the main actor. This project has already lost days to SceneKit
/// thread interactions — a representable writing back into `@Published` during layout, and
/// `.presentation` reads stalling on the render-thread lock — so nothing here reads scene state
/// during selection or mutates nodes off the main actor.
@MainActor
final class UAVWorldMeshStreamer {

    struct Statistics {
        var visibleNodes = 0
        var loadedGeometries = 0
        var pendingLoads = 0
        var triangles = 0
        var lastSelectionMilliseconds: Double = 0
        var budgetExhausted = false
        /// Nodes drawn at a coarser level than requested because the finer one is still loading.
        var substitutedByAncestor = 0
    }

    var policy = MeshStreamingPolicy()

    /// Geometry cache ceiling. Each node carries a 1024×1024 texture, roughly 4 MB resident, so
    /// this is a memory budget expressed in nodes rather than a speed knob.
    var maximumCachedGeometries = 900

    let rootNode = SCNNode()
    private(set) var statistics = Statistics()

    private let tree: MeshQuadtree
    private let originOffset: SIMD3<Double>

    private var geometries: [Int: SCNGeometry] = [:]
    private var sceneNodes: [Int: SCNNode] = [:]
    private var visibleIndices: Set<Int> = []
    private var pending: Set<Int> = []
    /// Monotonic counter used for least-recently-used eviction.
    private var lastUsed: [Int: UInt64] = [:]
    private var clock: UInt64 = 0

    private let loadQueue: OperationQueue

    init(tree: MeshQuadtree, originOffset: SIMD3<Double>) {
        self.tree = tree
        self.originOffset = originOffset
        rootNode.name = "world.mesh.root"

        let queue = OperationQueue()
        queue.name = "uavsim.world.mesh.loader"
        // Bounded concurrency: the loader is I/O plus JPEG decode, and letting it run unbounded
        // starves the render thread of memory bandwidth exactly when the camera is moving fastest.
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        self.loadQueue = queue
    }

    /// Loads the coarsest level synchronously.
    ///
    /// The whole no-holes guarantee rests on there always being *some* loaded ancestor to fall
    /// back to, so the roots are not optional and not deferred. They are also the cheapest nodes
    /// in the tree, so this costs little.
    func preloadRoots() {
        for index in tree.rootIndices {
            guard geometries[index] == nil else { continue }
            if let loaded = loadGeometry(at: index) {
                geometries[index] = loaded.geometry
                lastUsed[index] = tickClock()
            }
        }
    }

    // MARK: - Per-frame update

    func update(camera: MeshStreamingPolicy.Camera) {
        let started = DispatchTime.now()
        let selection = policy.select(tree: tree, camera: camera)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000

        var resolved = Set<Int>()
        var substituted = 0

        // Resolve each desired node to something that is actually loaded. Falling back to a
        // loaded ancestor is what prevents a hole appearing while finer geometry streams in —
        // showing nothing would make the ground vanish under the aircraft.
        for index in selection.nodeIndices {
            if geometries[index] != nil {
                resolved.insert(index)
                continue
            }
            requestLoad(index)
            if let ancestor = nearestLoadedAncestor(of: index) {
                resolved.insert(ancestor)
                substituted += 1
            }
        }

        // An ancestor standing in for several pending children is inserted once, and any
        // descendant of a resolved node is redundant.
        let pruned = removingDescendants(of: resolved)

        applyVisible(pruned)
        evictIfNeeded(keeping: pruned)

        statistics.visibleNodes = pruned.count
        statistics.loadedGeometries = geometries.count
        statistics.pendingLoads = pending.count
        statistics.lastSelectionMilliseconds = elapsed
        statistics.budgetExhausted = selection.budgetExhausted
        statistics.substitutedByAncestor = substituted
        statistics.triangles = pruned.reduce(into: 0) { total, index in
            total += triangleCounts[index] ?? 0
        }
    }

    // MARK: - Visibility

    private func applyVisible(_ desired: Set<Int>) {
        for index in visibleIndices.subtracting(desired) {
            sceneNodes[index]?.removeFromParentNode()
            sceneNodes[index] = nil
        }
        for index in desired.subtracting(visibleIndices) {
            guard let geometry = geometries[index] else { continue }
            let node = SCNNode(geometry: geometry)
            node.name = "world.mesh.\(tree.nodes[index].level).\(tree.nodes[index].quadPath)"
            node.castsShadow = false
            rootNode.addChildNode(node)
            sceneNodes[index] = node
        }
        for index in desired {
            lastUsed[index] = tickClock()
        }
        visibleIndices = desired
    }

    /// Drops any node that is a descendant of another node in the set, so an ancestor standing in
    /// for pending children does not draw on top of a sibling that already loaded.
    private func removingDescendants(of set: Set<Int>) -> Set<Int> {
        guard set.count > 1 else { return set }
        var result = set
        for index in set {
            var cursor = parentIndex[index]
            while let parent = cursor {
                if result.contains(parent) {
                    result.remove(index)
                    break
                }
                cursor = parentIndex[parent]
            }
        }
        return result
    }

    private func nearestLoadedAncestor(of index: Int) -> Int? {
        var cursor = parentIndex[index]
        while let candidate = cursor {
            if geometries[candidate] != nil { return candidate }
            cursor = parentIndex[candidate]
        }
        return nil
    }

    // MARK: - Loading

    private func requestLoad(_ index: Int) {
        guard geometries[index] == nil, !pending.contains(index) else { return }
        pending.insert(index)

        let node = tree.nodes[index]
        let offset = originOffset
        loadQueue.addOperation { [weak self] in
            // Parsing and image decoding happen here, off the main actor. Nothing in this block
            // touches the scene graph.
            let source = ContextCaptureTileIndex.Node(
                level: node.level,
                quadPath: node.quadPath,
                objectURL: node.objectURL,
                materialURL: node.materialURL,
                group: node.group,
                namePrefix: node.namePrefix
            )
            let loaded = ContextCaptureOBJLoader.isEmptyPlaceholder(source)
                ? nil
                : try? ContextCaptureOBJLoader.load(node: source, originOffset: offset)

            Task { @MainActor in
                guard let self else { return }
                self.pending.remove(index)
                guard let loaded else { return }
                self.geometries[index] = loaded.geometry
                self.triangleCounts[index] = loaded.triangleCount
                self.lastUsed[index] = self.tickClock()
            }
        }
    }

    private func loadGeometry(at index: Int) -> ContextCaptureOBJLoader.LoadedNode? {
        let node = tree.nodes[index]
        let source = ContextCaptureTileIndex.Node(
            level: node.level,
            quadPath: node.quadPath,
            objectURL: node.objectURL,
            materialURL: node.materialURL,
            group: node.group,
            namePrefix: node.namePrefix
        )
        guard !ContextCaptureOBJLoader.isEmptyPlaceholder(source) else { return nil }
        let loaded = try? ContextCaptureOBJLoader.load(node: source, originOffset: originOffset)
        if let loaded { triangleCounts[index] = loaded.triangleCount }
        return loaded
    }

    // MARK: - Eviction

    private func evictIfNeeded(keeping visible: Set<Int>) {
        guard geometries.count > maximumCachedGeometries else { return }

        // Roots are never evicted: they are the fallback that keeps the world hole-free.
        let roots = Set(tree.rootIndices)
        let evictable = geometries.keys.filter { !visible.contains($0) && !roots.contains($0) }
        guard !evictable.isEmpty else { return }

        let ordered = evictable.sorted { (lastUsed[$0] ?? 0) < (lastUsed[$1] ?? 0) }
        let excess = geometries.count - maximumCachedGeometries
        for index in ordered.prefix(excess) {
            geometries[index] = nil
            triangleCounts[index] = nil
            lastUsed[index] = nil
        }
    }

    // MARK: - Support

    private var triangleCounts: [Int: Int] = [:]

    /// Parent lookup, built once. Walking `childIndices` to find a parent would be O(n) per query
    /// and this runs inside the per-frame path.
    private lazy var parentIndex: [Int: Int] = {
        var result: [Int: Int] = [:]
        for (position, node) in tree.nodes.enumerated() {
            for child in node.childIndices {
                result[child] = position
            }
        }
        return result
    }()

    private func tickClock() -> UInt64 {
        clock &+= 1
        return clock
    }
}
