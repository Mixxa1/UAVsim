import Foundation
import simd

final class MissionPreviewBuilder {
    private enum ArcDirection: CaseIterable {
        case clockwise
        case counterClockwise
    }

    func buildPreview(
        draft: MissionDraft,
        viewport: MapViewportState,
        airframeClass: AirframeClass = .multirotor,
        fixedWingParameters: FixedWingParameters? = nil
    ) -> MissionPreviewRoute? {
        guard !draft.waypoints.isEmpty else {
            return nil
        }

        guard let executionRoute = buildExecutionRoute(
            draft: draft,
            viewport: viewport
        ) else {
            return nil
        }

        var missionPlanPoints = executionRoute.missionPlanPoints
        var executionPoints = executionRoute.executionPoints
        var waypointExecutionPointIndices = executionRoute.executionWaypointPointIndices
        var isFlyablePreview = false
        var previewStatusKey: String?

        if airframeClass == .fixedWing {
            if let flyablePreview = buildFixedWingPreview(
                draft: draft,
                viewport: viewport,
                missionPlanPoints: executionRoute.missionPlanPoints,
                planWaypointPointIndices: executionRoute.missionWaypointPointIndices,
                fixedWingParameters: fixedWingParameters
            ) {
                missionPlanPoints = flyablePreview.missionPlanPoints
                executionPoints = flyablePreview.executionPoints
                waypointExecutionPointIndices = flyablePreview.waypointExecutionPointIndices
                isFlyablePreview = true
            } else {
                previewStatusKey = "tactical.map.preview.unavailable"
            }
        }

        guard executionPoints.count >= 2 else {
            return nil
        }

        var totalLength: Float = 0.0
        var boundsMin = executionPoints[0]
        var boundsMax = executionPoints[0]

        for index in 1..<executionPoints.count {
            totalLength += simd_distance(executionPoints[index - 1], executionPoints[index])
            boundsMin = simd_min(boundsMin, executionPoints[index])
            boundsMax = simd_max(boundsMax, executionPoints[index])
        }

        return MissionPreviewRoute(
            id: UUID(),
            missionPlanPoints: missionPlanPoints,
            executionPoints: executionPoints,
            waypointExecutionPointIndices: waypointExecutionPointIndices,
            isFlyablePreview: isFlyablePreview,
            previewStatusKey: previewStatusKey,
            totalLengthMeters: totalLength,
            boundsMin: boundsMin,
            boundsMax: boundsMax
        )
    }

    private func buildFixedWingPreview(
        draft: MissionDraft,
        viewport: MapViewportState,
        missionPlanPoints: [SIMD2<Float>],
        planWaypointPointIndices: [Int],
        fixedWingParameters: FixedWingParameters?
    ) -> (missionPlanPoints: [SIMD2<Float>], executionPoints: [SIMD2<Float>], waypointExecutionPointIndices: [Int])? {
        guard missionPlanPoints.count >= 2 else {
            return nil
        }

        let wing = resolvedFixedWingParameters(fixedWingParameters)
        guard let corridorPoints = launchCorridorPoints(
            for: draft,
            viewport: viewport,
            fixedWingParameters: wing
        ) else {
            return nil
        }

        let planPoints = missionPlanPoints
        var flyableInputPoints = missionPlanPoints
        if corridorPoints.count > 1 {
            var prefixedPoints: [SIMD2<Float>] = []
            append(points: corridorPoints, to: &prefixedPoints)
            append(points: missionPlanPoints, to: &prefixedPoints)
            flyableInputPoints = prefixedPoints
        }

        let smoothedPoints = smoothedFixedWingPreview(
            points: flyableInputPoints,
            viewport: viewport,
            fixedWingParameters: wing
        )
        guard smoothedPoints.count >= 2 else {
            return nil
        }

        guard let mappedWaypointIndices = remapWaypointIndices(
            planPoints: planPoints,
            planWaypointPointIndices: planWaypointPointIndices,
            executionPoints: smoothedPoints,
            fixedWingParameters: wing
        ) else {
            return nil
        }

        return (
            missionPlanPoints: planPoints,
            executionPoints: smoothedPoints,
            waypointExecutionPointIndices: mappedWaypointIndices
        )
    }

