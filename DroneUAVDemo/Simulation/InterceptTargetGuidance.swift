import Foundation
import simd

/// Where an interception target is trying to fly.
///
/// It resolves a *course* that is held and turned, not a figure traced around a spawn point. The
/// shape this replaced was a sum of sines: the aircraft wandered, it never reacted to the
/// interceptor, and closing on it was a matter of waiting for the loop to come back around.
///
/// The result is an *aim point*, not a destination. A rotorcraft's sits far enough ahead that the
/// hover controller asks for a real translation speed; an aeroplane's sits far enough ahead to be
/// a leg its route follower can fly. Neither is a place the aircraft intends to stop.
///
/// Pure value logic on purpose — no scene, no component graph, no session — so the behaviour that
/// decides whether this mission is playable can be measured headlessly.
struct InterceptTargetGuidance {
    /// Everything the guidance is allowed to see. Supplied by the session each tick.
    struct Situation {
        var behavior: InterceptTargetBehavior
        var agility: Float
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var spawnPosition: SIMD3<Float>
        var attacker: SIMD3<Float>
        /// Centre of the mission area — the dock the run was launched from.
        var origin: SIMD3<Float>
        var areaRadius: Float
        var isFixedWing: Bool
        /// A damaged aircraft on the recovery profile stops flying anywhere at all.
        var isDamaged: Bool
        /// What is standing in the way. A target that dodges the interceptor beautifully and then
        /// flies into a tree is not evading anything — it is being flown by something that cannot
        /// see the world.
        var obstacles: [CollisionObstacle] = []
        var deltaTime: Float
    }

    // MARK: Tuning

    /// How far ahead a rotorcraft target's aim point sits. Far enough that the hover controller
    /// asks for a real translation speed, close enough that it still turns with the course.
    static let rotorcraftAimDistance: Float = 95
    /// Minimum length of an aeroplane target's published leg.
    static let fixedWingLegLength: Float = 900
    /// Inside this range an evading target considers itself threatened and breaks off.
    static let threatRange: Float = 160
    /// How much an evading rotorcraft climbs at maximum urgency, in metres.
    static let evasiveClimb: Float = 22
    /// Maximum course change, in radians per second at unit agility. Bounded so the target flies
    /// an arc a pilot can lead rather than snapping onto a new heading.
    static let courseTurnRate: Float = 0.9
    /// The bank a target is assumed to hold in a containment turn, as its tangent — a standard
    /// 30° turn. Together with speed it gives the radius the turn actually needs.
    static let nominalBankTangent: Float = 0.577
    static let gravity: Float = 9.81
    /// How far inside tangential the containment turn aims. Has to exceed the release threshold
    /// below, or the turn stops before it has finished.
    static let containmentInwardBias: Float = 0.6
    /// Containment lets go once the course has this much inward component — about 20° inside the
    /// tangent — so the aircraft crosses the area rather than orbiting its boundary.
    static let containmentReleaseComponent: Float = 0.35
    /// How far each patrol leg is swept off the exact opposite side, in radians. Zero would make
    /// the aircraft retrace one line forever.
    static let patrolSweepAngle: Float = 0.6
    /// How far ahead the target looks for something to fly into, as a multiple of the distance it
    /// covers in a second. Fast aircraft look further, which is the only way a lookahead can be
    /// right for both a hovering rotorcraft and an aeroplane at cruise.
    static let obstacleLookaheadSeconds: Float = 3.5
    static let minimumObstacleLookahead: Float = 70
    /// Horizontal room the target insists on having around anything solid.
    static let obstacleClearance: Float = 18
    /// Vertical room it insists on having over the top of it.
    static let obstacleOverflyClearance: Float = 18

    /// The heading currently being held. Nil until the first tick establishes one.
    private(set) var course: SIMD3<Float>?
    /// The point the patrol is currently crossing towards, and which way the next leg sweeps.
    private(set) var patrolTarget: SIMD3<Float>?
    private var patrolFlip = false
    /// Where a `damagedRecovery` target decided to stop and try to hold. Latched once, so a
    /// wobbling aircraft does not keep re-choosing a new place to recover to.
    private(set) var recoveryPosition: SIMD3<Float>?

