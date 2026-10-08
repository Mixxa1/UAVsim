import Foundation
import simd

/// A road actor. DroneState is only the shared pose/contact/replay transport at the boundary;
/// neither SimpleDronePhysicsEngine nor the aircraft's component damage model runs here.
final class GroundVehicleRuntime {
    let profile: GroundVehicleProfile
    let model: GroundVehicleModel
    let vehicleID: String
    var state: DroneState
    private(set) var damage = GroundVehicleDamage()
    private(set) var steering: Float = 0
    private(set) var wheelRoll: Double = 0
    var wheelAngle: Float { Float(wheelRoll.truncatingRemainder(dividingBy: 2 * .pi)) }
    private(set) var navigation = GroundVehicleNavigation()
    private(set) var maneuver: Maneuver = .driving
    private(set) var worldTime: TimeInterval = 0
    private(set) var effects: [InterceptWorldEffect] = []
    private(set) var burnStartedAt: TimeInterval?
    var burnAge: TimeInterval { burnStartedAt.map { max(0, worldTime - $0) } ?? 0 }
    private let effectRunID = UUID()
    private var emittedEffects = Set<String>()
    /// Effect origins in body coordinates: a roof flare must not jump into the engine bay on
    /// the next tick, and a moving or overturned vehicle carries its local fire with it.
    private var effectAnchors: [UUID: SIMD3<Float>] = [:]
    enum Maneuver: String { case driving, evading, reversing, stopped }
    private var speed: Float = 0
    private var lateralSpeed: Float = 0
    private var yaw: Float = 0
    private var goal: SIMD2<Float>?
    private var goalTimer: Float = 0
    private var reverseTimer: Float = 0
    private var stuckTimer: Float = 0
    private var collisionCooldown: Float = 0
    private var turnSign: Float = 1
    private var obstacleField: GroundVehicleObstacleField?
    private var obstacleFieldPosition = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    private var obstacleFieldCountdown: Float = 0
    private var safetyCommand: GroundVehicleDrivingSafety.Command?
    private var safetyCountdown: Float = 0
    private var safetyWaypoint = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
    private var rng: MissionSeededGenerator
    private let collision = CollisionAnalysisService()

    init(position: SIMD3<Float>, model: GroundVehicleModel = .cabover,
         profile: GroundVehicleProfile = GroundVehicleProfile(), seed: UInt64, vehicleID: String = "CAR-01") {
        self.profile = profile; self.model = model
        self.vehicleID = vehicleID
        rng = MissionSeededGenerator(seed: seed)
        state = .initial
        state.position = position
        state.physicalState = .landed
        state.motionState = .grounded
        state.armState = .armed
    }

    var contactProfile: VehicleContactProfile {
        var spheres: [VehicleContactSphere] = []
        let radius = profile.size.x * 0.44
        for z in [-profile.size.z * 0.32, 0, profile.size.z * 0.32] {
            spheres.append(VehicleContactSphere(componentID: GroundVehiclePart.body.rawValue,
                offset: SIMD3<Float>(0, profile.size.y * 0.47, z), radius: radius))
        }
        for part in GroundVehiclePart.allCases where part.isWheel && damage.condition(part) >= 0.12 {
            spheres.append(VehicleContactSphere(componentID: part.rawValue,
                offset: part.position(in: profile), radius: profile.wheelRadius, isGroundSupport: true))
        }
        return VehicleContactProfile(spheres: spheres,
            boundingRadius: spheres.map { simd_length($0.offset) + $0.radius }.max() ?? profile.clearance)
    }

    /// Mass/inertia/contact adapter only. Car damage is owned by GroundVehicleDamage.
    func componentGraph() -> VehicleComponentGraph {
        let parts = GroundVehiclePart.allCases.map { part in
            VehicleComponent(id: part.rawValue, kind: part.isWheel ? .landingGear(slot: part.rawValue) : .frame,
                parentID: part == .body ? nil : GroundVehiclePart.body.rawValue,
                massKg: profile.massKg * part.massFraction,
                localPosition: part.position(in: profile),
                boundingHalfExtents: part == .body ? profile.size * 0.5 : SIMD3<Float>(repeating: profile.wheelRadius),
                strengthJ: part == .body ? 180_000 * profile.massKg / 1800 : 20_000,
                integrity: damage.condition(part),
                attachmentState: part.isWheel && damage.condition(part) < 0.12 ? .detached : .attached,
                legacyComponent: nil,
                functionalDependencies: [], failureModes: [])
        }
        return VehicleComponentGraph(components: parts, structuralConnections: [])
    }

