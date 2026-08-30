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

    static let none = UAVStructuralLoadResult(connectionDamage: [], failedConnectionRootIDs: [])
}

/// Low-cost structural progression solver. It is intentionally not FEM: it
/// evaluates physically meaningful inertial, aerodynamic, thrust and
/// vibration loads against each joint's residual limits. A previously
/// weakened connection can therefore fail during a later manoeuvre without
/// another collision.
struct UAVStructuralLoadSolver {
    func evaluate(
        graph: inout VehicleComponentGraph,
        previousState: DroneState,
        state: DroneState,
        airframeClass: AirframeClass,
        rotorModel: VehicleRotorModel,
        deltaTime: Float,
        /// Ambient density the airframe is actually flying through. Defaulted to
        /// sea level so any caller that has no atmosphere handy behaves exactly as
        /// before; the runtime passes the real value.
        airDensity: Float = AtmosphereModel.seaLevelDensity,
        /// How much strength the structure has lost, 0...1, to heat and to time spent
        /// outside the flight envelope.
        ///
        /// Neither mechanism breaks anything by itself. Heat softens the material and a
        /// sustained exceedance fatigues it; what they do is lower the load at which the
        /// arithmetic below decides a joint has had enough. That is how both actually
        /// destroy an airframe — not by melting or by snapping at the instant a limit is
        /// crossed, but by making an ordinary manoeuvre the one that finds the weakness.
        /// Zero for every aircraft that stays cold and inside its limits, so the default
        /// leaves existing behaviour untouched.
        thermalWeakening: Float = 0.0
    ) -> UAVStructuralLoadResult {
        guard deltaTime > 0.0001, !graph.isEmpty else { return .none }

        let dt = max(0.0001, deltaTime)
        let accelerationWorld = (state.velocity - previousState.velocity) / dt
        let specificForceWorld = accelerationWorld - SIMD3<Float>(0.0, -9.81, 0.0)
        let specificForce = max(0.25, simd_length(specificForceWorld))
        let rates = airframeClass == .multirotor ? state.angularVelocity : state.bodyAngularVelocity
        let angularRate = simd_length(rates)
        let dynamicPressure = 0.5 * max(0.02, airDensity) * state.forwardAirspeed * state.forwardAirspeed
        let totalMass = max(0.05, graph.massProperties.totalMassKg)
        let rotorCount = max(1, rotorModel.rotors.count)
        let componentSnapshot = graph.attachedComponents
        let componentByID = Dictionary(uniqueKeysWithValues: componentSnapshot.map { ($0.id, $0) })

        // What the airframe's lifting surfaces are actually carrying right now, and how much
        // surface there is to carry it.
        //
        // The load a wing root sees in flight is the lift that wing is producing — the load factor
        // times its share of the aircraft's weight — not `q · S · CLmax`. Charging every surface
        // its maximum lift coefficient at all times makes the load grow with V² with nothing to
        // stop it, so an aircraft that simply accelerated in level cruise tore its own wings off:
        // on a 5.5 kg VTOL at 37 m/s that formula demands about 520 N per wing panel against a
        // ~500 N joint, while the lift the wing is really making is around 27 N. One recorded
        // flight lost both wings mid-air with no impact logged at all, then flew into a building.
        //
        // `q · S · CLmax` stays — as the *ceiling* it physically is. A surface cannot produce more
        // than that, so at low speed it is the binding limit; at cruise the airframe's own lift
        // budget is far lower and binds instead.
        let wingborneFraction: Float = {
            switch airframeClass {
            case .fixedWing:
                return 1.0
            case .hybridVTOL:
                return min(1.0, max(0.0, state.vtolWingborneBlend))
            case .multirotor:
                return 0.0
            }
        }()
        let airframeAerodynamicLift = totalMass * specificForce * wingborneFraction
        let totalLiftingArea = componentSnapshot.reduce(Float(0.0)) { total, member in
            total + (Self.liftingSurface(for: member)?.area ?? 0.0)
        }

        func belongsToSubtree(_ component: VehicleComponent, rootID: String) -> Bool {
            var cursor: VehicleComponent? = component
            var depth = 0
            while let current = cursor, depth < 16 {
                if current.id == rootID { return true }
                cursor = current.parentID.flatMap { componentByID[$0] }
                depth += 1
            }
            return false
        }

        var changes: [VehicleComponentGraph.ConnectionDamageEntry] = []
        // Stable ordering is part of determinism and makes event sequences
        // identical for the same tick/seed.
        let connections = graph.structuralConnections.sorted { $0.id < $1.id }
        for connection in connections where connection.state != .detached {
            guard let child = graph.component(id: connection.childComponentID),
                  child.isAttached,
                  let parent = graph.component(id: connection.parentComponentID) else {
                continue
            }

            let subtree = componentSnapshot.filter { belongsToSubtree($0, rootID: child.id) }
            let subtreeMass = max(0.001, subtree.reduce(Float(0.0)) { $0 + $1.massKg })
            let subtreeCenter = subtree.reduce(SIMD3<Float>(repeating: 0.0)) {
                $0 + ($1.localPosition + $1.deformation.translationMeters) * $1.massKg
            } / subtreeMass
            let lever = max(0.01, simd_distance(subtreeCenter, parent.localPosition))
            var force = subtreeMass * specificForce
            var bendingMoment = force * lever
            var torsionMoment = subtreeMass * angularRate * angularRate * lever * lever

            var rotorSlots: Set<String> = []
            var aerodynamicForce: Float = 0.0
            for member in subtree {
                switch member.kind {
                case .motor(let slot), .propeller(let slot):
                    rotorSlots.insert(slot)
                case .wingSection, .horizontalTail, .verticalTail, .elevator, .rudder:
                    guard let surface = Self.liftingSurface(for: member) else { break }
                    aerodynamicForce += aerodynamicLoad(
                        on: surface,
                        dynamicPressure: dynamicPressure,
                        airframeLift: airframeAerodynamicLift,
                        totalLiftingArea: totalLiftingArea
                    )
                case .frame, .fuselage, .arm, .tailSection, .battery, .flightController, .esc,
                     .radio, .cameraGimbal, .payloadMount, .landingGear:
                    break
                }
            }
            force += aerodynamicForce
            bendingMoment += aerodynamicForce * lever

            if !rotorSlots.isEmpty {
                let relevantRotors = rotorModel.rotors.filter { rotorSlots.contains($0.slot) }
                let baseRotorLoad = totalMass * 9.81 * state.motorThrottle / Float(rotorCount)
                let rotorLoad = relevantRotors.reduce(Float(0.0)) {
                    $0 + baseRotorLoad * $1.thrustFactor
                }
                let localVibration = relevantRotors.map(\.vibration01).max() ?? 0.0
                force += rotorLoad * (1.0 + localVibration * localVibration * 2.4)
                bendingMoment += rotorLoad * lever
                torsionMoment += connection.torsionLimitNm * localVibration * state.motorThrottle * 0.45
            }

            let residual = max(
                0.015,
                min(connection.residualStrength, child.residualStrength)
                    * (1.0 - max(0.0, min(0.95, thermalWeakening)))
            )
            let tensileRatio = force / max(0.01, connection.tensileLimitN * residual)
            let shearRatio = force / max(0.01, connection.shearLimitN * residual)
            let bendingRatio = bendingMoment / max(0.01, connection.bendingLimitNm * residual)
            let torsionRatio = torsionMoment / max(0.01, connection.torsionLimitNm * residual)
            let loadRatio = max(tensileRatio, shearRatio, bendingRatio, torsionRatio)

            if let change = graph.applyStructuralOverload(
                childComponentID: child.id,
                loadRatio: loadRatio,
                deltaTime: dt
            ) {
                changes.append(change)
            }
        }

        return UAVStructuralLoadResult(
            connectionDamage: changes,
            failedConnectionRootIDs: graph.failedConnectionRootIDs.sorted()
        )
    }