    mutating func aimPoint(_ situation: Situation) -> SIMD3<Float> {
        if situation.behavior == .damagedRecovery, situation.isDamaged {
            recoveryPosition = recoveryPosition ?? situation.position
            return recoveryPosition ?? situation.spawnPosition
        }

        let planarToAttacker = SIMD3<Float>(
            situation.attacker.x - situation.position.x,
            0,
            situation.attacker.z - situation.position.z
        )
        let range = simd_length(planarToAttacker)
        let intent = desiredCourse(situation, toAttacker: planarToAttacker, range: range)
        let heading = steer(toward: avoiding(intent, situation: situation), situation: situation)
        let reach = situation.isFixedWing
            ? max(Self.fixedWingLegLength, situation.areaRadius * 2.5)
            : Self.rotorcraftAimDistance * max(0.5, situation.agility)
        return SIMD3<Float>(
            situation.position.x + heading.x * reach,
            clearedAltitude(altitude(situation, range: range), situation: situation),
            situation.position.z + heading.z * reach
        )
    }

    // MARK: - Obstacles

    /// Steers the requested course around anything solid in front of the aircraft.
    ///
    /// A sideways push, not a replanned route: the target is flying a patrol or breaking off an
    /// interceptor, and what it needs is to not hit the tree it is about to reach. The push grows
    /// as the obstacle gets closer and as the course points more squarely at it.
    private func avoiding(_ heading: SIMD3<Float>, situation: Situation) -> SIMD3<Float> {
        let lookahead = obstacleLookahead(situation)
        var push = SIMD3<Float>.zero
        for obstacle in situation.obstacles {
            // Anything the aircraft is comfortably above is not in the way.
            guard obstacle.topY > situation.position.y - Self.obstacleOverflyClearance else { continue }
            let offset = SIMD3<Float>(
                obstacle.center.x - situation.position.x,
                0,
                obstacle.center.z - situation.position.z
            )
            let distance = simd_length(offset)
            let reach = obstacle.radius + Self.obstacleClearance
            guard distance > 0.001, distance < lookahead + reach else { continue }
            let toObstacle = offset / distance
            let ahead = simd_dot(heading, toObstacle)
            guard ahead > 0 else { continue }
            // How far off the course line the obstacle sits. Beyond its own radius plus the
            // clearance the aircraft is already going past it.
            let lateral = abs(distance * sqrt(max(0, 1 - ahead * ahead)))
            guard lateral < reach else { continue }
            let urgency = ahead * (1 - min(1, max(0, (distance - reach) / max(1, lookahead))))
            // Away from the obstacle, perpendicular to the line to it, on whichever side the
            // aircraft is already passing.
            var side = SIMD3<Float>(-toObstacle.z, 0, toObstacle.x)
            if simd_dot(side, heading) < 0 { side = -side }
            push += side * urgency
        }
        guard simd_length_squared(push) > 1e-6 else { return heading }
        return Self.planar(heading + push * 1.6)
    }

    /// Raises the aim point over anything tall enough to matter. Cheaper and more reliable than
    /// threading between trees, and what an aircraft with height to spare would actually do.
    private func clearedAltitude(_ requested: Float, situation: Situation) -> Float {
        let lookahead = obstacleLookahead(situation)
        var floor = requested
        for obstacle in situation.obstacles {
            let offset = SIMD3<Float>(
                obstacle.center.x - situation.position.x,
                0,
                obstacle.center.z - situation.position.z
            )
            let distance = simd_length(offset)
            guard distance < lookahead + obstacle.radius else { continue }
            floor = max(floor, obstacle.topY + Self.obstacleOverflyClearance)
        }
        return floor
    }

    private func obstacleLookahead(_ situation: Situation) -> Float {
        let speed = simd_length(SIMD3<Float>(situation.velocity.x, 0, situation.velocity.z))
        return max(Self.minimumObstacleLookahead, speed * Self.obstacleLookaheadSeconds)
    }

    // MARK: - Course

    /// The heading this behaviour wants right now, before smoothing.
    private mutating func desiredCourse(
        _ situation: Situation,
        toAttacker: SIMD3<Float>,
        range: Float
    ) -> SIMD3<Float> {
        switch situation.behavior {
        case .routeFollower, .damagedRecovery:
            // Transits the area and never reacts to the interceptor. This is the profile that is
            // meant to be catchable.
            return contained(patrolCourse(situation), situation: situation)
        case .evasiveBasic:
            let patrol = contained(patrolCourse(situation), situation: situation)
            guard range > 0.001, range < Self.threatRange else { return patrol }
            // Turn away, but not straight away: a target that only ran downwind would be a stern
            // chase forever. The lateral component is what breaks it off the interceptor's line,
            // and difficulty decides how hard.
            let away = simd_normalize(-toAttacker)
            let lateral = SIMD3<Float>(-away.z, 0, away.x) * breakSign(situation)
            let urgency = min(1, (Self.threatRange - range) / Self.threatRange)
            let evasive = Self.planar(away + lateral * (0.5 + 0.5 * situation.agility))
            return contained(Self.planar(patrol * (1 - urgency) + evasive * urgency), situation: situation)
        case .escapeBoundary:
            // Leaves. Outward from the mission origin, biased away from the interceptor, and
            // deliberately not turned back at the boundary — crossing it is the point.
            let outward = Self.planar(SIMD3<Float>(
                situation.position.x - situation.origin.x,
                0,
                situation.position.z - situation.origin.z
            ))
            let away = range > 0.001 ? simd_normalize(-toAttacker) : outward
            return Self.planar(outward + away * 0.6)
        }
    }