    private func smoothedFixedWingPreview(
        points: [SIMD2<Float>],
        viewport: MapViewportState,
        fixedWingParameters: FixedWingParameters
    ) -> [SIMD2<Float>] {
        guard points.count >= 3 else {
            return points
        }

        let turnRadius = fixedWingParameters.minimumTurnRadius()

        var output: [SIMD2<Float>] = [points[0]]
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1]
            let current = points[index]
            let next = points[index + 1]

            let incoming = current - previous
            let outgoing = next - current
            let incomingLength = simd_length(incoming)
            let outgoingLength = simd_length(outgoing)
            guard incomingLength > 0.1, outgoingLength > 0.1 else {
                append(points: [current], to: &output)
                continue
            }

            let dirIn = incoming / incomingLength
            let dirOut = outgoing / outgoingLength
            let rawDot = simd_dot(-dirIn, dirOut)
            let normalizedDot = max(Float(-0.999), min(Float(0.999), rawDot))
            let cornerAngle = acos(normalizedDot)
            let turnAngle = Float.pi - cornerAngle
            guard turnAngle > 0.16 else {
                append(points: [current], to: &output)
                continue
            }

            let trimDistance = min(
                turnRadius * tan(turnAngle * 0.5),
                min(incomingLength, outgoingLength) * 0.34
            )
            guard trimDistance > 0.12 else {
                append(points: [current], to: &output)
                continue
            }

            let entry = current - dirIn * trimDistance
            let exit = current + dirOut * trimDistance
            let turnSign = dirIn.x * dirOut.y - dirIn.y * dirOut.x
            let incomingNormal = turnSign >= 0.0
                ? SIMD2<Float>(-dirIn.y, dirIn.x)
                : SIMD2<Float>(dirIn.y, -dirIn.x)
            let outgoingNormal = turnSign >= 0.0
                ? SIMD2<Float>(-dirOut.y, dirOut.x)
                : SIMD2<Float>(dirOut.y, -dirOut.x)

            guard let center = lineIntersection(
                pointA: entry,
                directionA: incomingNormal,
                pointB: exit,
                directionB: outgoingNormal
            ) else {
                append(points: [current], to: &output)
                continue
            }

            let radius = simd_distance(center, entry)
            guard radius.isFinite, radius > 0.05 else {
                append(points: [current], to: &output)
                continue
            }

            let startAngle = atan2(entry.y - center.y, entry.x - center.x)
            let endAngle = atan2(exit.y - center.y, exit.x - center.x)
            let direction: ArcDirection = turnSign >= 0.0 ? .counterClockwise : .clockwise
            let arcPoints = sampledArc(
                center: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: endAngle,
                direction: direction
            )

            let candidateArc = [entry] + Array(arcPoints.dropFirst().dropLast()) + [exit]
            guard candidateArc.allSatisfy({ isInsideMissionBounds($0, viewport: viewport) }) else {
                append(points: [current], to: &output)
                continue
            }

