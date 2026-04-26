import Foundation
import simd

// MARK: - Primitive types

/// Direction of an arc primitive in the XZ plane.
/// `left` = counter-clockwise (positive sweep), `right` = clockwise (negative sweep).
enum FixedWingTurnDirection: String, Equatable {
    case left
    case right
}

/// A flyable path primitive used by the fixed-wing autopilot. The route is a
/// sequence of `line` and `arc` primitives that join smoothly tangent-to-tangent.
enum FixedWingPathPrimitive: Equatable {
    case line(start: SIMD2<Float>, end: SIMD2<Float>)
    case arc(
        center: SIMD2<Float>,
        radius: Float,
        startAngle: Float,
        sweepAngle: Float,
        direction: FixedWingTurnDirection,
        entry: SIMD2<Float>,
        exit: SIMD2<Float>
    )

    /// Approximate arc/segment length in metres.
    var length: Float {
        switch self {
        case let .line(start, end):
            return simd_distance(start, end)
        case let .arc(_, radius, _, sweepAngle, _, _, _):
            return abs(sweepAngle) * radius
        }
    }

    /// First (entry) point of the primitive.
    var startPoint: SIMD2<Float> {
        switch self {
        case let .line(start, _):
            return start
        case let .arc(_, _, _, _, _, entry, _):
            return entry
        }
    }

    /// Last (exit) point of the primitive.
    var endPoint: SIMD2<Float> {
        switch self {
        case let .line(_, end):
            return end
        case let .arc(_, _, _, _, _, _, exit):
            return exit
        }
    }

    /// Course (radians) at the very end of the primitive — used as a smooth
    /// hand-off into the next primitive without snap.
    var exitCourse: Float {
        switch self {
        case let .line(start, end):
            let direction = end - start
            guard let normalized = safeNormalize(direction) else {
                return 0.0
            }
            return courseRadiansFromDirection(normalized)
        case let .arc(center, _, _, sweepAngle, direction, _, exit):
            return arcTangentCourse(
                point: exit,
                center: center,
                turnDirection: direction,
                sweepAngle: sweepAngle
            )
        }
    }

    /// Course (radians) at the very beginning of the primitive.
    var entryCourse: Float {
        switch self {
        case let .line(start, end):
            let direction = end - start
            guard let normalized = safeNormalize(direction) else {
                return 0.0
            }
            return courseRadiansFromDirection(normalized)
        case let .arc(center, _, _, sweepAngle, direction, entry, _):
            return arcTangentCourse(
                point: entry,
                center: center,
                turnDirection: direction,
                sweepAngle: sweepAngle
            )
        }
    }
}

/// Maps a mission/manual waypoint anchor to the index of the primitive that
/// concludes "near" that waypoint (post-arc). Used for active waypoint progress
/// reporting and mission auto-advance.
struct FixedWingPrimitiveAnchor: Equatable {
    var missionWaypointIndex: Int?
    var waypointIdentifier: String?
    /// Index into `FixedWingFlyableRoute.primitives` after which the waypoint
    /// is considered passed.
    var primitiveIndex: Int
    /// World position of the original waypoint (without fillet trim).
    var waypointPosition: SIMD2<Float>
}

/// Flyable path consisting of explicit line + arc primitives. Built once per
/// route change and consumed by `FixedWingPrimitivePathFollower`.
struct FixedWingFlyableRoute: Equatable {
    var routeIdentifier: String
    var primitives: [FixedWingPathPrimitive]
    var anchors: [FixedWingPrimitiveAnchor]
    var samples: [SIMD2<Float>]

    var isUsable: Bool {
        !primitives.isEmpty
    }

    /// Total flyable length in metres.
    var totalLength: Float {
        primitives.reduce(0.0) { $0 + $1.length }
    }

    /// Cumulative length up to (but not including) primitive `index`.
    func cumulativeLength(through index: Int) -> Float {
        guard index > 0 else { return 0.0 }
        var sum: Float = 0.0
        for i in 0..<min(index, primitives.count) {
            sum += primitives[i].length
        }
        return sum
    }
}

// MARK: - Builder