    func receive(_ report: ImpactReport) {
        safetyCountdown = 0
        let point = simd_act(state.attitudeQuat.conjugate, report.contactPoint - state.position)
        let normal = simd_act(state.attitudeQuat.conjugate, report.contactNormal)
        damage.impact(energyJ: report.impactEnergyJ, bodyPoint: point, profile: profile, normal: normal)
        let tippingEnergy = profile.massKg * 9.81 * profile.trackWidth * 0.5
        if abs(normal.x) > 0.65, point.y > profile.size.y * 0.6, report.impactEnergyJ > tippingEnergy {
            damage.overturn()
        }
        syncCondition()
    }

    /// A slowly chosen evasive goal, followed through the same obstacle planner as a route.
    /// The controller can brake/reverse and turn around, but cannot rotate a moving truck in place.
    func step(deltaTime: Float, destination: SIMD2<Float>?, threat: SIMD3<Float>?,
              evasive: Bool, origin: SIMD2<Float>, areaRadius: Float,
              grip: Float, obstacles: [CollisionObstacle], ground: (SIMD3<Float>, Float) -> Float) -> [ImpactReport] {
        guard deltaTime.isFinite, deltaTime > 0 else { return [] }
        worldTime += TimeInterval(deltaTime)
        // Pair contacts may have changed the shared pose/velocity since the preceding step.
        yaw = atan2(-simd_act(state.attitudeQuat, SIMD3<Float>(0, 0, -1)).x,
                    -simd_act(state.attitudeQuat, SIMD3<Float>(0, 0, -1)).z)
        let forward = SIMD3<Float>(-sin(yaw), 0, -cos(yaw))
        let right = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
        speed = simd_dot(state.velocity, forward)
        lateralSpeed = simd_dot(state.velocity, right)
        let dt = min(0.1, deltaTime)
        let position = SIMD2<Float>(state.position.x, state.position.z)
        obstacleFieldCountdown -= dt
        if obstacleField == nil || obstacleFieldCountdown <= 0 ||
            simd_distance(obstacleFieldPosition, state.position) > 12 || abs(obstacleFieldPosition.y - state.position.y) > 0.75 {
            obstacleField = GroundVehicleObstacleField(obstacles: obstacles, groundY: state.position.y, height: profile.size.y)
            obstacleFieldPosition = state.position; obstacleFieldCountdown = 0.8
            safetyCountdown = 0
        }
        let field = obstacleField!
        goalTimer -= dt
        if let destination { goal = destination }
        else if goal == nil || goalTimer <= 0 || simd_distance(goal!, position) < 12 {
            var direction: SIMD2<Float>
            let toThreat = threat.map { position - SIMD2<Float>($0.x, $0.z) }
            if evasive, let toThreat, simd_length(toThreat) < 180 {
                let away = simd_length(toThreat) > 1 ? simd_normalize(toThreat) : SIMD2<Float>(0, -1)
                turnSign = Bool.random(using: &rng) ? 1 : -1
                direction = simd_normalize(away + SIMD2<Float>(-away.y, away.x) * turnSign * 0.7)
                maneuver = .evading
                goalTimer = Float.random(in: 3...6, using: &rng)
            } else {
                let angle = Float.random(in: 0...(2 * .pi), using: &rng)
                direction = SIMD2<Float>(sin(angle), cos(angle))
                goalTimer = 8
                maneuver = .driving
            }
            var candidate = position + direction * min(100, areaRadius * 0.5)
            let radial = candidate - origin
            let limit = max(25, areaRadius - profile.clearance * 2)
            if simd_length(radial) > limit { candidate = origin + simd_normalize(radial) * limit }
            goal = candidate
        }
        let safeGoal = goal ?? position
        let surfaceY = state.position.y
        let waypoint = navigation.waypoint(position: position, goal: safeGoal, clearance: profile.clearance,
            deltaTime: dt, obstacles: field.navigationObstacles, obstacleIndex: field.index, traversable: { p in
                guard simd_distance(p, origin) < areaRadius - self.profile.clearance else { return false }
                let h = ground(SIMD3<Float>(p.x, surfaceY, p.y), 0.35)
                return h.isFinite && abs(h - surfaceY) < 5
            })
        let direction = (waypoint ?? position) - position
        let desiredYaw = simd_length(direction) > 0.1 ? atan2(-direction.x, -direction.y) : yaw
        var error = Self.angle(desiredYaw - yaw)
        reverseTimer = max(0, reverseTimer - dt)
        let canDrive = !damage.functionalState.isTerminal
        let mu = max(0.12, profile.tyreFriction * max(0.2, grip) * max(0.15, damage.wheelFactor))
        let throttleAcceleration = profile.acceleration * damage.powerFactor * max(0.3, damage.wheelFactor)
        let brakeAcceleration = min(profile.brakeDeceleration * max(0.15, damage.brakeFactor), mu * 9.81)
        let needsTravel = simd_distance(safeGoal, position) > 2
        var desiredSpeed = canDrive && waypoint != nil ? profile.maxSpeed * max(0.15, damage.powerFactor) : 0
        desiredSpeed *= max(0.12, cos(min(abs(error), .pi / 2)))
        if let destination {
            let range = simd_distance(destination, position)
            desiredSpeed = min(desiredSpeed, range * 0.7, sqrt(2 * brakeAcceleration * max(0, range - 1)))
        }
        if !needsTravel || (abs(error) > 2.2 && speed > 1) { desiredSpeed = 0 }
        if canDrive, simd_distance(safeGoal, position) > 12, abs(speed) < 0.4 { stuckTimer += dt }
        else { stuckTimer = 0 }
        if (stuckTimer > 2.2 || (abs(error) > 2.2 && abs(speed) < 1)), reverseTimer == 0, canDrive, needsTravel {
            reverseTimer = 2; stuckTimer = 0; navigation.reset()
        }
        if reverseTimer > 0 {
            maneuver = .reversing; desiredSpeed = -profile.reverseSpeed
            error = -error
        }
        let lookahead = max(profile.wheelbase * 0.8, min(simd_length(direction), 6 + abs(speed) * 0.65))
        let aim = abs(error) > .pi * 0.85 ? turnSign : sin(error)
        let steeringLimit = profile.maximumSteering * max(0.08, damage.steeringFactor)
        let steeringRange = (damage.steeringBias - steeringLimit)...(damage.steeringBias + steeringLimit)
        let requestedSteering = max(-profile.maximumSteering, min(profile.maximumSteering,
            atan(2 * profile.wheelbase * aim / lookahead))) * max(0.08, damage.steeringFactor) + damage.steeringBias
        let curveSpeed = sqrt(mu * 9.81 / max(0.002, abs(tan(requestedSteering) / profile.wheelbase))) * 0.82
        desiredSpeed = max(-curveSpeed, min(curveSpeed, desiredSpeed))
        safetyCountdown -= dt
        if safetyCommand == nil || safetyCountdown <= 0 ||
            simd_distance(safetyWaypoint, waypoint ?? position) > 1 || (safetyCommand!.speed < 0) != (desiredSpeed < 0) {
            safetyCommand = canDrive ? GroundVehicleDrivingSafety.command(
                preferred: .init(speed: desiredSpeed, steering: requestedSteering), position: state.position,
                yaw: yaw, speed: speed, lateralSpeed: lateralSpeed, steering: steering, waypoint: waypoint ?? position,
                profile: profile, acceleration: throttleAcceleration, braking: brakeAcceleration, friction: mu,
                steeringRange: steeringRange,
                index: field.index, ground: ground) : .init(speed: 0, steering: requestedSteering)
            safetyCountdown = 0.1; safetyWaypoint = waypoint ?? position
        }
        let safeCommand = safetyCommand!
        desiredSpeed = canDrive ? (desiredSpeed < 0 ? max(desiredSpeed, safeCommand.speed) : min(desiredSpeed, safeCommand.speed)) : 0
        steering += max(-profile.steeringRate * dt, min(profile.steeringRate * dt, safeCommand.steering - steering))
        let curvature = tan(steering) / profile.wheelbase
        let acceleration = abs(desiredSpeed) > abs(speed) && desiredSpeed * speed >= 0
            ? throttleAcceleration : brakeAcceleration
        speed += max(-acceleration * dt, min(acceleration * dt, desiredSpeed - speed))
        let yawRate = max(-mu * 9.81 / max(1, abs(speed)), min(mu * 9.81 / max(1, abs(speed)), speed * curvature))
        yaw = Self.angle(yaw + yawRate * dt)
        lateralSpeed *= exp(-mu * 5 * dt)
        let heading = SIMD3<Float>(-sin(yaw), 0, -cos(yaw))
        let side = SIMD3<Float>(cos(yaw), 0, -sin(yaw))
        var velocity = heading * speed + side * lateralSpeed
        let previous = state
        var next = state.position + velocity * dt
        let floor = ground(next, 0.3)
        if !floor.isFinite || abs(floor - state.position.y) > max(0.22, simd_length(velocity) * dt * 0.38) {
            next = state.position; velocity = .zero; speed = 0; stuckTimer += dt
        } else { next.y = floor }
        let yawQ = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        state.position = next; state.velocity = velocity; state.attitudeQuat = yawQ
        state.orientation = SIMD3<Float>(0, 0, yaw)
        // Shared DroneState stores angular rates as roll, pitch, yaw (not spatial xyz).
        state.angularVelocity = SIMD3<Float>(0, 0, yawRate)
        state.bodyAngularVelocity = state.angularVelocity
        state.motorThrottle = canDrive ? min(1, abs(speed) / profile.maxSpeed + 0.2) : 0
        wheelRoll += Double(speed * dt / profile.wheelRadius)
        collisionCooldown = max(0, collisionCooldown - dt)
        var reports: [ImpactReport] = []
        let contacts = contactProfile
        if let contact = collision.firstSweptVehicleCollision(contactSpheres: contacts.spheres,
            fromPosition: previous.position, toPosition: next,
            fromOrientation: previous.attitudeQuat, toOrientation: yawQ,
            obstacles: field.contactIndex.query(from: previous.position, to: next, margin: contacts.boundingRadius)) {
            let closing = max(0, -simd_dot(velocity, contact.contactNormal))
            state.position = previous.position
            state.velocity = velocity + contact.contactNormal * closing
            speed = simd_dot(state.velocity, heading)
            navigation.reset(); goalTimer = 0
            safetyCountdown = 0
            if closing > 0.3, collisionCooldown == 0 {
                let energy = 0.5 * profile.massKg * closing * closing
                let bodyPoint = simd_act(yawQ.conjugate, contact.contactPoint - state.position)
                damage.impact(energyJ: energy, bodyPoint: bodyPoint, profile: profile)
                reports.append(ImpactReport(componentID: contact.componentID, obstacleID: contact.obstacle.id,
                    obstacleSource: contact.obstacle.source, material: .metalVehicle,
                    acousticSurface: contact.obstacle.resolvedAcousticSurface, vehicleMaterial: .steel,
                    impactEnergyJ: energy, normalClosingSpeed: closing, tangentialSpeed: simd_length(state.velocity),
                    tier: energy > 50_000 ? .criticalImpact : .heavyImpact, damage: [], connectionDamage: [],
                    contactPoint: contact.contactPoint, contactNormal: contact.contactNormal,
                    appliedImpulse: profile.massKg * closing, detachedPartMotions: []))
                collisionCooldown = 0.4
            }
        }
        // Wheel support controls pitch/roll; a roof or a kerb is not an airborne waypoint.
        let frontH = ground(state.position + heading * profile.wheelbase * 0.5, 0.3)
        let rearH = ground(state.position - heading * profile.wheelbase * 0.5, 0.3)
        let leftH = ground(state.position - side * profile.trackWidth * 0.5, 0.3)
        let rightH = ground(state.position + side * profile.trackWidth * 0.5, 0.3)
        let pitch = frontH.isFinite && rearH.isFinite ? atan2(frontH - rearH, profile.wheelbase) : 0
        var roll = leftH.isFinite && rightH.isFinite ? atan2(leftH - rightH, profile.trackWidth) : 0
        roll += yawRate * speed / 9.81 * 0.06 / max(0.3, damage.condition(.suspension))
        if abs(roll) > 0.65 { damage.overturn() }
        if damage.rolledOver {
            roll = .pi * 0.5
            let surface = ground(state.position, 0.3)
            if surface.isFinite { state.position.y = surface + profile.size.x * 0.5 }
        }
        state.attitudeQuat = yawQ * simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
            * simd_quatf(angle: roll, axis: SIMD3<Float>(0, 0, 1))
        state.orientation = SIMD3<Float>(roll, pitch, yaw)
        syncCondition()
        if abs(speed) < 0.15, reverseTimer == 0 { maneuver = .stopped }
        return reports
    }

