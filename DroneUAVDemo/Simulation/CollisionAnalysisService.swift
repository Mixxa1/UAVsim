import Foundation
import simd

struct CollisionObstacle {
    let id: UUID
    let center: SIMD3<Float>
    let radius: Float
    let source: String
    let baseY: Float
    let topY: Float
    let planarHalfExtents: SIMD2<Float>?
    let yawRadians: Float

    init(
        id: UUID,
        center: SIMD3<Float>,
        radius: Float,
        source: String,
        baseY: Float? = nil,
        topY: Float? = nil,
        planarHalfExtents: SIMD2<Float>? = nil,
        yawRadians: Float = 0.0
    ) {
        self.id = id
        self.center = center
        if let planarHalfExtents {
            self.radius = max(
                radius,
                simd_length(planarHalfExtents)
            )
        } else {
            self.radius = radius
        }
        self.source = source

        let fallbackBase = center.y - radius
        let fallbackTop = center.y + radius
        let resolvedBase = baseY ?? fallbackBase
        let resolvedTop = topY ?? fallbackTop
        self.baseY = min(resolvedBase, resolvedTop)
        self.topY = max(resolvedBase, resolvedTop)
        self.planarHalfExtents = planarHalfExtents
        self.yawRadians = yawRadians
    }

    var planarCenter: SIMD2<Float> {
        SIMD2<Float>(center.x, center.z)
    }

    // `centerY`/`droneCenterY` below is actually the drone's ground/gear reference height —
    // it matches DroneState.position.y, which is 0 when resting flush on the ground, not the
    // body's visual center (SceneKit's own physics proxy offsets upward from this same point
    // for that reason). Treating it as a sphere center here made the drone "land" with its
    // body already half-buried in any obstacle-borne surface (e.g. a container roof), which
    // the push-out resolution then fought every frame — the source of the landing bounce.
    func verticalGap(toDroneCenterY centerY: Float, droneRadius: Float) -> Float {
        let droneBottom = centerY
        let droneTop = centerY + droneRadius * 2.0

        if droneTop < baseY {
            return baseY - droneTop
        }
        if droneBottom > topY {
            return droneBottom - topY
        }
        return 0.0
    }

    /// Signed vertical distance when the drone is within the obstacle's horizontal footprint:
    /// positive when clear above/below, negative with the penetration depth from the nearer
    /// face (top or bottom) when overlapping. Resting flush on a flat roof yields ~0, not a
    /// large value — unlike the horizontal face distance, which is irrelevant while landed.
    func verticalPenetration(toDroneCenterY centerY: Float, droneRadius: Float) -> Float {
        let droneBottom = centerY
        let droneTop = centerY + droneRadius * 2.0

        if droneBottom >= topY {
            return droneBottom - topY
        }
        if droneTop <= baseY {
            return baseY - droneTop
        }
        let intoFromAbove = topY - droneBottom
        let intoFromBelow = droneTop - baseY
        return -min(intoFromAbove, intoFromBelow)
    }

    func planarSignedDistance(to point: SIMD2<Float>) -> Float {
        guard let halfExtents = planarHalfExtents else {
            return simd_distance(point, planarCenter) - radius
        }

        let local = rotate(point - planarCenter, radians: -yawRadians)
        let delta = abs(local) - halfExtents
        let outside = SIMD2<Float>(max(delta.x, 0.0), max(delta.y, 0.0))
        let outsideDistance = simd_length(outside)
        let insideDistance = min(max(delta.x, delta.y), 0.0)
        return outsideDistance + insideDistance
    }

    func planarContact(
        to point: SIMD2<Float>,
        droneRadius: Float
    ) -> (clearance: Float, towardObstacle: SIMD2<Float>, outwardNormal: SIMD2<Float>) {
        guard let halfExtents = planarHalfExtents else {
            let delta = planarCenter - point
            let distance = simd_length(delta)
            let toward = distance > 0.001
                ? delta / distance
                : SIMD2<Float>(0.0, 1.0)
            return (
                distance - (radius + droneRadius),
                toward,
                -toward
            )
        }

        let local = rotate(point - planarCenter, radians: -yawRadians)
        let closest = simd_clamp(local, -halfExtents, halfExtents)
        let towardLocal = closest - local
        let outsideDistance = simd_length(towardLocal)

        if outsideDistance > 0.001 {
            let toward = rotate(towardLocal / outsideDistance, radians: yawRadians)
            return (
                outsideDistance - droneRadius,
                toward,
                -toward
            )
        }

        let xGap = halfExtents.x - abs(local.x)
        let zGap = halfExtents.y - abs(local.y)
        let outwardLocal: SIMD2<Float>
        let faceDistance: Float
        if xGap < zGap {
            outwardLocal = SIMD2<Float>(local.x >= 0.0 ? 1.0 : -1.0, 0.0)
            faceDistance = xGap
        } else {
            outwardLocal = SIMD2<Float>(0.0, local.y >= 0.0 ? 1.0 : -1.0)
            faceDistance = zGap
        }
        let outward = rotate(outwardLocal, radians: yawRadians)
        return (
            -(max(0.0, faceDistance) + droneRadius),
            -outward,
            outward
        )
    }