/// Builds a `FixedWingFlyableRoute` from a sequence of waypoints (with optional
/// mission anchors) using line + fillet-arc primitives. Each intermediate
/// waypoint produces an arc that joins the inbound and outbound legs tangent
/// to both, so the airplane does not have to snap heading at corners.
final class FixedWingFlyableRouteBuilder {
    struct WaypointInput {
        var position: SIMD2<Float>
        var missionWaypointIndex: Int?
        var waypointIdentifier: String?
    }

    /// `start` is the runtime starting point (e.g. drone's current planar
    /// position). `waypoints` are the raw mission anchor waypoints in order.
    func build(
        routeIdentifier: String,
        start: SIMD2<Float>,
        waypoints: [WaypointInput],
        wing: FixedWingParameters,
        airspeed: Float
    ) -> FixedWingFlyableRoute? {
        guard isFiniteVector2(start) else { return nil }

        var anchorPoints: [WaypointInput] = []
        anchorPoints.reserveCapacity(waypoints.count + 1)
        anchorPoints.append(
            WaypointInput(
                position: start,
                missionWaypointIndex: nil,
                waypointIdentifier: "fixed-wing-flyable-runtime-start"
            )
        )

        for waypoint in waypoints {
            guard isFiniteVector2(waypoint.position) else { continue }
            if let last = anchorPoints.last,
               simd_distance(last.position, waypoint.position) < 0.05 {
                // Drop duplicates but inherit anchor metadata.
                if waypoint.missionWaypointIndex != nil ||
                   waypoint.waypointIdentifier != nil {
                    anchorPoints[anchorPoints.count - 1] = WaypointInput(
                        position: last.position,
                        missionWaypointIndex: waypoint.missionWaypointIndex ?? last.missionWaypointIndex,
                        waypointIdentifier: waypoint.waypointIdentifier ?? last.waypointIdentifier
                    )
                }
                continue
            }
            anchorPoints.append(waypoint)
        }

        guard anchorPoints.count >= 2 else { return nil }

        let referenceTurnRadius = max(
            0.5,
            wing.minimumTurnRadius(airspeed: max(airspeed, wing.minSafeAirspeed))
        )

        var primitives: [FixedWingPathPrimitive] = []
        var anchors: [FixedWingPrimitiveAnchor] = []

        // We need to track the *current* tangent point that the next line
        // primitive will start from. Initially that's the start anchor.
        var currentTangent = anchorPoints[0].position

        for i in 1..<(anchorPoints.count - 1) {
            let previous = anchorPoints[i - 1]
            let current = anchorPoints[i]
            let next = anchorPoints[i + 1]

            let result = buildFilletArc(
                previous: previous.position,
                current: current.position,
                next: next.position,
                referenceRadius: referenceTurnRadius,
                wing: wing
            )

            switch result {
            case let .arc(arcPrimitive):
                let entryPoint = arcPrimitive.startPoint
                if simd_distance(currentTangent, entryPoint) > 0.01 {
                    primitives.append(.line(start: currentTangent, end: entryPoint))
                }
                primitives.append(arcPrimitive)
                anchors.append(
                    FixedWingPrimitiveAnchor(
                        missionWaypointIndex: current.missionWaypointIndex,
                        waypointIdentifier: current.waypointIdentifier,
                        primitiveIndex: primitives.count - 1,
                        waypointPosition: current.position
                    )
                )
                currentTangent = arcPrimitive.endPoint

            case .skip:
                // The corner is too shallow or the geometry is degenerate —
                // just pass straight through this waypoint with an anchor
                // at the line that ends at it.
                if simd_distance(currentTangent, current.position) > 0.01 {
                    primitives.append(.line(start: currentTangent, end: current.position))
                }
                anchors.append(
                    FixedWingPrimitiveAnchor(
                        missionWaypointIndex: current.missionWaypointIndex,
                        waypointIdentifier: current.waypointIdentifier,
                        primitiveIndex: primitives.count - 1,
                        waypointPosition: current.position
                    )
                )
                currentTangent = current.position
            }
        }

        // Final leg: from the current tangent to the last waypoint.
        let lastAnchor = anchorPoints[anchorPoints.count - 1]
        if simd_distance(currentTangent, lastAnchor.position) > 0.01 {
            primitives.append(.line(start: currentTangent, end: lastAnchor.position))
        }
        if !primitives.isEmpty {
            anchors.append(
                FixedWingPrimitiveAnchor(
                    missionWaypointIndex: lastAnchor.missionWaypointIndex,
                    waypointIdentifier: lastAnchor.waypointIdentifier,
                    primitiveIndex: primitives.count - 1,
                    waypointPosition: lastAnchor.position
                )
            )
        }

        guard !primitives.isEmpty else { return nil }

        let samples = sample(primitives: primitives)

        return FixedWingFlyableRoute(
            routeIdentifier: routeIdentifier,
            primitives: primitives,
            anchors: anchors,
            samples: samples
        )
    }

