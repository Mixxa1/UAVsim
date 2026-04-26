import Foundation
import simd

enum FixedWingAssistMode: String, CaseIterable, Identifiable {
    case manual
    case headingHold
    case altitudeHold
    case waypointIntercept

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .manual:
            return "mode.manual"
        case .headingHold:
            return "mode.fixed_wing_heading_hold"
        case .altitudeHold:
            return "mode.fixed_wing_altitude_hold"
        case .waypointIntercept:
            return "mode.fixed_wing_waypoint_intercept"
        }
    }
}

enum FixedWingAssistWaypointMode: String, CaseIterable, Identifiable, Equatable, Hashable {
    case flyBy

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .flyBy:
            return "fixed_wing.assist.waypoint_mode.fly_by"
        }
    }
}

enum FixedWingAssistInterceptState: String, Equatable {
    case manual
    case headingHold
    case altitudeHold
    case singlePointIntercept
    case inboundLegTrack
    case flyByTurnTransition
    case outboundLegTrack
    case terminalCapture
    case routeComplete
    case autoAdvancePausedPoorGeometry
    case autoAdvancePausedObstacle

    var titleKey: String {
        switch self {
        case .manual:
            return "mode.manual"
        case .headingHold:
            return "mode.fixed_wing_heading_hold"
        case .altitudeHold:
            return "mode.fixed_wing_altitude_hold"
        case .singlePointIntercept:
            return "fixed_wing.assist.state.single_point_intercept"
        case .inboundLegTrack:
            return "fixed_wing.assist.state.inbound_leg_track"
        case .flyByTurnTransition:
            return "fixed_wing.assist.state.flyby_turn_transition"
        case .outboundLegTrack:
            return "fixed_wing.assist.state.outbound_leg_track"
        case .terminalCapture:
            return "fixed_wing.assist.state.terminal_capture"
        case .routeComplete:
            return "fixed_wing.assist.state.route_complete"
        case .autoAdvancePausedPoorGeometry:
            return "fixed_wing.assist.state.auto_advance_paused_poor_geometry"
        case .autoAdvancePausedObstacle:
            return "fixed_wing.assist.state.auto_advance_paused_obstacle"
        }
    }
}

enum FixedWingAssistInterceptFeasibilityState: String, Equatable {
    case feasible
    case tightTurn
    case poorGeometry

    var titleKey: String {
        switch self {
        case .feasible:
            return "fixed_wing.assist.feasibility.feasible"
        case .tightTurn:
            return "fixed_wing.assist.feasibility.tight_turn"
        case .poorGeometry:
            return "fixed_wing.assist.feasibility.poor_geometry"
        }
    }
}

enum FixedWingAssistTurnDirection: String, Equatable {
    case none
    case left
    case right
}

struct FixedWingAssistWaypointOption: Identifiable, Equatable {
    let id: UUID
    let label: String
    let position: SIMD2<Float>
}

