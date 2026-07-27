import SceneKit
import simd

/// Splits a large static world's scene graph into a grid of chunks and keeps only the chunks near
/// the camera attached to the scene.
///
/// An imported city arrives as one flat list of nodes — 5 863 buildings and some 15 000 trees for a
/// 3.5 km tile of Lower Manhattan. SceneKit walks and frustum-culls every one of them per frame, in
/// the main pass and again in each shadow cascade, and a street-level view down an avenue leaves
/// thousands of them inside the frustum with nothing to reject them. That is the shape of the
/// problem this solves: not triangles, but *count*.
///
/// Chunks are containers, not a level-of-detail scheme. Detaching a chunk removes its whole subtree
/// from traversal in one operation; the geometry stays alive in this object, so re-attaching costs
/// nothing but a node insert. Releasing chunk geometry to reclaim RAM is a separate, later step —
/// it needs the assemblers to be able to rebuild one chunk in isolation, which today they cannot.
///
/// The world is expected to be static. Anything that moves, or that anything else looks up by name
/// through the scene graph, must not be adopted here: while detached, a node is genuinely not in
/// the scene.
@MainActor
final class WorldChunkStreamer {

    /// How far a layer's chunks stay attached. Split per layer because the useful distances differ
    /// by two orders of magnitude: a 5 600-triangle tree is scenery that matters within a street,
    /// while a 300 m tower is a landmark that must be there from across the district.
    struct LayerPolicy {
        /// Attach radius with the camera on the ground, in metres.
        let groundRadius: Float
        /// Extra radius per metre of camera altitude. Looking down from height exposes far more of
        /// the map, and a horizon that visibly builds itself is worse than the frames it saves.
        let altitudeFactor: Float
        let maximumRadius: Float
        /// Extra distance an already-attached chunk is allowed before it is dropped, so a camera
        /// hovering exactly on the boundary does not attach and detach it every evaluation.
        let hysteresis: Float

        static let buildings = LayerPolicy(
            groundRadius: 850,
            altitudeFactor: 2.6,
            maximumRadius: 2400,
            hysteresis: 120
        )

        static let vegetation = LayerPolicy(
            groundRadius: 260,
            altitudeFactor: 0.7,
            maximumRadius: 700,
            hysteresis: 60
        )
    }

    struct Statistics {
        var chunkCount = 0
        var attachedChunkCount = 0
        var nodeCount = 0
        var attachedNodeCount = 0
    }

    private struct ChunkKey: Hashable {
        let column: Int
        let row: Int
    }

    private final class Chunk {
        let node: SCNNode
        /// Planar bounds of the chunk's cell. Distance is measured to the *box*, not to its centre:
        /// with 256 m cells the two differ by up to 181 m, which at a 260 m tree radius is the
        /// difference between trees around the aircraft and trees behind it.
        let minimum: SIMD2<Float>
        let maximum: SIMD2<Float>
        var nodeCount = 0
        var isAttached = true

        init(node: SCNNode, minimum: SIMD2<Float>, maximum: SIMD2<Float>) {
            self.node = node
            self.minimum = minimum
            self.maximum = maximum
        }
    }

    private final class Layer {
        let root: SCNNode
        let policy: LayerPolicy
        var chunks: [ChunkKey: Chunk] = [:]

        init(root: SCNNode, policy: LayerPolicy) {
            self.root = root
            self.policy = policy
        }
    }

    /// 256 m: large enough that a chunk holds a few hundred nodes and the whole tile needs only a
    /// couple of hundred chunks to evaluate, small enough that the attach radius is not dominated
    /// by the granularity of the grid itself.
    private let chunkSize: Float
    private var layers: [Layer] = []
    private var lastEvaluatedPosition: SIMD3<Float>?

    /// Re-evaluation thresholds. Chunk membership cannot change meaningfully inside these, and the
    /// evaluation runs on the tick path.
    private static let reevaluationDistance: Float = 24.0
    private static let reevaluationAltitude: Float = 20.0