    // MARK: - Fillet arc construction

    private enum FilletResult {
        case arc(FixedWingPathPrimitive)
        case skip
    }

    private func buildFilletArc(
        previous: SIMD2<Float>,
        current: SIMD2<Float>,
        next: SIMD2<Float>,
        referenceRadius: Float,
        wing: FixedWingParameters
    ) -> FilletResult {
        let inbound = current - previous
        let outbound = next - current
        let inboundLength = simd_length(inbound)
        let outboundLength = simd_length(outbound)
        guard inboundLength > 0.05, outboundLength > 0.05 else {
            return .skip
        }

        let dirIn = inbound / inboundLength
        let dirOut = outbound / outboundLength
        let dot = simd_dot(dirIn, dirOut).fwClampedFloat(to: -1.0...1.0)
        let turnAngle = acos(dot) // [0, π]
        // Skip very shallow corners — they don't need an arc.
        guard turnAngle > Float(7.0).degreesToRadiansFloat else {
            return .skip
        }
        // Cap reflex turns at ~150° to avoid degenerate geometry.
        let cappedTurnAngle = min(turnAngle, Float(150.0).degreesToRadiansFloat)

        // Cross-product Z component: > 0 = left turn (CCW), < 0 = right (CW).
        let turnSign = dirIn.x * dirOut.y - dirIn.y * dirOut.x
        guard abs(turnSign) > 0.001 else {
            return .skip
        }

        var radius = referenceRadius
        let halfAngle = cappedTurnAngle * 0.5
        var tangentDistance = radius * tan(halfAngle)

        // Bound tangent distance by 35% of either leg so we never cut more
        // than that into adjacent legs. If we'd need to cut more, shrink
        // the radius accordingly.
        let maxTangent = min(inboundLength, outboundLength) * 0.35
        if tangentDistance > maxTangent {
            tangentDistance = maxTangent
            radius = tangentDistance / max(0.001, tan(halfAngle))
        }

        // Enforce a minimum physically-plausible radius. If the leg is too
        // short to host even the smallest arc, fall back to skip.
        let minimumRadius = max(0.5, wing.waypointAcceptanceRadiusMeters * 0.45)
        guard radius >= minimumRadius, tangentDistance >= 0.10 else {
            return .skip
        }

        let entry = current - dirIn * tangentDistance
        let exit = current + dirOut * tangentDistance

        // Center is perpendicular to dirIn at entry, on the correct side.
        let leftNormalIn = SIMD2<Float>(-dirIn.y, dirIn.x)
        let center = turnSign > 0.0
            ? entry + leftNormalIn * radius
            : entry - leftNormalIn * radius

        let startAngle = atan2(entry.y - center.y, entry.x - center.x)
        let endAngle = atan2(exit.y - center.y, exit.x - center.x)
        var sweepAngle = endAngle - startAngle
        // Normalise to a single revolution in the correct direction.
        if turnSign > 0.0 {
            // CCW: positive sweep
            while sweepAngle < 0.0 { sweepAngle += .pi * 2.0 }
            while sweepAngle > .pi * 2.0 { sweepAngle -= .pi * 2.0 }
        } else {
            // CW: negative sweep
            while sweepAngle > 0.0 { sweepAngle -= .pi * 2.0 }
            while sweepAngle < -.pi * 2.0 { sweepAngle += .pi * 2.0 }
        }

        guard radius.isFinite,
              startAngle.isFinite,
              sweepAngle.isFinite,
              isFiniteVector2(entry),
              isFiniteVector2(exit),
              isFiniteVector2(center) else {
            return .skip
        }

        let direction: FixedWingTurnDirection = turnSign > 0.0 ? .left : .right
        return .arc(
            .arc(
                center: center,
                radius: radius,
                startAngle: startAngle,
                sweepAngle: sweepAngle,
                direction: direction,
                entry: entry,
                exit: exit
            )
        )
    }

