import Foundation
import simd

/// Makes an A* polyline flyable at a given turn radius instead of rejecting it.
///
/// A grid planner returns a route whose corners are safe *for a point*. A fixed wing rounds every
/// corner with a fillet of its live turn radius, and that fillet cuts toward the inside of the
/// turn by `R / cos(θ/2) − R`. At a 202 m radius a right-angle corner is cut by 84 m — so a route
/// that hugs a building corner is flown straight through the building, which is exactly what the
/// avoidance probe measures when the planner is given no manoeuvre reserve.
///
/// The previous answer was to inflate every obstacle by a whole turn radius so the shortest route
/// was flyable by construction. That deletes the map: on a 260 m block grid a 227 m reserve leaves
/// no free cell at all, including the one the aircraft is standing in.
///
/// This is the other answer. Keep the grid point-safe and repair the corners:
///
/// Move the corner *outward* along its bisector until the fillet the follower will fly is clear —
/// so the arc passes through where the corner used to be rather than 84 m inside it.
///
/// The repaired route keeps **one point per corner**, not the sampled arc. The follower already
/// builds a full-radius fillet from raw waypoints; feeding it the arc instead makes route points
/// only metres apart, and capture then races along them faster than the aircraft can turn — the
/// probe measures that as the route being abandoned mid-corner. The arc is computed here only to
/// prove the corner is clear.
///
/// A corner that cannot be repaired within the shift budget is left untouched and reported, so
/// the caller can still reject it.
enum FixedWingRouteRepair {
    struct Result {
        var points: [SIMD2<Float>]
        var repairedCorners: Int
        var unrepairableCorners: Int
    }

    /// Below this the corner is a straight join and needs no fillet.
    private static let minimumCornerRadians: Float = 0.06
    /// Above this a fillet is meaningless — the route doubles back and needs a different path.
    private static let maximumCornerRadians: Float = 150.0 * .pi / 180.0
    /// Outward shifts tried, as multiples of the fillet's own excursion. Zero first: a corner in
    /// open space needs no displacement and must not be moved for nothing.
    private static let outwardShiftFactors: [Float] = [0.0, 0.55, 1.0, 1.45]
    /// Chord sagitta budget when sampling an arc for the clearance test and for the emitted route.
    private static let arcSagittaMeters: Float = 0.35

    static func repair(
        route: [SIMD2<Float>],
        turnRadius: Float,
        clearanceRadius: Float,
        altitude: Float,
        obstacles: [CollisionObstacle],
        collisionService: CollisionAnalysisService,
        maximumOutwardShiftMeters: Float
    ) -> Result {
        guard route.count >= 3, turnRadius > 0.5 else {
            return Result(points: route, repairedCorners: 0, unrepairableCorners: 0)
        }

        // A* densifies straight runs to roughly one point per grid cell. Those samples are not
        // corners, but they leave only a few metres between consecutive points — so every
        // tangent-fit test fails and nothing is repairable. Reduce to real corners first.
        let route = cornersOnly(route)
        guard route.count >= 3 else {
            return Result(points: route, repairedCorners: 0, unrepairableCorners: 0)
        }

        var output: [SIMD2<Float>] = [route[0]]
        var repaired = 0
        var unrepairable = 0

        for index in 1..<(route.count - 1) {
            // The inbound leg starts wherever the previous corner's fillet left us, not at the
            // original polyline vertex — otherwise each repair silently invalidates the next
            // corner's tangent-fit test.
            let previous = output[output.count - 1]
            let corner = route[index]
            let next = route[index + 1]

            guard let fitted = fittedCorner(
                previous: previous,
                corner: corner,
                next: next,
                turnRadius: turnRadius,
                clearanceRadius: clearanceRadius,
                altitude: altitude,
                obstacles: obstacles,
                collisionService: collisionService,
                maximumOutwardShiftMeters: maximumOutwardShiftMeters
            ) else {
                output.append(corner)
                unrepairable += 1
                continue
            }

            if fitted.isStraightJoin {
                output.append(corner)
                continue
            }
            for point in fitted.points where simd_distance(output[output.count - 1], point) > 0.05 {
                output.append(point)
            }
            repaired += 1
        }

        if let last = route.last, simd_distance(output[output.count - 1], last) > 0.05 {
            output.append(last)
        }
        return Result(
            points: output,
            repairedCorners: repaired,
            unrepairableCorners: unrepairable
        )
    }

