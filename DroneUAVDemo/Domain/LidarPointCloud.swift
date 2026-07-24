import Foundation
import simd

/// A geo-referenced LiDAR point cloud accumulated over a flight.
///
/// Points are held in the simulator's local ENU metre-space — the frame the scene and the raycaster
/// already speak — and the cloud carries the world's `GeoOrigin`, so every point maps deterministically
/// to WGS84 on export. Doing the projection at export rather than per return keeps hundreds of
/// thousands of points cheap while still producing a genuinely geo-referenced dataset.
///
/// Each return keeps the attributes a real scanner records, because a cloud of bare XYZ cannot be
/// analysed: `intensity` (with surface reflectance and incidence folded in), `range`, a per-beam
/// `timestamp`, the `ring` (channel index within the sweep), the `scanID` of the sweep, and the
/// surface `classification`. Sweep trajectories are stored alongside, so the pose that produced any
/// return can be recovered and motion distortion measured rather than assumed away.
///
/// Two accumulation modes:
/// * **Voxel** — one point per occupied voxel, positioned at the **centroid** of every return that
///   fell in it, with intensity and range averaged and the contributing count kept. Averaging is what
///   makes the filter a noise reducer rather than an arbitrary sampler: ranging noise is zero-mean, so
///   `n` returns in a voxel cut its standard deviation by `√n`.
/// * **Raw** — no filtering at all. Every return is stored, which is the only mode in which sensor
///   noise, multi-hit structure and motion distortion survive to be studied.
struct LidarPointCloud {

    struct Point {
        /// Local ENU metres: +X east, +Y up, +Z north.
        var position: SIMD3<Float>
        /// Return strength in [0, 1] — surface reflectance × incidence × range falloff.
        var intensity: Float
        /// Sensor-to-surface distance in metres, before any voxel averaging.
        var range: Float
        /// Seconds since the cloud's first return. Per beam, not per sweep.
        var timestamp: Double
        var scanID: UInt32
        /// Beam index within the sweep — the scanner's channel.
        var ring: UInt16
        var classification: LidarSurfaceClass
        /// Returns merged into this point: 1 in raw mode, ≥1 for a voxel centroid.
        var returnCount: UInt32
    }

    /// The sensor trajectory for one sweep. Start and end are recorded separately because the
    /// aircraft moves *while* the fan sweeps — that difference is the motion distortion.
    struct ScanPose {
        let scanID: UInt32
        let startTimestamp: Double
        let endTimestamp: Double
        let startPosition: SIMD3<Float>
        let endPosition: SIMD3<Float>
        let startOrientation: simd_quatf
        let endOrientation: simd_quatf
        let vehiclePosition: SIMD3<Float>
        let vehicleOrientation: simd_quatf
    }

    enum InsertResult {
        /// A new point was appended at this index — the visual layer should draw it.
        case inserted(Int)
        /// Merged into an existing voxel at this index; nothing new to draw.
        case merged(Int)
        case rejected
    }

    /// Running sums behind a voxel centroid. Kept parallel to `points` and only in voxel mode.
    private struct Accumulator {
        var positionSum: SIMD3<Double>
        var intensitySum: Double
        var rangeSum: Double
        var count: UInt32
    }

    private(set) var points: [Point] = []
    private var accumulators: [Accumulator] = []
    private var voxelIndex: [Int64: Int] = [:]
    private var occupiedColumns: Set<Int64> = []
    private(set) var scanPoses: [ScanPose] = []

    /// Every return ever accepted, including those merged into an existing voxel.
    private(set) var totalReturns: UInt64 = 0

    private(set) var voxelSizeMeters: Float
    private(set) var isRawMode: Bool
    let maximumPoints: Int