    // MARK: - Sampling

    private func sample(primitives: [FixedWingPathPrimitive]) -> [SIMD2<Float>] {
        var output: [SIMD2<Float>] = []
        output.reserveCapacity(primitives.count * 6)

        for (index, primitive) in primitives.enumerated() {
            let isFirst = index == 0
            switch primitive {
            case let .line(start, end):
                if isFirst {
                    output.append(start)
                }
                output.append(end)
            case let .arc(center, radius, startAngle, sweepAngle, _, _, _):
                if isFirst {
                    let entry = SIMD2<Float>(
                        center.x + cos(startAngle) * radius,
                        center.y + sin(startAngle) * radius
                    )
                    output.append(entry)
                }
                let arcLength = abs(sweepAngle) * radius
                let sampleCount = max(2, Int(ceil(arcLength / 2.5)))
                for s in 1...sampleCount {
                    let t = Float(s) / Float(sampleCount)
                    let angle = startAngle + sweepAngle * t
                    output.append(
                        SIMD2<Float>(
                            center.x + cos(angle) * radius,
                            center.y + sin(angle) * radius
                        )
                    )
                }
            }
        }

        return output
    }
}

// MARK: - Follower

struct FixedWingPrimitiveFollowProgress: Equatable {
    var primitiveIndex: Int
    var alongPrimitiveDistance: Float
    var primitiveLength: Float
    var crossTrackError: Float
    var lookaheadPoint: SIMD2<Float>
    var desiredCourse: Float
    var primitiveCourseAtPosition: Float
    var primitiveType: PrimitiveType
    var isOnFinalPrimitive: Bool
    var distanceToPrimitiveEnd: Float
    var totalRemainingDistance: Float
    var activeAnchorIndex: Int
    var activeAnchorMissionIndex: Int?
    var activeAnchorPosition: SIMD2<Float>

    enum PrimitiveType: String, Equatable {
        case line
        case arc
    }
}

/// Follows a `FixedWingFlyableRoute` primitive-by-primitive. Tracks the
/// current primitive, computes a lookahead point, and produces a desired
/// course suitable for an L1-style nonlinear bank command.
final class FixedWingPrimitivePathFollower {
    private var routeIdentifier: String?
    private var activePrimitiveIndex: Int = 0
    private var minimumPrimitiveIndex: Int = 0

    func reset() {
        routeIdentifier = nil
        activePrimitiveIndex = 0
        minimumPrimitiveIndex = 0
    }

