import Foundation
import simd

// MARK: - Materials

struct ImpactSurfaceMaterial: Hashable {
    let restitution: Float
    let friction: Float
    let damageFactor: Float
    let isFoliage: Bool

    static let hardStructure = ImpactSurfaceMaterial(restitution: 0.30, friction: 0.60, damageFactor: 1.15, isFoliage: false)
    static let metalVehicle = ImpactSurfaceMaterial(restitution: 0.30, friction: 0.50, damageFactor: 1.10, isFoliage: false)
    static let woodTrunk = ImpactSurfaceMaterial(restitution: 0.25, friction: 0.50, damageFactor: 1.00, isFoliage: false)
    static let foliage = ImpactSurfaceMaterial(restitution: 0.00, friction: 0.10, damageFactor: 0.25, isFoliage: true)
    static let soil = ImpactSurfaceMaterial(restitution: 0.18, friction: 0.70, damageFactor: 0.85, isFoliage: false)
    static let generic = ImpactSurfaceMaterial(restitution: 0.25, friction: 0.60, damageFactor: 1.00, isFoliage: false)
}

// MARK: - Report

enum ImpactOutcomeTier: String {
    /// Trajectory deflection, no damage.
    case lightTouch
    /// Scratches/scuffs — minor integrity loss.
    case scrape
    /// Component efficiency visibly reduced.
    case heavyImpact
    /// Component destroyed (integrity -> 0 possible).
    case criticalImpact
}

struct ImpactReport {
    let componentID: String
    let obstacleSource: String?
    let material: ImpactSurfaceMaterial
    let impactEnergyJ: Float
    let normalClosingSpeed: Float
    let tier: ImpactOutcomeTier
    let damage: [VehicleComponentGraph.ImpactDamageEntry]
    let contactPoint: SIMD3<Float>
    let contactNormal: SIMD3<Float>
    let appliedImpulse: Float
}

// MARK: - Service

/// Rigid-body impact resolution replacing the legacy "teleport to contact,
/// zero the velocity, flatten the attitude" collision response: a proper
/// contact impulse with lever arm (linear + angular response), tangential
/// friction, material-dependent restitution, and *localized* damage applied
/// to the struck component and its neighbors — never uniformly to the whole
/// airframe.
final class ImpactResolutionService {

    // MARK: Material lookup

    /// Material by obstacle source string. Tree obstacles are composite:
    /// contact low on the cylinder or close to its axis is trunk wood,
    /// everything else is canopy foliage.
    static func material(
        forObstacleSource source: String?,
        obstacle: CollisionObstacle?,
        contactPoint: SIMD3<Float>
    ) -> ImpactSurfaceMaterial {
        guard let source = source?.lowercased() else {
            return .generic
        }

        if source.contains("tree") {
            guard let obstacle else { return .woodTrunk }
            let height = max(0.1, obstacle.topY - obstacle.baseY)
            let heightFraction = (contactPoint.y - obstacle.baseY) / height
            let planarDistance = simd_distance(
                SIMD2<Float>(contactPoint.x, contactPoint.z),
                obstacle.planarCenter
            )
            let isTrunk = heightFraction < 0.35 || planarDistance < obstacle.radius * 0.30
            return isTrunk ? .woodTrunk : .foliage
        }
        if source.contains("container") || source.contains("building") ||
            source.contains("wall") || source.contains("concrete") ||
            source.contains("crate") || source.contains("structure") {
            return .hardStructure
        }
        if source.contains("truck") || source.contains("vehicle") || source.contains("metal") {
            return .metalVehicle
        }
        if source.contains("ground") || source.contains("terrain") || source.contains("soil") {
            return .soil
        }
        return .generic
    }

    // MARK: Impact resolution