    private(set) var minBounds = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    private(set) var maxBounds = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)

    init(
        voxelSizeMeters: Float = LidarVoxelSize.coarse.rawValue,
        isRawMode: Bool = false,
        maximumPoints: Int = 1_200_000
    ) {
        self.voxelSizeMeters = max(0.02, voxelSizeMeters)
        self.isRawMode = isRawMode
        self.maximumPoints = max(1_000, maximumPoints)
    }

    var isEmpty: Bool { points.isEmpty }
    var count: Int { points.count }
    var isFull: Bool { points.count >= maximumPoints }

    /// Footprint mapped, in square metres — occupied ground columns times cell area.
    var coverageSquareMeters: Float {
        let cell = max(voxelSizeMeters, 0.1)
        return Float(occupiedColumns.count) * cell * cell
    }

    var elevationRange: (minimum: Float, maximum: Float)? {
        guard !points.isEmpty else { return nil }
        return (minBounds.y, maxBounds.y)
    }

    /// Mean returns per stored point — 1.0 in raw mode, higher where the survey overlapped itself.
    /// A direct read-out of how much noise averaging the voxel filter actually performed. Kept as a
    /// running total rather than a reduce: the HUD asks for this every sweep, and walking a
    /// million-point array sixty times a second would cost more than the scan itself.
    var meanReturnsPerPoint: Float {
        guard !points.isEmpty else { return 0 }
        return Float(Double(totalReturns) / Double(points.count))
    }

    // MARK: - Configuration

    /// Changing the filter invalidates what is already stored — a coarser cloud cannot be refined
    /// back, and raw returns discarded by a previous voxel pass cannot be recovered — so the survey
    /// starts clean. The caller is expected to make that visible in the UI.
    mutating func reconfigure(voxelSizeMeters: Float, isRawMode: Bool) {
        self.voxelSizeMeters = max(0.02, voxelSizeMeters)
        self.isRawMode = isRawMode
        clear()
    }

    // MARK: - Accumulation

    @discardableResult
    mutating func insert(_ point: Point) -> InsertResult {
        guard points.count < maximumPoints else { return .rejected }
        guard point.position.x.isFinite, point.position.y.isFinite, point.position.z.isFinite else {
            return .rejected
        }

        if isRawMode {
            points.append(point)
            totalReturns &+= 1
            occupiedColumns.insert(columnKey(point.position))
            expandBounds(point.position)
            return .inserted(points.count - 1)
        }

        let key = voxelKey(point.position)
        if let existing = voxelIndex[key] {
            accumulators[existing].positionSum += SIMD3<Double>(point.position)
            accumulators[existing].intensitySum += Double(point.intensity)
            accumulators[existing].rangeSum += Double(point.range)
            accumulators[existing].count &+= 1
            totalReturns &+= 1

            let accumulator = accumulators[existing]
            let inverse = 1.0 / Double(accumulator.count)
            let centroid = accumulator.positionSum * inverse
            points[existing].position = SIMD3<Float>(centroid)
            points[existing].intensity = Float(accumulator.intensitySum * inverse)
            points[existing].range = Float(accumulator.rangeSum * inverse)
            points[existing].returnCount = accumulator.count
            expandBounds(points[existing].position)
            return .merged(existing)
        }

        var stored = point
        stored.returnCount = 1
        points.append(stored)
        accumulators.append(Accumulator(
            positionSum: SIMD3<Double>(point.position),
            intensitySum: Double(point.intensity),
            rangeSum: Double(point.range),
            count: 1
        ))
        voxelIndex[key] = points.count - 1
        totalReturns &+= 1
        occupiedColumns.insert(columnKey(point.position))
        expandBounds(point.position)
        return .inserted(points.count - 1)
    }

    mutating func recordScanPose(_ pose: ScanPose) {
        scanPoses.append(pose)
    }

    mutating func clear() {
        points.removeAll(keepingCapacity: true)
        accumulators.removeAll(keepingCapacity: true)
        voxelIndex.removeAll(keepingCapacity: true)
        occupiedColumns.removeAll(keepingCapacity: true)
        scanPoses.removeAll(keepingCapacity: true)
        totalReturns = 0
        minBounds = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        maxBounds = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    }

    private mutating func expandBounds(_ position: SIMD3<Float>) {
        minBounds = simd_min(minBounds, position)
        maxBounds = simd_max(maxBounds, position)
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

    // MARK: - Colour

    /// RGB for a return under the selected view. Used identically on screen and in the export, so a
    /// PLY opens looking like what the pilot was shown.
    static func color(
        for point: Point,
        mode: LidarColorMode,
        elevationMinimum: Float,
        elevationMaximum: Float
    ) -> (red: UInt8, green: UInt8, blue: UInt8) {
        switch mode {
        case .height:
            return elevationColor(
                y: point.position.y,
                minimum: elevationMinimum,
                maximum: elevationMaximum
            )
        case .intensity:
            let value = UInt8(max(0, min(255, point.intensity * 255)))
            return (value, value, value)
        case .material:
            return point.classification.materialColor
        case .semantic:
            return point.classification.semanticColor
        }
    }

    /// Blue (low) → green → yellow → red (high) over the cloud's own vertical span.
    static func elevationColor(
        y: Float,
        minimum: Float,
        maximum: Float
    ) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let span = max(0.001, maximum - minimum)
        let t = max(0, min(1, (y - minimum) / span))
        let stops: [(Float, Float, Float)] = [
            (0.13, 0.32, 0.75),
            (0.20, 0.70, 0.45),
            (0.85, 0.80, 0.25),
            (0.85, 0.22, 0.18)
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

    // MARK: - Export

    /// `binary_little_endian` PLY carrying the full per-return record: position, RGB under the
    /// selected view, and the physical attributes. Binary rather than ASCII because the same survey
    /// is roughly a third of the size and opens an order of magnitude faster — 39 bytes per point,
    /// fixed stride, no parsing.
    func binaryPLYData(colorMode: LidarColorMode, comment: String) -> Data {
        let minimum = minBounds.y
        let maximum = maxBounds.y

        var header = ""
        header += "ply\n"
        header += "format binary_little_endian 1.0\n"
        header += "comment Generated by UAVsim LiDAR payload\n"
        header += "comment \(comment)\n"
        header += "comment colour_mode \(colorMode.rawValue)\n"
        header += "comment classification codes follow ASPRS LAS\n"
        header += "element vertex \(points.count)\n"
        header += "property float x\n"
        header += "property float y\n"
        header += "property float z\n"
        header += "property uchar red\n"
        header += "property uchar green\n"
        header += "property uchar blue\n"
        header += "property float intensity\n"
        header += "property float range\n"
        header += "property double timestamp\n"
        header += "property uint scan_id\n"
        header += "property ushort ring\n"
        header += "property uchar classification\n"
        header += "property uchar return_count\n"
        header += "end_header\n"

        // 3×4 + 3×1 + 4 + 4 + 8 + 4 + 2 + 1 + 1 = 39 bytes per vertex.
        var data = Data(header.utf8)
        data.reserveCapacity(header.utf8.count + points.count * 39)

        for point in points {
            let color = Self.color(
                for: point,
                mode: colorMode,
                elevationMinimum: minimum,
                elevationMaximum: maximum
            )
            appendLittleEndian(&data, point.position.x)
            appendLittleEndian(&data, point.position.y)
            appendLittleEndian(&data, point.position.z)
            data.append(color.red)
            data.append(color.green)
            data.append(color.blue)
            appendLittleEndian(&data, point.intensity)
            appendLittleEndian(&data, point.range)
            appendLittleEndian(&data, point.timestamp)
            appendLittleEndian(&data, point.scanID)
            appendLittleEndian(&data, point.ring)
            data.append(point.classification.rawValue)
            data.append(UInt8(min(255, point.returnCount)))
        }
        return data
    }

    /// The geo-referenced table: WGS84 per point plus every physical attribute, for GIS and
    /// spreadsheet analysis of noise, intensity and channel structure.
    func geoCSVData(origin: GeoOrigin) -> Data {
        var text = ""
        text.reserveCapacity(points.count * 96 + 256)
        text += "latitude_deg,longitude_deg,altitude_msl_m,"
        text += "local_east_m,local_up_m,local_north_m,"
        text += "intensity,range_m,timestamp_s,scan_id,ring,classification,class_name,return_count\n"
        for point in points {
            let coordinate = origin.geographic(ofLocalPosition: point.position)
            text += String(
                format: "%.8f,%.8f,%.3f,%.3f,%.3f,%.3f,%.4f,%.3f,%.6f,%u,%u,%u,%@,%u\n",
                coordinate.latitudeDegrees,
                coordinate.longitudeDegrees,
                coordinate.altitudeMetersMSL,
                Double(point.position.x),
                Double(point.position.y),
                Double(point.position.z),
                Double(point.intensity),
                Double(point.range),
                point.timestamp,
                point.scanID,
                UInt32(point.ring),
                UInt32(point.classification.rawValue),
                point.classification.label,
                point.returnCount
            )
        }
        return Data(text.utf8)
    }

    /// Sensor trajectory, one row per sweep. Without this a cloud cannot be de-skewed or audited:
    /// the pose that produced each return would be unknown.
    func trajectoryCSVData(origin: GeoOrigin?) -> Data {
        var text = ""
        text += "scan_id,start_timestamp_s,end_timestamp_s,"
        text += "sensor_start_east_m,sensor_start_up_m,sensor_start_north_m,"
        text += "sensor_end_east_m,sensor_end_up_m,sensor_end_north_m,"
        text += "sensor_start_qx,sensor_start_qy,sensor_start_qz,sensor_start_qw,"
        text += "sensor_end_qx,sensor_end_qy,sensor_end_qz,sensor_end_qw,"
        text += "uav_east_m,uav_up_m,uav_north_m,uav_qx,uav_qy,uav_qz,uav_qw,"
        text += "sensor_latitude_deg,sensor_longitude_deg,sensor_altitude_msl_m\n"
        for pose in scanPoses {
            var line = String(
                format: "%u,%.6f,%.6f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,",
                pose.scanID,
                pose.startTimestamp,
                pose.endTimestamp,
                Double(pose.startPosition.x), Double(pose.startPosition.y), Double(pose.startPosition.z),
                Double(pose.endPosition.x), Double(pose.endPosition.y), Double(pose.endPosition.z)
            )
            line += String(
                format: "%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,",
                Double(pose.startOrientation.imag.x), Double(pose.startOrientation.imag.y),
                Double(pose.startOrientation.imag.z), Double(pose.startOrientation.real),
                Double(pose.endOrientation.imag.x), Double(pose.endOrientation.imag.y),
                Double(pose.endOrientation.imag.z), Double(pose.endOrientation.real)
            )
            line += String(
                format: "%.3f,%.3f,%.3f,%.6f,%.6f,%.6f,%.6f",
                Double(pose.vehiclePosition.x), Double(pose.vehiclePosition.y), Double(pose.vehiclePosition.z),
                Double(pose.vehicleOrientation.imag.x), Double(pose.vehicleOrientation.imag.y),
                Double(pose.vehicleOrientation.imag.z), Double(pose.vehicleOrientation.real)
            )
            if let origin {
                let coordinate = origin.geographic(ofLocalPosition: pose.startPosition)
                line += String(
                    format: ",%.8f,%.8f,%.3f",
                    coordinate.latitudeDegrees,
                    coordinate.longitudeDegrees,
                    coordinate.altitudeMetersMSL
                )
            } else {
                line += ",,,"
            }
            text += line + "\n"
        }
        return Data(text.utf8)
    }

    private func appendLittleEndian(_ data: inout Data, _ value: Float) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendLittleEndian(_ data: inout Data, _ value: Double) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendLittleEndian(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendLittleEndian(_ data: inout Data, _ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

/// Live survey read-out handed back to the HUD each sweep.
struct LidarScanStatistics {
    let pointCount: Int
    let coverageSquareMeters: Double
    /// Mean returns merged per stored point — 1.0 in raw mode, the noise-averaging factor otherwise.
    let meanReturnsPerPoint: Double
    let scanCount: Int
    let isBufferFull: Bool
}
