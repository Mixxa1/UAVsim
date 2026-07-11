import Foundation

struct MissionOperationalStatus: Equatable {
    var estimatedRemainingTimeSec: Float
    var estimatedRemainingRangeM: Float
    var estimatedSafeReturnRangeM: Float
    var safeReturnRadiusM: Float
    var distanceToHomeM: Float
    var distanceToNearestEdgeM: Float
    var nearestBoundaryDirection: MapBoundaryDirection
    /// Distance to the *authored/detailed map's* edge — purely a visual-detail concept (crossing
    /// it is a benign notice, flight continues into the procedural outer belt). Not radio range,
    /// not a mission geofence — see `MissionSafetyState`/`MissionGeofenceConfiguration` for those.
    var worldDetailBoundaryState: WorldDetailBoundaryState
    var missionDistanceBudgetM: Float
    var canReachHomeSafely: Bool
    var canCompleteMissionSafely: Bool
    var currentLinkQuality: Float
    var isInWarningLinkZone: Bool
    var isInCriticalLinkZone: Bool
    var isLinkLost: Bool
    var mapScaleSuitability: MapScaleSuitability
    var recommendedMapScaleMin: MapScale
    var recommendedMapScaleMax: MapScale
    var recommendedOperationalMapScale: MapScale
    var linkQualityRadiusM: Float
    var degradedLinkRadiusM: Float
    var lostLinkRadiusM: Float
    var operationalRadiusM: Float

    static let idle = MissionOperationalStatus(
        estimatedRemainingTimeSec: 0.0,
        estimatedRemainingRangeM: 0.0,
        estimatedSafeReturnRangeM: 0.0,
        safeReturnRadiusM: 0.0,
        distanceToHomeM: 0.0,
        distanceToNearestEdgeM: 0.0,
        nearestBoundaryDirection: .north,
        worldDetailBoundaryState: .nominal,
        missionDistanceBudgetM: 0.0,
        canReachHomeSafely: false,
        canCompleteMissionSafely: false,
        currentLinkQuality: 1.0,
        isInWarningLinkZone: false,
        isInCriticalLinkZone: false,
        isLinkLost: false,
        mapScaleSuitability: .acceptable,
        recommendedMapScaleMin: .x16,
        recommendedMapScaleMax: .x32,
        recommendedOperationalMapScale: .x32,
        linkQualityRadiusM: 0.0,
        degradedLinkRadiusM: 0.0,
        lostLinkRadiusM: 0.0,
        operationalRadiusM: 0.0
    )
}

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
    var operationalStatus: MissionOperationalStatus
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
        operationalStatus: .idle,
        explanations: []
    )
}
