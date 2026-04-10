import Foundation
import simd

final class MissionPreviewBuilder {
    private enum ArcDirection: CaseIterable {
        case clockwise
        case counterClockwise
    }

    func buildPreview(
        draft: MissionDraft,
        viewport: MapViewportState
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

        var previewPoints = executionRoute.points
        if draft.constraints.includeReturnHomePreview,
           let lastOutboundPoint = executionRoute.points.last,
           let returnLeg = routedLeg(
                from: lastOutboundPoint,
                to: viewport.dockPosition,
                noFlyZones: draft.noFlyZones,
                viewport: viewport
           ) {
            append(points: returnLeg.dropFirst(), to: &previewPoints)
        }

        guard previewPoints.count >= 2 else {
            return nil
        }

        var totalLength: Float = 0.0
        var boundsMin = previewPoints[0]
        var boundsMax = previewPoints[0]

        for index in 1..<previewPoints.count {
            totalLength += simd_distance(previewPoints[index - 1], previewPoints[index])
            boundsMin = simd_min(boundsMin, previewPoints[index])
            boundsMax = simd_max(boundsMax, previewPoints[index])
        }

        return MissionPreviewRoute(
            id: UUID(),
            points: previewPoints,
            executionPoints: executionRoute.points,
            waypointExecutionPointIndices: executionRoute.waypointPointIndices,
            totalLengthMeters: totalLength,
            boundsMin: boundsMin,
            boundsMax: boundsMax
        )
    }

    private func buildExecutionRoute(
        draft: MissionDraft,
        viewport: MapViewportState
    ) -> (points: [SIMD2<Float>], waypointPointIndices: [Int])? {
        var routePoints: [SIMD2<Float>] = [viewport.dockPosition]
        var waypointPointIndices: [Int] = []

        for waypoint in draft.waypoints {
            guard let leg = routedLeg(
                from: routePoints[routePoints.count - 1],
                to: waypoint.position,
                noFlyZones: draft.noFlyZones,
                viewport: viewport
            ) else {
                return nil
            }

            append(points: leg.dropFirst(), to: &routePoints)
            waypointPointIndices.append(routePoints.count - 1)
        }

        guard routePoints.count >= 2,
              waypointPointIndices.count == draft.waypoints.count else {
            return nil
        }

        return (routePoints, waypointPointIndices)
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
        let extent = max(1.0, viewport.worldHalfExtent)
        return abs(point.x) <= extent + 0.05 &&
            abs(point.y) <= extent + 0.05 &&
            simd_distance(point, .zero) <= viewport.signalBoundaryRadius + 0.05
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
