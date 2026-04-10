import Foundation

enum MissionRunReadiness: String, Equatable {
    case draft
    case invalid
    case blocked
    case ready

    var titleKey: String {
        switch self {
        case .draft:
            return "mission.readiness.draft"
        case .invalid:
            return "mission.readiness.invalid"
        case .blocked:
            return "mission.readiness.blocked"
        case .ready:
            return "mission.readiness.ready"
        }
    }
}

enum MissionTruthStatus: String, Equatable {
    case draft
    case invalid
    case validated
    case executionUnbound
    case blocked
    case ready
    case running
    case paused
    case returningHome
    case completed
    case aborted
    case failed
    case noAuthority
    case noTarget
    case routeInvalid
    case runtimeDistanceUnavailable
    case failedBinding
    case runtimeUnsafe

    var titleKey: String {
        switch self {
        case .draft:
            return "mission.truth.status.draft"
        case .invalid:
            return "mission.truth.status.invalid"
        case .validated:
            return "mission.truth.status.validated"
        case .executionUnbound:
            return "mission.truth.status.execution_unbound"
        case .blocked:
            return "mission.truth.status.blocked"
        case .ready:
            return "mission.truth.status.ready"
        case .running:
            return "mission.truth.status.running"
        case .paused:
            return "mission.truth.status.paused"
        case .returningHome:
            return "mission.truth.status.returning_home"
        case .completed:
            return "mission.truth.status.completed"
        case .aborted:
            return "mission.truth.status.aborted"
        case .failed:
            return "mission.truth.status.failed"
        case .noAuthority:
            return "mission.truth.status.no_authority"
        case .noTarget:
            return "mission.truth.status.no_target"
        case .routeInvalid:
            return "mission.truth.status.route_invalid"
        case .runtimeDistanceUnavailable:
            return "mission.truth.status.runtime_distance_unavailable"
        case .failedBinding:
            return "mission.truth.status.failed_binding"
        case .runtimeUnsafe:
            return "mission.truth.status.runtime_unsafe"
        }
    }
}

enum MissionBlockReason: String, Equatable {
    case noValidatedPlan
    case executionContourMissing
    case executionBindingFailed
    case noMissionTarget
    case runtimeDistanceUnavailable
    case noControlAuthority
    case routeInvalid
    case runtimeStallDetected
    case batteryUnsafe
    case missionStartBlocked
    case runtimeUnsafe

    var detailKey: String {
        switch self {
        case .noValidatedPlan:
            return "mission.status.reason.no_validated_plan"
        case .executionContourMissing:
            return "mission.status.reason.execution_contour_missing"
        case .executionBindingFailed:
            return "mission.status.reason.execution_binding_failed"
        case .noMissionTarget:
            return "mission.status.reason.no_mission_target"
        case .runtimeDistanceUnavailable:
            return "mission.status.reason.runtime_distance_unavailable"
        case .noControlAuthority:
            return "mission.status.reason.no_control_authority"
        case .routeInvalid:
            return "mission.status.reason.route_invalid"
        case .runtimeStallDetected:
            return "mission.status.reason.runtime_stall_detected"
        case .batteryUnsafe:
            return "mission.status.reason.battery_unsafe"
        case .missionStartBlocked:
            return "mission.status.reason.mission_start_blocked"
        case .runtimeUnsafe:
            return "mission.status.reason.runtime_unsafe"
        }
    }

    var failureReason: MissionFailureReason {
        switch self {
        case .noValidatedPlan:
            return .noValidatedPlan
        case .executionContourMissing:
            return .executionContourMissing
        case .executionBindingFailed:
            return .executionBindingFailed
        case .noMissionTarget:
            return .noMissionTarget
        case .runtimeDistanceUnavailable:
            return .runtimeDistanceUnavailable
        case .noControlAuthority:
            return .noControlAuthority
        case .routeInvalid:
            return .routeInvalid
        case .runtimeStallDetected:
            return .runtimeStallDetected
        case .batteryUnsafe:
            return .batteryUnsafe
        case .missionStartBlocked:
            return .missionStartBlocked
        case .runtimeUnsafe:
            return .runtimeUnsafe
        }
    }
}

enum MissionFailsafeMode: String, Equatable {
    case none
    case hold
    case pauseMission
    case abortMission
    case returnHome

    var titleKey: String {
        switch self {
        case .none:
            return "mission.failsafe.none"
        case .hold:
            return "mission.failsafe.hold"
        case .pauseMission:
            return "mission.failsafe.pause"
        case .abortMission:
            return "mission.failsafe.abort"
        case .returnHome:
            return "mission.failsafe.return_home"
        }
    }
}

enum MissionAbortReason: String, Equatable {
    case operatorRequested
    case safetyAbort
    case runtimeUnsafe
    case authorityLost
    case routeInvalid
    case batteryUnsafe
    case returnHomeTriggered
    case unknownRuntimeMismatch

    var detailKey: String {
        switch self {
        case .operatorRequested:
            return "mission.status.reason.mission_aborted"
        case .safetyAbort:
            return "mission.status.reason.mission_aborted_by_safety"
        case .runtimeUnsafe:
            return "mission.status.reason.runtime_unsafe"
        case .authorityLost:
            return "mission.status.reason.no_control_authority"
        case .routeInvalid:
            return "mission.status.reason.route_invalid"
        case .batteryUnsafe:
            return "mission.status.reason.battery_unsafe"
        case .returnHomeTriggered:
            return "mission.status.reason.return_home_triggered"
        case .unknownRuntimeMismatch:
            return "mission.status.reason.unknown_runtime_mismatch"
        }
    }
}
