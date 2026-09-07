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
        thermalWeakening: Float = 0.0,
        /// What the propulsion is actually pushing with, newtons.
        ///
        /// Needed because a propeller mount carries *thrust*, and the load below used to
        /// be `m·g·throttle / rotorCount` for every rotor on every airframe. That is the
        /// right load for a multirotor, where each of N discs really does hold up its
        /// share of the aircraft — and badly wrong for an aeroplane, where one propeller
        /// was charged the whole weight. Defaulted to zero so a caller with no propulsion
        /// figure behaves as before on a multirotor, which is what the headless probes are.
        thrustNewtons: Float = 0.0,
        /// The aircraft's real wing area, m², or zero to measure it off the geometry.
        ///
        /// ⚠️ The geometry cannot be trusted for this. A wing section's area is taken from
        /// its bounding half-extents, and those come from the rendered wing — a rectangle
        /// drawn around a swept, tapered planform. Measured: 76.5 m² on an MQ-9B whose
        /// real wing is about 11.5. Worse, it moved: the procedural stand-in wings were a
        /// fraction of the real aircraft, so switching to the authored models multiplied
        /// this by 98 on the MQ-9B and by 570 on the X-10, and loads that had always been
        /// too small became large enough to tear wings off in level flight.
        ///
        /// So the geometry is used for the *distribution* — which surface carries what
        /// share — and the catalogue for the *magnitude*. That is the same split that
        /// `VehicleMassProperties` needed: trustworthy for distribution, untrustworthy
        /// for scale.
        referenceWingAreaM2: Float = 0.0
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
        // How far the drawn surfaces are from the real ones. The wing is the only surface
        // the catalogue gives an area for, so its error sets the scale for all of them.
        //
        // ⚠️ This has to be applied to *every* lifting surface, not just the wing. The load
        // on a surface is its share of the airframe's lift — `area / totalLiftingArea` —
        // and correcting one term of that sum while leaving the others as drawn does not
        // just rescale the loads, it redistributes them. Measured on the empennage's share
        // of the airframe's lift with the wing corrected alone: MQ-9B 35.7 %, AQM-35A
        // 55.2 % — more on the tail than on the wing. The manoeuvre margin that fell out
        // of that: the MQ-9B started shedding `tail.horizontal` at 2.0 g and the MQ-9A and
        // Hermes 900 at 2.8 g, in clean air with nothing to hit, where a transport airframe
        // is stressed for 2.5 g and a light one for 3.8. An operator's MQ-9B lost its
        // horizontal tail at 217 m the moment a lost radio link rolled it into a returnHome
        // turn, then porpoised into the ground.
        //
        // Every one of these areas is a bounding box drawn around a real surface, so they
        // are all over-estimates of the same kind and the same order: on the MQ-9B the wing
        // rectangle is 2.1x the catalogue wing, and the empennage draft is about 3x the
        // real V-tail. One factor for all of them keeps the geometry's proportions, which
        // is what the geometry is trusted for, and takes the magnitude from the catalogue,
        // which is what the catalogue is for.
        let geometricWingArea = componentSnapshot.reduce(Float(0.0)) { total, member in
            guard case .wingSection = member.kind else { return total }
            return total + (Self.liftingSurface(for: member)?.area ?? 0.0)
        }
        let surfaceAreaCorrection: Float = referenceWingAreaM2 > 0.0001 && geometricWingArea > 0.0001
            ? referenceWingAreaM2 / geometricWingArea
            : 1.0
        func correctedSurface(for member: VehicleComponent) -> LiftingSurface? {
            guard var surface = Self.liftingSurface(for: member) else { return nil }
            surface.area *= surfaceAreaCorrection
            return surface
        }
        let totalLiftingArea = componentSnapshot.reduce(Float(0.0)) { total, member in
            total + (correctedSurface(for: member)?.area ?? 0.0)
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
                    guard let surface = correctedSurface(for: member) else { break }
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
                // ⚠️ A rotor mount carries one of two quite different loads, and which one
                // depends on what the rotor is doing rather than on what it is.
                //
                // Holding the aircraft up: each of N discs carries m·g/N, and that is the
                // load a quadcopter's arm really sees. Pushing it along: the mount carries
                // thrust, which on an aeroplane is a small fraction of weight.
                //
                // This used to be the weight formula for everything. On the MQ-9B — one
                // propeller, 5,670 kg — it charged that single mount 26.0 kN at full
                // throttle against a 19.6 kN joint, so the aircraft tore its own propeller
                // off on the takeoff roll and reported critical structural damage with no
                // impact anywhere in the log. Hermes 900 did the same at 8.1 kN against
                // 7.2 kN. Measured, both of them.
                //
                // `wingborneFraction` is already the answer to "is this aircraft being
                // held up by its wing or by its rotors": 1 for a fixed wing, 0 for a
                // multirotor, the transition blend for a VTOL. So the two loads mix on
                // exactly that, and no case changes except the one that was wrong.
                let liftShare = totalMass * 9.81 * state.motorThrottle / Float(rotorCount)
                let thrustShare = max(0.0, thrustNewtons) / Float(rotorCount)
                let baseRotorLoad = liftShare * (1.0 - wingborneFraction)
                    + thrustShare * wingborneFraction
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
        // One source of truth, shared with the connection builder that sizes the joints
        // these loads pass through — see `VehicleComponent.liftingSurface`.
        guard let surface = component.liftingSurface else { return nil }
        return LiftingSurface(area: surface.area, maximumCoefficient: surface.maximumCoefficient)
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
        // ⚠️ The floor is a *profile-drag* load, so its coefficient has to be a profile-drag
        // coefficient. It was 0.08, which is roughly eight times what a clean surface
        // actually has (0.008–0.012 referenced to its own area), and because the floor grows
        // with V² and nothing above it does, it stopped being a floor and became the whole
        // answer: measured on every fixed wing in the catalogue, `aero` came out exactly
        // equal to this term, four to seventeen times the lift the surface was really
        // carrying. On an AQM-35 at its own published maximum that was 34.7 kN on a wing
        // root — six times the aircraft's entire weight — and the joint failed at a speed
        // the catalogue says is fine, in level flight, with nothing to hit. Two aircraft
        // shed their wings on a plain full-throttle climb; the operator's AQM-35 lost both
        // wing roots and then its tail at 285 m/s one metre off the ground, where sea-level
        // density makes this term the largest.
        //
        // At 0.01 the floor does what its name says: it binds only in a dive, where there is
        // no load factor but the air pressure is real, and the surface's share of the
        // airframe's own lift binds everywhere else.
        let parasiteFloor = dynamicPressure * surface.area * 0.01
        return max(parasiteFloor, min(stallCeiling, airframeLift * areaShare))
    }
}
