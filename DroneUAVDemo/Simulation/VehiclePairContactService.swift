import Foundation
import simd

struct VehiclePairContact {
    let fraction: Float
    let point: SIMD3<Float>
    /// From second body toward first body, like VehicleSweptContact.
    let normal: SIMD3<Float>
    let firstSphere: VehicleContactSphere
    let secondSphere: VehicleContactSphere
}

/// Continuous relative-motion narrow phase and a single two-body impulse. Neither body is
/// treated as an immovable obstacle. The existing component graph owns all contact damage.
enum VehiclePairContactService {
    static func firstContact(firstPrevious: DroneState, first: DroneState, firstProfile: VehicleContactProfile,
                             secondPrevious: DroneState, second: DroneState, secondProfile: VehicleContactProfile) -> VehiclePairContact? {
        guard !firstProfile.isEmpty, !secondProfile.isEmpty else { return nil }
        // Broad phase includes both translations. It must not discard two fast crossing bodies.
        let separation = simd_distance(firstPrevious.position, secondPrevious.position)
        let travel = simd_distance(firstPrevious.position, first.position) + simd_distance(secondPrevious.position, second.position)
        guard separation <= travel + firstProfile.boundingRadius + secondProfile.boundingRadius else { return nil }
        let angle = max(rotationAngle(firstPrevious.attitudeQuat, first.attitudeQuat),
                        rotationAngle(secondPrevious.attitudeQuat, second.attitudeQuat))
        let subdivisions = max(1, min(32, Int(ceil(angle / 0.08))))
        var best: VehiclePairContact?
        for step in 0..<subdivisions {
            let t0 = Float(step) / Float(subdivisions)
            let t1 = Float(step + 1) / Float(subdivisions)
            if let best, best.fraction < t0 { break }
            let ap0 = mix(firstPrevious.position, first.position, t0)
            let ap1 = mix(firstPrevious.position, first.position, t1)
            let bp0 = mix(secondPrevious.position, second.position, t0)
            let bp1 = mix(secondPrevious.position, second.position, t1)
            let aq0 = simd_slerp(firstPrevious.attitudeQuat, first.attitudeQuat, t0)
            let aq1 = simd_slerp(firstPrevious.attitudeQuat, first.attitudeQuat, t1)
            let bq0 = simd_slerp(secondPrevious.attitudeQuat, second.attitudeQuat, t0)
            let bq1 = simd_slerp(secondPrevious.attitudeQuat, second.attitudeQuat, t1)
            for a in firstProfile.spheres {
                let a0 = a.worldCenter(position: ap0, orientation: aq0)
                let a1 = a.worldCenter(position: ap1, orientation: aq1)
                for b in secondProfile.spheres {
                    let b0 = b.worldCenter(position: bp0, orientation: bq0)
                    let b1 = b.worldCenter(position: bp1, orientation: bq1)
                    let offset = a0 - b0
                    let motion = (a1 - a0) - (b1 - b0)
                    let radius = a.radius + b.radius
                    let c = simd_dot(offset, offset) - radius * radius
                    let localT: Float
                    if c <= 0 { localT = 0 }
                    else {
                        let aa = simd_dot(motion, motion)
                        let bb = simd_dot(offset, motion)
                        let discriminant = bb * bb - aa * c
                        guard aa > 1e-10, bb < 0, discriminant >= 0 else { continue }
                        localT = (-bb - sqrt(discriminant)) / aa
                        guard localT >= 0, localT <= 1 else { continue }
                    }
                    let fraction = t0 + (t1 - t0) * localT
                    guard best == nil || fraction < best!.fraction else { continue }
                    let ac = mix(a0, a1, localT)
                    let bc = mix(b0, b1, localT)
                    let delta = ac - bc
                    let fallback = simd_length_squared(motion) > 1e-10 ? -simd_normalize(motion) : SIMD3<Float>(1, 0, 0)
                    let normal = simd_length_squared(delta) > 1e-10 ? simd_normalize(delta) : fallback
                    best = VehiclePairContact(fraction: fraction, point: (ac - normal * a.radius + bc + normal * b.radius) * 0.5,
                                              normal: normal, firstSphere: a, secondSphere: b)
                }
            }
        }
        return best
    }

