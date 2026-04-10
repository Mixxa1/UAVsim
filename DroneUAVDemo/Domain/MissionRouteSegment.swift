import Foundation
import simd

enum MissionRouteSegmentRole: String, Equatable, Codable {
    case outbound
    case returnHome
}

struct MissionRouteSegment: Identifiable, Equatable {
    var id: Int { index }
    let index: Int
    let startPointIndex: Int
    let endPointIndex: Int
    let start: SIMD3<Float>
    let end: SIMD3<Float>
    let lengthMeters: Float
    let directionXZ: SIMD2<Float>
    let role: MissionRouteSegmentRole
    let targetWaypointIndex: Int?
}

struct MissionActiveSegment: Equatable {
    let index: Int
    let segment: MissionRouteSegment
    let activeWaypointIndex: Int?
}

struct MissionLineTrackingState: Equatable {
    let activeSegment: MissionActiveSegment
    let projectedPoint: SIMD3<Float>
    let targetPoint: SIMD3<Float>
    let crossTrackError: Float
    let signedCrossTrackError: Float
    let alongTrackProgress: Float
    let distanceToSegmentEnd: Float
    let distanceRemaining: Float
    let waypointDistance: Float
    let remainingPath: [SIMD3<Float>]
    let shouldAdvanceSegment: Bool
    let isRouteComplete: Bool
}