    /// A lifting surface's reference area and the largest force coefficient it can reach before
    /// it stalls. The coefficients are the ones this solver has always used; they are now the
    /// ceiling rather than the working value.
    private struct LiftingSurface {
        var area: Float
        var maximumCoefficient: Float
    }

    private static func liftingSurface(for component: VehicleComponent) -> LiftingSurface? {
        let half = component.boundingHalfExtents
        switch component.kind {
        case .wingSection:
            return LiftingSurface(area: max(0.005, half.x * half.z * 4.0), maximumCoefficient: 1.15)
        case .horizontalTail:
            return LiftingSurface(area: max(0.003, half.x * half.z * 4.0), maximumCoefficient: 0.72)
        case .verticalTail:
            return LiftingSurface(area: max(0.003, half.y * half.z * 4.0), maximumCoefficient: 0.72)
        case .elevator:
            return LiftingSurface(area: max(0.002, half.x * half.z * 4.0), maximumCoefficient: 0.48)
        case .rudder:
            return LiftingSurface(area: max(0.002, half.y * half.z * 4.0), maximumCoefficient: 0.48)
        case .motor, .propeller, .frame, .fuselage, .arm, .tailSection, .battery,
             .flightController, .esc, .radio, .cameraGimbal, .payloadMount, .landingGear:
            return nil
        }
    }

    /// The aerodynamic force on one surface: its area share of the lift the airframe is currently
    /// producing, never more than the surface can physically make, never less than the parasite
    /// load that dynamic pressure alone puts on it. The floor is what still breaks an airframe in
    /// a dive — where there is no load factor to speak of but the air pressure is real.
    private func aerodynamicLoad(
        on surface: LiftingSurface,
        dynamicPressure: Float,
        airframeLift: Float,
        totalLiftingArea: Float
    ) -> Float {
        let areaShare = totalLiftingArea > 0.0001 ? surface.area / totalLiftingArea : 1.0
        let stallCeiling = dynamicPressure * surface.area * surface.maximumCoefficient
        let parasiteFloor = dynamicPressure * surface.area * 0.08
        return max(parasiteFloor, min(stallCeiling, airframeLift * areaShare))
    }
}