    /// Resolves a swept contact in place: applies the contact impulse (and
    /// friction) to the state's linear/angular velocity, moves the vehicle to
    /// its pose at the hit fraction plus a small separation, and applies
    /// localized damage to the graph. Returns the report for HUD/log/failure
    /// consumers.
    func resolve(
        contact: VehicleSweptContact,
        previousPosition: SIMD3<Float>,
        state: inout DroneState,
        graph: inout VehicleComponentGraph,
        massProperties: VehicleMassProperties,
        airframeClass: AirframeClass,
        rotorsSpinning: Bool,
        deltaTime: Float,
        applyDamage: Bool = true
    ) -> ImpactReport {
        let material = Self.material(
            forObstacleSource: contact.obstacle.source,
            obstacle: contact.obstacle,
            contactPoint: contact.contactPoint
        )

        if material.isFoliage {
            return resolveFoliageContact(
                contact: contact,
                material: material,
                state: &state,
                graph: &graph,
                rotorsSpinning: rotorsSpinning,
                deltaTime: deltaTime,
                applyDamage: applyDamage
            )
        }

        let orientation = attitudeQuaternion(state: state, airframeClass: airframeClass)
        let normal = simd_normalize(contact.contactNormal)
        let mass = max(0.2, massProperties.totalMassKg)

        // Contact kinematics are evaluated before touching the position so a
        // resting/tangential contact (a parked aircraft brushing a wall, a
        // gear sphere kissing a container roof at zero approach speed) does
        // NOT get shoved around every tick.
        let worldCoM = state.position + simd_act(orientation, massProperties.centerOfMassOffset)
        let leverArm = contact.contactPoint - worldCoM
        let omegaWorld = worldAngularVelocity(state: state, orientation: orientation, airframeClass: airframeClass)
        let contactVelocity = state.velocity + simd_cross(omegaWorld, leverArm)
        let normalClosingSpeed = -simd_dot(contactVelocity, normal)

        guard normalClosingSpeed > 0.01 else {
            // Receding or tangential contact: nothing to bounce off. If the
            // sweep started already penetrating (hitFraction ~ 0) AND the
            // vehicle is actually moving, bleed out of the surface gently
            // instead of allowing a slow burrow. A resting body is left
            // alone — the per-tick nudge would read as creeping/fidgeting.
            if contact.hitFraction <= 0.001, simd_length(state.velocity) > 0.1 {
                state.position += normal * min(0.004, max(0.001, contact.sphereRadius * 0.02))
            }
            return ImpactReport(
                componentID: contact.componentID,
                obstacleSource: contact.obstacle.source,
                material: material,
                impactEnergyJ: 0.0,
                normalClosingSpeed: max(0.0, normalClosingSpeed),
                tier: .lightTouch,
                damage: [],
                contactPoint: contact.contactPoint,
                contactNormal: normal,
                appliedImpulse: 0.0
            )
        }

        // Stop the vehicle at its pose along the step where contact happened
        // (its own path — not a jump to some other point), with a small
        // normal separation so the next tick doesn't immediately re-collide.
        let separation = max(0.005, contact.sphereRadius * 0.04)
        let travel: SIMD3<Float> = state.position - previousPosition
        let poseAtHit: SIMD3<Float> = previousPosition + travel * contact.hitFraction
        state.position = poseAtHit + normal * separation

        // Effective mass along the contact normal: 1/K with the standard
        // K = 1/m + n·((I⁻¹(r×n))×r). Glancing hits far from the CoM see a
        // much smaller effective mass — they spin the airframe instead of
        // stopping it.
        let angularTermNormal = angularResponse(
            leverArm: leverArm,
            direction: normal,
            orientation: orientation,
            inertiaDiagonal: massProperties.inertiaDiagonal
        )
        let kNormal = 1.0 / mass + simd_dot(angularTermNormal.velocityAtContact, normal)
        let effectiveMass = 1.0 / max(0.0001, kNormal)

        let impulseMagnitude = (1.0 + material.restitution) * normalClosingSpeed * effectiveMass
        state.velocity += normal * (impulseMagnitude / mass)
        var deltaOmegaWorld = angularTermNormal.omegaPerUnitImpulse * impulseMagnitude

        // Coulomb-ish friction impulse against the tangential contact velocity.
        let tangentialVelocity = contactVelocity + normal * normalClosingSpeed
        let tangentialSpeed = simd_length(tangentialVelocity)
        if tangentialSpeed > 0.05 {
            let tangent = tangentialVelocity / tangentialSpeed
            let angularTermTangent = angularResponse(
                leverArm: leverArm,
                direction: tangent,
                orientation: orientation,
                inertiaDiagonal: massProperties.inertiaDiagonal
            )
            let kTangent = 1.0 / mass + simd_dot(angularTermTangent.velocityAtContact, tangent)
            let stoppingImpulse = tangentialSpeed / max(0.0001, kTangent)
            let frictionImpulse = min(material.friction * impulseMagnitude, stoppingImpulse)
            state.velocity -= tangent * (frictionImpulse / mass)
            deltaOmegaWorld -= angularTermTangent.omegaPerUnitImpulse * frictionImpulse
        }

        applyWorldAngularDelta(
            deltaOmegaWorld,
            state: &state,
            orientation: orientation,
            airframeClass: airframeClass
        )

        // Localized damage from the energy the contact actually absorbed.
        let impactEnergy = 0.5 * effectiveMass * normalClosingSpeed * normalClosingSpeed
        let primaryStrength = max(0.5, graph.component(id: contact.componentID)?.strengthJ ?? 40.0)
        var damageFactor = material.damageFactor
        if rotorsSpinning, isPropellerComponent(contact.componentID, graph: graph) {
            // A spinning blade striking anything sheds far more of itself
            // than a static one.
            damageFactor *= 1.6
        }
        let energyRatio = impactEnergy * damageFactor / primaryStrength

        let tier: ImpactOutcomeTier
        switch energyRatio {
        case ..<0.05: tier = .lightTouch
        case ..<0.30: tier = .scrape
        case ..<1.00: tier = .heavyImpact
        default: tier = .criticalImpact
        }

        var damage: [VehicleComponentGraph.ImpactDamageEntry] = []
        if tier != .lightTouch, applyDamage {
            let contactBody = simd_act(orientation.conjugate, contact.contactPoint - state.position)
            let primaryID = nearestComponentID(
                to: contactBody,
                preferred: contact.componentID,
                graph: graph
            )
            let spreadRadius = 0.15 + 0.45 * min(1.0, energyRatio)
            damage = graph.applyImpact(
                primaryComponentID: primaryID,
                energyJ: impactEnergy,
                damageFactor: damageFactor,
                spreadRadius: spreadRadius
            )
        }

        return ImpactReport(
            componentID: contact.componentID,
            obstacleSource: contact.obstacle.source,
            material: material,
            impactEnergyJ: impactEnergy,
            normalClosingSpeed: normalClosingSpeed,
            tier: tier,
            damage: damage,
            contactPoint: contact.contactPoint,
            contactNormal: normal,
            appliedImpulse: impulseMagnitude
        )
    }

