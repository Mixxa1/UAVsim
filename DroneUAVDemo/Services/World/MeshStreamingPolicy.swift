import Foundation
import simd

/// Decides which quadtree nodes should be on screen, given where the camera is.
///
/// Deliberately pure: it takes plain camera numbers and a tree, and returns node indices. No
/// SceneKit types, no I/O, no shared state. That matters for two reasons — the selection maths is
/// where level-of-detail bugs actually live and it can be tested exhaustively this way, and the
/// work can run off the main thread without touching the scene graph, which this project has
/// already been burned by once.
struct MeshStreamingPolicy {

    struct Camera {
        var position: SIMD3<Float>
        /// Unit vector the camera looks along.
        var forward: SIMD3<Float>
        var verticalFieldOfViewRadians: Float
        var viewportHeightPixels: Float
        var aspectRatio: Float

        init(
            position: SIMD3<Float>,
            forward: SIMD3<Float>,
            verticalFieldOfViewRadians: Float,
            viewportHeightPixels: Float,
            aspectRatio: Float = 16.0 / 9.0
        ) {
            self.position = position
            let length = simd_length(forward)
            self.forward = length > 1e-6 ? forward / length : SIMD3<Float>(0, 0, -1)
            self.verticalFieldOfViewRadians = verticalFieldOfViewRadians
            self.viewportHeightPixels = viewportHeightPixels
            self.aspectRatio = aspectRatio
        }
    }

    /// Refine a node while the detail it is missing would span more than this many pixels.
    /// Smaller means sharper and heavier; 16 px is the usual starting point for this kind of
    /// photogrammetric tileset.
    var screenSpaceErrorThreshold: Float = 16.0

    /// Hard ceiling on nodes drawn at once. Texture memory, not triangles, is the binding
    /// constraint: each node carries a 1024×1024 JPEG, which is about 4 MB once decoded and
    /// resident on the GPU, so a few hundred nodes is already gigabytes.
    var maximumNodes: Int = 500

    var frustumCullingEnabled: Bool = true

    /// Extra angular margin on the culling cone, so nodes just outside the view are still
    /// selected and can be loading before they swing in.
    var cullingMarginRadians: Float = 0.22

    // MARK: - Selection

    struct Result {
        /// Nodes that should be drawn, finest-appropriate for the current view.
        var nodeIndices: [Int]
        /// How many nodes were examined — a cheap proxy for traversal cost.
        var visited: Int
        /// True when the node budget cut the refinement short, i.e. the view is showing less
        /// detail than the error threshold asked for.
        var budgetExhausted: Bool
    }

    func select(tree: MeshQuadtree, camera: Camera) -> Result {
        guard !tree.nodes.isEmpty else {
            return Result(nodeIndices: [], visited: 0, budgetExhausted: false)
        }

        // Pixels per radian of angular size — the constant part of the screen-space error.
        let halfFieldOfView = max(camera.verticalFieldOfViewRadians * 0.5, 0.0001)
        let pixelScale = camera.viewportHeightPixels / (2.0 * tan(halfFieldOfView))

        var visited = 0
        var selected = Set<Int>()
        // Max-heap on screen-space error: always refine the node that is currently worst on
        // screen, so a tight node budget spends itself where it is most visible rather than on
        // whichever branch happened to be traversed first.
        var heap = ErrorHeap()

        for rootIndex in tree.rootIndices {
            visited += 1
            guard isVisible(tree.nodes[rootIndex], camera: camera) else { continue }
            selected.insert(rootIndex)
            let error = screenSpaceError(
                node: tree.nodes[rootIndex],
                camera: camera,
                pixelScale: pixelScale
            )
            if error > screenSpaceErrorThreshold, !tree.nodes[rootIndex].childIndices.isEmpty {
                heap.push(error: error, index: rootIndex)
            }
        }

        var budgetExhausted = false

        while let candidate = heap.pop() {
            let node = tree.nodes[candidate.index]
            // Refining replaces one node with up to four, so stop before overshooting.
            guard selected.count + node.childIndices.count - 1 <= maximumNodes else {
                budgetExhausted = true
                break
            }

            var visibleChildren: [Int] = []
            for childIndex in node.childIndices {
                visited += 1
                if isVisible(tree.nodes[childIndex], camera: camera) {
                    visibleChildren.append(childIndex)
                }
            }
            // A node whose children are all off-screen still has to draw itself, or the view
            // develops a hole exactly where the camera is pointing.
            guard !visibleChildren.isEmpty else { continue }

            selected.remove(candidate.index)
            for childIndex in visibleChildren {
                selected.insert(childIndex)
                let childNode = tree.nodes[childIndex]
                guard !childNode.childIndices.isEmpty else { continue }
                let error = screenSpaceError(
                    node: childNode,
                    camera: camera,
                    pixelScale: pixelScale
                )
                if error > screenSpaceErrorThreshold {
                    heap.push(error: error, index: childIndex)
                }
            }
        }

        return Result(
            nodeIndices: Array(selected),
            visited: visited,
            budgetExhausted: budgetExhausted
        )
    }