    /// Applies one two-body impulse at the contact and reports what it cost each aircraft.
    /// `applyDamage` is false while the pair is still resting against each other, so a single
    /// physical touch damages once instead of once per tick.
    static func resolve(contact: VehiclePairContact, firstPrevious: DroneState, secondPrevious: DroneState,
                        first: inout DroneState, firstGraph: inout VehicleComponentGraph, firstClass: AirframeClass,
                        second: inout DroneState, secondGraph: inout VehicleComponentGraph, secondClass: AirframeClass,
                        deltaTime: Float, applyDamage: Bool = true) -> (first: ImpactReport, second: ImpactReport) {
        let aMass = firstGraph.massProperties
        let bMass = secondGraph.massProperties
        let aPose = mix(firstPrevious.position, first.position, contact.fraction)
        let bPose = mix(secondPrevious.position, second.position, contact.fraction)
        let aq = simd_slerp(firstPrevious.attitudeQuat, first.attitudeQuat, contact.fraction)
        let bq = simd_slerp(secondPrevious.attitudeQuat, second.attitudeQuat, contact.fraction)
        let ar = contact.point - aPose - simd_act(aq, aMass.centerOfMassOffset)
        let br = contact.point - bPose - simd_act(bq, bMass.centerOfMassOffset)
        let n = contact.normal
        let relative = first.velocity + simd_cross(omega(first, firstClass, aq), ar)
            - second.velocity - simd_cross(omega(second, secondClass, bq), br)
        let closing = max(0, -simd_dot(relative, n))
        let invMassA = 1 / max(0.2, aMass.totalMassKg)
        let invMassB = 1 / max(0.2, bMass.totalMassKg)
        func inverseEffectiveMass(_ direction: SIMD3<Float>) -> Float {
            invMassA + invMassB + simd_dot(direction,
                simd_cross(inverseInertia(simd_cross(ar, direction), aq, aMass), ar) +
                simd_cross(inverseInertia(simd_cross(br, direction), bq, bMass), br))
        }
        let effectiveMass = 1 / max(0.0001, inverseEffectiveMass(n))
        let material = ImpactSurfaceMaterial.metalVehicle
        let j = (1 + material.restitution) * closing * effectiveMass
        let tangentVelocity = relative + n * closing
        let tangentSpeed = simd_length(tangentVelocity)
        var impulse = n * j
        var frictionWork: Float = 0
        if tangentSpeed > 0.001, closing > 0.01 {
            let tangent = tangentVelocity / tangentSpeed
            let friction = min(material.friction * j, tangentSpeed / max(0.0001, inverseEffectiveMass(tangent)))
            impulse -= tangent * friction
            frictionWork = max(0, friction * tangentSpeed - 0.5 * inverseEffectiveMass(tangent) * friction * friction)
        }
        if closing > 0.01 {
            first.position = aPose + n * 0.003
            second.position = bPose - n * 0.003
            first.attitudeQuat = aq
            second.attitudeQuat = bq
            first.velocity += impulse * invMassA
            second.velocity -= impulse * invMassB
            addOmega(inverseInertia(simd_cross(ar, impulse), aq, aMass), to: &first, kind: firstClass, orientation: aq)
            addOmega(inverseInertia(simd_cross(br, -impulse), bq, bMass), to: &second, kind: secondClass, orientation: bq)
        }
        // Both deforming bodies share the dissipated kinetic energy. The
        // softer component absorbs the greater share; charging each body the
        // full relative energy violates that contact's single energy budget.
        let impactEnergy = 0.5 * effectiveMass * closing * closing
        let energy = impactEnergy * (1 - material.restitution * material.restitution)
            + frictionWork * material.abrasionFactor
        let aStrength = max(0.5, firstGraph.component(id: contact.firstSphere.componentID)?.strengthJ ?? 40)
        let bStrength = max(0.5, secondGraph.component(id: contact.secondSphere.componentID)?.strengthJ ?? 40)
        let aShare = bStrength / (aStrength + bStrength)

        let impactID = UUID()
        let aReport = report(graph: &firstGraph, componentID: contact.firstSphere.componentID,
            orientation: aq, position: aPose, point: contact.point, normal: n, impulse: impulse,
            energy: energy * aShare, closing: closing, tangent: tangentSpeed, id: impactID,
            deltaTime: deltaTime, applyDamage: applyDamage)
        let bReport = report(graph: &secondGraph, componentID: contact.secondSphere.componentID,
            orientation: bq, position: bPose, point: contact.point, normal: -n, impulse: -impulse,
            energy: energy * (1 - aShare), closing: closing, tangent: tangentSpeed, id: impactID,
            deltaTime: deltaTime, applyDamage: applyDamage)
        return (aReport, bReport)
    }