    init(chunkSize: Float = 256.0) {
        self.chunkSize = max(32.0, chunkSize)
    }

    var isEmpty: Bool { layers.isEmpty }

    var statistics: Statistics {
        var result = Statistics()
        for layer in layers {
            for chunk in layer.chunks.values {
                result.chunkCount += 1
                result.nodeCount += chunk.nodeCount
                if chunk.isAttached {
                    result.attachedChunkCount += 1
                    result.attachedNodeCount += chunk.nodeCount
                }
            }
        }
        return result
    }

    /// Regroups `container`'s direct children into per-cell chunk nodes under the same container.
    ///
    /// The children keep their local transforms and the chunk nodes are left at identity, so every
    /// adopted node stays exactly where it was. Chunks start **attached**: a world that has not yet
    /// been evaluated must look the way it did before this existed, never emptier.
    func adopt(container: SCNNode, policy: LayerPolicy) {
        let children = container.childNodes
        guard !children.isEmpty else { return }

        let layer = Layer(root: container, policy: policy)
        for child in children {
            // World position, not local: it is the same value here (every container in an imported
            // world sits at identity) but it stays correct if a world ever offsets its root.
            let position = child.simdWorldPosition
            let key = ChunkKey(
                column: Int(floor(position.x / chunkSize)),
                row: Int(floor(position.z / chunkSize))
            )

            let chunk: Chunk
            if let existing = layer.chunks[key] {
                chunk = existing
            } else {
                let node = SCNNode()
                node.name = "\(container.name ?? "world.layer").chunk.\(key.column).\(key.row)"
                let minimum = SIMD2<Float>(
                    Float(key.column) * chunkSize,
                    Float(key.row) * chunkSize
                )
                chunk = Chunk(
                    node: node,
                    minimum: minimum,
                    maximum: minimum + SIMD2<Float>(repeating: chunkSize)
                )
                layer.chunks[key] = chunk
                container.addChildNode(node)
            }

            child.removeFromParentNode()
            chunk.node.addChildNode(child)
            chunk.nodeCount += 1
        }

        layers.append(layer)
        // The next evaluation must actually run, whatever the camera did before this layer existed.
        lastEvaluatedPosition = nil
    }

    /// Attaches and detaches chunks for the current camera position. Cheap to call every tick.
    func update(cameraPosition: SIMD3<Float>) {
        guard !layers.isEmpty else { return }
        guard cameraPosition.x.isFinite, cameraPosition.y.isFinite, cameraPosition.z.isFinite else {
            return
        }

        if let last = lastEvaluatedPosition {
            let planarMovement = simd_distance(
                SIMD2<Float>(last.x, last.z),
                SIMD2<Float>(cameraPosition.x, cameraPosition.z)
            )
            if planarMovement < Self.reevaluationDistance,
               abs(last.y - cameraPosition.y) < Self.reevaluationAltitude {
                return
            }
        }
        lastEvaluatedPosition = cameraPosition

        let planar = SIMD2<Float>(cameraPosition.x, cameraPosition.z)
        let altitude = max(0.0, cameraPosition.y)

        for layer in layers {
            let attachRadius = min(
                layer.policy.maximumRadius,
                layer.policy.groundRadius + altitude * layer.policy.altitudeFactor
            )
            let detachRadius = attachRadius + layer.policy.hysteresis

            for chunk in layer.chunks.values {
                let distance = Self.planarDistance(from: planar, toBox: chunk)
                if chunk.isAttached {
                    if distance > detachRadius {
                        chunk.node.removeFromParentNode()
                        chunk.isAttached = false
                    }
                } else if distance <= attachRadius {
                    layer.root.addChildNode(chunk.node)
                    chunk.isAttached = true
                }
            }
        }
    }

    private static func planarDistance(from point: SIMD2<Float>, toBox chunk: Chunk) -> Float {
        let clamped = simd_clamp(point, chunk.minimum, chunk.maximum)
        return simd_distance(point, clamped)
    }
}