    /// The patrol itself: cross the area, turn, cross it back. Expressed as a point to fly to
    /// rather than a heading to hold, because that is what makes the track legible — an operator
    /// can see where the target is going and set up a pass on it, which a heading controller
    /// arcing along the boundary never allows.
    private mutating func patrolCourse(_ situation: Situation) -> SIMD3<Float> {
        let arrival = max(30, turnRadius(situation) * 0.9)
        if let target = patrolTarget,
           simd_length(SIMD3<Float>(target.x - situation.position.x, 0, target.z - situation.position.z)) > arrival {
            return Self.planar(target - situation.position)
        }
        patrolTarget = nextPatrolTarget(situation)
        return Self.planar((patrolTarget ?? situation.spawnPosition) - situation.position)
    }

    /// The next crossing point: across the area from where the aircraft is now, offset to one
    /// side so consecutive legs form a track rather than the same line flown back and forth. The
    /// side alternates deterministically — a mission has to replay identically.
    private mutating func nextPatrolTarget(_ situation: Situation) -> SIMD3<Float> {
        patrolFlip.toggle()
        let offset = SIMD3<Float>(
            situation.position.x - situation.origin.x,
            0,
            situation.position.z - situation.origin.z
        )
        let outward = simd_length_squared(offset) > 1 ? simd_normalize(offset) : Self.planar(situation.velocity)
        let sweep: Float = patrolFlip ? Self.patrolSweepAngle : -Self.patrolSweepAngle
        let across = SIMD3<Float>(
            -outward.x * cos(sweep) - outward.z * sin(sweep),
            0,
            outward.x * sin(sweep) - outward.z * cos(sweep)
        )
        return situation.origin + across * patrolRingRadius(situation) + SIMD3<Float>(0, situation.spawnPosition.y, 0)
    }

    /// How far out the crossing points sit. Bounded by the room the aircraft needs to turn round
    /// at the end of a leg: an aeroplane at cruise overshoots its waypoint by a turn radius, and a
    /// ring chosen without that in mind is a ring that puts it outside the mission area.
    private func patrolRingRadius(_ situation: Situation) -> Float {
        max(
            situation.areaRadius * 0.2,
            min(situation.areaRadius * 0.5, situation.areaRadius - turnRadius(situation) * 1.15)
        )
    }

    /// Radius of a standard-rate turn at the aircraft's current speed.
    private func turnRadius(_ situation: Situation) -> Float {
        let speed = simd_length(SIMD3<Float>(situation.velocity.x, 0, situation.velocity.z))
        return (speed * speed) / (Self.gravity * Self.nominalBankTangent)
    }

    /// Turns the held course towards the requested one at a bounded *angular* rate.
    ///
    /// Deliberately a rotation and not a linear blend between the two direction vectors. Blending
    /// is degenerate when the two are opposed — which is exactly the case that matters here, an
    /// aircraft at the boundary being told to turn round — and it stalls near the antipode instead
    /// of turning through it.
    private mutating func steer(toward desired: SIMD3<Float>, situation: Situation) -> SIMD3<Float> {
        let current = course ?? initialCourse(situation)
        let maxTurn = Self.courseTurnRate * max(0.0001, situation.deltaTime) * max(0.2, situation.agility)
        let cosine = max(-1, min(1, simd_dot(current, desired)))
        let angle = acos(cosine)
        let turned: SIMD3<Float>
        if angle <= maxTurn || angle < 1e-4 {
            turned = desired
        } else {
            // Rotate about the vertical axis, in whichever direction is the shorter way round.
            let sign: Float = (current.z * desired.x - current.x * desired.z) >= 0 ? 1 : -1
            let step = maxTurn * sign
            turned = SIMD3<Float>(
                current.x * cos(step) + current.z * sin(step),
                0,
                -current.x * sin(step) + current.z * cos(step)
            )
        }
        let result = Self.planar(turned)
        course = result
        return result
    }

