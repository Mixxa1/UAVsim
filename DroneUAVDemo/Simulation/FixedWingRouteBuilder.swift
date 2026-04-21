import Foundation
import simd

final class FixedWingRouteBuilder {
    func build(from previewRoute: MissionPreviewRoute) -> MissionPlanRouteBuildResult {
        let routePoints = previewRoute.points
        let missionPoints = previewRoute.missionPlanPoints
        let waypointIndices = previewRoute.waypointExecutionPointIndices

        guard routePoints.count > 1 else {
            return MissionPlanRouteBuildResult(
                routeKind: .fixedWingFlyable,
                routePoints: routePoints,
                missionPoints: missionPoints,
                legs: []
            )
        }

        var legs: [MissionLeg] = []
        var startIndex = 0
        let boundedWaypointIndices = waypointIndices.filter { $0 > 0 && $0 < routePoints.count }

        for (waypointOrder, endIndex) in boundedWaypointIndices.enumerated() {
            let sampledPoints = Array(routePoints[startIndex...endIndex])
            legs.append(
                MissionLeg(
                    startPoint: sampledPoints.first ?? routePoints[startIndex],
                    endPoint: sampledPoints.last ?? routePoints[endIndex],
                    sampledPoints: sampledPoints,
                    kind: sampledPoints.count > 2 ? .leadTurn : .outbound,
                    targetWaypointIndex: waypointOrder
                )
            )
            startIndex = endIndex
        }

        if startIndex < routePoints.count - 1 {
            let sampledPoints = Array(routePoints[startIndex...(routePoints.count - 1)])
            legs.append(
                MissionLeg(
                    startPoint: sampledPoints.first ?? routePoints[startIndex],
                    endPoint: sampledPoints.last ?? routePoints[routePoints.count - 1],
                    sampledPoints: sampledPoints,
                    kind: .returnHome,
                    targetWaypointIndex: nil
                )
            )
        }

        return MissionPlanRouteBuildResult(
            routeKind: .fixedWingFlyable,
            routePoints: routePoints,
            missionPoints: missionPoints,
            legs: legs
        )
    }
}
