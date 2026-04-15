import Foundation

final class MissionFailsafeCoordinator {
    func resolve(
        executionState: MissionExecutionState,
        safetyState: MissionSafetyState,
        airframeClass: AirframeClass,
        flightMode: DroneFlightMode
    ) -> MissionFailsafeMode {
        if flightMode == .returnHome,
           executionState.abortReason == .returnHomeTriggered {
            return .returnHome
        }

        guard executionState.status == .running else {
            return .none
        }

        if !safetyState.runtimeConstraints.signalSafe ||
            !safetyState.runtimeConstraints.batterySafeToContinue ||
            !safetyState.runtimeConstraints.returnSafe {
            return .returnHome
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
            return .returnHome
        case .runtimeUnsafe:
            if !safetyState.runtimeConstraints.collisionSafe && airframeClass == .multirotor {
                return .hold
            }
            return .returnHome
        case .missionStartBlocked, .noValidatedPlan, .none:
            break
        }

        return .none
    }
}
