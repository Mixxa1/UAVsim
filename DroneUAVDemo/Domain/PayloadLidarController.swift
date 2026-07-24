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

    func updateStatistics(
        capturedPointCount: Int,
        coverageSquareMeters: Double,
        isBufferFull: Bool
    ) {
        opticsState.capturedPointCount = capturedPointCount
        opticsState.coverageSquareMeters = coverageSquareMeters
        opticsState.isBufferFull = isBufferFull
    }

    func consumeMissionSignals() -> [PayloadMissionSignal] {
        let output = pendingMissionSignals
        pendingMissionSignals.removeAll(keepingCapacity: true)
        return output
    }
}
