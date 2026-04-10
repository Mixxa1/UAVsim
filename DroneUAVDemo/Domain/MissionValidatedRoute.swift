import Foundation
import simd

struct MissionRoutePoint: Identifiable, Equatable {
    enum Kind: String, Equatable, Codable {
        case home
        case waypoint
        case returnPoint
    }

    var id: Int { index }
    let index: Int
    let position: SIMD3<Float>
    let kind: Kind
}

struct MissionValidatedRoute: Equatable {
    let id: UUID
    let points: [MissionRoutePoint]
    let segments: [MissionRouteSegment]
    let waypointRoutePointIndices: [Int]
    let returnLegStartSegmentIndex: Int?
    let totalLengthMeters: Float
    let boundsMin: SIMD2<Float>
    let boundsMax: SIMD2<Float>
    let cruiseAltitudeMeters: Float

    var isUsable: Bool {
        !segments.isEmpty && !waypointRoutePointIndices.isEmpty
    }

    var polyline: [SIMD3<Float>] {
        points.map(\.position)
    }

    func activeWaypointIndex(forSegmentIndex segmentIndex: Int) -> Int? {
        guard !waypointRoutePointIndices.isEmpty,
              segmentIndex >= 0,
              segmentIndex < segments.count else {
            return nil
        }

        let segmentEndPointIndex = segments[segmentIndex].endPointIndex
        for (waypointIndex, routePointIndex) in waypointRoutePointIndices.enumerated() {
            if routePointIndex >= segmentEndPointIndex {
                return waypointIndex
            }
        }
        return nil
    }

    func reachedWaypointCount(afterCompletedSegmentIndex segmentIndex: Int) -> Int {
        guard !waypointRoutePointIndices.isEmpty else {
            return 0
        }
        let completedRoutePointIndex = max(0, segmentIndex + 1)
        return waypointRoutePointIndices.filter { $0 <= completedRoutePointIndex }.count
    }

    func waypointPoint(forWaypointIndex waypointIndex: Int) -> SIMD3<Float>? {
        guard waypointIndex >= 0,
              waypointIndex < waypointRoutePointIndices.count else {
            return nil
        }

        let routePointIndex = waypointRoutePointIndices[waypointIndex]
        guard routePointIndex >= 0, routePointIndex < points.count else {
            return nil
        }
        return points[routePointIndex].position
    }

    func isReturnLeg(segmentIndex: Int) -> Bool {
        guard let returnLegStartSegmentIndex else {
            return false
        }
        return segmentIndex >= returnLegStartSegmentIndex
    }
}