    /// Static-penetration variant for contacts the sweep didn't catch (slow
    /// push into a wall detected by the analyzer): positional push-out along
    /// the normal plus the same impulse/damage math, driven by the current
    /// velocity instead of a swept hit.
    func resolvePenetration(
        penetrationDepth: Float,
        contactNormal: SIMD3<Float>,
        contactPoint: SIMD3<Float>,
        obstacle: CollisionObstacle,
        componentID: String,
        sphereRadius: Float,
        state: inout DroneState,
        graph: inout VehicleComponentGraph,
        massProperties: VehicleMassProperties,
        airframeClass: AirframeClass,
        rotorsSpinning: Bool,
        deltaTime: Float,
        applyDamage: Bool = true
    ) -> ImpactReport {
        let normal = simd_normalize(contactNormal)
        state.position += normal * (max(0.0, penetrationDepth) + max(0.005, sphereRadius * 0.04))

        let syntheticContact = VehicleSweptContact(
            obstacle: obstacle,
            componentID: componentID,
            contactPoint: contactPoint,
            contactNormal: normal,
            hitFraction: 1.0,
            isSupportSurfaceContact: false,
            sphereOffset: .zero,
            sphereRadius: sphereRadius
        )
        return resolve(
            contact: syntheticContact,
            previousPosition: state.position,
            state: &state,
            graph: &graph,
            massProperties: massProperties,
            airframeClass: airframeClass,
            rotorsSpinning: rotorsSpinning,
            deltaTime: deltaTime,
            applyDamage: applyDamage
        )
    }

    // MARK: Foliage

    /// Canopy contact: no rigid bounce — viscous drag through the branches
    /// plus light propeller damage. The aircraft keeps flying through. The
    /// contact fires every tick while inside the crown, so the damping must
    /// be dt-scaled (a per-invocation constant factor would stop the
    /// aircraft dead within a handful of frames).
    private func resolveFoliageContact(
        contact: VehicleSweptContact,
        material: ImpactSurfaceMaterial,
        state: inout DroneState,
        graph: inout VehicleComponentGraph,
        rotorsSpinning: Bool,
        deltaTime: Float,
        applyDamage: Bool
    ) -> ImpactReport {
        let speed = simd_length(state.velocity)
        let velocityDamping = exp(-2.8 * max(0.0, deltaTime))
        let angularDamping = exp(-1.6 * max(0.0, deltaTime))
        state.velocity *= velocityDamping
        state.angularVelocity *= angularDamping
        state.bodyAngularVelocity *= angularDamping

        var damage: [VehicleComponentGraph.ImpactDamageEntry] = []
        if applyDamage, rotorsSpinning, speed > 1.0 {
            // Spinning blades chew through leaves and take chips doing it.
            let energy = 0.5 * speed * speed * 0.05
            damage = graph.applyImpact(
                primaryComponentID: contact.componentID,
                energyJ: energy,
                damageFactor: material.damageFactor,
                spreadRadius: 0.10
            )
        }

        return ImpactReport(
            componentID: contact.componentID,
            obstacleSource: contact.obstacle.source,
            material: material,
            impactEnergyJ: 0.0,
            normalClosingSpeed: speed,
            tier: damage.isEmpty ? .lightTouch : .scrape,
            damage: damage,
            contactPoint: contact.contactPoint,
            contactNormal: contact.contactNormal,
            appliedImpulse: 0.0
        )
    }

