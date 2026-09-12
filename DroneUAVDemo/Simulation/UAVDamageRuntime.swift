import Foundation
import simd

enum UAVDamageEventType: String, Codable, Hashable {
    case impact
    case componentDamaged
    case componentDeformed
    case connectionLoosened
    case componentFailed
    case componentDetached
    case subsystemFailed
    case massPropertiesChanged
    case controlAuthorityReduced
    case controlAuthorityLost
    case secondaryImpact
    case vehicleSettled
}

/// Canonical Simulation-layer event. Replay, telemetry and LAN adapters all
/// consume this value instead of independently inferring damage from a
/// global `crashed` flag.
struct UAVDamageEvent: Hashable {
    let sequenceNumber: UInt64
    let timestamp: TimeInterval
    let type: UAVDamageEventType
    let componentID: String?
    let connectionID: String?
    let colliderID: String?
    let worldPoint: SIMD3<Float>?
    let impulseNs: Float?
    let energyJ: Float?
    let integrityBefore: Float?
    let integrityAfter: Float?
    let residualStrengthBefore: Float?
    let residualStrengthAfter: Float?
    let failureMode: ComponentFailureMode?
    let reason: String
    let detachedComponentIDs: [String]
    let massPropertiesRevision: UInt64?
}

final class UAVDamageEventRecorder {
    private(set) var nextSequenceNumber: UInt64 = 1
    private(set) var pendingEvents: [UAVDamageEvent] = []

    func reset() {
        nextSequenceNumber = 1
        pendingEvents.removeAll(keepingCapacity: false)
    }

    @discardableResult
    func record(
        timestamp: TimeInterval,
        type: UAVDamageEventType,
        componentID: String? = nil,
        connectionID: String? = nil,
        colliderID: String? = nil,
        worldPoint: SIMD3<Float>? = nil,
        impulseNs: Float? = nil,
        energyJ: Float? = nil,
        integrityBefore: Float? = nil,
        integrityAfter: Float? = nil,
        residualStrengthBefore: Float? = nil,
        residualStrengthAfter: Float? = nil,
        failureMode: ComponentFailureMode? = nil,
        reason: String,
        detachedComponentIDs: [String] = [],
        massPropertiesRevision: UInt64? = nil
    ) -> UAVDamageEvent {
        let event = UAVDamageEvent(
            sequenceNumber: nextSequenceNumber,
            timestamp: timestamp,
            type: type,
            componentID: componentID,
            connectionID: connectionID,
            colliderID: colliderID,
            worldPoint: worldPoint,
            impulseNs: impulseNs,
            energyJ: energyJ,
            integrityBefore: integrityBefore,
            integrityAfter: integrityAfter,
            residualStrengthBefore: residualStrengthBefore,
            residualStrengthAfter: residualStrengthAfter,
            failureMode: failureMode,
            reason: reason,
            detachedComponentIDs: detachedComponentIDs.sorted(),
            massPropertiesRevision: massPropertiesRevision
        )
        nextSequenceNumber &+= 1
        pendingEvents.append(event)
        return event
    }

    func consumePendingEvents() -> [UAVDamageEvent] {
        let events = pendingEvents
        pendingEvents.removeAll(keepingCapacity: true)
        return events
    }
}

struct UAVStructuralLoadResult {
    let connectionDamage: [VehicleComponentGraph.ConnectionDamageEntry]
    let failedConnectionRootIDs: [String]
    /// The load every joint carried this tick (applied-load convention), by child id. An
    /// impact on the next tick adds to these.
    var jointLoads: [String: VehicleJointLoad] = [:]

    static let none = UAVStructuralLoadResult(connectionDamage: [], failedConnectionRootIDs: [])
}

