import Foundation
import simd

/// The ContextCapture export's quadtree, resolved into a traversable tree with bounds and a
/// geometric error per node.
///
/// Streaming needs to decide *which* nodes to draw before loading any of them, so every node's
/// extent has to be known up front. The OBJ files themselves are the only source of that, so the
/// bounds are computed once by scanning vertex lines and then cached in a sidecar file — a
/// 14,000-node tile takes a few seconds the first time and loads instantly thereafter.
struct MeshQuadtree {

    struct Node {
        let level: Int
        let quadPath: String
        let group: String
        let namePrefix: String
        let objectURL: URL
        let materialURL: URL?

        /// Bounds in scene-local metres, already re-anchored to the world origin.
        let minimum: SIMD3<Float>
        let maximum: SIMD3<Float>

        /// Indices into `MeshQuadtree.nodes`.
        var childIndices: [Int]

        var center: SIMD3<Float> { (minimum + maximum) * 0.5 }
        var radius: Float { simd_length(maximum - minimum) * 0.5 }
        var isLeaf: Bool { childIndices.isEmpty }

        /// World-space size of the detail this node fails to represent — the standard driver for
        /// level-of-detail selection.
        ///
        /// Taken as a fraction of the node's own diagonal. Because each quadtree level covers a
        /// quarter of the area, the diagonal halves as you descend, so the error sequence falls
        /// off geometrically without needing per-level tuning. A leaf is assigned zero: there is
        /// nothing finer to descend to, so it must always be accepted.
        var geometricError: Float {
            isLeaf ? 0.0 : radius * 0.5
        }
    }

    let nodes: [Node]
    let rootIndices: [Int]

    // MARK: - Construction

    /// Builds the tree, computing or loading cached bounds.
    ///
    /// - Parameter originOffset: added to raw OBJ coordinates before the axis swap, matching what
    ///   `ContextCaptureOBJLoader` applies, so bounds and geometry agree.
    static func build(
        index: ContextCaptureTileIndex,
        originOffset: SIMD3<Double>,
        cacheURL: URL?,
        progress: ((Int, Int) -> Void)? = nil
    ) -> MeshQuadtree {
        let rawBounds = loadOrComputeBounds(
            index: index,
            cacheURL: cacheURL,
            progress: progress
        )

        var nodes: [Node] = []
        nodes.reserveCapacity(index.nodes.count)
        // Key nodes by group + prefix + path so children can be linked without an O(n²) scan.
        var indexByKey: [String: Int] = [:]

        for source in index.nodes {
            let key = nodeKey(source)
            guard let bounds = rawBounds[key] else { continue }

            // Same transform the loader applies: offset in OBJ axes, then swap to scene axes
            // (OBJ is Z-up with y north; the scene is Y-up with +Z north).
            let lowRaw = SIMD3<Double>(
                Double(bounds.minimum.x),
                Double(bounds.minimum.y),
                Double(bounds.minimum.z)
            )
            let highRaw = SIMD3<Double>(
                Double(bounds.maximum.x),
                Double(bounds.maximum.y),
                Double(bounds.maximum.z)
            )
            let low = Self.toSceneAxes(lowRaw, originOffset: originOffset)
            let high = Self.toSceneAxes(highRaw, originOffset: originOffset)
            let corners = [low, high]

            indexByKey[key] = nodes.count
            nodes.append(
                Node(
                    level: source.level,
                    quadPath: source.quadPath,
                    group: source.group,
                    namePrefix: source.namePrefix,
                    objectURL: source.objectURL,
                    materialURL: source.materialURL,
                    minimum: simd_min(corners[0], corners[1]),
                    maximum: simd_max(corners[0], corners[1]),
                    childIndices: []
                )
            )
        }

        // Link children: a node's children are the nodes one level deeper in the same group whose
        // quadrant path extends this one by a single digit.
        var rootIndices: [Int] = []
        for (position, node) in nodes.enumerated() {
            if node.quadPath.isEmpty {
                rootIndices.append(position)
                continue
            }
            let parentPath = String(node.quadPath.dropLast())
            let parentKey = "\(node.group)/\(node.namePrefix)/\(node.level - 1)/\(parentPath)"
            if let parentIndex = indexByKey[parentKey] {
                nodes[parentIndex].childIndices.append(position)
            } else {
                // A node whose parent is missing (an empty placeholder, for instance) would
                // otherwise be unreachable by traversal, so it is promoted to a root.
                rootIndices.append(position)
            }
        }

        // Grow every parent to enclose its children.
        //
        // Decimated ancestors do not automatically bound their descendants: fine vertical detail
        // — a spire, a mast, a crane — survives at level 21 but is simplified away by level 17,
        // leaving the coarse node's box short. Measured on the central Helsinki tile, 17 nodes
        // overhung their parent by up to 18 m. Left alone, culling a parent could discard a child
        // that is genuinely on screen, so bounds are made hierarchically conservative here, once,
        // rather than every traversal having to allow for it.
        propagateBoundsUpwards(nodes: &nodes)

        return MeshQuadtree(nodes: nodes, rootIndices: rootIndices)
    }

