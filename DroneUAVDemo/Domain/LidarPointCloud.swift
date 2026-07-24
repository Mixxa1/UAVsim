import Foundation
import simd

/// A geo-referenced LiDAR point cloud accumulated over a flight.
///
/// The cloud stores each return in the simulator's local ENU metre-space (the coordinates the
/// scene and the raycaster already speak). It is *geo-referenced* because it also holds the world's
/// `GeoOrigin`: every local point maps deterministically to a WGS84 latitude/longitude/altitude, so
/// the real-world coordinates are recovered on export rather than paid for — in memory — on every
/// one of the hundreds of thousands of points a survey produces.
///
/// Growth is bounded by a voxel grid rather than by time. A new return is dropped when its voxel
/// already holds a point, so flying the same rooftop twice does not double the cloud; the size
/// tracks the *surface area covered*, which is what a survey cares about, and a dense city block
/// settles instead of growing without limit. A hard `maximumPoints` ceiling is the final backstop.
struct LidarPointCloud {
    struct Point: Equatable {
        /// Local ENU metres: +X east, +Y up, +Z north (the project-wide convention).
        let position: SIMD3<Float>
        /// Synthetic return strength in [0, 1] — steeper incidence and longer range read weaker,
        /// the way a real sensor's intensity channel does.
        let intensity: Float
    }

    private(set) var points: [Point] = []
    /// Occupied 3-D voxels, for deduplication.
    private var occupiedVoxels: Set<Int64> = []
    /// Occupied 2-D ground columns, for the coverage read-out.
    private var occupiedColumns: Set<Int64> = []

    let voxelSizeMeters: Float
    let maximumPoints: Int

    private(set) var minBounds = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    private(set) var maxBounds = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

    init(voxelSizeMeters: Float = 0.5, maximumPoints: Int = 600_000) {
        self.voxelSizeMeters = max(0.05, voxelSizeMeters)
        self.maximumPoints = max(1_000, maximumPoints)
    }

    var isEmpty: Bool { points.isEmpty }
    var count: Int { points.count }
    var isFull: Bool { points.count >= maximumPoints }

    /// Footprint actually mapped, in square metres — occupied ground columns times cell area.
    var coverageSquareMeters: Float {
        Float(occupiedColumns.count) * voxelSizeMeters * voxelSizeMeters
    }

    /// Vertical span of the returns; nil while empty.
    var elevationRange: (minimum: Float, maximum: Float)? {
        guard !points.isEmpty else { return nil }
        return (minBounds.y, maxBounds.y)
    }

    /// Inserts a return, deduplicated to one point per voxel. Returns `true` when the point was new
    /// (so the scene layer can append just the fresh point to its geometry instead of rebuilding).
    @discardableResult
    mutating func insert(position: SIMD3<Float>, intensity: Float) -> Bool {
        guard points.count < maximumPoints else { return false }
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { return false }
        let voxel = voxelKey(position)
        guard occupiedVoxels.insert(voxel).inserted else { return false }
        occupiedColumns.insert(columnKey(position))
        points.append(Point(position: position, intensity: max(0, min(1, intensity))))
        minBounds = simd_min(minBounds, position)
        maxBounds = simd_max(maxBounds, position)
        return true
    }

    mutating func clear() {
        points.removeAll(keepingCapacity: true)
        occupiedVoxels.removeAll(keepingCapacity: true)
        occupiedColumns.removeAll(keepingCapacity: true)
        minBounds = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        maxBounds = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    }

    // MARK: - Voxel keys

    private func quantise(_ value: Float) -> Int32 {
        Int32((value / voxelSizeMeters).rounded(.down))
    }

    private func voxelKey(_ position: SIMD3<Float>) -> Int64 {
        let x = Int64(quantise(position.x)) & 0x1F_FFFF
        let y = Int64(quantise(position.y)) & 0x1F_FFFF
        let z = Int64(quantise(position.z)) & 0x1F_FFFF
        return (x << 42) | (y << 21) | z
    }

    private func columnKey(_ position: SIMD3<Float>) -> Int64 {
        let x = Int64(quantise(position.x)) & 0xFFFF_FFFF
        let z = Int64(quantise(position.z)) & 0xFFFF_FFFF
        return (x << 32) | z
    }

    // MARK: - Export

    /// Elevation-ramped RGB for a point, matching the live scene colouring so an exported PLY looks
    /// like what the pilot saw. Blue (low) → green → yellow → red (high) over the cloud's own span.
    static func elevationColor(
        y: Float,
        minimum: Float,
        maximum: Float
    ) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let span = max(0.001, maximum - minimum)
        let t = max(0, min(1, (y - minimum) / span))
        // Four-stop ramp.
        let stops: [(Float, Float, Float)] = [
            (0.13, 0.32, 0.75), // low  — blue
            (0.20, 0.70, 0.45), // teal-green
            (0.85, 0.80, 0.25), // yellow
            (0.85, 0.22, 0.18)  // high — red
        ]
        let scaled = t * Float(stops.count - 1)
        let index = min(stops.count - 2, Int(scaled))
        let localT = scaled - Float(index)
        let a = stops[index]
        let b = stops[index + 1]
        func channel(_ lhs: Float, _ rhs: Float) -> UInt8 {
            UInt8(max(0, min(255, (lhs + (rhs - lhs) * localT) * 255)))
        }
        return (channel(a.0, b.0), channel(a.1, b.1), channel(a.2, b.2))
    }

    /// ASCII PLY in local metres with elevation colour — the format CloudCompare/MeshLab open
    /// directly. Local coordinates, because a point-cloud viewer works in a metric frame; the
    /// real-world coordinates live in the CSV companion.
    func plyData() -> Data {
        let minimum = minBounds.y
        let maximum = maxBounds.y
        var text = ""
        text.reserveCapacity(points.count * 40 + 256)
        text += "ply\n"
        text += "format ascii 1.0\n"
        text += "comment Generated by UAVsim LiDAR payload\n"
        text += "element vertex \(points.count)\n"
        text += "property float x\nproperty float y\nproperty float z\n"
        text += "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        text += "end_header\n"
        for point in points {
            let color = Self.elevationColor(y: point.position.y, minimum: minimum, maximum: maximum)
            text += "\(point.position.x) \(point.position.y) \(point.position.z) "
            text += "\(color.red) \(color.green) \(color.blue)\n"
        }
        return Data(text.utf8)
    }

    /// The geo-referenced dataset: WGS84 latitude/longitude/MSL altitude per point, computed from
    /// the world origin, plus the local frame and intensity. Opens in any GIS, QGIS or a spreadsheet.
    func geoCSVData(origin: GeoOrigin) -> Data {
        var text = ""
        text.reserveCapacity(points.count * 64 + 128)
        text += "latitude_deg,longitude_deg,altitude_msl_m,intensity,local_east_m,local_up_m,local_north_m\n"
        for point in points {
            let coordinate = origin.geographic(ofLocalPosition: point.position)
            text += String(
                format: "%.8f,%.8f,%.3f,%.3f,%.3f,%.3f,%.3f\n",
                coordinate.latitudeDegrees,
                coordinate.longitudeDegrees,
                coordinate.altitudeMetersMSL,
                Double(point.intensity),
                Double(point.position.x),
                Double(point.position.y),
                Double(point.position.z)
            )
        }
        return Data(text.utf8)
    }
}