struct FixedWingAssistState: Equatable {
    var mode: FixedWingAssistMode
    var selectedWaypointID: UUID?
    var activeWaypointIndex: Int?
    var autoAdvanceEnabled: Bool
    var waypointMode: FixedWingAssistWaypointMode
    var nextWaypointIndex: Int?
    var hasPrevWaypoint: Bool
    var hasNextWaypoint: Bool
    var isFinalWaypoint: Bool
    var isPenultimateWaypoint: Bool
    var flyByCenterWaypointIndex: Int?
    var activeTripleIndices: String?
    var terminalCaptureAllowed: Bool
    var capturedWaypointIDs: [UUID]
    var interceptState: FixedWingAssistInterceptState
    var interceptFeasibilityState: FixedWingAssistInterceptFeasibilityState?
    var distanceToActiveWaypointMeters: Float?
    var headingErrorDegrees: Float?
    var rawHeadingErrorDegrees: Float?
    var estimatedTurnRadiusMeters: Float?
    var commandedBankDegrees: Float?
    var filteredBankCommandDegrees: Float?
    var commandedTurnDirection: FixedWingAssistTurnDirection
    var stateTransitionReason: String?
    var activeGuidanceTargetType: String
    var targetHeadingRadians: Float?
    var targetAltitudeMeters: Float?
    var interceptCompleted: Bool
    var captureCompletedReason: String?
    var autoAdvanceSuppressed: Bool
    var autoAdvanceSuppressedReason: String?
    var currentLegStart: SIMD2<Float>?
    var currentLegMiddle: SIMD2<Float>?
    var currentLegEnd: SIMD2<Float>?
    var inboundCourseDegrees: Float?
    var outboundCourseDegrees: Float?
    var courseChangeDegrees: Float?
    var leadDistanceMeters: Float?
    var flyByTransitionActive: Bool
    var flyByTransitionFeasible: Bool
    var activeGuidanceMode: String
    var headingErrorToNextWaypointDegrees: Float?
    var nextWaypointInForwardSector: Bool
    var enoughTurnInDistance: Bool
    var collisionRiskToNextWaypoint: Float?
    var obstacleInTurnCorridor: Bool
    var blockedPathToNextWaypoint: Bool
    var lateralGuidanceSuppressedForPoorGeometry: Bool
    var usingObsoleteFixedWingMode: Bool
    var previewUsesCachedFlyByPlan: Bool
    var controllerUsesCachedFlyByPlan: Bool
    var guidanceDirectToWaypointSuppressed: Bool
    var flyByPlanRecomputeCount: Int
    var fullRouteRebuildCount: Int
    var overlayRebuildCount: Int
    var guidanceRecomputeCount: Int
    var heavyMapRebuildCount: Int
    var frameTimeMs: Double?
    var frameTimeDuringTransitionMs: Double?

    var activeWaypointID: UUID? {
        selectedWaypointID
    }

    var turnTransitionActive: Bool {
        flyByTransitionActive
    }

    static let manual = FixedWingAssistState(
        mode: .manual,
        selectedWaypointID: nil,
        activeWaypointIndex: nil,
        autoAdvanceEnabled: false,
        waypointMode: .flyBy,
        nextWaypointIndex: nil,
        hasPrevWaypoint: false,
        hasNextWaypoint: false,
        isFinalWaypoint: false,
        isPenultimateWaypoint: false,
        flyByCenterWaypointIndex: nil,
        activeTripleIndices: nil,
        terminalCaptureAllowed: false,
        capturedWaypointIDs: [],
        interceptState: .manual,
        interceptFeasibilityState: nil,
        distanceToActiveWaypointMeters: nil,
        headingErrorDegrees: nil,
        rawHeadingErrorDegrees: nil,
        estimatedTurnRadiusMeters: nil,
        commandedBankDegrees: nil,
        filteredBankCommandDegrees: nil,
        commandedTurnDirection: .none,
        stateTransitionReason: nil,
        activeGuidanceTargetType: "none",
        targetHeadingRadians: nil,
        targetAltitudeMeters: nil,
        interceptCompleted: false,
        captureCompletedReason: nil,
        autoAdvanceSuppressed: false,
        autoAdvanceSuppressedReason: nil,
        currentLegStart: nil,
        currentLegMiddle: nil,
        currentLegEnd: nil,
        inboundCourseDegrees: nil,
        outboundCourseDegrees: nil,
        courseChangeDegrees: nil,
        leadDistanceMeters: nil,
        flyByTransitionActive: false,
        flyByTransitionFeasible: false,
        activeGuidanceMode: "none",
        headingErrorToNextWaypointDegrees: nil,
        nextWaypointInForwardSector: false,
        enoughTurnInDistance: false,
        collisionRiskToNextWaypoint: nil,
        obstacleInTurnCorridor: false,
        blockedPathToNextWaypoint: false,
        lateralGuidanceSuppressedForPoorGeometry: false,
        usingObsoleteFixedWingMode: false,
        previewUsesCachedFlyByPlan: false,
        controllerUsesCachedFlyByPlan: false,
        guidanceDirectToWaypointSuppressed: false,
        flyByPlanRecomputeCount: 0,
        fullRouteRebuildCount: 0,
        overlayRebuildCount: 0,
        guidanceRecomputeCount: 0,
        heavyMapRebuildCount: 0,
        frameTimeMs: nil,
        frameTimeDuringTransitionMs: nil
    )
}
