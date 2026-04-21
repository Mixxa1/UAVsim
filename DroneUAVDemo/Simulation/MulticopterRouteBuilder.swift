import Foundation
import simd

struct MissionPlanRouteBuildResult: Equatable {
    var routeKind: MissionRouteKind
    var routePoints: [SIMD2<Float>]
    var missionPoints: [SIMD2<Float>]
    var legs: [MissionLeg]
}

final class MulticopterRouteBuilder {
    func build(from previewRoute: MissionPreviewRoute) -> MissionPlanRouteBuildResult {
        let routePoints = previewRoute.points
        let missionPoints = previewRoute.missionPlanPoints
        let legs = zip(routePoints, routePoints.dropFirst()).enumerated().map { index, pair in
            MissionLeg(
                startPoint: pair.0,
                endPoint: pair.1,
                sampledPoints: [pair.0, pair.1],
                kind: .outbound,
                targetWaypointIndex: previewRoute.waypointExecutionPointIndices.firstIndex(where: { $0 == index + 1 })
            )
        }

        return MissionPlanRouteBuildResult(
            routeKind: .multicopterPolyline,
            routePoints: routePoints,
            missionPoints: missionPoints,
            legs: legs
        )
    }
}
