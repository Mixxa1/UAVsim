import Foundation

final class MissionFailsafeCoordinator {
    func resolve(
        executionState: MissionExecutionState,
        safetyState: MissionSafetyState,
        airframeClass: AirframeClass,
        flightMode: DroneFlightMode,
        missionGeofenceState: MissionGeofenceState = .inactive,
        missionGeofenceAction: MissionGeofenceAction = .warningOnly
    ) -> MissionFailsafeMode {
        if flightMode == .returnHome {
            return .returnHome
        }

        guard executionState.status == .running else {
            return .none
        }

        // The geofence is a scenario/autopilot rule, not a radio-channel effect (same principle
        // as real PX4/ArduPilot geofences) — its configured action is resolved directly, ahead of
        // the generic battery/collision/route checks below, since it's an independent trigger.
        if missionGeofenceState == .breach {
            switch missionGeofenceAction {
            case .warningOnly:
                break
            case .hold:
                return .hold
            case .returnHome:
                return .returnHome
            case .land, .missionFail:
                return .abortMission
            }
        }

        let runtime = safetyState.runtimeConstraints
        let batteryCritical = !runtime.batterySafeToContinue
        let signalCritical = !runtime.signalSafe
        let canReturnSafely = runtime.returnSafe

        // Strict invariant: automatic RTH must only be triggered by explicit
        // fail-safe conditions (signal/battery), never by generic mission noise.
        if batteryCritical || signalCritical {
            return canReturnSafely ? .returnHome : .abortMission
        }

        if airframeClass == .fixedWing || airframeClass == .hybridVTOL {
            switch safetyState.blockReason {
            case .routeInvalid:
                return .abortMission
            case .batteryUnsafe:
                return canReturnSafely ? .returnHome : .abortMission
            case .noControlAuthority:
                return .abortMission
            case .runtimeUnsafe:
                if !runtime.collisionSafe || !runtime.thermalSafe {
                    return .abortMission
                }
                return .none
            case .executionContourMissing,
                 .executionBindingFailed,
                 .runtimeDistanceUnavailable,
                 .noMissionTarget,
                 .runtimeStallDetected,
                 .missionStartBlocked,
                 .noValidatedPlan,
                 .none:
                return .none
            }
        }

        switch safetyState.blockReason {
        case .routeInvalid:
            return .abortMission
        case .executionContourMissing,
             .executionBindingFailed,
             .runtimeDistanceUnavailable,
             .noControlAuthority,
             .noMissionTarget,
             .runtimeStallDetected:
            return .pauseMission
        case .batteryUnsafe:
            return canReturnSafely ? .returnHome : .abortMission
        case .runtimeUnsafe:
            if !safetyState.runtimeConstraints.collisionSafe && airframeClass == .multirotor {
                return .hold
            }
            if airframeClass == .fixedWing || airframeClass == .hybridVTOL {
                return .pauseMission
            }
            return canReturnSafely ? .returnHome : .pauseMission
        case .missionStartBlocked, .noValidatedPlan, .none:
            break
        }

        return .none
    }
}
