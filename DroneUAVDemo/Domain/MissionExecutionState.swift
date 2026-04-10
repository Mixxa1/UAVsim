import Foundation

enum MissionExecutionStatus: String, Equatable {
    case idle
    case ready
    case running
    case paused
    case completed
    case aborted
    case blocked
    case failed

    var titleKey: String {
        switch self {
        case .idle:
            return "mission.execution.status.idle"
        case .ready:
            return "mission.execution.status.ready"
        case .running:
            return "mission.execution.status.running"
        case .paused:
            return "mission.execution.status.paused"
        case .completed:
            return "mission.execution.status.completed"
        case .aborted:
            return "mission.execution.status.aborted"
        case .blocked:
            return "mission.execution.status.blocked"
        case .failed:
            return "mission.execution.status.failed"
        }
    }
}

enum MissionExecutionMode: String, Equatable {
    case none
    case autopilotTarget
}

struct MissionExecutionState: Equatable {
    var mode: MissionExecutionMode
    var status: MissionExecutionStatus
    var bindingState: MissionExecutionBindingState
    var planID: UUID?
    var activeWaypointIndex: Int?
    var activeTarget: MissionTarget?
    var waypointProgress: [MissionWaypointProgress]
    var distanceToActiveTarget: Float?
    var hasBoundAutopilotTarget: Bool
    var failureReason: MissionFailureReason?
    var abortReason: MissionAbortReason?
    var explanations: [MissionStatusExplanation]
    var lastUpdatedAt: Date

    static let idle = MissionExecutionState(
        mode: .none,
        status: .idle,
        bindingState: .unbound,
        planID: nil,
        activeWaypointIndex: nil,
        activeTarget: nil,
        waypointProgress: [],
        distanceToActiveTarget: nil,
        hasBoundAutopilotTarget: false,
        failureReason: nil,
        abortReason: nil,
        explanations: [],
        lastUpdatedAt: .distantPast
    )

    var canStart: Bool {
        status == .ready && bindingState == .bound && activeTarget != nil
    }

    var canPause: Bool {
        status == .running
    }

    var canResume: Bool {
        status == .paused && activeTarget != nil
    }

    var canAbort: Bool {
        switch status {
        case .ready, .running, .paused, .blocked:
            return true
        case .idle, .completed, .aborted, .failed:
            return false
        }
    }

    var isMissionActive: Bool {
        switch status {
        case .ready, .running, .paused, .blocked:
            return true
        case .idle, .completed, .aborted, .failed:
            return false
        }
    }

    var hasExecutionContour: Bool {
        bindingState == .bound && !waypointProgress.isEmpty
    }

    var hasRuntimeDistance: Bool {
        distanceToActiveTarget != nil
    }
}