    // MARK: Frame math

    private struct AngularResponse {
        /// I⁻¹(r×d) in world frame — angular velocity change per unit impulse.
        let omegaPerUnitImpulse: SIMD3<Float>
        /// (I⁻¹(r×d))×r — the contact-point velocity contribution term.
        let velocityAtContact: SIMD3<Float>
    }

    private func angularResponse(
        leverArm: SIMD3<Float>,
        direction: SIMD3<Float>,
        orientation: simd_quatf,
        inertiaDiagonal: SIMD3<Float>
    ) -> AngularResponse {
        let torquePerImpulse = simd_cross(leverArm, direction)
        // World -> body axes, divide by diagonal inertia, back to world.
        let torqueBody = simd_act(orientation.conjugate, torquePerImpulse)
        let inertia = simd_max(inertiaDiagonal, SIMD3<Float>(repeating: 0.0005))
        let omegaBody = torqueBody / inertia
        let omegaWorld = simd_act(orientation, omegaBody)
        return AngularResponse(
            omegaPerUnitImpulse: omegaWorld,
            velocityAtContact: simd_cross(omegaWorld, leverArm)
        )
    }

    private func attitudeQuaternion(state: DroneState, airframeClass: AirframeClass) -> simd_quatf {
        switch airframeClass {
        case .fixedWing, .hybridVTOL:
            return state.fixedWingOrientationQuat
        case .multirotor:
            return orientationQuaternion(from: state.orientation)
        }
    }

    /// This codebase labels rates in (roll, pitch, yaw) component order with
    /// roll about body Z, pitch about body X, yaw about body Y (see the
    /// gyroscopic-precession note in SimpleDronePhysicsEngine). Standard
    /// (X,Y,Z) axis vector = (rates.y, rates.z, rates.x); inverse mapping
    /// axes -> rates = (axes.z, axes.x, axes.y).
    private func worldAngularVelocity(
        state: DroneState,
        orientation: simd_quatf,
        airframeClass: AirframeClass
    ) -> SIMD3<Float> {
        let rates: SIMD3<Float>
        switch airframeClass {
        case .fixedWing, .hybridVTOL:
            rates = state.bodyAngularVelocity
        case .multirotor:
            rates = state.angularVelocity
        }
        let axesVector = SIMD3<Float>(rates.y, rates.z, rates.x)
        return simd_act(orientation, axesVector)
    }

    private func applyWorldAngularDelta(
        _ deltaOmegaWorld: SIMD3<Float>,
        state: inout DroneState,
        orientation: simd_quatf,
        airframeClass: AirframeClass
    ) {
        let axesBody = simd_act(orientation.conjugate, deltaOmegaWorld)
        let ratesDelta = SIMD3<Float>(axesBody.z, axesBody.x, axesBody.y)
        switch airframeClass {
        case .fixedWing, .hybridVTOL:
            state.bodyAngularVelocity = clampMagnitude(state.bodyAngularVelocity + ratesDelta, limit: 10.0)
            state.angularVelocity = state.bodyAngularVelocity
        case .multirotor:
            state.angularVelocity = clampMagnitude(state.angularVelocity + ratesDelta, limit: 9.0)
        }
    }

    private func isPropellerComponent(_ id: String, graph: VehicleComponentGraph) -> Bool {
        guard let component = graph.component(id: id) else { return false }
        if case .propeller = component.kind { return true }
        return false
    }

    /// The sweep's provenance is the sphere's owner, but a big body sphere
    /// can strike with, say, its wingtip edge — refine to the structurally
    /// nearest component around the actual body-frame contact point.
    private func nearestComponentID(
        to bodyPoint: SIMD3<Float>,
        preferred: String,
        graph: VehicleComponentGraph
    ) -> String {
        let candidates = graph.components(within: 0.05, of: bodyPoint)
        let structural = candidates.first(where: { $0.kind.isStructural })
        return structural?.id ?? preferred
    }

    private func orientationQuaternion(from euler: SIMD3<Float>) -> simd_quatf {
        let yaw = simd_quatf(angle: euler.z, axis: SIMD3<Float>(0.0, 1.0, 0.0))
        let pitch = simd_quatf(angle: euler.y, axis: SIMD3<Float>(1.0, 0.0, 0.0))
        let roll = simd_quatf(angle: euler.x, axis: SIMD3<Float>(0.0, 0.0, 1.0))
        return yaw * pitch * roll
    }

    private func clampMagnitude(_ vector: SIMD3<Float>, limit: Float) -> SIMD3<Float> {
        let length = simd_length(vector)
        guard length > limit else {
            return vector
        }
        return simd_normalize(vector) * limit
    }
}
