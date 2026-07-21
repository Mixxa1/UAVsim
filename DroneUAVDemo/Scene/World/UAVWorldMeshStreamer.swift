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
        /// Cumulative geometries dropped from the cache. If this climbs during steady flight the
        /// working set does not fit and nodes are being reloaded — visible as a sector going blurry
        /// and sharpening again.
        var evictions = 0
        /// Cumulative loads of a node that had already been loaded and discarded earlier.
        var reloads = 0
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
        // Four workers kept continuously busy. A priority scheduler was tried here and measured
        // far worse: choosing the next load only after the previous one's completion had hopped
        // back to the main actor turned a continuous pipeline into a stepped one, and visible
        // nodes collapsed from ~460 to ~60 under a fast turn.
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

        debugLastSelection = Set(selection.nodeIndices)
        // Two kinds of node end up on screen, and they are kept apart deliberately.
        //
        // A *direct hit* is wanted by the policy and already resident: it is the real answer and is
        // never given up. A *stand-in* is a coarse ancestor drawn only because something finer has
        // not arrived yet, so that no hole opens under the aircraft.
        var direct = Set<Int>()
        var standIns = Set<Int>()

        for index in selection.nodeIndices {
            if geometries[index] != nil {
                direct.insert(index)
                continue
            }
            requestLoad(index)
            if let ancestor = nearestLoadedAncestor(of: index) {
                standIns.insert(ancestor)
            }
        }

        let keptDirect = removingDescendants(of: direct)

        // A stand-in that encloses geometry we already have is thrown away rather than drawn.
        //
        // This is the whole fix for the flicker. The nearest *loaded* ancestor of a missing level-21
        // node is very often the level-13 root, because the levels in between were never requested
        // and so were never loaded. Treating that root as ordinary coverage let it enclose — and
        // therefore delete — every resident fine node in its subtree. Measured on straight and level
        // flight over central Helsinki, one pending node repainted 58 sectors at once from level 21
        // down to level 13: a kilometre of city dropping to its blurriest representation to patch a
        // gap of a few metres, then snapping back a frame later. That is the sector-wide texture
        // change reported from the air, and it needs no camera rotation to happen.
        //
        // Dropping the stand-in cannot open the hole it was meant to fill: `applyVisible` keeps a
        // node on screen until something actually replaces it, so the patch keeps showing whatever
        // it was already showing until its own geometry arrives.
        let usefulStandIns = standIns.filter { candidate in
            !keptDirect.contains { tree.nodes[candidate].isAncestorPath(of: tree.nodes[$0]) }
                && !keptDirect.contains { tree.nodes[$0].isAncestorPath(of: tree.nodes[candidate]) }
                && !keptDirect.contains(candidate)
        }
        let substituted = usefulStandIns.count
        let pruned = removingDescendants(of: keptDirect.union(usefulStandIns))

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

    /// Diagnostics only: was this node's geometry resident at the last update?
    func debugIsLoaded(_ index: Int) -> Bool { geometries[index] != nil }
    /// Diagnostics only: did the policy ask for this node on the last update?
    private(set) var debugLastSelection: Set<Int> = []

    /// Currently-parented node indices, for diagnostics only.
    func debugVisibleNodeIndices() -> [Int] { Array(sceneNodes.keys) }

    // MARK: - Visibility

    /// Swaps the visible set, **adding before removing**.
    ///
    /// The order is the guarantee. Removing first leaves a frame — however brief — in which the
    /// ground under the aircraft is simply absent, and any node whose geometry turned out to be
    /// missing (evicted, still loading, failed) silently widened that gap because the add loop
    /// skipped it. Adding first means a replacement is provably on screen before its predecessor
    /// leaves, and a node that cannot be added keeps its predecessor instead of punching a hole.
    ///
    /// The cost is one frame of overlap where both the coarse and the fine version of a patch are
    /// drawn. That is invisible — they occupy the same surface — and vastly preferable to a gap.
    private func applyVisible(_ desired: Set<Int>) {
        var installed = Set<Int>()
        for index in desired.subtracting(visibleIndices) {
            guard let geometry = geometries[index] else { continue }
            let node = SCNNode(geometry: geometry)
            node.name = "world.mesh.\(tree.nodes[index].level).\(tree.nodes[index].quadPath)"
            node.castsShadow = false
            rootNode.addChildNode(node)
            sceneNodes[index] = node
            installed.insert(index)
        }

        // Anything that was wanted but could not be installed keeps whatever is already covering
        // it, so the retired set is only what genuinely has a successor.
        let unavailable = desired.subtracting(visibleIndices).subtracting(installed)
        var retiring = visibleIndices.subtracting(desired)
        if !unavailable.isEmpty {
            retiring = retiring.filter { old in
                // Keep an old node alive while it still covers something that failed to install.
                !unavailable.contains { missing in
                    tree.nodes[old].isAncestorPath(of: tree.nodes[missing])
                        || tree.nodes[missing].isAncestorPath(of: tree.nodes[old])
                }
            }
        }

        for index in retiring {
            sceneNodes[index]?.removeFromParentNode()
            sceneNodes[index] = nil
        }

        let desired = desired.intersection(sceneNodes.keys).union(visibleIndices.subtracting(retiring))
        for index in desired {
            lastUsed[index] = tickClock()
        }
        visibleIndices = desired
    }

    /// Drops any node that is a descendant of another node in the set, so an ancestor standing in
    /// for pending children does not draw on top of a sibling that already loaded.
    /// Drops any node already covered by a coarser node in the set.
    ///
    /// Compares **quadrant paths**, not parent pointers. Walking `parentIndex` upwards looks
    /// equivalent and is not: the chain has gaps. A node whose own parent was skipped at build
    /// time — the export contains zero-byte placeholder OBJs, which yield no bounds — is promoted
    /// to a root, and the walk from any of its descendants stops there instead of reaching the
    /// real ancestor.
    ///
    /// Measured on the central Helsinki tile, that left **35 ancestor/descendant pairs drawn
    /// simultaneously on every single frame** — an L13 root rendered on top of its own L20
    /// descendants. Two near-coincident surfaces then fight for the depth buffer and the winner
    /// changes frame to frame, which is seen not as geometry moving but as the texture on a sector
    /// abruptly switching between the coarse and the detailed version.
    ///
    /// A path prefix cannot have gaps, so it answers correctly regardless of what the tree build
    /// managed to link.
    private func removingDescendants(of set: Set<Int>) -> Set<Int> {
        guard set.count > 1 else { return set }

        // Only nodes from the same sub-tile can cover each other, so the comparison is confined
        // to small buckets rather than being quadratic over the whole visible set.
        var buckets: [String: [Int]] = [:]
        for index in set {
            let node = tree.nodes[index]
            buckets["\(node.group)/\(node.namePrefix)", default: []].append(index)
        }

        var result: Set<Int> = []
        for (_, bucket) in buckets {
            // Coarsest first: a node is kept only if nothing already kept encloses it.
            let ordered = bucket.sorted { tree.nodes[$0].level < tree.nodes[$1].level }
            var kept: [Int] = []
            for index in ordered {
                let node = tree.nodes[index]
                let covered = kept.contains { tree.nodes[$0].isAncestorPath(of: node) }
                if !covered { kept.append(index) }
            }
            result.formUnion(kept)
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
                if self.everLoaded.contains(index) { self.statistics.reloads += 1 }
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
        statistics.evictions += min(excess, ordered.count)
        for index in ordered.prefix(excess) {
            everLoaded.insert(index)
            geometries[index] = nil
            triangleCounts[index] = nil
            lastUsed[index] = nil
        }
    }

    // MARK: - Support

    private var triangleCounts: [Int: Int] = [:]
    private var everLoaded: Set<Int> = []

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
