import Foundation
import simd

/// One physical rotor (motor + propeller) of the per-rotor thrust model.
struct VehicleRotor: Hashable {
    /// Graph slot ("FL", "M5", "cruise"...) — matches `motor.<slot>` /
    /// `propeller.<slot>` component ids in the vehicle component graph.
    let slot: String
    /// Rotor position relative to the airframe's center of mass, body frame
    /// (+Y up, -Z forward). CoM-relative so torque lever arms are direct.
    var offsetBody: SIMD3<Float>
    /// Actual thrust axis after structural deformation, body frame.
    /// Pristine multirotors point along +Y.
    var thrustDirectionBody: SIMD3<Float> = SIMD3<Float>(0.0, 1.0, 0.0)
    var cruiseThrustDirectionBody: SIMD3<Float> = SIMD3<Float>(0.0, 0.0, -1.0)
    /// +1 / -1 blade spin direction (yaw reaction torque sign).
    let spinSign: Float
    /// SIMD4 telemetry lane (FL/FR/RL/RR -> 0-3) for `rotorAngularSpeed`;
    /// nil for rotors beyond the classic four (hex/octo extras).
    let laneIndex: Int?
    /// 0...1 achievable-thrust multiplier from propeller/motor integrity and
    /// any active failure mode. 1 = pristine, 0 = dead rotor.
    var thrustFactor: Float
    /// 0...1 imbalance level of this rotor (a chipped spinning blade shakes;
    /// a missing one doesn't) — feeds the FPV vibration channel and the
    /// vibration disturbance torque.
    var vibration01: Float

    static func laneIndex(forSlot slot: String) -> Int? {
        switch slot {
        case "FL": return 0
        case "FR": return 1
        case "RL": return 2
        case "RR": return 3
        default: return nil
        }
    }
}

/// Per-rotor thrust/torque model + control allocation (mixer) for the
/// multirotor stepper. Axis convention matches the engine's rate labeling:
/// rates are (roll, pitch, yaw) with roll about body Z, pitch about body X,
/// yaw about body Y. A rotor thrust t at CoM-relative offset r contributes
/// torque r × t·ŷ = t·(-r.z, 0, r.x) in (X, Y, Z) axes — i.e. pitch = -z·t,
/// roll = x·t — plus yaw reaction σ·κ·t about Y.
struct VehicleRotorModel: Hashable {
    var rotors: [VehicleRotor]
    /// κ: reaction-torque-to-thrust ratio (N·m per N). Scales yaw authority.
    let torqueToThrustRatio: Float
    /// Rotorcraft with a swashplate produce moments by cyclic disc tilt as
    /// well as differential collective. Zero denotes fixed-axis motors.
    var cyclicTiltLimitRad: Float = 0

    static let empty = VehicleRotorModel(rotors: [], torqueToThrustRatio: 0.02)

    var isEmpty: Bool { rotors.isEmpty }

    /// Mean achievable-thrust fraction across rotors (1 = pristine fleet).
    var totalThrustFactor: Float {
        guard !rotors.isEmpty else { return 1.0 }
        return rotors.reduce(Float(0.0)) { $0 + $1.thrustFactor } / Float(rotors.count)
    }

    /// Peak rotor imbalance, 0...1 — the FPV shake / vibration-torque driver.
    var vibrationLevel: Float {
        rotors.reduce(Float(0.0)) { max($0, $1.vibration01) }
    }

    var isPristine: Bool {
        let nominalAxis = SIMD3<Float>(0.0, 1.0, 0.0)
        return rotors.allSatisfy { rotor in
            rotor.thrustFactor > 0.999 &&
                rotor.vibration01 < 0.001 &&
                simd_distance_squared(rotor.thrustDirectionBody, nominalAxis) < 0.000001 &&
                simd_distance_squared(rotor.cruiseThrustDirectionBody, SIMD3<Float>(0, 0, -1)) < 0.000001
        }
    }