    // Matches SceneKit's actual eulerAngles.y direction — see the note on
    // DroneSceneController.rotatePlanar, which has the same fix for the same reason.
    private func rotate(_ value: SIMD2<Float>, radians: Float) -> SIMD2<Float> {
        let cosine = cos(radians)
        let sine = sin(radians)
        return SIMD2<Float>(
            value.x * cosine + value.y * sine,
            -value.x * sine + value.y * cosine
        )
    }
}

struct CollisionSweepResult {
    let obstacle: CollisionObstacle
    let contactPoint: SIMD3<Float>
    let contactNormal: SIMD3<Float>
    let hitFraction: Float
}

struct CollisionAnalysisInput {
    let dronePosition: SIMD3<Float>
    let droneVelocity: SIMD3<Float>
    let droneRadius: Float
    let obstacles: [CollisionObstacle]
    let weather: WeatherModel
}

final class CollisionAnalysisService {
    private let broadPhaseDistance: Float = 26.0
    private let maxCandidateCount = 48

    func analyze(input: CollisionAnalysisInput) -> CollisionAnalysisSnapshot {
        guard !input.obstacles.isEmpty else {
            return .safe
        }

        let broadPhaseDistanceSq = broadPhaseDistance * broadPhaseDistance
        let dronePlanar = SIMD2<Float>(input.dronePosition.x, input.dronePosition.z)
        var candidates: [(obstacle: CollisionObstacle, combinedGapSq: Float)] = []
        candidates.reserveCapacity(maxCandidateCount)

        for obstacle in input.obstacles {
            let planarDelta = obstacle.planarCenter - dronePlanar
            let planarDistanceSq = simd_length_squared(planarDelta)
            let verticalGap = obstacle.verticalGap(
                toDroneCenterY: input.dronePosition.y,
                droneRadius: input.droneRadius
            )
            let planarGap: Float
            if planarDistanceSq <= broadPhaseDistanceSq {
                planarGap = 0.0
            } else {
                planarGap = sqrt(planarDistanceSq) - broadPhaseDistance
            }
            let combinedGapSq = planarGap * planarGap + verticalGap * verticalGap
            guard combinedGapSq <= broadPhaseDistanceSq else {
                continue
            }
            insertCandidate(
                (obstacle, combinedGapSq),
                into: &candidates,
                limit: maxCandidateCount
            )
        }

        guard !candidates.isEmpty else {
            return .safe
        }

        var nearestDistance = Float.greatestFiniteMagnitude
        var nearestObstacleID: UUID?
        var nearestObstacleSource: String?
        var timeToCollision: Float?
        var maxRisk: Float = 0.0
        var nearestContactNormal: SIMD3<Float>?

        for candidate in candidates {
            let obstacle = candidate.obstacle
            let planarContact = obstacle.planarContact(
                to: dronePlanar,
                droneRadius: input.droneRadius
            )
            let horizontalClearance = planarContact.clearance
            let verticalGap = obstacle.verticalGap(
                toDroneCenterY: input.dronePosition.y,
                droneRadius: input.droneRadius
            )
            let clearance: Float
            let direction: SIMD3<Float>
            let contactNormal: SIMD3<Float>

            if horizontalClearance <= 0.0 {
                let verticalPenetration = obstacle.verticalPenetration(
                    toDroneCenterY: input.dronePosition.y,
                    droneRadius: input.droneRadius
                )
                let horizontalPenetrationDepth = max(0.0, -horizontalClearance)
                let verticalPenetrationDepth = max(0.0, -verticalPenetration)
                let shouldResolveVertically = verticalPenetrationDepth <= max(0.02, horizontalPenetrationDepth)

                if verticalGap > 0.0 {
                    clearance = verticalGap
                    let verticalDirection: Float = obstacle.center.y >= input.dronePosition.y ? 1.0 : -1.0
                    direction = SIMD3<Float>(0.0, verticalDirection, 0.0)
                    contactNormal = -direction
                } else if shouldResolveVertically {
                    // Resting on / hitting the top or bottom face (container roof, slab, etc.).
                    // For tall obstacles like tree trunks this only wins when the vertical
                    // penetration is actually shallower than the side penetration; otherwise the
                    // normal must stay horizontal or the copter tries to climb through the tree.
                    clearance = verticalPenetration
                    let verticalDirection: Float = obstacle.center.y >= input.dronePosition.y ? 1.0 : -1.0
                    direction = SIMD3<Float>(0.0, verticalDirection, 0.0)
                    contactNormal = -direction
                } else {
                    clearance = horizontalClearance
                    direction = SIMD3<Float>(
                        planarContact.towardObstacle.x,
                        0.0,
                        planarContact.towardObstacle.y
                    )
                    contactNormal = SIMD3<Float>(
                        planarContact.outwardNormal.x,
                        0.0,
                        planarContact.outwardNormal.y
                    )
                }
            } else if verticalGap <= 0.0 {
                clearance = horizontalClearance
                direction = SIMD3<Float>(
                    planarContact.towardObstacle.x,
                    0.0,
                    planarContact.towardObstacle.y
                )
                contactNormal = SIMD3<Float>(
                    planarContact.outwardNormal.x,
                    0.0,
                    planarContact.outwardNormal.y
                )
            } else {
                clearance = simd_length(SIMD2<Float>(horizontalClearance, verticalGap))

                let verticalDirection: Float = obstacle.center.y >= input.dronePosition.y ? 1.0 : -1.0
                let composite = SIMD3<Float>(
                    planarContact.towardObstacle.x * horizontalClearance,
                    verticalDirection * verticalGap,
                    planarContact.towardObstacle.y * horizontalClearance
                )
                direction = simd_length_squared(composite) > 0.0001
                    ? simd_normalize(composite)
                    : SIMD3<Float>(0.0, 0.0, 1.0)
                contactNormal = -direction
            }

            if clearance < nearestDistance {
                nearestDistance = clearance
                nearestObstacleID = obstacle.id
                nearestObstacleSource = obstacle.source
                nearestContactNormal = contactNormal
            }

            let closingSpeed = simd_dot(input.droneVelocity, direction)

            var obstacleRisk: Float = 0.0
            if clearance <= 0 {
                obstacleRisk = 1.0
                timeToCollision = 0.0
            } else {
                let distanceRisk = (1.0 - clearance / 10.0).clamped(to: 0.0...1.0)
                obstacleRisk = distanceRisk * 0.65

                if closingSpeed > 0.05 {
                    let ttc = clearance / closingSpeed
                    if timeToCollision == nil || ttc < (timeToCollision ?? .greatestFiniteMagnitude) {
                        timeToCollision = ttc
                    }
                    let ttcRisk = (1.0 - (ttc / 6.0)).clamped(to: 0.0...1.0)
                    obstacleRisk += ttcRisk * 0.35
                }
            }

            maxRisk = max(maxRisk, obstacleRisk)
        }

        let weatherRisk = input.weather.effectiveFactors.collisionRiskMultiplier
        let visibilityPenalty = 1.0 + (1.0 - input.weather.effectiveFactors.visibilityFactor) * 0.55
        let risk = (maxRisk * weatherRisk * visibilityPenalty).clamped(to: 0.0...1.0)

        let emergencyAction: CollisionEmergencyAction
        switch risk {
        case 0.85...:
            emergencyAction = .emergencyStop
        case 0.65..<0.85:
            emergencyAction = .avoid
        case 0.45..<0.65:
            emergencyAction = .hover
        case 0.25..<0.45:
            emergencyAction = .slowDown
        default:
            emergencyAction = .none
        }

        return CollisionAnalysisSnapshot(
            riskScore: risk,
            nearestObstacleDistance: nearestDistance,
            nearestObstacleID: nearestObstacleID,
            nearestObstacleSource: nearestObstacleSource,
            timeToCollision: timeToCollision,
            emergencyAction: emergencyAction,
            contactNormal: nearestContactNormal
        )
    }

