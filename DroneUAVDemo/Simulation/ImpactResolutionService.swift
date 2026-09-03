import Foundation
import simd

// MARK: - Materials

struct ImpactSurfaceMaterial: Hashable {
    let restitution: Float
    let friction: Float
    let damageFactor: Float
    /// Relative resistance of the contacted surface.  This is kept separate
    /// from restitution: a soft surface can still bounce while absorbing a
    /// large part of the energy.
    let hardness: Float
    let energyAbsorption: Float
    let cuttingFactor: Float
    let abrasionFactor: Float
    let isFoliage: Bool

    static let hardStructure = ImpactSurfaceMaterial(restitution: 0.30, friction: 0.60, damageFactor: 1.15, hardness: 0.95, energyAbsorption: 0.12, cuttingFactor: 0.08, abrasionFactor: 0.75, isFoliage: false)
    static let metalVehicle = ImpactSurfaceMaterial(restitution: 0.30, friction: 0.50, damageFactor: 1.10, hardness: 0.90, energyAbsorption: 0.18, cuttingFactor: 0.15, abrasionFactor: 0.62, isFoliage: false)
    static let asphalt = ImpactSurfaceMaterial(restitution: 0.24, friction: 0.82, damageFactor: 1.10, hardness: 0.90, energyAbsorption: 0.15, cuttingFactor: 0.03, abrasionFactor: 1.00, isFoliage: false)
    static let glass = ImpactSurfaceMaterial(restitution: 0.12, friction: 0.35, damageFactor: 0.88, hardness: 0.72, energyAbsorption: 0.42, cuttingFactor: 0.90, abrasionFactor: 0.55, isFoliage: false)
    static let woodTrunk = ImpactSurfaceMaterial(restitution: 0.25, friction: 0.50, damageFactor: 1.00, hardness: 0.68, energyAbsorption: 0.30, cuttingFactor: 0.42, abrasionFactor: 0.48, isFoliage: false)
    static let foliage = ImpactSurfaceMaterial(restitution: 0.00, friction: 0.10, damageFactor: 0.00, hardness: 0.02, energyAbsorption: 0.95, cuttingFactor: 0.00, abrasionFactor: 0.00, isFoliage: true)
    static let soil = ImpactSurfaceMaterial(restitution: 0.18, friction: 0.70, damageFactor: 0.85, hardness: 0.45, energyAbsorption: 0.55, cuttingFactor: 0.00, abrasionFactor: 0.58, isFoliage: false)
    static let sand = ImpactSurfaceMaterial(restitution: 0.05, friction: 0.72, damageFactor: 0.55, hardness: 0.18, energyAbsorption: 0.82, cuttingFactor: 0.00, abrasionFactor: 0.78, isFoliage: false)
    static let snow = ImpactSurfaceMaterial(restitution: 0.03, friction: 0.34, damageFactor: 0.32, hardness: 0.08, energyAbsorption: 0.90, cuttingFactor: 0.00, abrasionFactor: 0.15, isFoliage: false)
    static let water = ImpactSurfaceMaterial(restitution: 0.02, friction: 0.08, damageFactor: 0.62, hardness: 0.12, energyAbsorption: 0.78, cuttingFactor: 0.00, abrasionFactor: 0.04, isFoliage: false)
    static let generic = ImpactSurfaceMaterial(restitution: 0.25, friction: 0.60, damageFactor: 1.00, hardness: 0.70, energyAbsorption: 0.30, cuttingFactor: 0.05, abrasionFactor: 0.55, isFoliage: false)
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
    let obstacleID: UUID
    let obstacleSource: String?
    let material: ImpactSurfaceMaterial
    /// What was struck, acoustically. Separate from `material`, which describes behaviour
    /// rather than sound — see `AcousticSurfaceMaterial`.
    let acousticSurface: AcousticSurfaceMaterial
    /// What struck it. The same wall is a different noise against a plastic cover and a steel
    /// motor, and a resolver given only one side of the contact cannot say which.
    let vehicleMaterial: VehicleAcousticMaterial
    let impactEnergyJ: Float
    let normalClosingSpeed: Float
    /// Sliding speed in the contact plane, m/s.
    ///
    /// The solver has always computed this — it is what the friction impulse is built from —
    /// and never published it, which is why nothing downstream could tell a hit from a hit
    /// that turns into a slide. A scrape needs exactly this number.
    let tangentialSpeed: Float
    let tier: ImpactOutcomeTier
    let damage: [VehicleComponentGraph.ImpactDamageEntry]
    let connectionDamage: [VehicleComponentGraph.ConnectionDamageEntry]
    let contactPoint: SIMD3<Float>
    let contactNormal: SIMD3<Float>
    let appliedImpulse: Float
    /// Explicit post-fracture motion for subtrees hit during this contact.
    /// The main airframe receives only the reaction transmitted through the
    /// failed joint; the remainder of the obstacle impulse stays with the
    /// separating part.
    let detachedPartMotions: [ImpactDetachedPartMotion]
}