/// Quasi-static structural solver for sustained loads: flight, thrust, and resting or
/// sliding contact. Every joint is checked against what its section can carry *now*:
/// beyond ultimate it breaks this tick, past yield it takes a permanent set this tick,
/// below that nothing happens. Nothing erodes with time.
///
/// ⚠️ The previous version turned any load above a joint's limit into a strength loss per
/// second, and the contact solver charged every tick of resting or sliding on the ground as
/// a small impact that "cracked" the joints it passed through. Together they made parts fall
/// off seconds after a landing — measured on a 1 m/s touchdown of an MQ-9B: wings at +10.8 s
/// and +11.2 s, tail at +11.3 s, with the aircraft already stopped.
///
/// The one process that legitimately takes time is fatigue, and it is modelled as fatigue:
/// a damaged spinning propeller shakes its mount with a real out-of-balance force
/// `Δm·e·ω²` every revolution, and Miner's rule on a normalised S–N curve decides when the
/// mount gives up — seconds for a blade with its tip gone, never for a nicked one.
struct UAVStructuralLoadSolver {
    func evaluate(
        graph: inout VehicleComponentGraph,
        previousState: DroneState,
        state: DroneState,
        airframeClass: AirframeClass,
        rotorModel: VehicleRotorModel,
        deltaTime: Float,
        airDensity: Float = AtmosphereModel.seaLevelDensity,
        /// Strength the structure has lost to heat and to time outside the envelope, 0...1.
        thermalWeakening: Float = 0.0,
        /// What the propulsion is actually pushing with, newtons.
        thrustNewtons: Float = 0.0,
        /// The aircraft's real wing area, m², or zero to measure it off the geometry.
        ///
        /// ⚠️ The geometry cannot be trusted for magnitude — a station's area comes from a box
        /// around a swept, tapered strip. The geometry gives the distribution, the catalogue
        /// the scale (see the notes on `VehicleMassProperties`).
        referenceWingAreaM2: Float = 0.0,
        /// Steady contact forces from the ground/obstacle solver this tick, body frame.
        sustainedForces: [StructuralPointForce] = []
    ) -> UAVStructuralLoadResult {
        guard deltaTime > 0.0001, !graph.isEmpty else { return .none }
        let dt = max(0.0001, deltaTime)
        let orientation = Self.attitude(state: state, airframeClass: airframeClass)
        let previousOrientation = Self.attitude(state: previousState, airframeClass: airframeClass)
        let conjugate = orientation.conjugate
        // Impacts are resolved by the contact solvers. The ground clamp's own velocity step is
        // one of those — the approach velocity it captured is what the flight forces produced —
        // and anything beyond 60 g inside one tick is too.
        // The engine publishes the specific force its flight forces produced; that is the load.
        // Differencing the velocity instead would also read every clamp, governor and contact
        // correction applied to it as a manoeuvre.
        let flightSpecificForce: SIMD3<Float>
        if let published = state.specificForceBody {
            flightSpecificForce = published
        } else {
            let flightVelocity = state.groundApproach?.velocity ?? state.velocity
            var accelerationWorld = (flightVelocity - previousState.velocity) / dt
            if simd_length(accelerationWorld) > 600 { accelerationWorld = .zero }
            flightSpecificForce = simd_act(conjugate, accelerationWorld - SIMD3<Float>(0, -9.81, 0))
        }
        let omega = Self.bodyRates(state: state, airframeClass: airframeClass)
        var alpha: SIMD3<Float>
        if let rates = state.angularAccelerationRates {
            alpha = SIMD3<Float>(rates.y, rates.z, rates.x)
        } else {
            let previousOmega = Self.bodyRates(state: previousState, airframeClass: airframeClass)
            alpha = (omega - previousOmega) / dt
            if simd_length(alpha) > 400 { alpha = .zero }
        }
        _ = previousOrientation

        let properties = graph.massProperties
        let totalMass = max(0.05, properties.totalMassKg)
        let transforms = graph.deformationTransforms()
        // Contact reactions are flight forces the engine did not see: the ground clamp stands
        // in for them. They accelerate the airframe exactly like lift does, so they belong in
        // the specific force as well as in the point loads — an aircraft resting on its gear
        // is a 1 g airframe, not a weightless one.
        let contactForce = sustainedForces.reduce(SIMD3<Float>.zero) { $0 + $1.forceBody }
        let specificForceBody = flightSpecificForce + (state.specificForceBody != nil ? contactForce / totalMass : .zero)
        func position(_ component: VehicleComponent) -> SIMD3<Float> {
            let p = (transforms[component.id] ?? matrix_identity_float4x4) * SIMD4<Float>(component.localPosition, 1)
            return SIMD3<Float>(p.x, p.y, p.z)
        }
        let wingborneFraction: Float = {
            switch airframeClass {
            case .fixedWing: return 1.0
            case .hybridVTOL: return min(1.0, max(0.0, state.vtolWingborneBlend))
            case .multirotor: return 0.0
            }
        }()
        let dynamicPressure = 0.5 * max(0.02, airDensity) * state.forwardAirspeed * state.forwardAirspeed
        let aeroDamage = FixedWingAeroDamage.build(from: graph)
        let panelEffectiveness = Dictionary(uniqueKeysWithValues: aeroDamage.panelEffectiveness)

        var forces = sustainedForces
        // Lifting surfaces: the airframe's normal load, shared by effective area; side load on
        // the fins. Each surface is capped at what it can make before stalling, and a damaged
        // or folded panel also drags.
        let attached = graph.attachedComponents
        let geometricWingArea = attached.reduce(Float(0)) { total, member in
            guard case .wingSection = member.kind else { return total }
            return total + (member.liftingSurface?.area ?? 0)
        }
        let areaCorrection: Float = referenceWingAreaM2 > 0.0001 && geometricWingArea > 0.0001
            ? referenceWingAreaM2 / geometricWingArea : 1
        struct Surface { let component: VehicleComponent; let area: Float; let maximum: Float; let effectiveness: Float; let vertical: Bool }
        var surfaces: [Surface] = []
        for component in attached {
            guard let lifting = component.liftingSurface else { continue }
            let vertical: Bool
            switch component.kind {
            case .verticalTail, .rudder: vertical = true
            default: vertical = false
            }
            let effectiveness = panelEffectiveness[component.id] ?? component.integrity
            surfaces.append(Surface(component: component, area: lifting.area * areaCorrection,
                                    maximum: lifting.maximumCoefficient, effectiveness: effectiveness, vertical: vertical))
        }
        let normalLoad = totalMass * specificForceBody.y * wingborneFraction
        let sideLoad = totalMass * specificForceBody.x * wingborneFraction
        let horizontalArea = surfaces.filter { !$0.vertical }.reduce(Float(0)) { $0 + $1.area * $1.effectiveness }
        let verticalArea = surfaces.filter { $0.vertical }.reduce(Float(0)) { $0 + $1.area * $1.effectiveness }
        for surface in surfaces {
            let share = surface.vertical
                ? (verticalArea > 0.0001 ? surface.area * surface.effectiveness / verticalArea : 0)
                : (horizontalArea > 0.0001 ? surface.area * surface.effectiveness / horizontalArea : 0)
            let demanded = surface.vertical ? sideLoad * share : normalLoad * share
            let ceiling = dynamicPressure * surface.area * surface.maximum * surface.effectiveness
            let aero = max(-ceiling, min(ceiling, demanded))
            let drag = dynamicPressure * surface.area * DamagedWingPanel.damagedSectionDragIncrement * (1 - surface.effectiveness)
            let force = surface.vertical ? SIMD3<Float>(aero, 0, drag) : SIMD3<Float>(0, aero, drag)
            forces.append(StructuralPointForce(componentID: surface.component.id,
                                               pointBody: position(surface.component), forceBody: force))
        }
        // Rotors: hover-borne share of the normal load at the lift rotors, cruise thrust at
        // the cruise propellers.
        let liftRotors = rotorModel.rotors.filter { !$0.slot.hasPrefix("cruise") }
        let cruiseRotors = rotorModel.rotors.filter { $0.slot.hasPrefix("cruise") }
        let liftFactorSum = max(0.0001, liftRotors.reduce(Float(0)) { $0 + $1.thrustFactor })
        let rotorBorne = totalMass * max(0, simd_dot(specificForceBody, SIMD3<Float>(0, 1, 0))) * (1 - wingborneFraction)
        for rotor in liftRotors {
            guard let motor = graph.component(id: "motor.\(rotor.slot)"), motor.isAttached else { continue }
            let thrust = rotorBorne * rotor.thrustFactor / liftFactorSum
            forces.append(StructuralPointForce(componentID: motor.id, pointBody: position(motor),
                                               forceBody: rotor.thrustDirectionBody * thrust))
        }
        let cruiseFactorSum = max(0.0001, cruiseRotors.reduce(Float(0)) { $0 + $1.thrustFactor })
        for rotor in cruiseRotors {
            guard let motor = graph.component(id: "motor.\(rotor.slot)"), motor.isAttached else { continue }
            let thrust = max(0, thrustNewtons) * rotor.thrustFactor / cruiseFactorSum
            forces.append(StructuralPointForce(componentID: motor.id, pointBody: position(motor),
                                               forceBody: rotor.cruiseThrustDirectionBody * thrust))
        }

        let loadCase = StructuralLoadCase(
            specificForceBody: specificForceBody,
            angularVelocityBody: omega,
            angularAccelerationBody: alpha,
            centerOfMass: properties.centerOfMassOffset,
            pointForces: forces)
        let loads = StructuralLoadField.jointLoads(graph: graph, loadCase: loadCase, transforms: transforms)

        var changes: [VehicleComponentGraph.ConnectionDamageEntry] = []
        // Stable ordering is part of determinism.
        let connections = graph.structuralConnections.sorted { $0.id < $1.id }
        for connection in connections where connection.state != .detached {
            guard let load = loads[connection.childComponentID],
                  let child = graph.component(id: connection.childComponentID), child.isAttached,
                  let outcome = StructuralJointResponse.evaluate(
                    connection: connection,
                    currentRotation: child.deformation.bendRadians,
                    load: load,
                    thermalWeakening: thermalWeakening) else { continue }
            if let entry = graph.applyJointOutcome(
                childComponentID: connection.childComponentID,
                plasticRotationBody: outcome.plasticRotationBody,
                plasticRotationSpent: outcome.plasticRotationSpent,
                residualStrength: outcome.residualStrength,
                stiffnessScale: outcome.stiffnessScale,
                fracture: outcome.fracture) {
                changes.append(entry)
            }
        }
        changes += accumulateRotorFatigue(graph: &graph, state: state, rotorModel: rotorModel,
                                          loads: loads, transforms: transforms, deltaTime: dt,
                                          thermalWeakening: thermalWeakening)

        var result = UAVStructuralLoadResult(
            connectionDamage: changes,
            failedConnectionRootIDs: graph.failedConnectionRootIDs
        )
        result.jointLoads = loads
        return result
    }

