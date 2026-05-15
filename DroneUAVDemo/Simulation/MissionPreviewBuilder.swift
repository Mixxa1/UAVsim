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

    func routePathAvoidingNoFly(
        points: [SIMD2<Float>],
        zones: [MissionZone],
        viewport: MapViewportState
    ) -> [SIMD2<Float>]? {
        guard points.count >= 2 else {
            return points
        }

        let noFlyZones = zones.filter { $0.type == .noFlyZone && $0.radius > 0.0 }
        guard !noFlyZones.isEmpty else {
            return compacted(points.map { viewport.clampedToWorld($0) })
        }

        var output: [SIMD2<Float>] = [viewport.clampedToWorld(points[0])]
        output.reserveCapacity(points.count + noFlyZones.count * 2)

        for point in points.dropFirst() {
            guard let leg = routedLeg(
                from: output[output.count - 1],
                to: point,
                noFlyZones: noFlyZones,
                viewport: viewport
            ) else {
                return nil
            }
            append(points: leg.dropFirst(), to: &output)
        }

        let compactedOutput = compacted(output)
        return pathStaysOutsideNoFly(compactedOutput, zones: noFlyZones) ? compactedOutput : nil
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
            zones: draft.noFlyZones,
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
        zones: [MissionZone],
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
            guard candidateArc.allSatisfy({ isInsideMissionBounds($0, viewport: viewport) }),
                  pathStaysOutsideNoFly(candidateArc, zones: zones) else {
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
            guard let leg = routedLeg(
                from: executionPoints[executionPoints.count - 1],
                to: waypoint.position,
                noFlyZones: draft.noFlyZones,
                viewport: viewport
            ) else {
                return nil
            }

            append(points: leg.dropFirst(), to: &executionPoints)
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

        let corridorPoints = [start, end]
        guard pathStaysOutsideNoFly(corridorPoints, zones: draft.noFlyZones) else {
            return nil
        }
        return corridorPoints
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

    private func routedLeg(
        from start: SIMD2<Float>,
        to end: SIMD2<Float>,
        noFlyZones: [MissionZone],
        viewport: MapViewportState
    ) -> [SIMD2<Float>]? {
        let clampedStart = viewport.clampedToWorld(start)
        let clampedEnd = viewport.clampedToWorld(end)
        let relevantZones = noFlyZones.filter { $0.radius > 0.0 }
        guard !relevantZones.isEmpty else {
            return [clampedStart, clampedEnd]
        }

        for zone in relevantZones {
            let paddedRadius = hardZoneBoundary(for: zone)
            let startDistance = simd_distance(clampedStart, zone.center)
            let endDistance = simd_distance(clampedEnd, zone.center)
            guard startDistance > paddedRadius + 0.05,
                  endDistance > paddedRadius + 0.05 else {
                return nil
            }
        }

        var candidate = [clampedStart, clampedEnd]
        let maxIterations = max(8, relevantZones.count * 16)
        var iteration = 0

        while let conflict = firstBlockingConflict(
            in: candidate,
            zones: relevantZones
        ) {
            iteration += 1
            guard iteration <= maxIterations,
                  let detour = routedSegment(
                    from: conflict.start,
                    to: conflict.end,
                    around: conflict.zone,
                    avoiding: relevantZones,
                    viewport: viewport
                  ) else {
                return nil
            }

            candidate.replaceSubrange(
                conflict.segmentIndex...(conflict.segmentIndex + 1),
                with: detour
            )
            candidate = compacted(candidate)
        }

        return pathStaysOutsideNoFly(candidate, zones: relevantZones) ? candidate : nil
    }

    private func routedSegment(
        from start: SIMD2<Float>,
        to end: SIMD2<Float>,
        around zone: MissionZone,
        avoiding allZones: [MissionZone],
        viewport: MapViewportState
    ) -> [SIMD2<Float>]? {
        let paddedRadius = avoidanceRadius(
            for: zone,
            segmentStart: start,
            segmentEnd: end
        )
        guard segmentIntersectsCircle(
            from: start,
            to: end,
            center: zone.center,
            radius: paddedRadius
        ) else {
            return [start, end]
        }

        let detours = detourCandidates(
            from: start,
            to: end,
            center: zone.center,
            radius: paddedRadius,
            allZones: allZones,
            blockingRadius: paddedRadius,
            viewport: viewport
        )

        return detours.min(by: { pathLength($0) < pathLength($1) })
    }

    private func detourCandidates(
        from start: SIMD2<Float>,
        to end: SIMD2<Float>,
        center: SIMD2<Float>,
        radius: Float,
        allZones: [MissionZone],
        blockingRadius: Float,
        viewport: MapViewportState
    ) -> [[SIMD2<Float>]] {
        let startTangents = tangentAngles(for: start, around: center, radius: radius)
        let endTangents = tangentAngles(for: end, around: center, radius: radius)
        guard !startTangents.isEmpty, !endTangents.isEmpty else {
            return []
        }

        var candidates: [[SIMD2<Float>]] = []

        for startAngle in startTangents {
            for endAngle in endTangents {
                for direction in ArcDirection.allCases {
                    let startTangent = point(onCircleWithCenter: center, radius: radius, angle: startAngle)
                    let arcPoints = sampledArc(
                        center: center,
                        radius: radius,
                        startAngle: startAngle,
                        endAngle: endAngle,
                        direction: direction
                    )

                    var candidate = [start, startTangent]
                    append(points: arcPoints.dropFirst(), to: &candidate)
                    append(points: [end], to: &candidate)

                    guard candidate.count >= 2,
                          candidate.allSatisfy({ isInsideMissionBounds($0, viewport: viewport) }),
                          candidate.allSatisfy({ pointIsOutsideNoFlyBoundary($0, zones: allZones) }),
                          pathStaysOutsideNoFly(
                            candidate,
                            center: center,
                            radius: blockingRadius
                          ) else {
                        continue
                    }

                    candidates.append(candidate)
                }
            }
        }

        return candidates
    }

    private func tangentAngles(
        for point: SIMD2<Float>,
        around center: SIMD2<Float>,
        radius: Float
    ) -> [Float] {
        let delta = point - center
        let distance = simd_length(delta)
        guard distance > radius + 0.0001 else {
            return []
        }

        let baseAngle = atan2(delta.y, delta.x)
        let normalizedRadius = min(1.0, max(0.0, radius / distance))
        let tangentOffset = acos(normalizedRadius)
        return [baseAngle + tangentOffset, baseAngle - tangentOffset]
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

    private func segmentIntersectsCircle(
        from start: SIMD2<Float>,
        to end: SIMD2<Float>,
        center: SIMD2<Float>,
        radius: Float
    ) -> Bool {
        let delta = end - start
        let lengthSquared = simd_length_squared(delta)
        guard lengthSquared > 0.0001 else {
            return simd_distance(start, center) <= radius
        }

        let t = simd_dot(center - start, delta) / lengthSquared
        let clampedT = min(1.0, max(0.0, t))
        let closestPoint = start + delta * clampedT
        return simd_distance(closestPoint, center) <= radius
    }

    private func pathStaysOutsideNoFly(
        _ points: [SIMD2<Float>],
        center: SIMD2<Float>,
        radius: Float
    ) -> Bool {
        guard points.count > 1 else {
            return false
        }

        for point in points {
            if simd_distance(point, center) < radius - 0.08 {
                return false
            }
        }

        for pair in zip(points, points.dropFirst()) {
            if segmentIntersectsCircle(
                from: pair.0,
                to: pair.1,
                center: center,
                radius: radius - 0.08
            ) {
                return false
            }
        }

        return true
    }

    private func pathStaysOutsideNoFly(
        _ points: [SIMD2<Float>],
        zones: [MissionZone]
    ) -> Bool {
        guard points.count > 1 else {
            return false
        }

        for zone in zones {
            let paddedRadius = hardZoneBoundary(for: zone)
            if !pathStaysOutsideNoFly(
                points,
                center: zone.center,
                radius: paddedRadius
            ) {
                return false
            }
        }

        return true
    }

    private func isInsideMissionBounds(
        _ point: SIMD2<Float>,
        viewport: MapViewportState
    ) -> Bool {
        viewport.isWithinWorldBounds(point, tolerance: 0.05)
    }

    private func preferredClearanceMargin(for zone: MissionZone) -> Float {
        max(0.35, min(1.0, zone.radius * 0.05))
    }

    private func hardZoneBoundary(for zone: MissionZone) -> Float {
        zone.radius + 0.05
    }

    private func avoidanceRadius(
        for zone: MissionZone,
        segmentStart start: SIMD2<Float>,
        segmentEnd end: SIMD2<Float>
    ) -> Float {
        let hardBoundary = hardZoneBoundary(for: zone)
        let availableUpperBound = min(
            simd_distance(start, zone.center),
            simd_distance(end, zone.center)
        ) - 0.08
        guard availableUpperBound > hardBoundary else {
            return hardBoundary
        }
        return min(zone.radius + preferredClearanceMargin(for: zone), availableUpperBound)
    }

    private func pointIsOutsideNoFlyBoundary(
        _ point: SIMD2<Float>,
        zones: [MissionZone]
    ) -> Bool {
        for zone in zones {
            let paddedRadius = hardZoneBoundary(for: zone)
            if simd_distance(point, zone.center) < paddedRadius - 0.08 {
                return false
            }
        }
        return true
    }

    private struct SegmentZoneConflict {
        let segmentIndex: Int
        let start: SIMD2<Float>
        let end: SIMD2<Float>
        let zone: MissionZone
    }

    private func firstBlockingConflict(
        in points: [SIMD2<Float>],
        zones: [MissionZone]
    ) -> SegmentZoneConflict? {
        guard points.count > 1 else {
            return nil
        }

        for (segmentIndex, pair) in zip(points.indices, zip(points, points.dropFirst())) {
            let blockingZone = zones
                .sorted { lhs, rhs in
                    simd_distance(pair.0, lhs.center) < simd_distance(pair.0, rhs.center)
                }
                .first { zone in
                    let paddedRadius = avoidanceRadius(
                        for: zone,
                        segmentStart: pair.0,
                        segmentEnd: pair.1
                    )
                    return segmentIntersectsCircle(
                        from: pair.0,
                        to: pair.1,
                        center: zone.center,
                        radius: paddedRadius
                    )
                }

            if let blockingZone {
                return SegmentZoneConflict(
                    segmentIndex: segmentIndex,
                    start: pair.0,
                    end: pair.1,
                    zone: blockingZone
                )
            }
        }

        return nil
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

    private func pathLength(_ points: [SIMD2<Float>]) -> Float {
        guard points.count > 1 else {
            return 0.0
        }

        return zip(points, points.dropFirst()).reduce(into: 0.0) { total, pair in
            total += simd_distance(pair.0, pair.1)
        }
    }
}
