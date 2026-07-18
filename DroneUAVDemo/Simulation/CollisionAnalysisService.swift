import Foundation
import simd

struct CollisionMeshTriangle {
    let point0: SIMD3<Float>
    let point1: SIMD3<Float>
    let point2: SIMD3<Float>
    let normal: SIMD3<Float>
    let minimum: SIMD3<Float>
    let maximum: SIMD3<Float>
    let supportsLandingSurface: Bool

    init?(
        point0: SIMD3<Float>,
        point1: SIMD3<Float>,
        point2: SIMD3<Float>,
        supportsLandingSurface: Bool = false
    ) {
        let rawNormal = simd_cross(point1 - point0, point2 - point0)
        guard point0.x.isFinite, point0.y.isFinite, point0.z.isFinite,
              point1.x.isFinite, point1.y.isFinite, point1.z.isFinite,
              point2.x.isFinite, point2.y.isFinite, point2.z.isFinite,
              simd_length_squared(rawNormal) > 0.000001 else {
            return nil
        }
        self.point0 = point0
        self.point1 = point1
        self.point2 = point2
        self.normal = simd_normalize(rawNormal)
        self.minimum = simd_min(simd_min(point0, point1), point2)
        self.maximum = simd_max(simd_max(point0, point1), point2)
        self.supportsLandingSurface = supportsLandingSurface
    }
}

struct CollisionObstacle {
    let id: UUID
    let center: SIMD3<Float>
    let radius: Float
    let source: String
    let baseY: Float
    let topY: Float
    let planarHalfExtents: SIMD2<Float>?
    let yawRadians: Float
    let meshTriangles: [CollisionMeshTriangle]?

    init(
        id: UUID,
        center: SIMD3<Float>,
        radius: Float,
        source: String,
        baseY: Float? = nil,
        topY: Float? = nil,
        planarHalfExtents: SIMD2<Float>? = nil,
        yawRadians: Float = 0.0,
        meshTriangles: [CollisionMeshTriangle]? = nil
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
        self.meshTriangles = meshTriangles
    }

    var planarCenter: SIMD2<Float> {
        SIMD2<Float>(center.x, center.z)
    }