    /// Mean thrust factor of cruise rotors (slot prefix "cruise"); a pure
    /// fixed-wing catalogs all its rotors as cruise, VTOL mixes cruise and
    /// quadrant lift slots. Falls back to the overall mean, and 1 for an
    /// empty model.
    var cruiseThrustFactor: Float {
        let cruise = rotors.filter { $0.slot.hasPrefix("cruise") }
        guard !cruise.isEmpty else { return totalThrustFactor }
        return cruise.reduce(Float(0.0)) { $0 + $1.thrustFactor } / Float(cruise.count)
    }

    /// Thrust factor of the rotor nearest to a VTOL propulsion unit's mount
    /// position — unit ids don't share the graph's slot naming, so damage is
    /// mapped by geometry. `mountOffset` is airframe-origin-relative; rotor
    /// offsets are CoM-relative, hence the `centerOfMass` shift.
    func thrustFactor(nearMount mountOffset: SIMD3<Float>, centerOfMass: SIMD3<Float>) -> Float {
        guard !rotors.isEmpty else { return 1.0 }
        var best: Float = 1.0
        var bestDistance = Float.greatestFiniteMagnitude
        for rotor in rotors {
            let distance = simd_distance(rotor.offsetBody + centerOfMass, mountOffset)
            if distance < bestDistance {
                bestDistance = distance
                best = rotor.thrustFactor
            }
        }
        return best
    }

    /// Cruise force and the moment caused by unequal or deflected propellers.
    /// The mean mount is the pristine thrust-line reference already trimmed by
    /// the aerodynamic model; only departure from that reference adds moment.
    func cruiseWrench(nominalThrust: Float) -> (force: SIMD3<Float>, moment: SIMD3<Float>) {
        if isPristine { return (SIMD3<Float>(0, 0, -nominalThrust), .zero) }
        let cruise = rotors.filter { $0.slot.hasPrefix("cruise") }
        let active = cruise.isEmpty ? rotors : cruise
        guard !active.isEmpty else { return (SIMD3<Float>(0, 0, -nominalThrust), .zero) }
        let center = active.reduce(SIMD3<Float>.zero) { $0 + $1.offsetBody } / Float(active.count)
        let perRotor = nominalThrust / Float(active.count)
        var force = SIMD3<Float>.zero, moment = SIMD3<Float>.zero
        for rotor in active {
            let direction = rotor.cruiseThrustDirectionBody
            let localForce = direction * perRotor * rotor.thrustFactor
            force += localForce
            moment += simd_cross(rotor.offsetBody - center, localForce)
        }
        return (force, SIMD3<Float>(moment.z, moment.x, moment.y))
    }

    struct AllocationResult {
        /// Per-rotor thrust, N, index-aligned with `rotors`.
        let thrusts: [Float]
        /// Actually produced torque in (roll, pitch, yaw) rate order.
        let actualTorque: SIMD3<Float>
        /// Actually produced collective thrust, N.
        let actualCollective: Float
        /// Vector sum of every rotor force in body axes. This differs from a
        /// scalar collective once an arm/mount bends.
        let actualForceBody: SIMD3<Float>
    }

    /// Sum of `|lever|` over the rotors for each axis, in the engine's (roll, pitch, yaw) rate
    /// order: the torque produced per newton of symmetric thrust differential.
    ///
    /// Roll acts through the rotors' body-X offsets, pitch through their body-Z offsets, and yaw
    /// through the blades' reaction torque — which is why yaw is the weak axis on any multirotor
    /// (κ is a couple of percent, against arm lengths of tenths of a metre).
    var controlLeverPerNewton: SIMD3<Float> {
        var roll: Float = 0.0
        var pitch: Float = 0.0
        var yaw: Float = 0.0
        for rotor in rotors {
            roll += abs(rotor.offsetBody.x)
            pitch += abs(rotor.offsetBody.z)
            yaw += max(0.001, torqueToThrustRatio)
        }
        return SIMD3<Float>(roll, pitch, yaw)
    }