    private static func report(graph: inout VehicleComponentGraph, componentID: String, orientation: simd_quatf,
                               position: SIMD3<Float>, point: SIMD3<Float>, normal: SIMD3<Float>, impulse: SIMD3<Float>,
                               energy: Float, closing: Float, tangent: Float, id: UUID,
                               deltaTime: Float, applyDamage: Bool) -> ImpactReport {
        let bodyPoint = simd_act(orientation.conjugate, point - position)
        let material = ImpactSurfaceMaterial.metalVehicle
        let ratio = energy * material.damageFactor / max(0.5, graph.component(id: componentID)?.strengthJ ?? 40)
        let tier: ImpactOutcomeTier = ratio < 0.05 ? .lightTouch : ratio < 0.3 ? .scrape : ratio < 1 ? .heavyImpact : .criticalImpact
        // Spread widens with severity, the same way it does for a contact with the world: a hard
        // enough hit is not a dent in one component, it goes through the structure around it.
        let spreadRadius = 0.15 + 0.45 * min(1, ratio)
        let damage = applyDamage ? graph.applyImpact(primaryComponentID: componentID, energyJ: energy,
            damageFactor: material.damageFactor, spreadRadius: spreadRadius, contactPointBody: bodyPoint,
            impulseBody: simd_act(orientation.conjugate, impulse)) : []
        // The ram's contact force lands on the struck part's mount; everything else carries
        // the inertia of what hangs off it while the airframe is shoved aside.
        var connections: [VehicleComponentGraph.ConnectionDamageEntry] = []
        if applyDamage {
            let properties = graph.massProperties
            let pulse = ImpactResolutionService.contactDuration(component: graph.component(id: componentID),
                                                                material: material, closingSpeed: closing)
            let peakForce = simd_act(orientation.conjugate, impulse) * (Float.pi / (2 * max(0.001, pulse)))
            let lever = bodyPoint - properties.centerOfMassOffset
            connections = ImpactResolutionService.applyInertialShock(
                graph: &graph,
                massProperties: properties,
                history: .halfSine(
                    peakLinear: peakForce / max(0.05, properties.totalMassKg),
                    peakAngular: simd_cross(lever, peakForce)
                        / simd_max(properties.inertiaDiagonal, SIMD3<Float>(repeating: 0.0005)),
                    duration: pulse),
                excludedMember: nil,
                stationAccelerations: [:],
                directForce: StructuralPointForce(componentID: componentID, pointBody: bodyPoint, forceBody: peakForce),
                preload: ImpactResolutionService.flightPreload(graph: graph, massProperties: properties,
                                                              orientation: orientation),
                thermalWeakening: 0)
        }
        return ImpactReport(componentID: componentID, obstacleID: id, obstacleSource: InterceptContactSource.vehicle,
            material: material, acousticSurface: .metal,
            vehicleMaterial: ImpactResolutionService.vehicleMaterial(componentID: componentID, graph: graph, skin: .aluminium),
            impactEnergyJ: energy, normalClosingSpeed: closing, tangentialSpeed: tangent, tier: tier,
            damage: damage, connectionDamage: connections, contactPoint: point, contactNormal: normal,
            appliedImpulse: simd_length(impulse), detachedPartMotions: [])
    }
    private static func rotationAngle(_ a: simd_quatf, _ b: simd_quatf) -> Float {
        2 * acos(min(1, abs(simd_dot(a.vector, b.vector))))
    }
    private static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
    private static func inverseInertia(_ torque: SIMD3<Float>, _ q: simd_quatf, _ mass: VehicleMassProperties) -> SIMD3<Float> {
        simd_act(q, simd_act(q.conjugate, torque) / simd_max(mass.inertiaDiagonal, SIMD3<Float>(repeating: 0.0001)))
    }
    /// World-frame angular velocity. A multirotor's rates are stored world-relative and a
    /// fixed-wing's body-relative, and the component order differs from the vector's — this is
    /// where both conventions are reconciled, in one place, rather than at each call site.
    private static func omega(_ state: DroneState, _ kind: AirframeClass, _ q: simd_quatf) -> SIMD3<Float> {
        let rates = kind == .multirotor ? state.angularVelocity : state.bodyAngularVelocity
        return simd_act(q, SIMD3<Float>(rates.y, rates.z, rates.x))
    }

    /// The inverse of `omega`: takes a world-frame angular impulse back into whichever rate
    /// representation the airframe class actually integrates.
    private static func addOmega(_ value: SIMD3<Float>, to state: inout DroneState, kind: AirframeClass, orientation: simd_quatf) {
        let body = simd_act(orientation.conjugate, value)
        let delta = SIMD3<Float>(body.z, body.x, body.y)
        if kind == .multirotor {
            state.angularVelocity += delta
        } else {
            state.bodyAngularVelocity += delta
            state.angularVelocity = state.bodyAngularVelocity
        }
    }
}

extension InterceptImpactClass {
    init(_ tier: ImpactOutcomeTier) {
        switch tier {
        case .lightTouch: self = .touch
        case .scrape: self = .scrape
        case .heavyImpact: self = .heavy
        case .criticalImpact: self = .critical
        }
    }
}