    func firstSweptCollision(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        droneRadius: Float,
        obstacles: [CollisionObstacle]
    ) -> CollisionSweepResult? {
        let movement = end - start
        guard simd_length_squared(movement) > 0.000001 else {
            return nil
        }

        var best: CollisionSweepResult?
        for obstacle in obstacles {
            guard let halfExtents = obstacle.planarHalfExtents,
                  let hit = sweepSphereAgainstBox(
                    from: start,
                    to: end,
                    radius: droneRadius,
                    obstacle: obstacle,
                    halfExtents: halfExtents
                  ),
                  best == nil || hit.hitFraction < (best?.hitFraction ?? 1.0) else {
                continue
            }
            best = hit
        }
        return best
    }

    private func sweepSphereAgainstBox(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        radius: Float,
        obstacle: CollisionObstacle,
        halfExtents: SIMD2<Float>
    ) -> CollisionSweepResult? {
        let localStartXZ = rotate(
            SIMD2<Float>(start.x, start.z) - obstacle.planarCenter,
            radians: -obstacle.yawRadians
        )
        let localEndXZ = rotate(
            SIMD2<Float>(end.x, end.z) - obstacle.planarCenter,
            radians: -obstacle.yawRadians
        )
        let localStart = SIMD3<Float>(localStartXZ.x, start.y, localStartXZ.y)
        let localEnd = SIMD3<Float>(localEndXZ.x, end.y, localEndXZ.y)
        // `start.y`/`end.y` track the drone's ground/gear reference, not its body center (see
        // the note on verticalGap/verticalPenetration above) — so the Y padding here is not
        // symmetric like the X/Z padding: no padding below topY (a descent should stop exactly
        // when the gear reaches the surface) and a full body-height margin below baseY (so
        // ascending into the underside of a thin slab from below still gets caught).
        let boxMin = SIMD3<Float>(
            -halfExtents.x - radius,
            obstacle.baseY - radius * 2.0,
            -halfExtents.y - radius
        )
        let boxMax = SIMD3<Float>(
            halfExtents.x + radius,
            obstacle.topY,
            halfExtents.y + radius
        )

        guard let slabHit = segmentBoxIntersection(
            from: localStart,
            to: localEnd,
            boxMin: boxMin,
            boxMax: boxMax
        ) else {
            return nil
        }

        // Thin slabs (floor/roof, a few cm tall) only act as a real obstacle when crossed
        // vertically — through their top or bottom face. Their radius-expanded side faces
        // would otherwise read as a wall at the entrance threshold of an open container even
        // though there is nothing there to actually hit.
        let isThinSlab = (obstacle.topY - obstacle.baseY) <= 0.3
        if isThinSlab, abs(slabHit.normal.y) < 0.5 {
            return nil
        }

        let worldNormalXZ = rotate(
            SIMD2<Float>(slabHit.normal.x, slabHit.normal.z),
            radians: obstacle.yawRadians
        )
        let normal = SIMD3<Float>(
            worldNormalXZ.x,
            slabHit.normal.y,
            worldNormalXZ.y
        )
        return CollisionSweepResult(
            obstacle: obstacle,
            contactPoint: start + (end - start) * slabHit.fraction,
            contactNormal: normal,
            hitFraction: slabHit.fraction
        )
    }

