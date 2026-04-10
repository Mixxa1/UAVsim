import Foundation
import simd

final class MissionRouteBuilder {
    func build(
        rawPath: [SIMD3<Float>],
        missionWaypoints: [TargetMarkerState],
        cruiseAltitudeMeters: Float,
        returnLegStartRoutePointIndex: Int?
    ) -> MissionValidatedRoute? {
        let normalizedInput = normalizedInputPath(
            rawPath,
            waypointIndices: matchWaypointIndices(routePoints: rawPath, waypoints: missionWaypoints) ?? [],
            returnLegStartRoutePointIndex: returnLegStartRoutePointIndex
        )
        guard normalizedInput.points.count >= 2,
              !normalizedInput.waypointRoutePointIndices.isEmpty else {
            return nil
        }

        let routePoints = materializeRoutePoints(
            normalizedInput.points,
            waypointRoutePointIndices: normalizedInput.waypointRoutePointIndices,
            returnLegStartRoutePointIndex: normalizedInput.returnLegStartRoutePointIndex
        )
        let segments = buildSegments(
            points: routePoints,
            waypointRoutePointIndices: normalizedInput.waypointRoutePointIndices,
            returnLegStartRoutePointIndex: normalizedInput.returnLegStartRoutePointIndex
        )
        guard !segments.isEmpty else {
            return nil
        }

        let totalLengthMeters = segments.reduce(0.0) { $0 + $1.lengthMeters }
        let bounds = buildBounds(points: routePoints)
        let returnLegStartSegmentIndex = segments.first(where: { $0.role == .returnHome })?.index

        return MissionValidatedRoute(
            id: UUID(),
            points: routePoints,
            segments: segments,
            waypointRoutePointIndices: normalizedInput.waypointRoutePointIndices,
            returnLegStartSegmentIndex: returnLegStartSegmentIndex,
            totalLengthMeters: totalLengthMeters,
            boundsMin: bounds.min,
            boundsMax: bounds.max,
            cruiseAltitudeMeters: cruiseAltitudeMeters
        )
    }

    func build(from plan: MissionPlan) -> MissionValidatedRoute? {
        if let validatedRoute = plan.validatedRoute {
            return validatedRoute
        }
        return build(
            rawPath: plan.validatedRoutePath,
            missionWaypoints: plan.waypoints,
            cruiseAltitudeMeters: plan.cruiseAltitudeMeters,
            returnLegStartRoutePointIndex: nil
        )
    }

    private func matchWaypointIndices(
        routePoints: [SIMD3<Float>],
        waypoints: [TargetMarkerState]
    ) -> [Int]? {
        guard !routePoints.isEmpty, !waypoints.isEmpty else {
            return nil
        }

        var result: [Int] = []
        var searchStart = 0

        for waypoint in waypoints {
            let match = nearestRoutePointIndex(
                to: waypoint.position,
                in: routePoints,
                startingAt: searchStart
            )
            guard let match, match.distance <= 1.6 else {
                return nil
            }
            result.append(match.index)
            searchStart = match.index
        }

        return result
    }

    private func normalizedInputPath(
        _ rawPoints: [SIMD3<Float>],
        waypointIndices: [Int],
        returnLegStartRoutePointIndex: Int?
    ) -> (points: [SIMD3<Float>], waypointRoutePointIndices: [Int], returnLegStartRoutePointIndex: Int?) {
        guard !rawPoints.isEmpty else {
            return ([], [], nil)
        }

        let requiredIndices = Set(waypointIndices + (returnLegStartRoutePointIndex.map { [$0] } ?? []))
        var points: [SIMD3<Float>] = [rawPoints[0]]
        var waypointRoutePointIndices: [Int] = []
        var returnLegStartNormalizedIndex: Int?
        var sourceToNormalized: [Int: Int] = [0: 0]

        for sourceIndex in 1..<rawPoints.count {
            let candidate = rawPoints[sourceIndex]
            let previous = points[points.count - 1]
            let planarDistance = simd_length(
                SIMD2<Float>(candidate.x - previous.x, candidate.z - previous.z)
            )
            if planarDistance > 0.05 || requiredIndices.contains(sourceIndex) || sourceIndex == rawPoints.count - 1 {
                points.append(candidate)
                sourceToNormalized[sourceIndex] = points.count - 1
            } else {
                sourceToNormalized[sourceIndex] = points.count - 1
            }
        }

        for sourceIndex in waypointIndices {
            if let normalizedIndex = sourceToNormalized[sourceIndex] {
                waypointRoutePointIndices.append(normalizedIndex)
            }
        }

        if let returnLegStartRoutePointIndex,
           let normalizedIndex = sourceToNormalized[returnLegStartRoutePointIndex] {
            returnLegStartNormalizedIndex = normalizedIndex
        }

        return (points, waypointRoutePointIndices, returnLegStartNormalizedIndex)
    }

