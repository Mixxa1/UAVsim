import Foundation

final class PayloadRangefinderController {
    private enum GimbalConstants {
        static let minGimbalPitchDegrees = -90.0
        static let maxGimbalPitchDegrees = 35.0
        static let significantDistanceChangeMeters = 0.5
        static let minFieldOfViewDegrees = 0.5
    }

    private(set) var opticsState = PayloadRangefinderOpticsState()

    private var pendingMissionSignals: [PayloadMissionSignal] = []
    private var lastEmittedPowerState: Bool?
    private var lastReportedDistance: Double?

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
            opticsState.isArmed = false
            opticsState.measuredDistanceMeters = nil
            lastReportedDistance = nil
        }

        if lastEmittedPowerState != isPowered {
            pendingMissionSignals.append(.rangefinderPowered(isPowered))
            lastEmittedPowerState = isPowered
        }
    }

    func setArmed(_ enabled: Bool) {
        guard opticsState.isAvailable, opticsState.isPowered else {
            opticsState.isArmed = false
            return
        }
        opticsState.isArmed = enabled
        if !enabled {
            opticsState.measuredDistanceMeters = nil
            lastReportedDistance = nil
        }
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

    func setZoom(_ value: Double) {
        let clampedZoom = min(max(value, opticsState.minZoom), opticsState.maxZoom)
        opticsState.zoomLevel = clampedZoom
        opticsState.currentFieldOfViewDegrees = max(
            GimbalConstants.minFieldOfViewDegrees,
            opticsState.baseFieldOfViewDegrees / clampedZoom
        )
    }

    func updateMeasuredDistance(_ meters: Double?) {
        opticsState.measuredDistanceMeters = meters
        guard let meters else {
            lastReportedDistance = nil
            return
        }
        if lastReportedDistance == nil || abs((lastReportedDistance ?? 0.0) - meters) >= GimbalConstants.significantDistanceChangeMeters {
            pendingMissionSignals.append(.rangeMeasured(distanceMeters: meters))
            lastReportedDistance = meters
        }
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