    private func segmentBoxIntersection(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        boxMin: SIMD3<Float>,
        boxMax: SIMD3<Float>
    ) -> (fraction: Float, normal: SIMD3<Float>)? {
        let direction = end - start
        var entry: Float = 0.0
        var exit: Float = 1.0
        var entryNormal = SIMD3<Float>(repeating: 0.0)

        for axis in 0..<3 {
            let origin = start[axis]
            let delta = direction[axis]
            if abs(delta) < 0.000001 {
                if origin < boxMin[axis] || origin > boxMax[axis] {
                    return nil
                }
                continue
            }

            var near = (boxMin[axis] - origin) / delta
            var far = (boxMax[axis] - origin) / delta
            var normal = SIMD3<Float>(repeating: 0.0)
            normal[axis] = delta > 0.0 ? -1.0 : 1.0
            if near > far {
                swap(&near, &far)
            }

            if near > entry {
                entry = near
                entryNormal = normal
            }
            exit = min(exit, far)
            if entry > exit {
                return nil
            }
        }

        guard entry >= 0.0, entry <= 1.0,
              simd_length_squared(entryNormal) > 0.0 else {
            return nil
        }
        return (entry, entryNormal)
    }

    // Matches SceneKit's actual eulerAngles.y direction — see the note on
    // DroneSceneController.rotatePlanar, which has the same fix for the same reason.
    private func rotate(_ value: SIMD2<Float>, radians: Float) -> SIMD2<Float> {
        let cosine = cos(radians)
        let sine = sin(radians)
        return SIMD2<Float>(
            value.x * cosine + value.y * sine,
            -value.x * sine + value.y * cosine
        )
    }

    private func insertCandidate(
        _ candidate: (obstacle: CollisionObstacle, combinedGapSq: Float),
        into candidates: inout [(obstacle: CollisionObstacle, combinedGapSq: Float)],
        limit: Int
    ) {
        if candidates.isEmpty {
            candidates.append(candidate)
            return
        }

        var insertionIndex = candidates.count
        while insertionIndex > 0,
              candidate.combinedGapSq < candidates[insertionIndex - 1].combinedGapSq {
            insertionIndex -= 1
        }

        if insertionIndex >= limit {
            return
        }

        candidates.insert(candidate, at: insertionIndex)
        if candidates.count > limit {
            candidates.removeLast()
        }
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
