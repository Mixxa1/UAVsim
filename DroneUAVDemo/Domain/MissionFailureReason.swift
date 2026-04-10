import Foundation

enum MissionFailureReason: String, Equatable, Identifiable {
    case noValidatedPlan
    case draftEmpty
    case previewUnavailable
    case routeInvalid
    case invalidAltitudeWindow
    case invalidSpeedWindow
    case zoneInvalid
    case planNotPrepared
    case planNotReady
    case executionContourMissing
    case executionBindingFailed
    case executionNotStarted
    case targetAltitudeOutOfRange
    case altitudeConstraintsApplied
    case speedMaxConstraintApplied
    case speedMinConstraintAdvisory
    case noMissionTarget
    case runtimeDistanceUnavailable
    case noTargetBound
    case noControlAuthority
    case authorityFlapDetected
    case runtimeStallDetected
    case batteryUnsafe
    case missionStartBlocked
    case missionAbortedBySafety
    case missionPausedByOperator
    case missionPausedByRuntime
    case returnHomeTriggered
    case runtimeUnsafe
    case unknownRuntimeMismatch
    case executionBlocked
    case waypointReached
    case missionPaused
    case missionCompleted
    case missionAborted
    case missionFailed

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .noValidatedPlan, .draftEmpty:
            return "mission.plan.status.draft"
        case .previewUnavailable,
             .routeInvalid,
             .invalidAltitudeWindow,
             .invalidSpeedWindow,
             .zoneInvalid,
             .planNotPrepared,
             .planNotReady:
            return "mission.plan.status.invalid"
        case .executionContourMissing,
             .executionBindingFailed,
             .runtimeDistanceUnavailable,
             .targetAltitudeOutOfRange:
            return "mission.execution.status.blocked"
        case .executionNotStarted:
            return "mission.execution.status.ready"
        case .altitudeConstraintsApplied,
             .speedMaxConstraintApplied,
             .speedMinConstraintAdvisory:
            return "mission.execution.status.ready"
        case .noMissionTarget, .noTargetBound:
            return "mission.execution.status.blocked"
        case .noControlAuthority:
            return "mission.execution.status.no_authority"
        case .authorityFlapDetected:
            return "mission.execution.status.running"
        case .runtimeStallDetected,
             .batteryUnsafe,
             .missionStartBlocked,
             .runtimeUnsafe,
             .unknownRuntimeMismatch:
            return "mission.execution.status.blocked"
        case .missionAbortedBySafety, .returnHomeTriggered:
            return "mission.execution.status.aborted"
        case .missionPausedByOperator, .missionPausedByRuntime:
            return "mission.execution.status.paused"
        case .executionBlocked:
            return "mission.execution.status.blocked"
        case .waypointReached:
            return "mission.execution.status.running"
        case .missionPaused:
            return "mission.execution.status.paused"
        case .missionCompleted:
            return "mission.execution.status.completed"
        case .missionAborted:
            return "mission.execution.status.aborted"
        case .missionFailed:
            return "mission.execution.status.failed"
        }
    }
}