    private func materializeRoutePoints(
        _ points: [SIMD3<Float>],
        waypointRoutePointIndices: [Int],
        returnLegStartRoutePointIndex: Int?
    ) -> [MissionRoutePoint] {
        let waypointIndices = Set(waypointRoutePointIndices)
        let lastPointIndex = max(0, points.count - 1)
        let lastPoint = points[lastPointIndex]
        let firstPoint = points[0]
        let lastPointReturnsHome = simd_length(
            SIMD2<Float>(lastPoint.x - firstPoint.x, lastPoint.z - firstPoint.z)
        ) <= 0.25

        return points.enumerated().map { index, point in
            let kind: MissionRoutePoint.Kind
            if index == 0 {
                kind = .home
            } else if waypointIndices.contains(index) {
                kind = .waypoint
            } else if index == lastPointIndex,
                      returnLegStartRoutePointIndex != nil,
                      !lastPointReturnsHome {
                kind = .returnPoint
            } else if index == lastPointIndex, lastPointReturnsHome {
                kind = .home
            } else {
                kind = .waypoint
            }

            return MissionRoutePoint(
                index: index,
                position: point,
                kind: kind
            )
        }
    }

    private func buildSegments(
        points: [MissionRoutePoint],
        waypointRoutePointIndices: [Int],
        returnLegStartRoutePointIndex: Int?
    ) -> [MissionRouteSegment] {
        guard points.count >= 2 else {
            return []
        }

        var output: [MissionRouteSegment] = []
        output.reserveCapacity(points.count - 1)

        for index in 1..<points.count {
            let start = points[index - 1].position
            let end = points[index].position
            let deltaXZ = SIMD2<Float>(end.x - start.x, end.z - start.z)
            let length = simd_length(deltaXZ)
            guard length > 0.05 else {
                continue
            }

            let role: MissionRouteSegmentRole
            if let returnLegStartRoutePointIndex, index - 1 >= returnLegStartRoutePointIndex {
                role = .returnHome
            } else {
                role = .outbound
            }

            let targetWaypointIndex = waypointRoutePointIndices.firstIndex(where: { $0 >= index })

            output.append(
                MissionRouteSegment(
                    index: output.count,
                    startPointIndex: index - 1,
                    endPointIndex: index,
                    start: start,
                    end: end,
                    lengthMeters: length,
                    directionXZ: deltaXZ / length,
                    role: role,
                    targetWaypointIndex: targetWaypointIndex
                )
            )
        }

        return output
    }

    private func buildBounds(points: [MissionRoutePoint]) -> (min: SIMD2<Float>, max: SIMD2<Float>) {
        guard let first = points.first?.position else {
            return (.zero, .zero)
        }

        var minX = first.x
        var maxX = first.x
        var minZ = first.z
        var maxZ = first.z

        for point in points.dropFirst().map(\.position) {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minZ = min(minZ, point.z)
            maxZ = max(maxZ, point.z)
        }

        return (SIMD2<Float>(minX, minZ), SIMD2<Float>(maxX, maxZ))
    }

    private func nearestRoutePointIndex(
        to waypoint: SIMD2<Float>,
        in routePoints: [SIMD3<Float>],
        startingAt searchStart: Int
    ) -> (index: Int, distance: Float)? {
        guard !routePoints.isEmpty else {
            return nil
        }

        var bestIndex: Int?
        var bestDistance = Float.greatestFiniteMagnitude

        for index in max(0, searchStart)..<routePoints.count {
            let point = routePoints[index]
            let distance = simd_length(SIMD2<Float>(point.x - waypoint.x, point.z - waypoint.y))
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }

        guard let bestIndex else {
            return nil
        }
        return (bestIndex, bestDistance)
    }
}