    /// Control allocation: distribute the commanded collective thrust and
    /// body torque over the rotors, clamp each rotor to what its (possibly
    /// damaged) hardware can deliver, and report the torque/thrust actually
    /// produced. Saturation and dead rotors therefore yield an honest
    /// residual moment — a quad missing a propeller cannot produce trimmed
    /// hover torque, and the resulting spin is emergent rather than
    /// scripted. For a pristine, unsaturated, geometrically symmetric layout
    /// the allocation reproduces the commanded values exactly.
    ///
    /// `desiredTorque` is in the engine's (roll, pitch, yaw) rate order.
    func allocate(
        desiredTorque: SIMD3<Float>,
        desiredCollective: Float,
        maxRotorThrust: Float
    ) -> AllocationResult {
        if cyclicTiltLimitRad > 0, !rotors.isEmpty, maxRotorThrust > 0.0001 {
            return allocateCyclic(desiredTorque: desiredTorque, desiredCollective: desiredCollective,
                                  maxRotorThrust: maxRotorThrust)
        }
        guard !rotors.isEmpty, maxRotorThrust > 0.0001 else {
            return AllocationResult(
                thrusts: [],
                actualTorque: desiredTorque,
                actualCollective: desiredCollective,
                actualForceBody: SIMD3<Float>(0.0, desiredCollective, 0.0)
            )
        }

        let count = Float(rotors.count)
        var sumX2: Float = 0.0
        var sumZ2: Float = 0.0
        for rotor in rotors {
            sumX2 += rotor.offsetBody.x * rotor.offsetBody.x
            sumZ2 += rotor.offsetBody.z * rotor.offsetBody.z
        }
        sumX2 = max(0.0005, sumX2)
        sumZ2 = max(0.0005, sumZ2)
        let kappa = max(0.001, torqueToThrustRatio)

        var thrusts: [Float] = []
        thrusts.reserveCapacity(rotors.count)
        var actualTorqueAxes = SIMD3<Float>(repeating: 0.0)
        var actualCollective: Float = 0.0
        var actualForceBody = SIMD3<Float>(repeating: 0.0)

        for rotor in rotors {
            // Least-squares per-channel distribution (exact for symmetric
            // layouts; mild physical cross-coupling for asymmetric ones).
            let base = desiredCollective / count
            let rollShare = desiredTorque.x * rotor.offsetBody.x / sumX2
            let pitchShare = desiredTorque.y * (-rotor.offsetBody.z) / sumZ2
            let yawShare = desiredTorque.z * rotor.spinSign / (kappa * count)
            let commanded = base + rollShare + pitchShare + yawShare

            let ceiling = maxRotorThrust * rotor.thrustFactor.clamped(to: 0.0...1.0)
            let actual = commanded.clamped(to: 0.0...max(0.0, ceiling))
            thrusts.append(actual)

            let direction = simd_length_squared(rotor.thrustDirectionBody) > 0.0001
                ? simd_normalize(rotor.thrustDirectionBody)
                : SIMD3<Float>(0.0, 1.0, 0.0)
            let force = direction * actual
            let reactionTorque = direction * (rotor.spinSign * kappa * actual)
            actualTorqueAxes += simd_cross(rotor.offsetBody, force) + reactionTorque
            actualForceBody += force
            actualCollective += max(0.0, force.y)
        }

        return AllocationResult(
            thrusts: thrusts,
            actualTorque: SIMD3<Float>(actualTorqueAxes.z, actualTorqueAxes.x, actualTorqueAxes.y),
            actualCollective: actualCollective,
            actualForceBody: actualForceBody
        )
    }

    // MARK: - Damage factors

