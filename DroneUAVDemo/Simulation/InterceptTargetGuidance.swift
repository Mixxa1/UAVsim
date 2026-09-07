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
        /// How the other aircraft is moving. Only pursuit reads it, and only to aim where the
        /// quarry will be — a hunter that flies at where its quarry *is* never closes on anything
        /// faster than a hover.
        var attackerVelocity: SIMD3<Float> = .zero
        /// What this aircraft can do, not what it is doing. The collision solve needs the speed the
        /// hunter will *arrive* at; using the speed it happens to be flying at the instant it is
        /// asked — a standing start, or the bottom of a turn — puts the meeting point in the wrong
        /// place and the whole approach is built on it.
        var cruiseSpeed: Float = 0
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
    /// How far ahead a hunter is willing to aim, in seconds. Bounded because a long lead against a
    /// quarry that is about to turn points at empty sky.
    static let maximumPursuitLead: Float = 8
    /// Speed the collision solve assumes when the hunter is barely moving, so a standing start
    /// still produces a course rather than a division by nothing.
    static let minimumPursuitSpeed: Float = 8
    /// Inside this the hunter stops solving and flies at the aircraft.
    static let pursuitTerminalRange: Float = 40
    /// Inside this it stops going round things. Committed is committed: a hunter that breaks off a
    /// final approach to clear a tree is a hunter the operator can shake by flying past one.
    static let pursuitCommitRange: Float = 90
    /// How much harder a hunter turns than a target flying its own business.
    static let pursuitTurnRateScale: Float = 2.2
    /// How far past the quarry a hunter aims. Enough that the position controller is still asking
    /// for a real translation and goes through rather than stopping alongside; short enough that a
    /// small heading error is a small miss.
    static let pursuitOvershoot: Float = 12
    /// Room a committed hunter keeps around a trunk: an airframe's width and a margin, not the
    /// corridor a patrolling aircraft steers by. Wide enough to survive a wood, narrow enough that
    /// flying past a tree does not shake the pursuit.
    static let pursuitObstacleClearance: Float = 7
    /// How far a hunter clears the top of something it has to hop. Small: it is coming back down
    /// the other side to a quarry that is under the canopy, not leaving the wood.
    static let pursuitOverflyClearance: Float = 6
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
        // Committed only decides how the *course* is followed. Obstacles are another matter: a
        // hunter with avoidance switched off flew into trunks and destroyed itself after a few
        // hundred metres of wood, which is a worse outcome than losing a pursuit.
        let committed = situation.behavior == .interceptorPursuit && range < Self.pursuitCommitRange
        // Measured: narrowing the *lateral* clearance for a committed hunter bought nothing — the
        // approach to a quarry under the canopy stayed the same width — and cost it robustness on
        // a long transit through the wood. What actually reaches down through a wood is the
        // altitude rule below, so lateral avoidance is left exactly as every other aircraft flies.
        let requested = avoiding(intent, situation: situation)
        // On the final approach the solution is followed exactly rather than turned towards at a
        // bounded rate. Smoothing is what a course *holder* needs; a hunter closing the last fifty
        // metres that lags its own solution by a fraction of a second arrives beside the aircraft
        // instead of through it, which is what "flies imprecisely" looks like from the cockpit.
        let heading = committed ? { course = requested; return requested }() : steer(toward: requested, situation: situation)
        let held = altitude(situation, range: range)
        return SIMD3<Float>(
            situation.position.x + heading.x * aimDistance(situation, range: range),
            situation.behavior == .interceptorPursuit
                ? clearedAltitude(
                    held,
                    situation: situation,
                    heading: heading,
                    lateralClearance: Self.pursuitObstacleClearance,
                    overflyClearance: Self.pursuitOverflyClearance
                  )
                : clearedAltitude(held, situation: situation),
            situation.position.z + heading.z * aimDistance(situation, range: range)
        )
    }

    /// How far along the chosen heading the aim point is put.
    ///
    /// For a hunter this shortens as the range closes, and it is the difference between a pass and
    /// a hit. The aim point is a lever: the aircraft flies at *it*, so a heading that is half a
    /// degree off puts the commanded point — and therefore the aircraft — `distance × sin(error)`
    /// to one side of the quarry. Measured against a hovering aircraft with a fixed 95 m aim point,
    /// approaches went past at 14, 7 and 5 metres before one finally connected. Aiming just beyond
    /// the quarry instead divides that error by the same factor the distance shrank by, while
    /// staying far enough ahead that the position controller still asks for full speed and drives
    /// *through* rather than flaring to a stop alongside.
    private func aimDistance(_ situation: Situation, range: Float) -> Float {
        let cruise = situation.isFixedWing
            ? max(Self.fixedWingLegLength, situation.areaRadius * 2.5)
            : Self.rotorcraftAimDistance * max(0.5, situation.agility)
        guard situation.behavior == .interceptorPursuit, !situation.isFixedWing else { return cruise }
        return min(cruise, range + Self.pursuitOvershoot)
    }

    // MARK: - Obstacles

    /// Steers the requested course around anything solid in front of the aircraft.
    ///
    /// A sideways push, not a replanned route: the target is flying a patrol or breaking off an
    /// interceptor, and what it needs is to not hit the tree it is about to reach. The push grows
    /// as the obstacle gets closer and as the course points more squarely at it.
    private func avoiding(
        _ heading: SIMD3<Float>,
        situation: Situation,
        lookahead requestedLookahead: Float? = nil,
        clearance: Float = InterceptTargetGuidance.obstacleClearance
    ) -> SIMD3<Float> {
        let lookahead = requestedLookahead ?? obstacleLookahead(situation)
        var push = SIMD3<Float>.zero
        for obstacle in situation.obstacles {
            // Anything the aircraft is comfortably above is not in the way.
            guard obstacle.topY > situation.position.y - clearance else { continue }
            let offset = SIMD3<Float>(
                obstacle.center.x - situation.position.x,
                0,
                obstacle.center.z - situation.position.z
            )
            let distance = simd_length(offset)
            let reach = obstacle.radius + clearance
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
    /// `heading` narrows this to what is actually in the aircraft's path.
    ///
    /// Without it the rule is "anything within the lookahead, in any direction" — which in a wood
    /// is every trunk, all the time, so the aim point sits permanently above the canopy. For a
    /// patrolling target that is the right answer and stays the default. For a hunter it is fatal
    /// to the mission: measured against a quarry hovering below the canopy, the hunter circled
    /// overhead and never got closer than 21 m. Given a heading it lifts over the trunk it is about
    /// to hit and comes back down behind it.
    private func clearedAltitude(
        _ requested: Float,
        situation: Situation,
        heading: SIMD3<Float>? = nil,
        lateralClearance: Float = InterceptTargetGuidance.obstacleClearance,
        overflyClearance: Float = InterceptTargetGuidance.obstacleOverflyClearance
    ) -> Float {
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
            if let heading, distance > 0.001 {
                let toObstacle = offset / distance
                let ahead = simd_dot(heading, toObstacle)
                guard ahead > 0 else { continue }
                let lateral = abs(distance * sqrt(max(0, 1 - ahead * ahead)))
                guard lateral < obstacle.radius + lateralClearance else { continue }
            }
            floor = max(floor, obstacle.topY + overflyClearance)
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
        case .interceptorPursuit:
            // A collision course, not a lead guess and not a tail chase.
            //
            // Not contained by the boundary either. A hunter that broke off at the fence would hand
            // the operator a corner of the map to sit in, which is not a mission.
            guard range > 0.001 else { return course ?? initialCourse(situation) }
            // Inside knife range the solution is noise — the geometry changes faster than a course
            // can be turned — so it stops solving and simply goes for the aircraft.
            guard range > Self.pursuitTerminalRange else { return Self.planar(toAttacker) }
            return Self.planar(collisionCourse(situation, toAttacker: toAttacker, range: range))
        }
    }

    /// Where to point to arrive at the same place as the quarry at the same time.
    ///
    /// Solves |R + V·t| = S·t for the earliest positive `t` — the constant-bearing course an
    /// interceptor actually flies, which cuts the corner on a turning quarry and heads off one
    /// running for a zone. A fixed lead time, which this replaced, aims at a point the quarry has
    /// no intention of passing through, and pure pursuit against anything moving is a stern chase
    /// that only ends if the hunter is much the faster aircraft.
    ///
    /// With no solution — a quarry faster than the hunter, opening the range — the best available
    /// answer is to aim at where it will be at the longest lead worth taking and hope it turns.
    private func collisionCourse(
        _ situation: Situation,
        toAttacker: SIMD3<Float>,
        range: Float
    ) -> SIMD3<Float> {
        let quarry = SIMD3<Float>(situation.attackerVelocity.x, 0, situation.attackerVelocity.z)
        let speed = max(
            Self.minimumPursuitSpeed,
            situation.cruiseSpeed,
            simd_length(SIMD3<Float>(situation.velocity.x, 0, situation.velocity.z))
        )
        let a = simd_length_squared(quarry) - speed * speed
        let b = 2 * simd_dot(toAttacker, quarry)
        let c = range * range

        var time: Float?
        if abs(a) < 1e-4 {
            if b < -1e-4 { time = -c / b }
        } else {
            let discriminant = b * b - 4 * a * c
            if discriminant >= 0 {
                let root = sqrt(discriminant)
                let candidates = [(-b - root) / (2 * a), (-b + root) / (2 * a)].filter { $0 > 0 }
                time = candidates.min()
            }
        }
        let lead = min(Self.maximumPursuitLead, time ?? (range / speed))
        return toAttacker + quarry * lead
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
        // A hunter turns harder than an aircraft going about its own business. It is flying to a
        // solution that moves whenever the quarry does, and at a target's turn rate it arrives
        // permanently one correction behind.
        let scale = situation.behavior == .interceptorPursuit ? Self.pursuitTurnRateScale : 1
        let maxTurn = Self.courseTurnRate * scale * max(0.0001, situation.deltaTime) * max(0.2, situation.agility)
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
        // A hunter goes where its quarry is going to be, in height as well as on the ground.
        // Holding the quarry's *current* altitude leaves it permanently one climb behind, and
        // holding its own spawn altitude leaves it circling overhead while the operator flies
        // underneath it.
        if situation.behavior == .interceptorPursuit {
            let speed = max(Self.minimumPursuitSpeed, situation.cruiseSpeed)
            let lead = min(Self.maximumPursuitLead, range / speed)
            return situation.attacker.y + situation.attackerVelocity.y * lead
        }
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