    /// Update the follower with the current planar position. Returns `nil` if
    /// the route is empty / unusable.
    /// - Parameter minimumWaypointIndex: bumps the active primitive index to
    ///   the primitive that ends at or after the active mission waypoint.
    func update(
        position: SIMD2<Float>,
        route: FixedWingFlyableRoute,
        wing: FixedWingParameters,
        airspeed: Float,
        minimumWaypointIndex: Int?
    ) -> FixedWingPrimitiveFollowProgress? {
        guard route.isUsable, isFiniteVector2(position) else {
            return nil
        }

        // Reset/migrate state when the route identifier changes.
        if routeIdentifier != route.routeIdentifier {
            routeIdentifier = route.routeIdentifier
            activePrimitiveIndex = 0
            minimumPrimitiveIndex = 0
        }

        // Auto-advance: enforce the minimum primitive demanded by the
        // mission's active waypoint index.
        let demandedMinimum = primitiveIndex(
            forMinimumWaypointIndex: minimumWaypointIndex,
            in: route
        )
        if demandedMinimum > minimumPrimitiveIndex {
            minimumPrimitiveIndex = demandedMinimum
        }
        if activePrimitiveIndex < minimumPrimitiveIndex {
            activePrimitiveIndex = minimumPrimitiveIndex
        }

        let lookaheadDistance = max(
            wing.waypointAcceptanceRadiusMeters * 1.2,
            wing.guidanceLookaheadDistance(airspeed: max(airspeed, wing.minSafeAirspeed))
        )

        // Try to advance through completed primitives based on along-track /
        // angular progress, but never beyond the final primitive.
        let finalIndex = route.primitives.count - 1
        var safety = route.primitives.count + 4
        while activePrimitiveIndex < finalIndex, safety > 0 {
            safety -= 1
            let primitive = route.primitives[activePrimitiveIndex]
            let projection = project(position: position, on: primitive)
            if shouldAdvancePrimitive(
                projection: projection,
                primitive: primitive,
                wing: wing
            ) {
                activePrimitiveIndex += 1
                continue
            }
            break
        }

        guard activePrimitiveIndex >= 0, activePrimitiveIndex <= finalIndex else {
            return nil
        }

        let primitive = route.primitives[activePrimitiveIndex]
        let projection = project(position: position, on: primitive)
        let lookahead = lookaheadPoint(
            on: primitive,
            from: projection.alongDistance,
            lookaheadDistance: lookaheadDistance,
            route: route,
            primitiveIndex: activePrimitiveIndex
        )
        let desiredCourseRaw = flyableCourseToPoint(
            from: position,
            to: lookahead,
            fallback: projection.courseAtPosition
        )
        // If the lookahead point essentially coincides with our current
        // position (e.g. micro-segments) prefer the primitive's local course
        // to keep the nose moving forward.
        let desiredCourse = simd_distance(position, lookahead) > 0.05
            ? desiredCourseRaw
            : projection.courseAtPosition

        let activeAnchor = anchor(
            forPrimitiveIndex: activePrimitiveIndex,
            in: route
        )
        let totalRemaining = remainingDistance(
            from: activePrimitiveIndex,
            alongCurrent: projection.alongDistance,
            in: route
        )

        let progress = FixedWingPrimitiveFollowProgress(
            primitiveIndex: activePrimitiveIndex,
            alongPrimitiveDistance: projection.alongDistance,
            primitiveLength: primitive.length,
            crossTrackError: projection.crossTrack,
            lookaheadPoint: lookahead,
            desiredCourse: desiredCourse,
            primitiveCourseAtPosition: projection.courseAtPosition,
            primitiveType: {
                if case .line = primitive { return .line }
                return .arc
            }(),
            isOnFinalPrimitive: activePrimitiveIndex == finalIndex,
            distanceToPrimitiveEnd: max(0.0, primitive.length - projection.alongDistance),
            totalRemainingDistance: totalRemaining,
            activeAnchorIndex: activeAnchor.index,
            activeAnchorMissionIndex: activeAnchor.missionIndex,
            activeAnchorPosition: activeAnchor.position
        )

        guard progress.desiredCourse.isFinite,
              progress.alongPrimitiveDistance.isFinite,
              progress.crossTrackError.isFinite else {
            return nil
        }

        return progress
    }

    // MARK: - Internals

    private struct PrimitiveProjection {
        var alongDistance: Float
        var crossTrack: Float
        var courseAtPosition: Float
    }

    private func project(
        position: SIMD2<Float>,
        on primitive: FixedWingPathPrimitive
    ) -> PrimitiveProjection {
        switch primitive {
        case let .line(start, end):
            let delta = end - start
            let length = max(0.001, simd_length(delta))
            let direction = delta / length
            let local = position - start
            let along = simd_dot(local, direction).fwClampedFloat(to: -length...(length * 1.5))
            let normal = SIMD2<Float>(-direction.y, direction.x)
            let cross = simd_dot(local, normal)
            let course = courseRadiansFromDirection(direction)
            return PrimitiveProjection(
                alongDistance: along,
                crossTrack: cross,
                courseAtPosition: course
            )
        case let .arc(center, radius, startAngle, sweepAngle, direction, _, _):
            let radial = position - center
            let radialLength = max(0.001, simd_length(radial))
            let currentAngle = atan2(radial.y, radial.x)
            // Compute progress along the arc respecting sweep direction.
            let relAngle = signedAngularProgress(
                currentAngle: currentAngle,
                startAngle: startAngle,
                sweepAngle: sweepAngle
            )
            let along = relAngle * radius
            let cross = direction == .left
                ? radius - radialLength
                : radialLength - radius
            // Tangent course at the projected angle (along the sweep direction).
            let projectedAngle = startAngle + sign(sweepAngle) * relAngle
            let course = arcTangentCourse(
                point: SIMD2<Float>(
                    center.x + cos(projectedAngle) * radius,
                    center.y + sin(projectedAngle) * radius
                ),
                center: center,
                turnDirection: direction,
                sweepAngle: sweepAngle
            )
            return PrimitiveProjection(
                alongDistance: along,
                crossTrack: cross,
                courseAtPosition: course
            )
        }
    }

