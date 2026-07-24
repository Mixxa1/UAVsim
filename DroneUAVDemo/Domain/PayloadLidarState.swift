import Foundation

/// Observable state of the LiDAR survey payload — power, scan enable, the down-looking gimbal and
/// the fan geometry, plus the live statistics the scene layer feeds back each tick (point count,
/// coverage, buffer-full flag). Mirrors `PayloadRangefinderOpticsState`; the accumulated cloud
/// itself lives in the scene layer, which owns the raycaster and the geometry.
struct PayloadLidarOpticsState: Codable, Equatable {
    var isAvailable: Bool
    var isPowered: Bool
    /// Whether the sweep is actively accumulating points as the aircraft flies.
    var isScanning: Bool

    /// Boresight pitch of the sensor. −90° looks straight down (nadir survey).
    var gimbalPitchDegrees: Double
    /// Boresight yaw of the sensor, relative to the airframe. 0° looks forward.
    var gimbalYawDegrees: Double
    /// Total cross-track fan angle swept each tick, centred on the boresight.
    var fanFieldOfViewDegrees: Double
    /// Beams per cross-track sweep.
    var beamCount: Int
    var maxRangeMeters: Double

    // Live statistics, written by the scene layer.
    var capturedPointCount: Int
    var coverageSquareMeters: Double
    var isBufferFull: Bool

    var feedLabel: String

    init(
        isAvailable: Bool = true,
        isPowered: Bool = true,
        isScanning: Bool = false,
        gimbalPitchDegrees: Double = -90.0,
        gimbalYawDegrees: Double = 0.0,
        fanFieldOfViewDegrees: Double = 70.0,
        beamCount: Int = 48,
        maxRangeMeters: Double = 350.0,
        capturedPointCount: Int = 0,
        coverageSquareMeters: Double = 0.0,
        isBufferFull: Bool = false,
        feedLabel: String = "LIDAR"
    ) {
        self.isAvailable = isAvailable
        self.isPowered = isPowered
        self.isScanning = isScanning
        self.gimbalPitchDegrees = gimbalPitchDegrees
        self.gimbalYawDegrees = gimbalYawDegrees
        self.fanFieldOfViewDegrees = fanFieldOfViewDegrees
        self.beamCount = beamCount
        self.maxRangeMeters = maxRangeMeters
        self.capturedPointCount = capturedPointCount
        self.coverageSquareMeters = coverageSquareMeters
        self.isBufferFull = isBufferFull
        self.feedLabel = feedLabel
    }
}
