import Foundation
import simd

struct MissionProgressUpdate: Equatable {
    var distanceToActiveTarget: Float?
    var hasReachedActiveTarget: Bool
    var hasBoundTarget: Bool
}

final class MissionProgressTracker {
    func evaluate(
        executionState: MissionExecutionState,
        planarPosition: SIMD2<Float>,
        currentMarker: TargetMarkerState?,
        autoNavigationStatus: AutoNavigationStatus,
        flightMode: DroneFlightMode,
        airframeClass: AirframeClass,
        fixedWingParameters: FixedWingParameters?,
        fixedWingDebugState: FixedWingAutopilotDebugState?,
        adapter: MissionAutopilotAdapter
    ) -> MissionProgressUpdate {
        guard let activeTarget = executionState.activeTarget else {
            return MissionProgressUpdate(
                distanceToActiveTarget: nil,
                hasReachedActiveTarget: false,
                hasBoundTarget: false
            )
        }

        let distance = simd_distance(planarPosition, activeTarget.position)
        let arrivalRadius: Float = {
            switch airframeClass {
            case .multirotor:
                return 0.95
            case .fixedWing:
                let wing = fixedWingParameters ?? FixedWingParameters(
                    family: .conventionalSurvey,
                    minSustainableSpeedMps: 10.0,
                    cruiseSpeedMps: 17.0,
                    climbSpeedMps: 13.0,
                    stallWarningSpeedMps: 9.0,
                    waypointAcceptanceRadiusMeters: 9.0,
                    nominalTurnRateDegPerSec: 9.0,
                    bankResponseGain: 0.72,
                    climbResponseGain: 0.64,
                    descentResponseGain: 0.54,
                    dragFactor: 1.0,
                    throttleResponseGain: 0.64,
                    turnAuthority: 0.64,
                    maxBankAngleDeg: 38.0
                )
                let nominalTurnRateRad = max(0.05, wing.nominalTurnRateDegPerSec * .pi / 180.0)
                let minimumTurnRadius = max(
                    wing.waypointAcceptanceRadiusMeters * 1.05,
                    wing.cruiseSpeedMps / nominalTurnRateRad
                )
                return max(
                    wing.waypointAcceptanceRadiusMeters * 1.15,
                    minimumTurnRadius * 0.48
                )
            }
        }()
        let fixedWingRouteActive = airframeClass == .fixedWing &&
            fixedWingRouteActive(debugState: fixedWingDebugState)
        let hasBoundTarget: Bool = {
            if fixedWingRouteActive {
                return true
            }
            return adapter.isBound(
                activeTarget: activeTarget,
                currentMarker: currentMarker
            )
        }()
        let autopilotSettled = !autoNavigationStatus.isActive ||
            autoNavigationStatus.phase == .hold ||
            (airframeClass == .fixedWing && autoNavigationStatus.phase == .approach) ||
            flightMode != .autoPath
        let hasReachedActiveTarget: Bool = {
            guard hasBoundTarget else {
                return false
            }
            if airframeClass == .fixedWing,
               let fixedWingDebugState {
                let controllerWaypointIndex = fixedWingDebugState.currentWaypointIndex
                if controllerWaypointIndex > activeTarget.index {
                    return true
                }

                let finalStateReached = fixedWingDebugState.missionState == .loitering ||
                    fixedWingDebugState.missionState == .completed
                return controllerWaypointIndex >= activeTarget.index &&
                    finalStateReached &&
                    distance <= fixedWingArrivalRadius(for: fixedWingParameters)
            }

            return distance <= arrivalRadius && autopilotSettled
        }()

        return MissionProgressUpdate(
            distanceToActiveTarget: distance,
            hasReachedActiveTarget: hasReachedActiveTarget,
            hasBoundTarget: hasBoundTarget
        )
    }

    private func fixedWingRouteActive(
        debugState: FixedWingAutopilotDebugState?
    ) -> Bool {
        guard let debugState else {
            return false
        }
        switch debugState.missionState {
        case .idle, .failed:
            return false
        case .aligningToLaunch,
             .climbout,
             .capturingLeg,
             .trackingLeg,
             .flyByTurn,
             .loitering,
             .completed,
             .recoveringSpeed:
            return true
        }
    }

    private func fixedWingArrivalRadius(
        for fixedWingParameters: FixedWingParameters?
    ) -> Float {
        let wing = fixedWingParameters ?? FixedWingParameters(
            family: .conventionalSurvey,
            minSustainableSpeedMps: 10.0,
            cruiseSpeedMps: 17.0,
            climbSpeedMps: 13.0,
            stallWarningSpeedMps: 9.0,
            waypointAcceptanceRadiusMeters: 9.0,
            nominalTurnRateDegPerSec: 9.0,
            bankResponseGain: 0.72,
            climbResponseGain: 0.64,
            descentResponseGain: 0.54,
            dragFactor: 1.0,
            throttleResponseGain: 0.64,
            turnAuthority: 0.64,
            maxBankAngleDeg: 38.0
        )
        return max(wing.waypointAcceptanceRadiusMeters * 1.15, 10.0)
    }
}