    private func allocateCyclic(desiredTorque: SIMD3<Float>, desiredCollective: Float,
                                maxRotorThrust: Float) -> AllocationResult {
        let lever = max(0.05, rotors.map { simd_length($0.offsetBody) }.max() ?? 0.05)
        let target = SIMD4<Float>(desiredCollective, desiredTorque.x / lever,
                                  desiredTorque.y / lever, desiredTorque.z / lever)
        func column(_ rotor: VehicleRotor, _ force: SIMD3<Float>) -> SIMD4<Float> {
            let torque = simd_cross(rotor.offsetBody, force) + force * (rotor.spinSign * torqueToThrustRatio)
            return SIMD4<Float>(force.y, torque.z / lever, torque.x / lever, torque.y / lever)
        }
        var forces = rotors.map { rotor in
            rotor.thrustDirectionBody * min(maxRotorThrust * rotor.thrustFactor,
                                           max(0, desiredCollective) / Float(rotors.count))
        }
        let axes = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]
        let columns = rotors.map { rotor in axes.map { column(rotor, $0) } }
        var produced = zip(rotors, forces).reduce(SIMD4<Float>.zero) { $0 + column($1.0, $1.1) }
        // Projected coordinate descent on actual force/moment balance. Projection
        // enforces each rotor's remaining thrust and cyclic cone, including a dead
        // rotor. No torque is manufactured on an absent lateral rotor arm.
        for _ in 0..<40 {
            for i in rotors.indices {
                for axis in 0..<3 {
                    let c = columns[i][axis]
                    let delta = simd_dot(target - produced, c) / max(0.0001, simd_dot(c, c)) * 0.7
                    forces[i][axis] += delta
                    produced += c * delta
                }
                let direction = simd_normalize(rotors[i].thrustDirectionBody)
                let axial = max(0, simd_dot(forces[i], direction))
                var lateral = forces[i] - direction * simd_dot(forces[i], direction)
                let lateralLimit = axial * tan(cyclicTiltLimitRad)
                if simd_length(lateral) > lateralLimit {
                    lateral *= lateralLimit / max(0.0001, simd_length(lateral))
                }
                var projected = direction * axial + lateral
                let ceiling = maxRotorThrust * rotors[i].thrustFactor
                if simd_length(projected) > ceiling {
                    projected *= ceiling / max(0.0001, simd_length(projected))
                }
                produced += column(rotors[i], projected - forces[i])
                forces[i] = projected
            }
        }
        let force = forces.reduce(SIMD3<Float>.zero, +)
        return AllocationResult(thrusts: forces.map { simd_length($0) },
            actualTorque: SIMD3<Float>(produced.y, produced.z, produced.w) * lever,
            actualCollective: max(0, force.y), actualForceBody: force)
    }

    /// Achievable-thrust fraction of a propeller at the given integrity —
    /// slightly superlinear: blade area loss costs more thrust than the raw
    /// integrity fraction (spec: 0.9 chip / 0.6 noticeable / 0.3 heavy
    /// imbalance / 0.0 destroyed).
    static func propellerThrustFactor(integrity: Float) -> Float {
        guard integrity > 0.001 else { return 0.0 }
        return pow(integrity.clamped(to: 0.0...1.0), 1.3)
    }

    /// Achievable-thrust fraction of a motor at the given integrity: a
    /// damaged motor derates but keeps most of its output until it dies.
    static func motorThrustFactor(integrity: Float) -> Float {
        guard integrity > 0.001 else { return 0.0 }
        return 0.3 + 0.7 * integrity.clamped(to: 0.0...1.0)
    }

    /// Imbalance of a damaged blade: peaks mid-damage (a badly chipped but
    /// still-spinning prop shakes hardest), fades toward both pristine and
    /// fully destroyed (nothing left to shake).
    static func propellerVibration(integrity: Float) -> Float {
        let n = integrity.clamped(to: 0.0...1.0)
        guard n > 0.001 else { return 0.0 }
        return (2.2 * n * (1.0 - n)).clamped(to: 0.0...1.0)
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
