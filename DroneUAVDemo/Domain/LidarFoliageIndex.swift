import Foundation
import simd

/// Tree crowns as porous volumes, for the LiDAR only.
///
/// The flight model represents a tree by a narrow trunk-and-cone collision proxy, and that proxy is
/// shared by collision resolution, the multirotor's obstacle avoidance, ground-height queries and
/// the fixed-wing pre-launch check. Widening it to match the rendered crown would therefore change
/// how the aircraft flies — in dense foliage, exactly where avoidance has historically been
/// touchy — for the sake of a sensor detail. So the sensor gets its own model instead, read by
/// nothing else in the simulator.
///
/// Physically this is also the better description: a crown is not a wall. The beam enters, and each
/// metre of foliage it crosses has some chance of sending part of the pulse back — Beer-Lambert
/// extinction through a medium of leaves — which is why real foliage returns are scattered through
/// the crown's depth rather than lying on its surface, and why a pulse routinely produces a canopy
/// return *and* a ground return behind it.
struct LidarFoliageIndex {

    struct Volume {
        /// Centre of the crown ellipsoid, in local ENU metres.
        let center: SIMD3<Float>
        /// Horizontal semi-axis.
        let radius: Float
        /// Vertical semi-axis.
        let halfHeight: Float
        /// Extinction coefficient, per metre of foliage traversed. Denser crowns stop the beam
        /// sooner and return more of it near the top.
        let density: Float
    }

    private static let cellSize: Float = 32.0

    private let volumes: [Volume]
    private var cells: [Int64: [Int32]] = [:]
    /// Widest crown in the set — how far outside the query box a crown's centre may sit and still
    /// be crossed by the ray.
    private let maximumRadius: Float

    var isEmpty: Bool { volumes.isEmpty }
    var count: Int { volumes.count }
    /// The crowns themselves — the environment registry describes the same trees as objects.
    var allVolumes: [Volume] { volumes }

    init(volumes: [Volume]) {
        self.volumes = volumes
        self.maximumRadius = volumes.reduce(0) { max($0, $1.radius) }
        // Each crown is registered in exactly one cell — the one holding its centre. Queries widen
        // their box by `maximumRadius` to compensate, which keeps a crown from ever appearing in
        // two buckets and so removes the need to de-duplicate hits per ray. That de-duplication was
        // a set allocation on every beam of every sweep.
        for (index, volume) in volumes.enumerated() {
            let x = Int32((volume.center.x / Self.cellSize).rounded(.down))
            let z = Int32((volume.center.z / Self.cellSize).rounded(.down))
            cells[Self.key(x, z), default: []].append(Int32(index))
        }
    }

    private static func key(_ x: Int32, _ z: Int32) -> Int64 {
        (Int64(x) << 32) | Int64(UInt32(bitPattern: z))
    }

    /// Crowns whose cells the ray's horizontal footprint covers. Deliberately a box sweep rather
    /// than a DDA: a LiDAR ray is short and mostly vertical, so the footprint is a handful of cells.
    func candidates(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        maxDistance: Float,
        _ body: (Volume) -> Void
    ) {
        guard !volumes.isEmpty else { return }
        let end = origin + direction * maxDistance
        let pad = maximumRadius
        let minimumX = Int32(((min(origin.x, end.x) - pad) / Self.cellSize).rounded(.down))
        let maximumX = Int32(((max(origin.x, end.x) + pad) / Self.cellSize).rounded(.down))
        let minimumZ = Int32(((min(origin.z, end.z) - pad) / Self.cellSize).rounded(.down))
        let maximumZ = Int32(((max(origin.z, end.z) + pad) / Self.cellSize).rounded(.down))
        // A grazing ray at full range would sweep a very wide box; cap the work rather than let one
        // beam walk the whole city.
        guard (maximumX - minimumX) * (maximumZ - minimumZ) <= 4_096 else { return }

        for x in minimumX...maximumX {
            for z in minimumZ...maximumZ {
                guard let bucket = cells[Self.key(x, z)] else { continue }
                for index in bucket {
                    body(volumes[Int(index)])
                }
            }
        }
    }

    /// Entry and exit distances where the ray crosses the crown ellipsoid, or nil if it misses.
    /// Scaling the ray into the ellipsoid's unit-sphere space leaves the distance parameter intact,
    /// so the results are already in metres along the original ray.
    static func intersection(
        volume: Volume,
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        maxDistance: Float
    ) -> (entry: Float, exit: Float)? {
        let scale = SIMD3<Float>(
            1.0 / max(volume.radius, 0.05),
            1.0 / max(volume.halfHeight, 0.05),
            1.0 / max(volume.radius, 0.05)
        )
        let offset = (origin - volume.center) * scale
        let scaled = direction * scale

        let a = simd_dot(scaled, scaled)
        guard a > 1e-9 else { return nil }
        let b = 2.0 * simd_dot(offset, scaled)
        let c = simd_dot(offset, offset) - 1.0
        let discriminant = b * b - 4.0 * a * c
        guard discriminant > 0 else { return nil }

        let root = discriminant.squareRoot()
        let first = (-b - root) / (2.0 * a)
        let second = (-b + root) / (2.0 * a)
        let entry = max(0.0, min(first, second))
        let exit = min(maxDistance, max(first, second))
        guard exit > entry else { return nil }
        return (entry, exit)
    }
}