    /// Miner's rule on the out-of-balance force of each damaged, spinning propeller.
    ///
    /// A chipped or broken blade leaves `Δm` of missing mass at roughly 0.8 of its radius;
    /// the hub then carries `Δm·e·ω²` rotating once per revolution. Every joint between the
    /// propeller and the airframe sees that as an alternating load, whose ratio to the
    /// section's capacity — raised by the steady load already there (Goodman) — sets the
    /// cycles to failure on the material's S–N curve, `N = 10^((1 − S)/b)`.
    /// Blade mass lost is taken as 40 % of the integrity lost: thrust falls off faster than
    /// mass because a broken tip is where most of the thrust is made.
    private func accumulateRotorFatigue(
        graph: inout VehicleComponentGraph,
        state: DroneState,
        rotorModel: VehicleRotorModel,
        loads: [String: VehicleJointLoad],
        transforms: [String: simd_float4x4],
        deltaTime: Float,
        thermalWeakening: Float
    ) -> [VehicleComponentGraph.ConnectionDamageEntry] {
        var entries: [VehicleComponentGraph.ConnectionDamageEntry] = []
        for rotor in rotorModel.rotors {
            guard let propeller = graph.component(id: "propeller.\(rotor.slot)"), propeller.isAttached,
                  propeller.integrity < 0.999 else { continue }
            let speed: Float = {
                if let lane = VehicleRotor.laneIndex(forSlot: rotor.slot) { return abs(state.rotorAngularSpeed[lane]) }
                return state.motorThrottle * 600
            }()
            guard speed > 5 else { continue }
            let radius = max(propeller.boundingHalfExtents.x, propeller.boundingHalfExtents.z)
            let missing = propeller.massKg * (1 - propeller.integrity) * 0.4
            let amplitude = missing * 0.8 * radius * speed * speed
            guard amplitude > 1e-4 else { continue }
            let hubTransform = transforms[propeller.id] ?? matrix_identity_float4x4
            let hub4 = hubTransform * SIMD4<Float>(propeller.localPosition, 1)
            let hub = SIMD3<Float>(hub4.x, hub4.y, hub4.z)
            let axis = simd_normalize(rotor.slot.hasPrefix("cruise") ? rotor.cruiseThrustDirectionBody : rotor.thrustDirectionBody)
            let helper = abs(axis.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
            let radialA = simd_normalize(simd_cross(axis, helper))
            let radialB = simd_cross(axis, radialA)
            let cycles = speed / (2 * Float.pi) * deltaTime
            var cursor: String? = propeller.id
            var depth = 0
            while let id = cursor, depth < 32 {
                depth += 1
                guard let connection = graph.connection(childComponentID: id), connection.state != .detached,
                      let section = connection.section else {
                    cursor = graph.component(id: id)?.parentID
                    continue
                }
                let parentTransform = graph.component(id: connection.parentComponentID).flatMap { transforms[$0.id] }
                    ?? matrix_identity_float4x4
                let a4 = parentTransform * SIMD4<Float>(section.anchor, 1)
                let anchor = SIMD3<Float>(a4.x, a4.y, a4.z)
                let residual = max(0.016, connection.residualStrength) * (1 - max(0, min(0.95, thermalWeakening)))
                var alternating: Float = 0
                for radial in [radialA, radialB] {
                    let force = radial * amplitude
                    let load = section.localLoad(force: force, moment: simd_cross(hub - anchor, force))
                    alternating = max(alternating, section.utilisation(of: load, residual: residual))
                }
                let mean = loads[id].map { section.utilisation(of: $0, residual: residual) } ?? 0
                let effective = alternating / max(0.05, 1 - min(0.95, mean))
                let slope = section.material.fatigueSlopePerDecade
                let cyclesToFailure = pow(10, max(0, (1 - effective)) / max(0.01, slope))
                let damage = connection.fatigueDamage + cycles / max(1, cyclesToFailure)
                if effective >= 1 || damage >= 1 {
                    // Fatigue rupture: the crack runs through the section.
                    let skinHolds = connection.section?.isMemberStation == true
                        && section.forceUtilisation(of: loads[id] ?? .zero,
                                                   residual: residual * section.material.retainedSkinFraction) < 1
                    if let entry = graph.applyJointOutcome(
                        childComponentID: id,
                        plasticRotationBody: graph.component(id: id)?.deformation.bendRadians ?? .zero,
                        plasticRotationSpent: connection.plasticRotationSpent,
                        residualStrength: skinHolds ? section.material.retainedSkinFraction : 0,
                        stiffnessScale: 0.02,
                        fracture: skinHolds ? .hinged : .separated,
                        fatigueDamage: 1) {
                        entries.append(entry)
                    }
                    break
                } else if damage > connection.fatigueDamage + 1e-7 {
                    graph.applyJointOutcome(
                        childComponentID: id,
                        plasticRotationBody: graph.component(id: id)?.deformation.bendRadians ?? .zero,
                        plasticRotationSpent: connection.plasticRotationSpent,
                        residualStrength: connection.residualStrength,
                        stiffnessScale: connection.stiffnessScale,
                        fracture: connection.fracture,
                        fatigueDamage: damage)
                }
                cursor = connection.parentComponentID
            }
        }
        return entries
    }

    private static func attitude(state: DroneState, airframeClass: AirframeClass) -> simd_quatf {
        switch airframeClass {
        case .fixedWing, .hybridVTOL:
            return state.attitudeQuat
        case .multirotor:
            let euler = state.orientation
            let yaw = simd_quatf(angle: euler.z, axis: SIMD3<Float>(0, 1, 0))
            let pitch = simd_quatf(angle: euler.y, axis: SIMD3<Float>(1, 0, 0))
            let roll = simd_quatf(angle: euler.x, axis: SIMD3<Float>(0, 0, 1))
            return yaw * pitch * roll
        }
    }

    /// Body-axis angular velocity (x, y, z) from this codebase's (roll, pitch, yaw) rates:
    /// roll about body Z, pitch about X, yaw about Y.
    private static func bodyRates(state: DroneState, airframeClass: AirframeClass) -> SIMD3<Float> {
        let rates = airframeClass == .multirotor ? state.angularVelocity : state.bodyAngularVelocity
        return SIMD3<Float>(rates.y, rates.z, rates.x)
    }
}
