import Foundation

struct MissionStatusSnapshot: Equatable {
    var truthStatus: MissionTruthStatus
    var draftStatus: MissionDraftStatus
    var planStatus: MissionPlanStatus
    var executionReadiness: MissionExecutionReadiness
    var executionStatus: MissionExecutionStatus
    var executionBindingState: MissionExecutionBindingState
    var controlAuthority: FlightControlAuthority
    var safetyState: MissionSafetyState
    var activeTargetLabel: String?
    var distanceToActiveTarget: Float?
    var completedWaypointCount: Int
    var totalWaypointCount: Int
    var hasValidatedPlan: Bool
    var hasExecutionContour: Bool
    var hasActiveExecutionTarget: Bool
    var hasRuntimeDistance: Bool
    var hasBoundAutopilotTarget: Bool
    var startPermissionGranted: Bool
    var canPrepare: Bool
    var canStart: Bool
    var canPause: Bool
    var canResume: Bool
    var canAbort: Bool
    var explanations: [MissionStatusExplanation]

    var primaryExplanation: MissionStatusExplanation? {
        explanations.sorted { lhs, rhs in
            if lhs.severity.priority != rhs.severity.priority {
                return lhs.severity.priority < rhs.severity.priority
            }
            if lhs.isBlocking != rhs.isBlocking {
                return lhs.isBlocking && !rhs.isBlocking
            }
            return lhs.detailKey < rhs.detailKey
        }.first
    }

    static let empty = MissionStatusSnapshot(
        truthStatus: .draft,
        draftStatus: .empty,
        planStatus: .draft,
        executionReadiness: .draft,
        executionStatus: .idle,
        executionBindingState: .unbound,
        controlAuthority: .none,
        safetyState: .idle,
        activeTargetLabel: nil,
        distanceToActiveTarget: nil,
        completedWaypointCount: 0,
        totalWaypointCount: 0,
        hasValidatedPlan: false,
        hasExecutionContour: false,
        hasActiveExecutionTarget: false,
        hasRuntimeDistance: false,
        hasBoundAutopilotTarget: false,
        startPermissionGranted: false,
        canPrepare: false,
        canStart: false,
        canPause: false,
        canResume: false,
        canAbort: false,
        explanations: []
    )
}
