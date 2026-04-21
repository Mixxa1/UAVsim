import Foundation
import simd

struct MissionPreviewRoute: Equatable {
    let id: UUID
    let missionPlanPoints: [SIMD2<Float>]
    let executionPoints: [SIMD2<Float>]
    let waypointExecutionPointIndices: [Int]
    let isFlyablePreview: Bool
    let previewStatusKey: String?
    let totalLengthMeters: Float
    let boundsMin: SIMD2<Float>
    let boundsMax: SIMD2<Float>

    var points: [SIMD2<Float>] {
        executionPoints
    }

    var visibleExecutionPoints: [SIMD2<Float>] {
        guard executionPoints.count > 1,
              let firstWaypointIndex = waypointExecutionPointIndices.first,
              let lastWaypointIndex = waypointExecutionPointIndices.last,
              firstWaypointIndex >= 0,
              lastWaypointIndex < executionPoints.count,
              firstWaypointIndex < lastWaypointIndex else {
            return missionPlanPoints
        }

        return Array(executionPoints[firstWaypointIndex...lastWaypointIndex])
    }

    var segmentCount: Int {
        max(0, waypointExecutionPointIndices.count - 1)
    }
}