    private func syncCondition() {
        switch damage.functionalState {
        case .nominal: state.damageCondition = .nominal
        case .damaged: state.damageCondition = .degraded
        case .degraded: state.damageCondition = .critical
        case .destroyed: state.damageCondition = .destroyed
        default: state.damageCondition = .uncontrolled
        }
        state.controlState = damage.functionalState.isTerminal ? .none : .full
        state.armState = damage.functionalState.isTerminal ? .disarmed : .armed
        state.motionState = simd_length(state.velocity) > 0.15 ? .rolling : .settled
        state.physicalState = .landed
        syncEffects()
    }

    /// Damage effects have a simulation clock and a finite aftermath. The scene and recorder
    /// consume the same effects, so a burning car cannot turn into a clean chassis in a replay.
    private func syncEffects() {
        effects.removeAll { worldTime >= $0.startedAt + $0.lifetime }
        let liveIDs = Set(effects.map(\.id))
        effectAnchors = effectAnchors.filter { liveIDs.contains($0.key) }
        let firePoint = damage.firePoint ?? GroundVehiclePart.engine.position(in: profile)
        let anchor = firePoint + SIMD3<Float>(0, 0.45, 0)
        if damage.burning {
            if burnStartedAt == nil { burnStartedAt = worldTime }
            emitEffect("fire", kind: .fire, lifetime: 70, scale: 2.4, anchor: anchor)
            emitEffect("burn-smoke", kind: .smoke, lifetime: 100, scale: 2.6, anchor: anchor)
        } else if damage.powerFactor < 0.35 {
            emitEffect("engine-smoke", kind: .smoke, lifetime: 18, scale: 1.2, anchor: anchor)
        }
        effects = effects.map { effect in
            let position = state.position + simd_act(state.attitudeQuat, effectAnchors[effect.id] ?? anchor)
            return InterceptWorldEffect(id: effect.id, runID: effect.runID, impactID: effect.impactID,
                vehicleID: effect.vehicleID, kind: effect.kind, position: position,
                normal: effect.normal, startedAt: effect.startedAt, lifetime: effect.lifetime, scale: effect.scale)
        }
    }

    private func emitEffect(_ key: String, kind: InterceptEffectKind, lifetime: TimeInterval,
                            scale: Float, anchor: SIMD3<Float>) {
        guard effects.count < 18, emittedEffects.insert(key).inserted else { return }
        let id = UUID()
        effectAnchors[id] = anchor
        effects.append(InterceptWorldEffect(id: id, runID: effectRunID, impactID: UUID(),
            vehicleID: vehicleID, kind: kind, position: state.position + simd_act(state.attitudeQuat, anchor),
            startedAt: worldTime, lifetime: lifetime, scale: scale))
    }

    static func angle(_ a: Float) -> Float { atan2(sin(a), cos(a)) }

    static func surfaceGrip(_ weather: WeatherModel) -> Float {
        switch weather.preset {
        case .rain, .thunderstorm: return 1 - weather.normalizedIntensity * 0.4
        case .snow: return 1 - weather.normalizedIntensity * 0.65
        default: return 1
        }
    }
}