struct ImpactDetachedPartMotion: Hashable {
    let rootComponentID: String
    let centerOfMassVelocityWorld: SIMD3<Float>
    let angularVelocityWorld: SIMD3<Float>
    let obstacleImpulseWorld: SIMD3<Float>
    let transmittedJointImpulseWorld: SIMD3<Float>
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

        if source.contains("trunk") || source.contains("branch") {
            return .woodTrunk
        }
        if source.contains("canopy") || source.contains("foliage") || source.contains("leaves") {
            return .foliage
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
        if source.contains("glass") || source.contains("window") {
            return .glass
        }
        if source.contains("container") || source.contains("building") ||
            source.contains("wall") || source.contains("concrete") ||
            source.contains("crate") || source.contains("structure") {
            return .hardStructure
        }
        if source.contains("truck") || source.contains("vehicle") || source.contains("metal") {
            return .metalVehicle
        }
        if source.contains("asphalt") || source.contains("runway") || source.contains("road") {
            return .asphalt
        }
        if source.contains("sand") {
            return .sand
        }
        if source.contains("snow") || source.contains("ice") {
            return .snow
        }
        if source.contains("water") || source.contains("river") || source.contains("lake") {
            return .water
        }
        if source.contains("ground") || source.contains("terrain") || source.contains("soil") {
            return .soil
        }
        return .generic
    }

    /// What the struck surface sounds like.
    ///
    /// The obstacle's own declaration wins, because whoever built it knew. Only when nothing
    /// was declared does this fall back — first to the physical material the collision solver
    /// already resolved, which is a better guess than a second independent keyword match, and
    /// then to the provenance string.
    ///
    /// The tree case is the one place the two resolutions must agree rather than merely
    /// coexist: `material(forObstacleSource:)` decides trunk-versus-canopy from where on the
    /// cylinder the contact landed, and an acoustic classifier that re-derived that from the
    /// name alone would put a canopy brush and a trunk strike in the same bucket.
    static func acousticSurface(
        for obstacle: CollisionObstacle,
        contactPoint: SIMD3<Float>,
        physicalMaterial: ImpactSurfaceMaterial
    ) -> AcousticSurfaceMaterial {
        if let declared = obstacle.acousticSurface { return declared }

        switch physicalMaterial {
        case .foliage:
            return .foliage
        case .woodTrunk:
            return .treeTrunk
        case .glass:
            return .glass
        case .asphalt:
            return .asphalt
        case .metalVehicle:
            return .metal
        case .water:
            return .water
        case .snow:
            return .snow
        case .sand, .soil:
            // Sand and soil differ in how much they absorb, which the physics cares about,
            // and hardly at all in the dull thump they make.
            return .soil
        case .hardStructure, .generic:
            // A hard structure could be masonry, a shipping container or a crate. This is
            // where the name is genuinely the only evidence.
            return AcousticSurfaceMaterial.fromObstacleSource(obstacle.source)
        default:
            return AcousticSurfaceMaterial.fromObstacleSource(obstacle.source)
        }
    }