    /// Turns a course that is leaving the mission area back into it. Without this the only thing
    /// keeping a patrolling target inside the boundary would be luck.
    ///
    /// The answer is a turn along the boundary biased inwards, not a mirror image of the course:
    /// an aircraft flying straight out would be asked for an exact reversal, which is both
    /// unflyable and the one direction a heading controller cannot resolve.
    private func contained(_ heading: SIMD3<Float>, situation: Situation) -> SIMD3<Float> {
        let offset = SIMD3<Float>(
            situation.position.x - situation.origin.x,
            0,
            situation.position.z - situation.origin.z
        )
        let distance = simd_length(offset)
        let limit = containmentLimit(situation)
        guard distance > limit, distance > 0.001 else { return heading }
        let outward = offset / distance
        let outwardComponent = simd_dot(heading, outward)
        // Held until the course is properly pointed back inside, not merely tangential. Releasing
        // at the tangent makes the tangent the equilibrium, and an aircraft that lags its
        // commanded bank sits a degree or two outside it — a slow spiral out of the area instead
        // of a patrol. With the hysteresis the aircraft turns through the boundary and crosses
        // the area again, rather than orbiting its rim forever.
        guard outwardComponent > -Self.containmentReleaseComponent else { return heading }

        // Keep whichever way along the boundary it was already going; if it was heading straight
        // out there is no such side, so pick one and commit to it.
        var alongBoundary = heading - outward * outwardComponent
        if simd_length_squared(alongBoundary) < 1e-6 {
            alongBoundary = SIMD3<Float>(-outward.z, 0, outward.x)
        }
        // How hard it turns in scales with how far past the limit it already is, so a target
        // brushing the boundary arcs along it and one well outside comes back decisively.
        let overshoot = min(1, (distance - limit) / max(1, situation.areaRadius - limit))
        let inwardBias = Self.containmentInwardBias + 0.9 * overshoot
        return Self.planar(simd_normalize(alongBoundary) - outward * inwardBias)
    }

    /// Where the turn back has to begin, which is a function of how much room the aircraft needs
    /// to complete it. A fixed fraction of the radius cannot serve both: at 12 m/s a rotorcraft
    /// turns inside 25 m, while an aeroplane at cruise needs the better part of 150 m, and giving
    /// the aeroplane the rotorcraft's margin puts it outside the mission area every lap.
    private func containmentLimit(_ situation: Situation) -> Float {
        let margin = min(situation.areaRadius * 0.5, turnRadius(situation) * 1.35)
        return max(situation.areaRadius * 0.35, situation.areaRadius - margin)
    }

    /// Which way the target breaks when it evades: towards the middle of the area, so an evading
    /// aircraft does not fly itself straight out of the mission and hand the operator a
    /// `targetEscaped` failure it had no chance to prevent.
    private func breakSign(_ situation: Situation) -> Float {
        let inward = SIMD3<Float>(
            situation.origin.x - situation.position.x,
            0,
            situation.origin.z - situation.position.z
        )
        guard simd_length_squared(inward) > 1 else { return 1 }
        return simd_dot(SIMD3<Float>(-inward.z, 0, inward.x), inward) >= 0 ? 1 : -1
    }

    /// Opening heading. An aircraft that is already moving is already on a course — taking it
    /// from the velocity is what stops an aeroplane spawned mid-transit from being commanded into
    /// an immediate 180° turn on its first tick.
    private func initialCourse(_ situation: Situation) -> SIMD3<Float> {
        let velocity = SIMD3<Float>(situation.velocity.x, 0, situation.velocity.z)
        if simd_length(velocity) > 1 { return simd_normalize(velocity) }
        return Self.planar(SIMD3<Float>(
            situation.spawnPosition.x - situation.origin.x,
            0,
            situation.spawnPosition.z - situation.origin.z
        ))
    }

    // MARK: - Altitude

    /// Altitude the target holds. A rotorcraft climbs a little while breaking off, which is what
    /// turns a close pass into a miss rather than a graze.
    private func altitude(_ situation: Situation, range: Float) -> Float {
        let base = situation.spawnPosition.y
        guard situation.behavior == .evasiveBasic,
              !situation.isFixedWing,
              range < Self.threatRange else { return base }
        let urgency = min(1, (Self.threatRange - range) / Self.threatRange)
        return base + urgency * Self.evasiveClimb * situation.agility
    }

    // MARK: - Helpers

    static func planar(_ vector: SIMD3<Float>) -> SIMD3<Float> {
        let flat = SIMD3<Float>(vector.x, 0, vector.z)
        return simd_length_squared(flat) > 1e-6 ? simd_normalize(flat) : SIMD3<Float>(0, 0, -1)
    }
}