    private func shouldAdvancePrimitive(
        projection: PrimitiveProjection,
        primitive: FixedWingPathPrimitive,
        wing: FixedWingParameters
    ) -> Bool {
        let length = primitive.length
        guard length.isFinite, length > 0.001 else { return true }

        let acceptance = max(
            wing.waypointAcceptanceRadiusMeters * 0.55,
            length * 0.04
        )
        // Past the end of the primitive: definitely advance.
        if projection.alongDistance >= length - 0.05 {
            return true
        }
        // Sufficiently close to end *and* well-tracked cross-track: advance
        // ahead of time so the next primitive (often a line after an arc)
        // takes over without overshoot.
        if projection.alongDistance >= max(0.0, length - acceptance),
           abs(projection.crossTrack) <= acceptance * 1.4 {
            return true
        }
        return false
    }

    private func lookaheadPoint(
        on primitive: FixedWingPathPrimitive,
        from alongDistance: Float,
        lookaheadDistance: Float,
        route: FixedWingFlyableRoute,
        primitiveIndex: Int
    ) -> SIMD2<Float> {
        var remainingLookahead = max(0.05, lookaheadDistance)
        var index = primitiveIndex
        var startAlong = max(0.0, alongDistance)

        while index < route.primitives.count {
            let prim = route.primitives[index]
            let length = prim.length
            let availableOnPrimitive = max(0.0, length - startAlong)
            if remainingLookahead <= availableOnPrimitive || index == route.primitives.count - 1 {
                let target = min(length, startAlong + remainingLookahead)
                return point(on: prim, atAlongDistance: target)
            }
            remainingLookahead -= availableOnPrimitive
            index += 1
            startAlong = 0.0
        }

        // Should not reach here if route has primitives, but fall back to last point.
        return route.primitives.last?.endPoint ?? .zero
    }

    private func point(
        on primitive: FixedWingPathPrimitive,
        atAlongDistance distance: Float
    ) -> SIMD2<Float> {
        switch primitive {
        case let .line(start, end):
            let delta = end - start
            let length = max(0.001, simd_length(delta))
            let t = (distance / length).fwClampedFloat(to: 0.0...1.0)
            return start + delta * t
        case let .arc(center, radius, startAngle, sweepAngle, _, _, _):
            let arcLength = max(0.001, abs(sweepAngle) * radius)
            let t = (distance / arcLength).fwClampedFloat(to: 0.0...1.0)
            let angle = startAngle + sweepAngle * t
            return SIMD2<Float>(
                center.x + cos(angle) * radius,
                center.y + sin(angle) * radius
            )
        }
    }

    private func remainingDistance(
        from primitiveIndex: Int,
        alongCurrent: Float,
        in route: FixedWingFlyableRoute
    ) -> Float {
        guard primitiveIndex >= 0, primitiveIndex < route.primitives.count else {
            return 0.0
        }
        var remaining = max(0.0, route.primitives[primitiveIndex].length - alongCurrent)
        for i in (primitiveIndex + 1)..<route.primitives.count {
            remaining += route.primitives[i].length
        }
        return remaining
    }

