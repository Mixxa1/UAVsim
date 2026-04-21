import Foundation
import simd

struct MissionPlan: Identifiable, Equatable {
    let id: UUID
    var builtAt: Date
    var airframeKind: UAVAirframeKind
    var startPoint: SIMD2<Float>
    var routePoints: [SIMD2<Float>]
    var missionPoints: [SIMD2<Float>]
    var routeKind: MissionRouteKind
    var legs: [MissionLeg]
    var launchMode: LaunchMode
    var launchObject: MissionLaunchObject?
    var launchAsset: LaunchAsset?
    var waypoints: [MissionTarget]
    var executionTargets: [MissionTarget]
    var zones: [MissionZone]
    var constraints: MissionConstraints
    var status: MissionPlanStatus
    var explanations: [MissionStatusExplanation]

    var isReadyForExecution: Bool {
        status == .validated && !waypoints.isEmpty && !executionTargets.isEmpty && routePoints.count >= 2
    }
}