    /// Drops points that lie on the straight segment between their neighbours. A real planner
    /// corner and every endpoint survive.
    private static func cornersOnly(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        var result: [SIMD2<Float>] = []
        result.reserveCapacity(points.count)
        for point in points {
            if let last = result.last, simd_distance(last, point) <= 0.05 { continue }
            result.append(point)
            while result.count >= 3 {
                let count = result.count
                let a = result[count - 3]
                let b = result[count - 2]
                let c = result[count - 1]
                let ac = c - a
                let lengthSquared = simd_length_squared(ac)
                guard lengthSquared > 0.0001 else { break }
                let projection = simd_dot(b - a, ac) / lengthSquared
                let closest = a + ac * projection
                guard projection > 0.0, projection < 1.0,
                      simd_dot(b - a, c - b) > 0.0,
                      simd_distance(b, closest) <= 0.25 else {
                    break
                }
                result.remove(at: count - 2)
            }
        }
        return result
    }

    private struct FittedCorner {
        var points: [SIMD2<Float>]
        var isStraightJoin: Bool
    }

    private static func fittedCorner(
        previous: SIMD2<Float>,
        corner: SIMD2<Float>,
        next: SIMD2<Float>,
        turnRadius: Float,
        clearanceRadius: Float,
        altitude: Float,
        obstacles: [CollisionObstacle],
        collisionService: CollisionAnalysisService,
        maximumOutwardShiftMeters: Float
    ) -> FittedCorner? {
        let inbound = corner - previous
        let outbound = next - corner
        let inboundLength = simd_length(inbound)
        let outboundLength = simd_length(outbound)
        guard inboundLength > 0.05, outboundLength > 0.05 else { return nil }

        let inboundDirection = inbound / inboundLength
        let outboundDirection = outbound / outboundLength
        let dot = min(1.0, max(-1.0, simd_dot(inboundDirection, outboundDirection)))
        let turnAngle = acos(dot)
        if turnAngle <= minimumCornerRadians {
            return FittedCorner(points: [], isStraightJoin: true)
        }
        guard turnAngle < maximumCornerRadians else { return nil }

        let halfAngle = turnAngle * 0.5
        let excursion = turnRadius / max(0.05, cos(halfAngle)) - turnRadius
        // Outward is away from the wedge the two legs enclose — the side the fillet does *not*
        // cut toward.
        let inwardBisector = simd_normalize(-inboundDirection + outboundDirection)
        guard inwardBisector.x.isFinite, inwardBisector.y.isFinite else { return nil }
        let outwardBisector = -inwardBisector

        for factor in outwardShiftFactors {
            let shift = min(excursion * factor, maximumOutwardShiftMeters)
            let shiftedCorner = corner + outwardBisector * shift
            guard let candidate = filletPoints(
                previous: previous,
                corner: shiftedCorner,
                next: next,
                turnRadius: turnRadius,
                clearanceRadius: clearanceRadius
            ) else {
                continue
            }
            if isPathClear(
                candidate,
                clearanceRadius: clearanceRadius,
                altitude: altitude,
                obstacles: obstacles,
                collisionService: collisionService
            ) {
                // The arc proved the corner; the route carries the corner itself.
                return FittedCorner(points: [shiftedCorner], isStraightJoin: false)
            }
        }
        return nil
    }