    private func anchor(
        forPrimitiveIndex primitiveIndex: Int,
        in route: FixedWingFlyableRoute
    ) -> (index: Int, missionIndex: Int?, position: SIMD2<Float>) {
        for (i, anchor) in route.anchors.enumerated() {
            if anchor.primitiveIndex >= primitiveIndex {
                return (i, anchor.missionWaypointIndex, anchor.waypointPosition)
            }
        }
        if let last = route.anchors.last {
            return (route.anchors.count - 1, last.missionWaypointIndex, last.waypointPosition)
        }
        let endpoint = route.primitives.last?.endPoint ?? .zero
        return (0, nil, endpoint)
    }

    private func primitiveIndex(
        forMinimumWaypointIndex minimumWaypointIndex: Int?,
        in route: FixedWingFlyableRoute
    ) -> Int {
        guard let minimumWaypointIndex else { return 0 }
        for anchor in route.anchors {
            guard let missionIndex = anchor.missionWaypointIndex else { continue }
            if missionIndex >= minimumWaypointIndex {
                // The anchor's primitiveIndex is the *last* primitive of the
                // current waypoint's path. To begin tracking toward it we
                // must be at primitiveIndex - 1 (the line that arrives at the
                // arc) — but for arcs/lines that end at the waypoint we want
                // primitiveIndex itself. Use index - 1 for arc anchors so we
                // capture the inbound line first.
                if case .arc = route.primitives[anchor.primitiveIndex],
                   anchor.primitiveIndex > 0 {
                    return anchor.primitiveIndex - 1
                }
                return anchor.primitiveIndex
            }
        }
        return 0
    }
}

// MARK: - Free helpers

@inline(__always)
func courseRadiansFromDirection(_ direction: SIMD2<Float>) -> Float {
    // Project convention: nose-forward aligns with -Z, so a unit vector (x, z)
    // mapping to course = atan2(-x, -z). This keeps the resulting course
    // consistent with the rest of the autopilot pipeline.
    atan2(-direction.x, -direction.y)
}

@inline(__always)
func arcTangentCourse(
    point: SIMD2<Float>,
    center: SIMD2<Float>,
    turnDirection: FixedWingTurnDirection,
    sweepAngle: Float
) -> Float {
    let radial = point - center
    guard let normalizedRadial = safeNormalize(radial) else {
        return 0.0
    }
    // Tangent perpendicular to radial; rotation sense from sweep sign.
    let signedSweep = sweepAngle >= 0.0 ? Float(1.0) : Float(-1.0)
    let tangent = signedSweep > 0.0
        ? SIMD2<Float>(-normalizedRadial.y, normalizedRadial.x)
        : SIMD2<Float>(normalizedRadial.y, -normalizedRadial.x)
    // turnDirection is informational; the sign is already in sweepAngle.
    _ = turnDirection
    return courseRadiansFromDirection(tangent)
}

@inline(__always)
func signedAngularProgress(
    currentAngle: Float,
    startAngle: Float,
    sweepAngle: Float
) -> Float {
    // Returns the magnitude of progress along the sweep, clamped to [0, |sweep|].
    var delta = currentAngle - startAngle
    if sweepAngle > 0.0 {
        while delta < 0.0 { delta += .pi * 2.0 }
        while delta > .pi * 2.0 { delta -= .pi * 2.0 }
        return min(delta, sweepAngle)
    } else {
        while delta > 0.0 { delta -= .pi * 2.0 }
        while delta < -.pi * 2.0 { delta += .pi * 2.0 }
        return min(-delta, -sweepAngle)
    }
}

@inline(__always)
func flyableCourseToPoint(
    from currentPosition: SIMD2<Float>,
    to targetPosition: SIMD2<Float>,
    fallback: Float
) -> Float {
    let delta = targetPosition - currentPosition
    let lengthSquared = simd_length_squared(delta)
    guard lengthSquared.isFinite, lengthSquared > 0.0001 else {
        return fallback
    }
    return courseRadiansFromDirection(simd_normalize(delta))
}

private func sign(_ value: Float) -> Float {
    if value > 0.0 { return 1.0 }
    if value < 0.0 { return -1.0 }
    return 0.0
}

// MARK: - Float helpers (private to this module surface)

extension Float {
    @inline(__always)
    func fwClampedFloat(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }

    @inline(__always)
    var degreesToRadiansFloat: Float {
        self * .pi / 180.0
    }
}