            append(points: [entry], to: &output)
            append(points: candidateArc.dropFirst(), to: &output)
        }

        append(points: [points[points.count - 1]], to: &output)
        return compacted(output)
    }

    private func lineIntersection(
        pointA: SIMD2<Float>,
        directionA: SIMD2<Float>,
        pointB: SIMD2<Float>,
        directionB: SIMD2<Float>
    ) -> SIMD2<Float>? {
        let denominator = directionA.x * directionB.y - directionA.y * directionB.x
        guard abs(denominator) > 0.0001 else {
            return nil
        }
        let delta = pointB - pointA
        let t = (delta.x * directionB.y - delta.y * directionB.x) / denominator
        return pointA + directionA * t
    }

    private func buildExecutionRoute(
        draft: MissionDraft,
        viewport: MapViewportState
    ) -> (
        executionPoints: [SIMD2<Float>],
        executionWaypointPointIndices: [Int],
        missionPlanPoints: [SIMD2<Float>],
        missionWaypointPointIndices: [Int]
    )? {
        let routeStart = resolvedRouteStartPoint(
            draft: draft,
            viewport: viewport
        )
        var executionPoints: [SIMD2<Float>] = [routeStart]
        var executionWaypointPointIndices: [Int] = []

        for waypoint in draft.waypoints {
            let clampedTarget = viewport.clampedToWorld(waypoint.position)
            append(points: [clampedTarget], to: &executionPoints)
            executionWaypointPointIndices.append(executionPoints.count - 1)
        }

        guard executionPoints.count >= 2,
              executionWaypointPointIndices.count == draft.waypoints.count else {
            return nil
        }

        // Visible mission geometry excludes the hidden route start so map
        // rendering and validation operate only on user-defined mission legs.
        let missionPlanPoints = Array(executionPoints.dropFirst())
        let missionWaypointPointIndices = executionWaypointPointIndices.map { $0 - 1 }
        guard missionWaypointPointIndices.count == draft.waypoints.count,
              missionWaypointPointIndices.allSatisfy({ $0 >= 0 && $0 < missionPlanPoints.count }) else {
            return nil
        }

        return (
            executionPoints,
            executionWaypointPointIndices,
            missionPlanPoints,
            missionWaypointPointIndices
        )
    }

    private func resolvedRouteStartPoint(
        draft: MissionDraft,
        viewport: MapViewportState
    ) -> SIMD2<Float> {
        if draft.selectedLaunchMode.requiresLaunchObject,
           let launchObject = draft.launchObject {
            return viewport.clampedToWorld(launchObject.position)
        }
        return viewport.dockPosition
    }

    private func launchCorridorPoints(
        for draft: MissionDraft,
        viewport: MapViewportState,
        fixedWingParameters: FixedWingParameters
    ) -> [SIMD2<Float>]? {
        guard draft.selectedLaunchMode.requiresLaunchObject else {
            return [resolvedRouteStartPoint(draft: draft, viewport: viewport)]
        }
        guard let launchObject = draft.launchObject else {
            return nil
        }

        let start = viewport.clampedToWorld(launchObject.position)
        let corridorLength = fixedWingParameters.corridorLength(for: draft.selectedLaunchMode)
        guard corridorLength > 0.05 else {
            return [start]
        }

        let headingRadians = launchHeadingRadians(for: launchObject)
        let forward = SIMD2<Float>(sin(headingRadians), cos(headingRadians))
        let end = start + forward * corridorLength
        guard viewport.isWithinWorldBounds(end, tolerance: 0.05) else {
            return nil
        }

        return [start, end]
    }

    private func launchHeadingRadians(for launchObject: MissionLaunchObject) -> Float {
        switch launchObject.type {
        case .vtolStartPoint:
            return launchObject.transitionHeadingRadians ?? launchObject.headingRadians
        case .handLaunchPoint, .catapultLine, .runwayStrip:
            return launchObject.headingRadians
        }
    }

    private func remapWaypointIndices(
        planPoints: [SIMD2<Float>],
        planWaypointPointIndices: [Int],
        executionPoints: [SIMD2<Float>],
        fixedWingParameters: FixedWingParameters
    ) -> [Int]? {
        guard !planWaypointPointIndices.isEmpty else {
            return nil
        }

        var mappedIndices: [Int] = []
        var searchStart = 0
        let maximumDistance = max(
            fixedWingParameters.waypointAcceptanceRadiusMeters * 2.4,
            fixedWingParameters.minimumTurnRadius() * 0.95
        )

        for waypointPointIndex in planWaypointPointIndices {
            guard waypointPointIndex >= 0,
                  waypointPointIndex < planPoints.count else {
                return nil
            }

            let waypointPoint = planPoints[waypointPointIndex]
            var bestIndex: Int?
            var bestDistance = Float.greatestFiniteMagnitude

            for index in searchStart..<executionPoints.count {
                let distance = simd_distance(executionPoints[index], waypointPoint)
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = index
                }
            }

            guard let bestIndex, bestDistance <= maximumDistance else {
                return nil
            }

            mappedIndices.append(bestIndex)
            searchStart = bestIndex
        }

        return mappedIndices
    }

    private func resolvedFixedWingParameters(
        _ fixedWingParameters: FixedWingParameters?
    ) -> FixedWingParameters {
        fixedWingParameters ?? FixedWingParameters(
            family: .conventionalSurvey,
            minSustainableSpeedMps: 10.0,
            cruiseSpeedMps: 17.0,
            climbSpeedMps: 13.0,
            stallWarningSpeedMps: 9.0,
            waypointAcceptanceRadiusMeters: 9.0,
            nominalTurnRateDegPerSec: 9.0,
            bankResponseGain: 0.72,
            climbResponseGain: 0.64,
            descentResponseGain: 0.54,
            dragFactor: 1.0,
            throttleResponseGain: 0.64,
            turnAuthority: 0.64,
            maxBankAngleDeg: 38.0
        )
    }

    private func sampledArc(
        center: SIMD2<Float>,
        radius: Float,
        startAngle: Float,
        endAngle: Float,
        direction: ArcDirection
    ) -> [SIMD2<Float>] {
        let deltaAngle: Float = {
            switch direction {
            case .clockwise:
                let normalizedStart = normalizedAngle(startAngle)
                let normalizedEnd = normalizedAngle(endAngle)
                return normalizedStart >= normalizedEnd
                    ? normalizedStart - normalizedEnd
                    : normalizedStart + (.pi * 2.0 - normalizedEnd)
            case .counterClockwise:
                let normalizedStart = normalizedAngle(startAngle)
                let normalizedEnd = normalizedAngle(endAngle)
                return normalizedEnd >= normalizedStart
                    ? normalizedEnd - normalizedStart
                    : normalizedEnd + (.pi * 2.0 - normalizedStart)
            }
        }()

        let arcLength = radius * max(0.0, deltaAngle)
        let sampleCount = max(1, Int(ceil(arcLength / 2.4)))
        var points: [SIMD2<Float>] = []
        points.reserveCapacity(sampleCount + 1)

        for sampleIndex in 0...sampleCount {
            let progress = Float(sampleIndex) / Float(sampleCount)
            let angle: Float
            switch direction {
            case .clockwise:
                angle = startAngle - deltaAngle * progress
            case .counterClockwise:
                angle = startAngle + deltaAngle * progress
            }
            points.append(point(onCircleWithCenter: center, radius: radius, angle: angle))
        }

        return points
    }

    private func point(
        onCircleWithCenter center: SIMD2<Float>,
        radius: Float,
        angle: Float
    ) -> SIMD2<Float> {
        SIMD2<Float>(
            center.x + cos(angle) * radius,
            center.y + sin(angle) * radius
        )
    }

    private func normalizedAngle(_ angle: Float) -> Float {
        let tau = Float.pi * 2.0
        var value = angle.truncatingRemainder(dividingBy: tau)
        if value < 0.0 {
            value += tau
        }
        return value
    }

    private func isInsideMissionBounds(
        _ point: SIMD2<Float>,
        viewport: MapViewportState
    ) -> Bool {
        viewport.isWithinWorldBounds(point, tolerance: 0.05)
    }

    private func compacted(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        var output: [SIMD2<Float>] = []
        append(points: points, to: &output)
        return output
    }

    private func append<S: Sequence>(
        points: S,
        to output: inout [SIMD2<Float>]
    ) where S.Element == SIMD2<Float> {
        for point in points {
            if let last = output.last, simd_distance(last, point) <= 0.05 {
                continue
            }
            output.append(point)
        }
    }

}