    /// Entry point, arc samples and exit point of the fillet, or `nil` when the tangent run does
    /// not fit between this corner and its neighbours. The radius is never reduced to force a fit:
    /// a smaller fillet is one the aircraft cannot fly.
    private static func filletPoints(
        previous: SIMD2<Float>,
        corner: SIMD2<Float>,
        next: SIMD2<Float>,
        turnRadius: Float,
        clearanceRadius: Float
    ) -> [SIMD2<Float>]? {
        let inbound = corner - previous
        let outbound = next - corner
        let inboundLength = simd_length(inbound)
        let outboundLength = simd_length(outbound)
        guard inboundLength > 0.05, outboundLength > 0.05 else { return nil }

        let inboundDirection = inbound / inboundLength
        let outboundDirection = outbound / outboundLength
        let dot = min(1.0, max(-1.0, simd_dot(inboundDirection, outboundDirection)))
        let turnAngle = acos(dot)
        guard turnAngle > minimumCornerRadians, turnAngle < maximumCornerRadians else {
            return nil
        }

        let tangentDistance = turnRadius * tan(turnAngle * 0.5)
        guard tangentDistance.isFinite,
              tangentDistance + clearanceRadius <= inboundLength,
              tangentDistance + clearanceRadius <= outboundLength else {
            return nil
        }

        let turnSign = inboundDirection.x * outboundDirection.y
            - inboundDirection.y * outboundDirection.x
        guard abs(turnSign) > 0.0001 else { return nil }

        let entry = corner - inboundDirection * tangentDistance
        let exit = corner + outboundDirection * tangentDistance
        let leftNormal = SIMD2<Float>(-inboundDirection.y, inboundDirection.x)
        let center = turnSign > 0.0
            ? entry + leftNormal * turnRadius
            : entry - leftNormal * turnRadius
        let startAngle = atan2(entry.y - center.y, entry.x - center.x)
        let endAngle = atan2(exit.y - center.y, exit.x - center.x)
        var sweep = endAngle - startAngle
        if turnSign > 0.0 {
            while sweep < 0.0 { sweep += .pi * 2.0 }
            while sweep > .pi * 2.0 { sweep -= .pi * 2.0 }
        } else {
            while sweep > 0.0 { sweep -= .pi * 2.0 }
            while sweep < -.pi * 2.0 { sweep += .pi * 2.0 }
        }
        guard sweep.isFinite, abs(sweep) > 0.01 else { return nil }

        let sagitta = min(arcSagittaMeters, turnRadius * 0.99)
        let cosine = min(1.0, max(-1.0, 1.0 - sagitta / turnRadius))
        let maximumStep = max(0.01, 2.0 * acos(cosine))
        let sampleCount = max(2, Int(ceil(abs(sweep) / maximumStep)))

        var points: [SIMD2<Float>] = [entry]
        points.reserveCapacity(sampleCount + 2)
        for sample in 1..<sampleCount {
            let angle = startAngle + sweep * (Float(sample) / Float(sampleCount))
            points.append(
                SIMD2<Float>(
                    center.x + cos(angle) * turnRadius,
                    center.y + sin(angle) * turnRadius
                )
            )
        }
        points.append(exit)
        return points
    }

    private static func isPathClear(
        _ points: [SIMD2<Float>],
        clearanceRadius: Float,
        altitude: Float,
        obstacles: [CollisionObstacle],
        collisionService: CollisionAnalysisService
    ) -> Bool {
        guard points.count >= 2, !obstacles.isEmpty else { return true }
        for pair in zip(points, points.dropFirst()) {
            let hit = collisionService.firstSweptCenterCollision(
                from: SIMD3<Float>(pair.0.x, altitude, pair.0.y),
                to: SIMD3<Float>(pair.1.x, altitude, pair.1.y),
                radius: clearanceRadius,
                obstacles: obstacles
            )
            if hit != nil { return false }
        }
        return true
    }
}