    private static func propagateBoundsUpwards(nodes: inout [Node]) {
        // Deepest first, so a parent sees children that have already absorbed their own subtree.
        let order = nodes.indices.sorted { nodes[$0].level > nodes[$1].level }
        for position in order {
            let childIndices = nodes[position].childIndices
            guard !childIndices.isEmpty else { continue }
            var minimum = nodes[position].minimum
            var maximum = nodes[position].maximum
            for childIndex in childIndices {
                minimum = simd_min(minimum, nodes[childIndex].minimum)
                maximum = simd_max(maximum, nodes[childIndex].maximum)
            }
            nodes[position] = Node(
                level: nodes[position].level,
                quadPath: nodes[position].quadPath,
                group: nodes[position].group,
                namePrefix: nodes[position].namePrefix,
                objectURL: nodes[position].objectURL,
                materialURL: nodes[position].materialURL,
                minimum: minimum,
                maximum: maximum,
                childIndices: childIndices
            )
        }
    }

    /// OBJ axes (x east, y north, z up) → scene axes (x east, y up, z north), applying the world
    /// re-anchoring offset in double precision first.
    private static func toSceneAxes(
        _ raw: SIMD3<Double>,
        originOffset: SIMD3<Double>
    ) -> SIMD3<Float> {
        let east = raw.x + originOffset.x
        let north = raw.y + originOffset.y
        let up = raw.z + originOffset.z
        return SIMD3<Float>(Float(east), Float(up), Float(north))
    }

    private static func nodeKey(_ node: ContextCaptureTileIndex.Node) -> String {
        "\(node.group)/\(node.namePrefix)/\(node.level)/\(node.quadPath)"
    }

    // MARK: - Bounds

    struct RawBounds: Codable {
        let minimum: SIMD3<Float>
        let maximum: SIMD3<Float>
    }

    private static func loadOrComputeBounds(
        index: ContextCaptureTileIndex,
        cacheURL: URL?,
        progress: ((Int, Int) -> Void)?
    ) -> [String: RawBounds] {
        if let cacheURL,
           let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([String: RawBounds].self, from: data),
           cached.count == index.nodes.count {
            return cached
        }

        var result: [String: RawBounds] = [:]
        result.reserveCapacity(index.nodes.count)

        let total = index.nodes.count
        for (position, node) in index.nodes.enumerated() {
            if let bounds = vertexBounds(of: node.objectURL) {
                result[nodeKey(node)] = bounds
            }
            if position % 500 == 0 { progress?(position, total) }
        }
        progress?(total, total)

        if let cacheURL, let data = try? JSONEncoder().encode(result) {
            try? data.write(to: cacheURL)
        }
        return result
    }

    /// Min/max of an OBJ's vertex positions, in the file's own axes.
    ///
    /// Reads only `v` lines and stops parsing each one after three numbers. Full geometry loading
    /// is an order of magnitude more work and none of it is needed to know where a node sits.
    static func vertexBounds(of url: URL) -> RawBounds? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var found = false

        text.enumerateLines { line, _ in
            guard line.hasPrefix("v ") else { return }
            let parts = line.dropFirst(2).split(separator: " ")
            guard parts.count >= 3,
                  let x = Float(parts[0]),
                  let y = Float(parts[1]),
                  let z = Float(parts[2]) else {
                return
            }
            let point = SIMD3<Float>(x, y, z)
            minimum = simd_min(minimum, point)
            maximum = simd_max(maximum, point)
            found = true
        }

        return found ? RawBounds(minimum: minimum, maximum: maximum) : nil
    }
}
