import Foundation
import simd

struct MissionRouteValidation {
    let isValid: Bool
    let reason: String?
}

final class MissionRouteValidator {
    func validate(route: MissionValidatedRoute?, for plan: MissionPlan) -> MissionRouteValidation {
        guard let route else {
            return MissionRouteValidation(isValid: false, reason: "mission.runtime.route_missing")
        }

        guard route.isUsable else {
            return MissionRouteValidation(isValid: false, reason: "mission.runtime.route_unusable")
        }

        guard route.waypointRoutePointIndices.count == plan.waypoints.count else {
            return MissionRouteValidation(isValid: false, reason: "mission.runtime.waypoint_mapping_mismatch")
        }

        if route.points.count < 2 || route.segments.isEmpty {
            return MissionRouteValidation(isValid: false, reason: "mission.runtime.route_empty")
        }

        var previousRoutePointIndex = -1
        for routePointIndex in route.waypointRoutePointIndices {
            guard routePointIndex > previousRoutePointIndex,
                  routePointIndex > 0,
                  routePointIndex < route.points.count else {
                return MissionRouteValidation(isValid: false, reason: "mission.runtime.waypoint_mapping_invalid")
            }
            previousRoutePointIndex = routePointIndex
        }

        for segment in route.segments {
            guard segment.lengthMeters > 0.05,
                  segment.startPointIndex < segment.endPointIndex,
                  segment.endPointIndex < route.points.count else {
                return MissionRouteValidation(isValid: false, reason: "mission.runtime.segment_invalid")
            }

            guard segment.targetWaypointIndex == route.activeWaypointIndex(forSegmentIndex: segment.index) else {
                return MissionRouteValidation(isValid: false, reason: "mission.runtime.segment_waypoint_mapping_invalid")
            }

            let actualStart = route.points[segment.startPointIndex].position
            let actualEnd = route.points[segment.endPointIndex].position
            guard simd_length(SIMD2<Float>(actualStart.x - segment.start.x, actualStart.z - segment.start.z)) <= 0.01,
                  simd_length(SIMD2<Float>(actualEnd.x - segment.end.x, actualEnd.z - segment.end.z)) <= 0.01 else {
                return MissionRouteValidation(isValid: false, reason: "mission.runtime.segment_point_mismatch")
            }

            if let returnLegStartSegmentIndex = route.returnLegStartSegmentIndex,
               segment.index >= returnLegStartSegmentIndex,
               segment.role != .returnHome {
                return MissionRouteValidation(isValid: false, reason: "mission.runtime.segment_role_invalid")
            }
        }

        for (waypointIndex, waypoint) in plan.waypoints.enumerated() {
            guard let routeWaypointPoint = route.waypointPoint(forWaypointIndex: waypointIndex) else {
                return MissionRouteValidation(isValid: false, reason: "mission.runtime.waypoint_missing")
            }
            let deviation = simd_length(
                SIMD2<Float>(
                    routeWaypointPoint.x - waypoint.position.x,
                    routeWaypointPoint.z - waypoint.position.y
                )
            )
            guard deviation <= 0.75 else {
                return MissionRouteValidation(isValid: false, reason: "mission.runtime.waypoint_off_route")
            }
        }

        return MissionRouteValidation(isValid: true, reason: nil)
    }
}
