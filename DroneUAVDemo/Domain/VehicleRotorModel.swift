import Foundation
import simd

/// One physical rotor (motor + propeller) of the per-rotor thrust model.
struct VehicleRotor: Hashable {
    /// Graph slot ("FL", "M5", "cruise"...) — matches `motor.<slot>` /
    /// `propeller.<slot>` component ids in the vehicle component graph.
    let slot: String
    /// Rotor position relative to the airframe's center of mass, body frame
    /// (+Y up, -Z forward). CoM-relative so torque lever arms are direct.
    let offsetBody: SIMD3<Float>
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
        rotors.allSatisfy { $0.thrustFactor > 0.999 && $0.vibration01 < 0.001 }
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

    struct AllocationResult {
        /// Per-rotor thrust, N, index-aligned with `rotors`.
        let thrusts: [Float]
        /// Actually produced torque in (roll, pitch, yaw) rate order.
        let actualTorque: SIMD3<Float>
        /// Actually produced collective thrust, N.
        let actualCollective: Float
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
        guard !rotors.isEmpty, maxRotorThrust > 0.0001 else {
            return AllocationResult(
                thrusts: [],
                actualTorque: desiredTorque,
                actualCollective: desiredCollective
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
        var actualRoll: Float = 0.0
        var actualPitch: Float = 0.0
        var actualYaw: Float = 0.0
        var actualCollective: Float = 0.0

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

            actualRoll += rotor.offsetBody.x * actual
            actualPitch += -rotor.offsetBody.z * actual
            actualYaw += rotor.spinSign * kappa * actual
            actualCollective += actual
        }

        return AllocationResult(
            thrusts: thrusts,
            actualTorque: SIMD3<Float>(actualRoll, actualPitch, actualYaw),
            actualCollective: actualCollective
        )
    }

    // MARK: - Damage factors

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
        guard n > 0.001 else { return 0.15 }
        return (2.2 * n * (1.0 - n)).clamped(to: 0.0...1.0)
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