    var hasMeshCollision: Bool {
        meshTriangles?.isEmpty == false
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

struct CollisionObstacleSpatialIndex {
    private struct CellKey: Hashable {
        let x: Int
        let z: Int
    }

    static let empty = CollisionObstacleSpatialIndex(obstacles: [])

    private let cellSize: Float
    private let cells: [CellKey: [CollisionObstacle]]

    init(
        obstacles: [CollisionObstacle],
        cellSize: Float = 32.0
    ) {
        self.cellSize = max(4.0, cellSize)

        var nextCells: [CellKey: [CollisionObstacle]] = [:]
        nextCells.reserveCapacity(max(16, obstacles.count))
        for obstacle in obstacles {
            let radius = max(0.0, obstacle.radius)
            let minCell = Self.cellKey(
                x: obstacle.center.x - radius,
                z: obstacle.center.z - radius,
                cellSize: self.cellSize
            )
            let maxCell = Self.cellKey(
                x: obstacle.center.x + radius,
                z: obstacle.center.z + radius,
                cellSize: self.cellSize
            )

            for x in minCell.x...maxCell.x {
                for z in minCell.z...maxCell.z {
                    nextCells[CellKey(x: x, z: z), default: []].append(obstacle)
                }
            }
        }
        cells = nextCells
    }

    func query(
        near position: SIMD3<Float>,
        radius: Float
    ) -> [CollisionObstacle] {
        let clampedRadius = max(0.0, radius)
        return query(
            minX: position.x - clampedRadius,
            maxX: position.x + clampedRadius,
            minZ: position.z - clampedRadius,
            maxZ: position.z + clampedRadius
        )
    }

    func query(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        margin: Float
    ) -> [CollisionObstacle] {
        let clampedMargin = max(0.0, margin)
        return query(
            minX: min(start.x, end.x) - clampedMargin,
            maxX: max(start.x, end.x) + clampedMargin,
            minZ: min(start.z, end.z) - clampedMargin,
            maxZ: max(start.z, end.z) + clampedMargin
        )
    }

    private func query(
        minX: Float,
        maxX: Float,
        minZ: Float,
        maxZ: Float
    ) -> [CollisionObstacle] {
        guard !cells.isEmpty else {
            return []
        }

        let minCell = Self.cellKey(x: minX, z: minZ, cellSize: cellSize)
        let maxCell = Self.cellKey(x: maxX, z: maxZ, cellSize: cellSize)
        var results: [CollisionObstacle] = []
        var seen: Set<UUID> = []

        for x in minCell.x...maxCell.x {
            for z in minCell.z...maxCell.z {
                guard let bucket = cells[CellKey(x: x, z: z)] else {
                    continue
                }
                for obstacle in bucket where seen.insert(obstacle.id).inserted {
                    results.append(obstacle)
                }
            }
        }

        return results
    }

    private static func cellKey(
        x: Float,
        z: Float,
        cellSize: Float
    ) -> CellKey {
        CellKey(
            x: Int((x / cellSize).rounded(.down)),
            z: Int((z / cellSize).rounded(.down))
        )
    }
}

struct CollisionSweepResult {
    let obstacle: CollisionObstacle
    let contactPoint: SIMD3<Float>
    let contactNormal: SIMD3<Float>
    let hitFraction: Float
    let isSupportSurfaceContact: Bool
}

/// Earliest narrow-phase contact of the vehicle's multi-sphere contact
/// profile over one integration step. Unlike the legacy single-sphere sweep,
/// `contactPoint` is the actual surface point (for impulse lever arms) and
/// the struck sphere's component provenance is carried along.
struct VehicleSweptContact {
    let obstacle: CollisionObstacle
    let componentID: String
    /// World-space point on the striking sphere's surface at the moment of contact.
    let contactPoint: SIMD3<Float>
    /// Outward normal (pointing away from the obstacle, toward the vehicle).
    let contactNormal: SIMD3<Float>
    let hitFraction: Float
    let isSupportSurfaceContact: Bool
    /// Body-frame offset of the striking contact sphere.
    let sphereOffset: SIMD3<Float>
    let sphereRadius: Float
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

    var spatialQueryRadius: Float {
        broadPhaseDistance + 12.0
    }

    func analyze(input: CollisionAnalysisInput) -> CollisionAnalysisSnapshot {
        guard !input.obstacles.isEmpty else {
            return .safe
        }

        let broadPhaseDistanceSq = broadPhaseDistance * broadPhaseDistance
        let dronePlanar = SIMD2<Float>(input.dronePosition.x, input.dronePosition.z)
        var candidates: [(obstacle: CollisionObstacle, combinedGapSq: Float)] = []
        candidates.reserveCapacity(maxCandidateCount)

        for obstacle in input.obstacles {
            let verticalGap = obstacle.verticalGap(
                toDroneCenterY: input.dronePosition.y,
                droneRadius: input.droneRadius
            )
            let planarGap = max(0.0, obstacle.planarSignedDistance(to: dronePlanar))
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
            let clearance: Float
            let direction: SIMD3<Float>
            let contactNormal: SIMD3<Float>

            if obstacle.hasMeshCollision {
                guard let meshContact = nearestMeshContact(
                    obstacle: obstacle,
                    dronePosition: input.dronePosition,
                    droneVelocity: input.droneVelocity,
                    droneRadius: input.droneRadius
                ) else {
                    continue
                }
                clearance = meshContact.clearance
                direction = meshContact.direction
                contactNormal = meshContact.contactNormal
            } else {
                let planarContact = obstacle.planarContact(
                    to: dronePlanar,
                    droneRadius: input.droneRadius
                )
                let horizontalClearance = planarContact.clearance
                let verticalGap = obstacle.verticalGap(
                    toDroneCenterY: input.dronePosition.y,
                    droneRadius: input.droneRadius
                )
                let isTreeObstacle = obstacle.source.contains("tree")
                let treeHorizontalAvoidanceClearance = max(0.45, input.droneRadius * 0.45)
                let treeVerticalAvoidanceClearance = max(0.18, input.droneRadius * 0.55)
                let shouldAvoidTreeHorizontally = isTreeObstacle &&
                    verticalGap <= treeVerticalAvoidanceClearance &&
                    horizontalClearance <= treeHorizontalAvoidanceClearance

                if shouldAvoidTreeHorizontally {
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
                } else if horizontalClearance <= 0.0 {
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
            let hit: CollisionSweepResult?
            if obstacle.hasMeshCollision {
                hit = sweepSphereAgainstMesh(
                    from: start,
                    to: end,
                    radius: droneRadius,
                    obstacle: obstacle
                )
            } else if let halfExtents = obstacle.planarHalfExtents {
                hit = sweepSphereAgainstBox(
                    from: start,
                    to: end,
                    radius: droneRadius,
                    obstacle: obstacle,
                    halfExtents: halfExtents
                )
            } else {
                hit = nil
            }
            guard let hit,
                  best == nil || hit.hitFraction < (best?.hitFraction ?? 1.0) else {
                continue
            }
            best = hit
        }
        return best
    }

    /// Multi-sphere narrow phase for the vehicle contact profile: sweeps every
    /// contact sphere (attitude-aware — offsets rotate with the airframe) and
    /// returns the earliest contact. Unlike the legacy single-sphere sweep,
    /// sphere positions here are true centers (not gear-reference points), and
    /// plain cylinder obstacles (tree trunks) are swept as well instead of
    /// being left to the post-hoc penetration path.
    func firstSweptVehicleCollision(
        contactSpheres: [VehicleContactSphere],
        fromPosition: SIMD3<Float>,
        toPosition: SIMD3<Float>,
        fromOrientation: simd_quatf,
        toOrientation: simd_quatf,
        obstacles: [CollisionObstacle]
    ) -> VehicleSweptContact? {
        guard !contactSpheres.isEmpty, !obstacles.isEmpty else {
            return nil
        }

        var best: VehicleSweptContact?
        for sphere in contactSpheres {
            let start = fromPosition + simd_act(fromOrientation, sphere.offset)
            let end = toPosition + simd_act(toOrientation, sphere.offset)
            guard simd_length_squared(end - start) > 0.000001 else {
                continue
            }

            for obstacle in obstacles {
                let hit: (fraction: Float, normal: SIMD3<Float>, isSupport: Bool)?
                if obstacle.hasMeshCollision {
                    hit = sweepCenterAgainstMesh(
                        centerStart: start,
                        centerEnd: end,
                        radius: sphere.radius,
                        obstacle: obstacle
                    )
                } else if let halfExtents = obstacle.planarHalfExtents {
                    hit = sweepCenterAgainstBox(
                        centerStart: start,
                        centerEnd: end,
                        radius: sphere.radius,
                        obstacle: obstacle,
                        halfExtents: halfExtents
                    )
                } else {
                    hit = sweepCenterAgainstCylinder(
                        centerStart: start,
                        centerEnd: end,
                        radius: sphere.radius,
                        obstacle: obstacle
                    )
                }

                guard let hit,
                      best == nil || hit.fraction < (best?.hitFraction ?? 1.0) else {
                    continue
                }
                let centerAtHit = start + (end - start) * hit.fraction
                best = VehicleSweptContact(
                    obstacle: obstacle,
                    componentID: sphere.componentID,
                    contactPoint: centerAtHit - hit.normal * sphere.radius,
                    contactNormal: hit.normal,
                    hitFraction: hit.fraction,
                    isSupportSurfaceContact: hit.isSupport,
                    sphereOffset: sphere.offset,
                    sphereRadius: sphere.radius
                )
            }
        }
        return best
    }

    private func sweepCenterAgainstMesh(
        centerStart: SIMD3<Float>,
        centerEnd: SIMD3<Float>,
        radius: Float,
        obstacle: CollisionObstacle
    ) -> (fraction: Float, normal: SIMD3<Float>, isSupport: Bool)? {
        guard let triangles = obstacle.meshTriangles,
              !triangles.isEmpty else {
            return nil
        }

        let movement = centerEnd - centerStart
        var best: (fraction: Float, normal: SIMD3<Float>, isSupport: Bool)?

        for triangle in triangles {
            guard segmentBoundsMayIntersectTriangle(
                from: centerStart,
                to: centerEnd,
                radius: radius,
                triangle: triangle
            ) else {
                continue
            }

            if let planeHit = spherePlaneTriangleHit(
                from: centerStart,
                movement: movement,
                radius: radius,
                triangle: triangle
            ), best == nil || planeHit.fraction < (best?.fraction ?? 1.0) {
                best = (planeHit.fraction, planeHit.normal, planeHit.isSupportSurfaceContact)
            }

            if let edgeHit = sphereEdgeTriangleHit(
                from: centerStart,
                to: centerEnd,
                radius: radius,
                triangle: triangle
            ), best == nil || edgeHit.fraction < (best?.fraction ?? 1.0) {
                best = (edgeHit.fraction, edgeHit.normal, false)
            }
        }
        return best
    }

    /// Center-based box sweep with symmetric radius padding on every axis —
    /// unlike the legacy gear-reference sweep, whose asymmetric Y padding
    /// encodes "position.y is the gear point". A gear sphere's bottom kissing
    /// the roof is exactly center == topY + radius here.
    private func sweepCenterAgainstBox(
        centerStart: SIMD3<Float>,
        centerEnd: SIMD3<Float>,
        radius: Float,
        obstacle: CollisionObstacle,
        halfExtents: SIMD2<Float>
    ) -> (fraction: Float, normal: SIMD3<Float>, isSupport: Bool)? {
        let localStartXZ = rotate(
            SIMD2<Float>(centerStart.x, centerStart.z) - obstacle.planarCenter,
            radians: -obstacle.yawRadians
        )
        let localEndXZ = rotate(
            SIMD2<Float>(centerEnd.x, centerEnd.z) - obstacle.planarCenter,
            radians: -obstacle.yawRadians
        )
        let localStart = SIMD3<Float>(localStartXZ.x, centerStart.y, localStartXZ.y)
        let localEnd = SIMD3<Float>(localEndXZ.x, centerEnd.y, localEndXZ.y)
        let boxMin = SIMD3<Float>(
            -halfExtents.x - radius,
            obstacle.baseY - radius,
            -halfExtents.y - radius
        )
        let boxMax = SIMD3<Float>(
            halfExtents.x + radius,
            obstacle.topY + radius,
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

        // Same thin-slab rule as the legacy sweep: floor/roof slabs only act
        // as obstacles when crossed vertically.
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
        return (slabHit.fraction, normal, false)
    }

    /// Center-based sweep against a plain finite cylinder (tree trunks and
    /// other radius-only obstacles): side wall via 2D ray-circle, caps via
    /// plane crossings, start-penetration reported at fraction 0.
    private func sweepCenterAgainstCylinder(
        centerStart: SIMD3<Float>,
        centerEnd: SIMD3<Float>,
        radius: Float,
        obstacle: CollisionObstacle
    ) -> (fraction: Float, normal: SIMD3<Float>, isSupport: Bool)? {
        let combinedRadius = obstacle.radius + radius
        let p0 = SIMD2<Float>(centerStart.x, centerStart.z) - obstacle.planarCenter
        let d = SIMD2<Float>(centerEnd.x - centerStart.x, centerEnd.z - centerStart.z)
        let yStart = centerStart.y
        let dy = centerEnd.y - centerStart.y
        let yMin = obstacle.baseY - radius
        let yMax = obstacle.topY + radius

        var bestFraction: Float?
        var bestNormal = SIMD3<Float>(0.0, 1.0, 0.0)

        func consider(_ fraction: Float, _ normal: SIMD3<Float>) {
            if bestFraction == nil || fraction < (bestFraction ?? 1.0) {
                bestFraction = fraction
                bestNormal = normal
            }
        }

        let startPlanarDistanceSq = simd_dot(p0, p0)
        let startInsideWall = startPlanarDistanceSq <= combinedRadius * combinedRadius
        let startInsideY = yStart >= yMin && yStart <= yMax

        if startInsideWall, startInsideY {
            let outward: SIMD3<Float>
            if startPlanarDistanceSq > 0.000001 {
                let planarNormal = p0 / sqrt(startPlanarDistanceSq)
                outward = SIMD3<Float>(planarNormal.x, 0.0, planarNormal.y)
            } else {
                outward = SIMD3<Float>(0.0, 1.0, 0.0)
            }
            return (0.0, outward, false)
        }

        let a = simd_dot(d, d)
        if a > 0.000001 {
            let b = 2.0 * simd_dot(p0, d)
            let c = startPlanarDistanceSq - combinedRadius * combinedRadius
            let discriminant = b * b - 4.0 * a * c
            if discriminant >= 0.0 {
                let t = (-b - sqrt(discriminant)) / (2.0 * a)
                if t >= 0.0, t <= 1.0 {
                    let yAtHit = yStart + dy * t
                    if yAtHit >= yMin, yAtHit <= yMax {
                        let planarAtHit = p0 + d * t
                        let normalXZ = simd_length_squared(planarAtHit) > 0.000001
                            ? simd_normalize(planarAtHit)
                            : SIMD2<Float>(0.0, 1.0)
                        consider(t, SIMD3<Float>(normalXZ.x, 0.0, normalXZ.y))
                    }
                }
            }
        }

        if abs(dy) > 0.000001 {
            let capRadiusSq = obstacle.radius * obstacle.radius
            let tTop = (yMax - yStart) / dy
            if dy < 0.0, tTop >= 0.0, tTop <= 1.0 {
                let planar = p0 + d * tTop
                if simd_dot(planar, planar) <= capRadiusSq {
                    consider(tTop, SIMD3<Float>(0.0, 1.0, 0.0))
                }
            }
            let tBottom = (yMin - yStart) / dy
            if dy > 0.0, tBottom >= 0.0, tBottom <= 1.0 {
                let planar = p0 + d * tBottom
                if simd_dot(planar, planar) <= capRadiusSq {
                    consider(tBottom, SIMD3<Float>(0.0, -1.0, 0.0))
                }
            }
        }

        guard let fraction = bestFraction else {
            return nil
        }
        return (fraction, bestNormal, false)
    }

    private func nearestMeshContact(
        obstacle: CollisionObstacle,
        dronePosition: SIMD3<Float>,
        droneVelocity: SIMD3<Float>,
        droneRadius: Float
    ) -> (clearance: Float, direction: SIMD3<Float>, contactNormal: SIMD3<Float>)? {
        guard let triangles = obstacle.meshTriangles,
              !triangles.isEmpty else {
            return nil
        }

        let sphereCenter = dronePosition + SIMD3<Float>(0.0, droneRadius, 0.0)
        let queryPadding = droneRadius + 12.0
        var bestDistanceSq = Float.greatestFiniteMagnitude
        var bestPoint = sphereCenter
        var bestNormal = SIMD3<Float>(0.0, 1.0, 0.0)

        for triangle in triangles {
            guard sphereCenter.x >= triangle.minimum.x - queryPadding,
                  sphereCenter.x <= triangle.maximum.x + queryPadding,
                  sphereCenter.y >= triangle.minimum.y - queryPadding,
                  sphereCenter.y <= triangle.maximum.y + queryPadding,
                  sphereCenter.z >= triangle.minimum.z - queryPadding,
                  sphereCenter.z <= triangle.maximum.z + queryPadding else {
                continue
            }

            let closest = closestPoint(on: triangle, to: sphereCenter)
            if isPassiveTopSupportMeshContact(
                triangle: triangle,
                sphereCenter: sphereCenter,
                sphereRadius: droneRadius,
                droneVelocity: droneVelocity
            ) {
                continue
            }

            let delta = sphereCenter - closest
            let distanceSq = simd_length_squared(delta)
            guard distanceSq < bestDistanceSq else {
                continue
            }
            bestDistanceSq = distanceSq
            bestPoint = closest
            bestNormal = orientedNormal(
                triangle: triangle,
                sphereCenter: sphereCenter,
                fallbackDirection: delta
            )
        }

        guard bestDistanceSq.isFinite else {
            return nil
        }

        let distance = sqrt(max(0.0, bestDistanceSq))
        let normal = distance > 0.0001
            ? simd_normalize(sphereCenter - bestPoint)
            : bestNormal
        return (
            distance - droneRadius,
            -normal,
            normal
        )
    }

    private func sweepSphereAgainstMesh(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        radius: Float,
        obstacle: CollisionObstacle
    ) -> CollisionSweepResult? {
        guard let triangles = obstacle.meshTriangles,
              !triangles.isEmpty else {
            return nil
        }

        let centerStart = start + SIMD3<Float>(0.0, radius, 0.0)
        let centerEnd = end + SIMD3<Float>(0.0, radius, 0.0)
        let movement = centerEnd - centerStart
        var best: CollisionSweepResult?

        for triangle in triangles {
            guard segmentBoundsMayIntersectTriangle(
                from: centerStart,
                to: centerEnd,
                radius: radius,
                triangle: triangle
            ) else {
                continue
            }

            if let planeHit = spherePlaneTriangleHit(
                from: centerStart,
                movement: movement,
                radius: radius,
                triangle: triangle
            ), best == nil || planeHit.fraction < (best?.hitFraction ?? 1.0) {
                best = CollisionSweepResult(
                    obstacle: obstacle,
                    contactPoint: start + (end - start) * planeHit.fraction,
                    contactNormal: planeHit.normal,
                    hitFraction: planeHit.fraction,
                    isSupportSurfaceContact: planeHit.isSupportSurfaceContact
                )
            }

            if let edgeHit = sphereEdgeTriangleHit(
                from: centerStart,
                to: centerEnd,
                radius: radius,
                triangle: triangle
            ), best == nil || edgeHit.fraction < (best?.hitFraction ?? 1.0) {
                best = CollisionSweepResult(
                    obstacle: obstacle,
                    contactPoint: start + (end - start) * edgeHit.fraction,
                    contactNormal: edgeHit.normal,
                    hitFraction: edgeHit.fraction,
                    isSupportSurfaceContact: false
                )
            }
        }

        return best
    }

    private func segmentBoundsMayIntersectTriangle(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        radius: Float,
        triangle: CollisionMeshTriangle
    ) -> Bool {
        let segmentMinimum = simd_min(start, end) - SIMD3<Float>(repeating: radius)
        let segmentMaximum = simd_max(start, end) + SIMD3<Float>(repeating: radius)
        return segmentMaximum.x >= triangle.minimum.x &&
            segmentMinimum.x <= triangle.maximum.x &&
            segmentMaximum.y >= triangle.minimum.y &&
            segmentMinimum.y <= triangle.maximum.y &&
            segmentMaximum.z >= triangle.minimum.z &&
            segmentMinimum.z <= triangle.maximum.z
    }

    private func spherePlaneTriangleHit(
        from start: SIMD3<Float>,
        movement: SIMD3<Float>,
        radius: Float,
        triangle: CollisionMeshTriangle
    ) -> (fraction: Float, normal: SIMD3<Float>, isSupportSurfaceContact: Bool)? {
        let signedStart = simd_dot(start - triangle.point0, triangle.normal)
        let signedEnd = simd_dot(start + movement - triangle.point0, triangle.normal)
        var candidates: [(fraction: Float, normal: SIMD3<Float>)] = []

        addPlaneCrossing(
            targetDistance: radius,
            signedStart: signedStart,
            signedEnd: signedEnd,
            normal: triangle.normal,
            candidates: &candidates
        )
        addPlaneCrossing(
            targetDistance: -radius,
            signedStart: signedStart,
            signedEnd: signedEnd,
            normal: -triangle.normal,
            candidates: &candidates
        )
        if abs(signedStart) <= radius {
            candidates.append((
                fraction: 0.0,
                normal: signedStart >= 0.0 ? triangle.normal : -triangle.normal
            ))
        }

        for candidate in candidates.sorted(by: { $0.fraction < $1.fraction }) {
            let center = start + movement * candidate.fraction
            let surfacePoint = center - candidate.normal * radius
            if point(surfacePoint, isInside: triangle, tolerance: 0.015) {
                if isPassiveTopSupportSweepContact(
                    triangle: triangle,
                    sphereCenter: center,
                    sphereRadius: radius,
                    contactNormal: candidate.normal,
                    movement: movement
                ) {
                    continue
                }
                return (
                    candidate.fraction,
                    candidate.normal,
                    triangle.supportsLandingSurface &&
                        candidate.normal.y > 0.35 &&
                        simd_dot(movement, candidate.normal) < -0.001
                )
            }
        }
        return nil
    }

    private func addPlaneCrossing(
        targetDistance: Float,
        signedStart: Float,
        signedEnd: Float,
        normal: SIMD3<Float>,
        candidates: inout [(fraction: Float, normal: SIMD3<Float>)]
    ) {
        let denominator = signedEnd - signedStart
        guard abs(denominator) > 0.000001 else {
            return
        }
        let fraction = (targetDistance - signedStart) / denominator
        guard fraction >= 0.0, fraction <= 1.0 else {
            return
        }
        candidates.append((fraction, normal))
    }

    private func sphereEdgeTriangleHit(
        from start: SIMD3<Float>,
        to end: SIMD3<Float>,
        radius: Float,
        triangle: CollisionMeshTriangle
    ) -> (fraction: Float, normal: SIMD3<Float>)? {
        if isPassiveTopSupportEdgeSweep(
            triangle: triangle,
            start: start,
            end: end,
            sphereRadius: radius
        ) {
            return nil
        }

        let edges = [
            (triangle.point0, triangle.point1),
            (triangle.point1, triangle.point2),
            (triangle.point2, triangle.point0)
        ]
        var best: (fraction: Float, normal: SIMD3<Float>)?

        let endpointChecks = [
            (fraction: Float(0.0), point: start),
            (fraction: Float(1.0), point: end)
        ]
        for endpoint in endpointChecks {
            let closest = closestPoint(on: triangle, to: endpoint.point)
            let delta = endpoint.point - closest
            let distanceSq = simd_length_squared(delta)
            guard distanceSq <= radius * radius else {
                continue
            }
            let normal = distanceSq > 0.000001
                ? simd_normalize(delta)
                : orientedNormal(
                    triangle: triangle,
                    sphereCenter: endpoint.point,
                    fallbackDirection: delta
                )
            if best == nil || endpoint.fraction < (best?.fraction ?? 1.0) {
                best = (endpoint.fraction, normal)
            }
        }

        for edge in edges {
            let closest = closestPointsBetweenSegments(
                start0: start,
                end0: end,
                start1: edge.0,
                end1: edge.1
            )
            guard closest.distanceSquared <= radius * radius else {
                continue
            }
            let delta = closest.point0 - closest.point1
            let normal = simd_length_squared(delta) > 0.000001
                ? simd_normalize(delta)
                : orientedNormal(
                    triangle: triangle,
                    sphereCenter: closest.point0,
                    fallbackDirection: delta
                )
            if best == nil || closest.fraction0 < (best?.fraction ?? 1.0) {
                best = (closest.fraction0, normal)
            }
        }

        return best
    }

    private func isPassiveTopSupportMeshContact(
        triangle: CollisionMeshTriangle,
        sphereCenter: SIMD3<Float>,
        sphereRadius: Float,
        droneVelocity: SIMD3<Float>
    ) -> Bool {
        guard triangle.supportsLandingSurface else {
            return false
        }
        let upwardNormal = triangle.normal.y >= 0.0 ? triangle.normal : -triangle.normal
        guard upwardNormal.y > 0.35 else {
            return false
        }

        let normalSpeed = simd_dot(droneVelocity, upwardNormal)
        guard normalSpeed >= -3.0 else {
            return false
        }

        let signedDistance = simd_dot(sphereCenter - triangle.point0, upwardNormal)
        let supportTolerance = max(0.07, sphereRadius * 0.16)
        let supportBand = max(0.24, sphereRadius * 0.58)
        guard signedDistance >= sphereRadius - supportTolerance,
              signedDistance <= sphereRadius + supportBand else {
            return false
        }

        let surfacePoint = sphereCenter - upwardNormal * signedDistance
        return point(surfacePoint, isInside: triangle, tolerance: 0.045)
    }

    private func isPassiveTopSupportSweepContact(
        triangle: CollisionMeshTriangle,
        sphereCenter: SIMD3<Float>,
        sphereRadius: Float,
        contactNormal: SIMD3<Float>,
        movement: SIMD3<Float>
    ) -> Bool {
        guard triangle.supportsLandingSurface else {
            return false
        }
        guard contactNormal.y > 0.35,
              simd_dot(movement, contactNormal) >= -0.001 else {
            return false
        }

        let signedDistance = simd_dot(sphereCenter - triangle.point0, contactNormal)
        let supportTolerance = max(0.06, sphereRadius * 0.14)
        let supportBand = max(0.20, sphereRadius * 0.48)
        guard signedDistance >= sphereRadius - supportTolerance,
              signedDistance <= sphereRadius + supportBand else {
            return false
        }

        let surfacePoint = sphereCenter - contactNormal * signedDistance
        return point(surfacePoint, isInside: triangle, tolerance: 0.04)
    }

    private func isPassiveTopSupportEdgeSweep(
        triangle: CollisionMeshTriangle,
        start: SIMD3<Float>,
        end: SIMD3<Float>,
        sphereRadius: Float
    ) -> Bool {
        guard triangle.supportsLandingSurface else {
            return false
        }
        let upwardNormal = triangle.normal.y >= 0.0 ? triangle.normal : -triangle.normal
        guard upwardNormal.y > 0.35,
              simd_dot(end - start, upwardNormal) >= -0.001 else {
            return false
        }

        let supportTolerance = max(0.07, sphereRadius * 0.16)
        let supportBand = max(0.24, sphereRadius * 0.58)
        for center in [start, end] {
            let signedDistance = simd_dot(center - triangle.point0, upwardNormal)
            guard signedDistance >= sphereRadius - supportTolerance,
                  signedDistance <= sphereRadius + supportBand else {
                continue
            }
            let surfacePoint = center - upwardNormal * signedDistance
            if point(surfacePoint, isInside: triangle, tolerance: 0.08) {
                return true
            }
        }
        return false
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
            hitFraction: slabHit.fraction,
            isSupportSurfaceContact: false
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

    private func closestPoint(
        on triangle: CollisionMeshTriangle,
        to point: SIMD3<Float>
    ) -> SIMD3<Float> {
        let a = triangle.point0
        let b = triangle.point1
        let c = triangle.point2
        let ab = b - a
        let ac = c - a
        let ap = point - a

        let d1 = simd_dot(ab, ap)
        let d2 = simd_dot(ac, ap)
        if d1 <= 0.0, d2 <= 0.0 {
            return a
        }

        let bp = point - b
        let d3 = simd_dot(ab, bp)
        let d4 = simd_dot(ac, bp)
        if d3 >= 0.0, d4 <= d3 {
            return b
        }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0.0, d1 >= 0.0, d3 <= 0.0 {
            let v = d1 / (d1 - d3)
            return a + ab * v
        }

        let cp = point - c
        let d5 = simd_dot(ab, cp)
        let d6 = simd_dot(ac, cp)
        if d6 >= 0.0, d5 <= d6 {
            return c
        }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0.0, d2 >= 0.0, d6 <= 0.0 {
            let w = d2 / (d2 - d6)
            return a + ac * w
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0.0, d4 - d3 >= 0.0, d5 - d6 >= 0.0 {
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return b + (c - b) * w
        }

        let denominator = 1.0 / (va + vb + vc)
        let v = vb * denominator
        let w = vc * denominator
        return a + ab * v + ac * w
    }

    private func point(
        _ point: SIMD3<Float>,
        isInside triangle: CollisionMeshTriangle,
        tolerance: Float
    ) -> Bool {
        let v0 = triangle.point1 - triangle.point0
        let v1 = triangle.point2 - triangle.point0
        let v2 = point - triangle.point0

        let dot00 = simd_dot(v0, v0)
        let dot01 = simd_dot(v0, v1)
        let dot02 = simd_dot(v0, v2)
        let dot11 = simd_dot(v1, v1)
        let dot12 = simd_dot(v1, v2)
        let denominator = dot00 * dot11 - dot01 * dot01
        guard abs(denominator) > 0.000001 else {
            return false
        }

        let inverse = 1.0 / denominator
        let u = (dot11 * dot02 - dot01 * dot12) * inverse
        let v = (dot00 * dot12 - dot01 * dot02) * inverse
        return u >= -tolerance &&
            v >= -tolerance &&
            u + v <= 1.0 + tolerance
    }

    private func closestPointsBetweenSegments(
        start0: SIMD3<Float>,
        end0: SIMD3<Float>,
        start1: SIMD3<Float>,
        end1: SIMD3<Float>
    ) -> (
        fraction0: Float,
        point0: SIMD3<Float>,
        point1: SIMD3<Float>,
        distanceSquared: Float
    ) {
        let d0 = end0 - start0
        let d1 = end1 - start1
        let r = start0 - start1
        let a = simd_dot(d0, d0)
        let e = simd_dot(d1, d1)
        let f = simd_dot(d1, r)
        var s: Float = 0.0
        var t: Float = 0.0

        if a <= 0.000001, e <= 0.000001 {
            let delta = start0 - start1
            return (0.0, start0, start1, simd_length_squared(delta))
        }

        if a <= 0.000001 {
            s = 0.0
            t = (f / e).clamped(to: 0.0...1.0)
        } else {
            let c = simd_dot(d0, r)
            if e <= 0.000001 {
                t = 0.0
                s = (-c / a).clamped(to: 0.0...1.0)
            } else {
                let b = simd_dot(d0, d1)
                let denominator = a * e - b * b
                if abs(denominator) > 0.000001 {
                    s = ((b * f - c * e) / denominator).clamped(to: 0.0...1.0)
                } else {
                    s = 0.0
                }
                let tNominal = b * s + f
                if tNominal < 0.0 {
                    t = 0.0
                    s = (-c / a).clamped(to: 0.0...1.0)
                } else if tNominal > e {
                    t = 1.0
                    s = ((b - c) / a).clamped(to: 0.0...1.0)
                } else {
                    t = tNominal / e
                }
            }
        }

        let point0 = start0 + d0 * s
        let point1 = start1 + d1 * t
        return (
            s,
            point0,
            point1,
            simd_length_squared(point0 - point1)
        )
    }

    private func orientedNormal(
        triangle: CollisionMeshTriangle,
        sphereCenter: SIMD3<Float>,
        fallbackDirection: SIMD3<Float>
    ) -> SIMD3<Float> {
        if simd_length_squared(fallbackDirection) > 0.000001 {
            return simd_normalize(fallbackDirection)
        }
        let signedDistance = simd_dot(sphereCenter - triangle.point0, triangle.normal)
        return signedDistance >= 0.0 ? triangle.normal : -triangle.normal
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
