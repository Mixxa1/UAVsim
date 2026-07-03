import Foundation

/// Parallel to `PayloadRangefinderController` — same gimbal clamp/wrap conventions, adapted to
/// the hose's spray/aim semantics instead of arm/measure.
final class PayloadFireHoseController {
    private enum GimbalConstants {
        static let minGimbalPitchDegrees = -90.0
        static let maxGimbalPitchDegrees = 35.0
    }

    private(set) var opticsState = PayloadFireHoseOpticsState(nozzleThrowMeters: Double(FireHoseTuning.default.nozzleThrowMeters))

    private var pendingMissionSignals: [PayloadMissionSignal] = []
    private var lastEmittedPowerState: Bool?

    func setAvailability(
        isAvailable: Bool,
        isPowered: Bool,
        feedLabel: String? = nil
    ) {
        opticsState.isAvailable = isAvailable
        opticsState.isPowered = isPowered
        if let feedLabel {
            opticsState.feedLabel = feedLabel
        }

        if !isAvailable || !isPowered {
            opticsState.isSpraying = false
            opticsState.aimedFireTreeIndex = nil
            opticsState.suppressionProgress = 0.0
        }

        if lastEmittedPowerState != isPowered {
            pendingMissionSignals.append(.hosePowered(isPowered))
            lastEmittedPowerState = isPowered
        }
    }

    func setSpraying(_ enabled: Bool) {
        guard opticsState.isAvailable, opticsState.isPowered else {
            opticsState.isSpraying = false
            return
        }
        opticsState.isSpraying = enabled
    }

    func adjustGimbal(yawDeltaDegrees: Double, pitchDeltaDegrees: Double) {
        opticsState.gimbalYawDegrees = normalizedYawDegrees(opticsState.gimbalYawDegrees + yawDeltaDegrees)
        opticsState.gimbalPitchDegrees = min(
            max(
                opticsState.gimbalPitchDegrees + pitchDeltaDegrees,
                GimbalConstants.minGimbalPitchDegrees
            ),
            GimbalConstants.maxGimbalPitchDegrees
        )
    }

    func resetGimbalOrientation() {
        opticsState.gimbalYawDegrees = 0.0
        opticsState.gimbalPitchDegrees = -12.0
    }

    func updateAimedFire(index: Int?, progress: Double) {
        opticsState.aimedFireTreeIndex = index
        opticsState.suppressionProgress = index == nil ? 0.0 : progress
    }

    func consumeMissionSignals() -> [PayloadMissionSignal] {
        let output = pendingMissionSignals
        pendingMissionSignals.removeAll(keepingCapacity: true)
        return output
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
}
