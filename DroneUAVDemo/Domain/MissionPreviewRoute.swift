import Foundation
import simd

struct MissionLaunchPreview: Equatable {
    let mode: LaunchMode
    let launchObjectID: UUID
    let objectType: MissionLaunchObjectType
    let origin: SIMD2<Float>
    let railEnd: SIMD2<Float>?
    let corridorEnd: SIMD2<Float>
    let headingDegrees: Float
    let launchAngleDegrees: Float
    let corridorLengthMeters: Float
    let isWithinWorldBounds: Bool
    let hasSafeEdgeMargin: Bool
    let avoidsNoFlyZones: Bool
    let hasValidLaunchAngle: Bool

    var isValid: Bool {
        isWithinWorldBounds && hasSafeEdgeMargin && avoidsNoFlyZones && hasValidLaunchAngle
    }

    var points: [SIMD2<Float>] {
        if let railEnd, simd_distance(origin, railEnd) > 0.05 {
            return [origin, railEnd, corridorEnd]
        }
        return [origin, corridorEnd]
    }
}

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
