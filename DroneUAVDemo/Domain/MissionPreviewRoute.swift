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

    var segmentCount: Int {
        max(0, points.count - 1)
    }
}