    /// What the part that made contact is made of.
    static func vehicleMaterial(
        componentID: String,
        graph: VehicleComponentGraph,
        skin: UAVSkinMaterial
    ) -> VehicleAcousticMaterial {
        guard let component = graph.component(id: componentID) else {
            return VehicleAcousticMaterial.fromSkin(skin)
        }
        return VehicleAcousticMaterial.resolve(componentKind: component.kind, skin: skin)
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
        bodyOriginWorldOffset: SIMD3<Float> = .zero,
        rotorsSpinning: Bool,
        deltaTime: Float,
        applyDamage: Bool = true,
        restingSpeedThreshold: Float = 0.01,
        /// What the airframe's structure is made of. Defaulted so callers that do not care
        /// about sound — the headless contact probes — are unaffected.
        skinMaterial: UAVSkinMaterial = .aluminium
    ) -> ImpactReport {
        let material = Self.material(
            forObstacleSource: contact.obstacle.source,
            obstacle: contact.obstacle,
            contactPoint: contact.contactPoint
        )
        let acousticSurface = Self.acousticSurface(
            for: contact.obstacle,
            contactPoint: contact.contactPoint,
            physicalMaterial: material
        )

        if material.isFoliage {
            return resolveFoliageContact(
                contact: contact,
                material: material,
                acousticSurface: acousticSurface,
                skinMaterial: skinMaterial,
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
        let travel: SIMD3<Float> = state.position - previousPosition
        let statePositionAtHit: SIMD3<Float> = previousPosition + travel * contact.hitFraction
        let bodyOriginAtHit = statePositionAtHit + bodyOriginWorldOffset
        let contactBodyAtHit = simd_act(
            orientation.conjugate,
            contact.contactPoint - bodyOriginAtHit
        )
        let resolvedComponentID = nearestComponentID(
            to: contactBodyAtHit,
            preferred: contact.componentID,
            graph: graph
        )

        // Contact kinematics are evaluated before touching the position so a
        // resting/tangential contact (a parked aircraft brushing a wall, a
        // gear sphere kissing a container roof at zero approach speed) does
        // NOT get shoved around every tick.
        let worldCoM = bodyOriginAtHit + simd_act(orientation, massProperties.centerOfMassOffset)
        let leverArm = contact.contactPoint - worldCoM
        let omegaWorld = worldAngularVelocity(state: state, orientation: orientation, airframeClass: airframeClass)
        let incomingLinearVelocity = state.velocity
        let failedRootsBeforeImpact = Set(graph.failedConnectionRootIDs)
        let contactVelocity = state.velocity + simd_cross(omegaWorld, leverArm)
        let normalClosingSpeed = -simd_dot(contactVelocity, normal)

        guard normalClosingSpeed > restingSpeedThreshold else {
            // Receding, tangential, or (for an uncontrolled/crashed body, whose caller raises
            // restingSpeedThreshold above the live-flight default) a settled resting contact:
            // nothing to bounce off. If the
            // sweep started already penetrating (hitFraction ~ 0) AND the
            // vehicle is actually moving, bleed out of the surface gently
            // instead of allowing a slow burrow. A resting body is left
            // alone — the per-tick nudge would read as creeping/fidgeting.
            if contact.hitFraction <= 0.001, simd_length(state.velocity) > 0.1 {
                state.position += normal * min(0.004, max(0.001, contact.sphereRadius * 0.02))
            }
            // A contact with no approach speed is very often a *slide* — a wreck skidding
            // along a runway, a gear leg dragging across a roof — so the tangential speed is
            // reported here too. Returning zero would silence exactly the case scrape exists
            // for.
            let restingTangentialSpeed = simd_length(contactVelocity + normal * normalClosingSpeed)
            return ImpactReport(
                componentID: contact.componentID,
                obstacleID: contact.obstacle.id,
                obstacleSource: contact.obstacle.source,
                material: material,
                acousticSurface: acousticSurface,
                vehicleMaterial: Self.vehicleMaterial(
                    componentID: contact.componentID,
                    graph: graph,
                    skin: skinMaterial
                ),
                impactEnergyJ: 0.0,
                normalClosingSpeed: max(0.0, normalClosingSpeed),
                tangentialSpeed: restingTangentialSpeed,
                tier: .lightTouch,
                damage: [],
                connectionDamage: [],
                contactPoint: contact.contactPoint,
                contactNormal: normal,
                appliedImpulse: 0.0,
                detachedPartMotions: []
            )
        }

        // Stop the vehicle at its pose along the step where contact happened
        // (its own path — not a jump to some other point), with a small
        // normal separation so the next tick doesn't immediately re-collide.
        let separation = max(0.005, contact.sphereRadius * 0.04)
        state.position = statePositionAtHit + normal * separation

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

        let candidateNormalImpulse = (1.0 + material.restitution) * normalClosingSpeed * effectiveMass

        // Coulomb-ish friction impulse against the tangential contact velocity.
        let tangentialVelocity = contactVelocity + normal * normalClosingSpeed
        let tangentialSpeed = simd_length(tangentialVelocity)
        var tangent = SIMD3<Float>(repeating: 0.0)
        var candidateFrictionImpulse: Float = 0.0
        if tangentialSpeed > 0.05 {
            tangent = tangentialVelocity / tangentialSpeed
            let angularTermTangent = angularResponse(
                leverArm: leverArm,
                direction: tangent,
                orientation: orientation,
                inertiaDiagonal: massProperties.inertiaDiagonal
            )
            let kTangent = 1.0 / mass + simd_dot(angularTermTangent.velocityAtContact, tangent)
            let stoppingImpulse = tangentialSpeed / max(0.0001, kTangent)
            candidateFrictionImpulse = min(material.friction * candidateNormalImpulse, stoppingImpulse)
        }

        // Localized damage from the energy the contact actually absorbed.
        let impactEnergy = 0.5 * effectiveMass * normalClosingSpeed * normalClosingSpeed
        let absorption = min(1.0, max(0.0, material.energyAbsorption))
        let transmittedNormalEnergy = impactEnergy * (1.0 - absorption * 0.65)
        let abrasionEnergy = 0.5 * effectiveMass * tangentialSpeed * tangentialSpeed *
            material.abrasionFactor * 0.16
        let damageEnergy = transmittedNormalEnergy + abrasionEnergy
        let primaryStrength = max(0.5, graph.component(id: resolvedComponentID)?.strengthJ ?? 40.0)
        var damageFactor = material.damageFactor
        if rotorsSpinning, isPropellerComponent(resolvedComponentID, graph: graph) {
            // A spinning blade striking anything sheds far more of itself
            // than a static one.
            damageFactor *= 1.6 + material.cuttingFactor * 0.25
        }
        let energyRatio = damageEnergy * damageFactor / primaryStrength

        let tier: ImpactOutcomeTier
        switch energyRatio {
        case ..<0.05: tier = .lightTouch
        case ..<0.30: tier = .scrape
        case ..<1.00: tier = .heavyImpact
        default: tier = .criticalImpact
        }

        var damage: [VehicleComponentGraph.ImpactDamageEntry] = []
        var connectionDamage: [VehicleComponentGraph.ConnectionDamageEntry] = []
        if applyDamage, damageEnergy > 0.0001, damageFactor > 0.0 {
            let spreadRadius = 0.15 + 0.45 * min(1.0, energyRatio)
            damage = graph.applyImpact(
                primaryComponentID: resolvedComponentID,
                energyJ: damageEnergy,
                damageFactor: damageFactor,
                spreadRadius: spreadRadius,
                contactPointBody: contactBodyAtHit
            )
            // Use the intact-body candidate impulse to decide whether the
            // joint can carry the contact. The impulse is not applied to the
            // aircraft until this structural decision is known.
            let impulseBody = simd_act(orientation.conjugate, normal * candidateNormalImpulse)
            connectionDamage = graph.applyConnectionImpact(
                primaryComponentID: resolvedComponentID,
                contactPointBody: contactBodyAtHit,
                impulseBody: impulseBody,
                energyJ: damageEnergy,
                damageFactor: damageFactor * max(0.15, material.hardness),
                contactDuration: max(0.008, min(0.045, deltaTime))
            )
        }

        let newlyFailedRoots = graph.failedConnectionRootIDs.filter {
            !failedRootsBeforeImpact.contains($0)
        }
        let contactDuration = max(0.008, min(0.045, deltaTime))
        var appliedNormalImpulse = candidateNormalImpulse
        var detachedPartMotions: [ImpactDetachedPartMotion] = []

        // A contact that breaks its load path is no longer a collision of the
        // entire intact aircraft. Only the root's finite reaction reaches the
        // retained airframe; the remaining obstacle impulse stays with the
        // separating subtree. This prevents a wing-tip strike from making the
        // fuselage rebound like a single rigid ball.
        if let failedRootID = newlyFailedRoots.first(where: { rootID in
            graph.detachedSubtreePreview(rootComponentID: rootID)?
                .componentIDs.contains(resolvedComponentID) == true
        }),
           let part = graph.detachedSubtreePreview(rootComponentID: failedRootID),
           let rootConnection = graph.connection(childComponentID: failedRootID),
           let rootComponent = graph.component(id: failedRootID),
           let parentComponent = graph.component(id: rootConnection.parentComponentID) {
            // Fracture consumes the restitution part of the candidate impulse:
            // the detached piece may deflect, but the broken assembly does not
            // receive an elastic whole-aircraft rebound.
            let fractureNormalImpulse = candidateNormalImpulse /
                max(1.0, 1.0 + material.restitution)
            let fractureFrictionImpulse = min(
                candidateFrictionImpulse,
                material.friction * fractureNormalImpulse
            )
            let obstacleImpulse = normal * fractureNormalImpulse -
                tangent * fractureFrictionImpulse
            appliedNormalImpulse = fractureNormalImpulse

            let residualBefore = connectionDamage.first {
                $0.childComponentID == failedRootID
            }?.residualStrengthBefore ?? max(0.015, rootConnection.residualStrength)
            let normalBody = simd_act(orientation.conjugate, normal)
            let transmissibleNormalImpulse = min(
                fractureNormalImpulse,
                jointImpulseCapacity(
                    connection: rootConnection,
                    parent: parentComponent,
                    child: rootComponent,
                    contactPointBody: contactBodyAtHit,
                    impulseDirectionBody: normalBody,
                    residualStrength: residualBefore,
                    contactDuration: contactDuration
                )
            )
            let transmissionFraction = (
                transmissibleNormalImpulse / max(0.0001, fractureNormalImpulse)
            )
            let clampedTransmissionFraction = min(1.0, max(0.0, transmissionFraction))
            let transmittedJointImpulse = normal * transmissibleNormalImpulse -
                tangent * (fractureFrictionImpulse * clampedTransmissionFraction)

            let jointBodyPoint = (parentComponent.localPosition + rootComponent.localPosition) * 0.5
            let jointWorldPoint = bodyOriginAtHit + simd_act(orientation, jointBodyPoint)
            let retainedProperties = graph.massProperties(
                excludingComponentIDs: part.componentIDs
            )
            let retainedMass = max(0.2, retainedProperties.totalMassKg)
            let retainedCoMWorld = bodyOriginAtHit + simd_act(
                orientation,
                retainedProperties.centerOfMassOffset
            )
            // `state.velocity` is the CoM velocity in the impact solver. Move
            // it from the old combined CoM to the new retained CoM before
            // applying the limited joint reaction.
            state.velocity = incomingLinearVelocity +
                simd_cross(omegaWorld, retainedCoMWorld - worldCoM) +
                transmittedJointImpulse / retainedMass
            let retainedAngularDelta = angularVelocityDelta(
                leverArm: jointWorldPoint - retainedCoMWorld,
                impulse: transmittedJointImpulse,
                orientation: orientation,
                inertiaDiagonal: retainedProperties.inertiaDiagonal
            )
            applyWorldAngularDelta(
                retainedAngularDelta,
                state: &state,
                orientation: orientation,
                airframeClass: airframeClass
            )

            let partMass = max(0.005, part.massProperties.totalMassKg)
            let partCoMWorld = bodyOriginAtHit + simd_act(
                orientation,
                part.massProperties.centerOfMassOffset
            )
            let partInitialVelocity = incomingLinearVelocity +
                simd_cross(omegaWorld, partCoMWorld - worldCoM)
            let partNetImpulse = obstacleImpulse - transmittedJointImpulse
            let partContactAngularDelta = angularVelocityDelta(
                leverArm: contact.contactPoint - partCoMWorld,
                impulse: obstacleImpulse,
                orientation: orientation,
                inertiaDiagonal: part.massProperties.inertiaDiagonal
            )
            let partJointAngularDelta = angularVelocityDelta(
                leverArm: jointWorldPoint - partCoMWorld,
                impulse: -transmittedJointImpulse,
                orientation: orientation,
                inertiaDiagonal: part.massProperties.inertiaDiagonal
            )
            detachedPartMotions.append(
                ImpactDetachedPartMotion(
                    rootComponentID: failedRootID,
                    centerOfMassVelocityWorld: partInitialVelocity + partNetImpulse / partMass,
                    angularVelocityWorld: clampMagnitude(
                        omegaWorld + partContactAngularDelta + partJointAngularDelta,
                        limit: 35.0
                    ),
                    obstacleImpulseWorld: obstacleImpulse,
                    transmittedJointImpulseWorld: transmittedJointImpulse
                )
            )
        } else {
            let rigidImpulse = normal * candidateNormalImpulse -
                tangent * candidateFrictionImpulse
            state.velocity += rigidImpulse / mass
            let rigidAngularDelta = angularVelocityDelta(
                leverArm: leverArm,
                impulse: rigidImpulse,
                orientation: orientation,
                inertiaDiagonal: massProperties.inertiaDiagonal
            )
            applyWorldAngularDelta(
                rigidAngularDelta,
                state: &state,
                orientation: orientation,
                airframeClass: airframeClass
            )
        }

        return ImpactReport(
            componentID: resolvedComponentID,
            obstacleID: contact.obstacle.id,
            obstacleSource: contact.obstacle.source,
            material: material,
            acousticSurface: acousticSurface,
            vehicleMaterial: Self.vehicleMaterial(
                componentID: resolvedComponentID,
                graph: graph,
                skin: skinMaterial
            ),
            impactEnergyJ: impactEnergy,
            normalClosingSpeed: normalClosingSpeed,
            tangentialSpeed: tangentialSpeed,
            tier: tier,
            damage: damage,
            connectionDamage: connectionDamage,
            contactPoint: contact.contactPoint,
            contactNormal: normal,
            appliedImpulse: appliedNormalImpulse,
            detachedPartMotions: detachedPartMotions
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
        bodyOriginWorldOffset: SIMD3<Float> = .zero,
        rotorsSpinning: Bool,
        deltaTime: Float,
        applyDamage: Bool = true,
        restingSpeedThreshold: Float = 0.01,
        skinMaterial: UAVSkinMaterial = .aluminium
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
            bodyOriginWorldOffset: bodyOriginWorldOffset,
            rotorsSpinning: rotorsSpinning,
            deltaTime: deltaTime,
            applyDamage: applyDamage,
            restingSpeedThreshold: restingSpeedThreshold,
            skinMaterial: skinMaterial
        )
    }

    // MARK: Foliage

    /// Canopy contact: no rigid bounce — viscous drag through the branches, the aircraft keeps
    /// flying through rather than bouncing. The contact fires every tick while inside the crown,
    /// so the damping must be dt-scaled (a per-invocation constant factor would stop the aircraft
    /// dead within a handful of frames).
    ///
    /// Soft leaves alone genuinely shouldn't scratch paint, but "foliage" here is the whole canopy
    /// — twigs and thin branches too, not just leaf mass — and a real branch snags/nicks a
    /// spinning prop or a delicate micro-frame (tinywhoop-class) the way it never bothers a heavy
    /// commercial airframe shrugging through soft leaves. A flat "foliage never damages anything"
    /// rule doesn't capture that asymmetry, so this applies a small, deliberately gentle damage
    /// term — reusing the same `graph.applyImpact`/`strengthJ` math as a real hit, just against a
    /// tiny reference "twig" energy instead of the vehicle's own kinetic energy — so it comes out
    /// automatically fragility-scaled: a light/fragile component takes a real, visible nick, while
    /// the same contact on a heavy/tough one is correctly still negligible. Below a slow walking
    /// pace (`0.6 m/s`) it stays exactly zero either way — gently brushing leaves at a crawl still
    /// shouldn't do anything.
    private func resolveFoliageContact(
        contact: VehicleSweptContact,
        material: ImpactSurfaceMaterial,
        acousticSurface: AcousticSurfaceMaterial,
        skinMaterial: UAVSkinMaterial,
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
        var branchEnergyJ: Float = 0.0
        if applyDamage, speed > 0.6, let target = graph.component(id: contact.componentID) {
            let strikingProp = rotorsSpinning && isPropellerComponent(contact.componentID, graph: graph)
            // ~30g reference "twig" mass — deliberately small next to a rigid-material hit, where
            // the vehicle's own (much larger) effective mass drives the energy instead.
            branchEnergyJ = 0.5 * 0.03 * speed * speed * (strikingProp ? 1.8 : 1.0)
            damage = graph.applyImpact(
                primaryComponentID: target.id,
                energyJ: branchEnergyJ,
                damageFactor: 0.35,
                spreadRadius: 0.08
            )
        }

        return ImpactReport(
            componentID: contact.componentID,
            obstacleID: contact.obstacle.id,
            obstacleSource: contact.obstacle.source,
            material: material,
            acousticSurface: acousticSurface,
            vehicleMaterial: Self.vehicleMaterial(
                componentID: contact.componentID,
                graph: graph,
                skin: skinMaterial
            ),
            impactEnergyJ: branchEnergyJ,
            normalClosingSpeed: speed,
            // Brushing through a canopy is not a slide against anything: the branches move.
            tangentialSpeed: 0.0,
            tier: .lightTouch,
            damage: damage,
            connectionDamage: [],
            contactPoint: contact.contactPoint,
            contactNormal: contact.contactNormal,
            appliedImpulse: 0.0,
            detachedPartMotions: []
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

    /// Angular-velocity change from an arbitrary world-space impulse.
    private func angularVelocityDelta(
        leverArm: SIMD3<Float>,
        impulse: SIMD3<Float>,
        orientation: simd_quatf,
        inertiaDiagonal: SIMD3<Float>
    ) -> SIMD3<Float> {
        let angularImpulseWorld = simd_cross(leverArm, impulse)
        let angularImpulseBody = simd_act(orientation.conjugate, angularImpulseWorld)
        let inertia = simd_max(inertiaDiagonal, SIMD3<Float>(repeating: 0.0005))
        return simd_act(orientation, angularImpulseBody / inertia)
    }

    /// Maximum scalar impulse that the joint could transmit along the impact
    /// direction before reaching its pre-impact residual force/moment limit.
    /// The ratios deliberately mirror `applyConnectionImpact` so structural
    /// failure and retained-body reaction use the same load envelope.
    private func jointImpulseCapacity(
        connection: VehicleStructuralConnection,
        parent: VehicleComponent,
        child: VehicleComponent,
        contactPointBody: SIMD3<Float>,
        impulseDirectionBody: SIMD3<Float>,
        residualStrength: Float,
        contactDuration: Float
    ) -> Float {
        let directionLength = simd_length(impulseDirectionBody)
        guard directionLength > 0.0001 else { return 0.0 }
        let direction = impulseDirectionBody / directionLength
        let duration = max(0.004, contactDuration)
        let forcePerImpulse = direction / duration
        let lever = contactPointBody - parent.localPosition
        let momentPerImpulse = simd_cross(lever, forcePerImpulse)
        let jointAxisRaw = child.localPosition - parent.localPosition
        let jointAxis = simd_length_squared(jointAxisRaw) > 0.000001
            ? simd_normalize(jointAxisRaw)
            : SIMD3<Float>(0.0, 1.0, 0.0)
        let axialForce = simd_dot(forcePerImpulse, jointAxis)
        let tensilePerImpulse = abs(axialForce)
        let shearPerImpulse = simd_length(forcePerImpulse - jointAxis * axialForce)
        let axialMoment = simd_dot(momentPerImpulse, jointAxis)
        let torsionPerImpulse = abs(axialMoment)
        let bendingPerImpulse = simd_length(momentPerImpulse - jointAxis * axialMoment)
        let ratioPerImpulse = max(
            tensilePerImpulse / max(0.01, connection.tensileLimitN),
            shearPerImpulse / max(0.01, connection.shearLimitN),
            bendingPerImpulse / max(0.01, connection.bendingLimitNm),
            torsionPerImpulse / max(0.01, connection.torsionLimitNm)
        )
        guard ratioPerImpulse > 0.000001 else { return .greatestFiniteMagnitude }
        return max(0.0, residualStrength) / ratioPerImpulse
    }

    private func attitudeQuaternion(state: DroneState, airframeClass: AirframeClass) -> simd_quatf {
        switch airframeClass {
        case .fixedWing, .hybridVTOL:
            return state.attitudeQuat
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
        func distanceToBounds(_ component: VehicleComponent) -> Float {
            let delta = simd_abs(bodyPoint - component.localPosition) - component.boundingHalfExtents
            return simd_length(simd_max(delta, SIMD3<Float>(repeating: 0.0)))
        }

        if let preferredComponent = graph.component(id: preferred),
           preferredComponent.isAttached,
           distanceToBounds(preferredComponent) <= 0.015 {
            return preferred
        }
        return graph.attachedComponents
            .filter { $0.kind.isStructural }
            .min { lhs, rhs in
                let lhsDistance = distanceToBounds(lhs)
                let rhsDistance = distanceToBounds(rhs)
                if abs(lhsDistance - rhsDistance) < 0.0001 {
                    return lhs.id < rhs.id
                }
                return lhsDistance < rhsDistance
            }?.id ?? preferred
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