    // MARK: - Metrics

    /// Angular size of the node's geometric error, in pixels.
    func screenSpaceError(
        node: MeshQuadtree.Node,
        camera: Camera,
        pixelScale: Float
    ) -> Float {
        guard node.geometricError > 0 else { return 0 }
        let distance = distanceToBounds(node: node, from: camera.position)
        // Inside the node's own bounds the error is effectively infinite — that node must be
        // refined as far as it goes.
        guard distance > 0.001 else { return .greatestFiniteMagnitude }
        return node.geometricError * pixelScale / distance
    }

    /// Distance from a point to the node's axis-aligned bounds, zero when inside.
    func distanceToBounds(node: MeshQuadtree.Node, from point: SIMD3<Float>) -> Float {
        let clamped = simd_clamp(point, node.minimum, node.maximum)
        return simd_length(point - clamped)
    }

    /// Conservative cone test against the view direction.
    ///
    /// A cone rather than six frustum planes: it over-selects slightly at the corners of a wide
    /// viewport, which costs a few nodes, and it cannot under-select, which would punch visible
    /// holes. Given that the alternative is threading a projection matrix through a pure
    /// function, the trade is worth it.
    func isVisible(_ node: MeshQuadtree.Node, camera: Camera) -> Bool {
        guard frustumCullingEnabled else { return true }

        let toCenter = node.center - camera.position
        let distance = simd_length(toCenter)
        let radius = node.radius
        // Anything the camera is inside of is visible by definition.
        guard distance > radius else { return true }

        let cosine = simd_dot(toCenter / distance, camera.forward)
        let angle = acos(simd_clamp(cosine, -1.0, 1.0))
        // Half-angle of a cone enclosing the whole viewport, widened by the node's own angular
        // radius and the look-ahead margin.
        let verticalHalf = camera.verticalFieldOfViewRadians * 0.5
        let horizontalHalf = atan(tan(verticalHalf) * max(camera.aspectRatio, 0.0001))
        let diagonalHalf = (verticalHalf * verticalHalf + horizontalHalf * horizontalHalf).squareRoot()
        let nodeAngularRadius = asin(simd_clamp(radius / distance, 0.0, 1.0))

        return angle <= diagonalHalf + nodeAngularRadius + cullingMarginRadians
    }
}

/// Binary max-heap keyed on screen-space error.
///
/// A plain sorted array would be re-sorted on every push during traversal, which for a tree this
/// size measurably dominates the selection pass — the same linear-scan trap already fixed once in
/// this project's path planner.
private struct ErrorHeap {
    private var storage: [(error: Float, index: Int)] = []

    var isEmpty: Bool { storage.isEmpty }

    mutating func push(error: Float, index: Int) {
        storage.append((error, index))
        var child = storage.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard storage[child].error > storage[parent].error else { break }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> (error: Float, index: Int)? {
        guard !storage.isEmpty else { return nil }
        storage.swapAt(0, storage.count - 1)
        let top = storage.removeLast()

        var parent = 0
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var largest = parent
            if left < storage.count, storage[left].error > storage[largest].error { largest = left }
            if right < storage.count, storage[right].error > storage[largest].error { largest = right }
            guard largest != parent else { break }
            storage.swapAt(parent, largest)
            parent = largest
        }
        return top
    }
}
