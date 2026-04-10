import Foundation
import simd

struct MissionAutopilotCommand: Equatable {
    var targetMarker: TargetMarkerState?
    var startNavigation: Bool

    static let clear = MissionAutopilotCommand(
        targetMarker: nil,
        startNavigation: false
    )
}

struct MissionAutopilotControlEnvelope: Equatable {
    var axisScale: Float
    var forceSpeedBoost: Bool

    static let `default` = MissionAutopilotControlEnvelope(
        axisScale: 1.0,
        forceSpeedBoost: false
    )
}

final class MissionAutopilotAdapter {
    func bind(target: MissionTarget, startNavigation: Bool) -> MissionAutopilotCommand {
        MissionAutopilotCommand(
            targetMarker: TargetMarkerState(position: target.position),
            startNavigation: startNavigation
        )
    }

    func clear() -> MissionAutopilotCommand {
        .clear
    }

    func resolvedTravelAltitude(
        for plan: MissionPlan?,
        baselineAltitude: Float,
        terrainMaxAltitude: Float
    ) -> Float {
        guard let plan else {
            return min(max(0.0, baselineAltitude), max(0.0, terrainMaxAltitude))
        }
        return plan.constraints.clampedMissionAltitude(
            baselineAltitude,
            terrainMaxAltitude: terrainMaxAltitude
        )
    }

    func controlEnvelope(
        for plan: MissionPlan?,
        currentHorizontalSpeed: Float,
        profileMaxSpeed: Float
    ) -> MissionAutopilotControlEnvelope {
        guard let plan, profileMaxSpeed > 0.05 else {
            return .default
        }

        let effectiveMaxSpeed = plan.constraints.speed.effectiveMaximum(
            profileMaxSpeed: profileMaxSpeed
        )
        let hasCustomMaxSpeed = plan.constraints.speed.hasCustomMaximum(
            profileMaxSpeed: profileMaxSpeed
        )
        let axisScale: Float = {
            guard hasCustomMaxSpeed else {
                return 1.0
            }
            return max(0.08, min(1.0, effectiveMaxSpeed / profileMaxSpeed))
        }()
        let minimumSpeed = max(0.0, plan.constraints.speed.minimumMetersPerSecond)
        let forceSpeedBoost = minimumSpeed > 0.05 &&
            currentHorizontalSpeed + 0.25 < min(minimumSpeed, profileMaxSpeed)

        return MissionAutopilotControlEnvelope(
            axisScale: axisScale,
            forceSpeedBoost: forceSpeedBoost
        )
    }

    func isBound(
        activeTarget: MissionTarget?,
        currentMarker: TargetMarkerState?
    ) -> Bool {
        guard let activeTarget, let currentMarker else {
            return false
        }
        return simd_distance(activeTarget.position, currentMarker.position) <= 0.001
    }
}
