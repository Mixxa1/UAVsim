import Foundation

/// Owns the LiDAR payload's control state and emits mission signals on power/scan transitions.
/// Mirrors `PayloadRangefinderController`; the point-cloud accumulation and geometry live in the
/// scene layer, which reports its statistics back through `updateStatistics`.
final class PayloadLidarController {
    private enum Limits {
        static let minPitchDegrees = -90.0
        // Up to the horizon (a touch above) so the sensor can be aimed at building facades, not
        // only at the ground.
        static let maxPitchDegrees = 15.0
        static let minFanDegrees = 10.0
        static let maxFanDegrees = 120.0
    }

    private(set) var opticsState = PayloadLidarOpticsState()

    private var pendingMissionSignals: [PayloadMissionSignal] = []
    private var lastEmittedPowerState: Bool?

    func setAvailability(isAvailable: Bool, isPowered: Bool, feedLabel: String? = nil) {
        opticsState.isAvailable = isAvailable
        opticsState.isPowered = isPowered
        if let feedLabel {
            opticsState.feedLabel = feedLabel
        }
        if !isAvailable || !isPowered {
            opticsState.isScanning = false
        }
        if lastEmittedPowerState != isPowered {
            pendingMissionSignals.append(.lidarPowered(isPowered))
            lastEmittedPowerState = isPowered
        }
    }

    func setScanning(_ enabled: Bool) {
        guard opticsState.isAvailable, opticsState.isPowered else {
            opticsState.isScanning = false
            return
        }
        opticsState.isScanning = enabled
    }

    func toggleScanning() {
        setScanning(!opticsState.isScanning)
    }

    func adjustGimbal(yawDeltaDegrees: Double = 0.0, pitchDeltaDegrees: Double = 0.0) {
        opticsState.gimbalPitchDegrees = min(
            max(opticsState.gimbalPitchDegrees + pitchDeltaDegrees, Limits.minPitchDegrees),
            Limits.maxPitchDegrees
        )
        opticsState.gimbalYawDegrees = normalizedYawDegrees(
            opticsState.gimbalYawDegrees + yawDeltaDegrees
        )
    }

    private func normalizedYawDegrees(_ value: Double) -> Double {
        var wrapped = value.truncatingRemainder(dividingBy: 360.0)
        if wrapped <= -180.0 {
            wrapped += 360.0
        } else if wrapped > 180.0 {
            wrapped -= 360.0
        }
        return wrapped
    }

    func setFanFieldOfView(_ degrees: Double) {
        opticsState.fanFieldOfViewDegrees = min(
            max(degrees, Limits.minFanDegrees),
            Limits.maxFanDegrees
        )
    }

    func resetGimbalOrientation() {
        opticsState.gimbalPitchDegrees = -90.0
        opticsState.gimbalYawDegrees = 0.0
    }

    /// Filter changes discard the survey: a coarser cloud cannot be refined back, and raw returns a
    /// previous voxel pass threw away cannot be recovered. Returns true when the cloud must be
    /// cleared, so the caller can do it and say so.
    @discardableResult
    func setVoxelSize(_ size: LidarVoxelSize) -> Bool {
        guard opticsState.voxelSize != size else { return false }
        opticsState.voxelSize = size
        return true
    }

    @discardableResult
    func setRetainsRawReturns(_ enabled: Bool) -> Bool {
        guard opticsState.retainsRawReturns != enabled else { return false }
        opticsState.retainsRawReturns = enabled
        return true
    }

    /// Purely a view change — the stored returns are untouched, only their colouring is re-derived.
    @discardableResult
    func setColorMode(_ mode: LidarColorMode) -> Bool {
        guard opticsState.colorMode != mode else { return false }
        opticsState.colorMode = mode
        return true
    }

    func updateStatistics(
        capturedPointCount: Int,
        rawReturnCount: Int = 0,
        coverageSquareMeters: Double,
        meanReturnsPerPoint: Double,
        scanCount: Int,
        isBufferFull: Bool
    ) {
        opticsState.capturedPointCount = capturedPointCount
        opticsState.rawReturnCount = rawReturnCount
        opticsState.coverageSquareMeters = coverageSquareMeters
        opticsState.meanReturnsPerPoint = meanReturnsPerPoint
        opticsState.scanCount = scanCount
        opticsState.isBufferFull = isBufferFull
    }

    func consumeMissionSignals() -> [PayloadMissionSignal] {
        let output = pendingMissionSignals
        pendingMissionSignals.removeAll(keepingCapacity: true)
        return output
    }
}
