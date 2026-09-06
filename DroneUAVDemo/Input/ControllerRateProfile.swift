import Foundation

// How far a stick has to move before the aircraft does something, and how much it does.
//
// Separate from `ControllerAxisMap` on purpose, and split the way a transmitter splits it: the
// binding owns the *hardware* — which physical axis, which way round, how much slop around centre —
// and this owns the *feel*. Two aircraft on the same gamepad want the same dead zone and different
// rates.

// MARK: - One axis

/// The stick-to-rate curve for a single rotational axis, in the shape pilots already know from a
/// flight controller: a sensitivity, a ramp towards the ends of the travel, and centre softening.
///
/// One deliberate difference from a real flight controller, and it is the honest one: `sensitivity`
/// is a fraction of *the airframe's own* maximum rate, not an absolute figure in degrees per second.
/// The aeroplane or the quad decides how fast it can actually rotate — a slider cannot grant an
/// airframe authority its motors do not have — so what this sets is how much of that ceiling full
/// stick asks for.
struct ControllerAxisRates: Codable, Equatable {
    /// What full deflection commands, as a share of the airframe's maximum rate. 1 is everything
    /// the aircraft has; 0.5 is a deliberately calmer aircraft.
    var sensitivity: Double
    /// How much of the travel is spent in the gentle part before the curve ramps to the ceiling.
    /// 0 is a straight line; higher values keep the middle of the stick soft and put the sharpness
    /// at the ends.
    var superRate: Double
    /// Centre softening. The usual RC expo: it does not change what full stick does, only how
    /// quickly you get there.
    var expo: Double

    init(sensitivity: Double = 1, superRate: Double = 0.55, expo: Double = 0.3) {
        self.sensitivity = sensitivity
        self.superRate = superRate
        self.expo = expo
    }

    /// The commanded rate for a stick at `input` (−1…1), as a share of the airframe's maximum.
    func command(_ input: Double) -> Double {
        let clamped = min(1, max(-1, input))
        let magnitude = abs(clamped)
        guard magnitude > 0 else { return 0 }
        let shaped = expoShaped(magnitude) * superShaped(magnitude) * clampedSensitivity
        return clamped < 0 ? -shaped : shaped
    }

    /// The share of the ceiling reached at half stick. The single number that says what the curve
    /// is actually doing, and the one worth putting on screen next to the sliders.
    var halfStickShare: Double { command(0.5) }

    var clampedSensitivity: Double { min(1, max(0.1, sensitivity)) }

    private func expoShaped(_ magnitude: Double) -> Double {
        let e = min(1, max(0, expo))
        return magnitude * magnitude * magnitude * e + magnitude * (1 - e)
    }

    /// Normalised so full stick always lands exactly on `sensitivity`: the ramp redistributes the
    /// travel, it does not add authority at the end of it.
    private func superShaped(_ magnitude: Double) -> Double {
        let s = min(1, max(0, superRate)) * 0.9
        guard s > 0 else { return magnitude / max(0.0001, magnitude) == 0 ? 0 : 1 }
        let atInput = 1 / max(0.01, 1 - magnitude * s)
        let atFull = 1 / max(0.01, 1 - s)
        return atInput / atFull
    }
}

// MARK: - Throttle

/// The throttle's own curve. A throttle is not a rate axis: it has no centre, and what a pilot
/// wants shaped is where the hover point sits in the travel.
struct ControllerThrottleCurve: Codable, Equatable {
    /// Where the curve's inflection sits in the travel, 0…1. Put it at the hover point and the
    /// stick becomes fine around hover and coarse at the extremes.
    var mid: Double
    /// How pronounced that shaping is. 0 is a straight line.
    var expo: Double
    /// The bottom of the usable range. An armed multirotor with its stick at the very bottom is
    /// still turning its motors; this is where that floor sits.
    var idle: Double

    init(mid: Double = 0.5, expo: Double = 0, idle: Double = 0.04) {
        self.mid = mid
        self.expo = expo
        self.idle = idle
    }

    /// Maps a raw 0…1 stick position onto the commanded throttle.
    func shaped(_ position: Double) -> Double {
        let x = min(1, max(0, position))
        let m = min(0.9, max(0.1, mid))
        let e = min(1, max(0, expo))
        let offset = x - m
        // The flight-controller throttle curve: linear through the mid point, bent away from it in
        // proportion to expo and to the distance from it.
        let reference = offset > 0 ? (1 - m) : m
        let bent = m + offset * (1 - e + e * (offset * offset) / max(0.0001, reference * reference))
        let curved = min(1, max(0, bent))
        let floor = min(0.3, max(0, idle))
        return floor + (1 - floor) * curved
    }
}

// MARK: - The profile

struct ControllerRateProfile: Codable, Equatable {
    var roll: ControllerAxisRates
    var pitch: ControllerAxisRates
    var yaw: ControllerAxisRates
    var throttle: ControllerThrottleCurve

    init(
        roll: ControllerAxisRates = ControllerAxisRates(),
        pitch: ControllerAxisRates = ControllerAxisRates(),
        // Yaw is deliberately calmer than roll and pitch, the way nearly every rate profile ends
        // up: a quad's yaw authority is its weakest axis and its most easily over-commanded.
        yaw: ControllerAxisRates = ControllerAxisRates(sensitivity: 0.85, superRate: 0.45, expo: 0.25),
        throttle: ControllerThrottleCurve = ControllerThrottleCurve()
    ) {
        self.roll = roll
        self.pitch = pitch
        self.yaw = yaw
        self.throttle = throttle
    }

    static let `default` = ControllerRateProfile()

    /// A deliberately gentle profile: full stick asks for about half the airframe's rate, with a
    /// soft middle. What to hand somebody who has never flown one of these.
    static let calm = ControllerRateProfile(
        roll: ControllerAxisRates(sensitivity: 0.55, superRate: 0.35, expo: 0.45),
        pitch: ControllerAxisRates(sensitivity: 0.55, superRate: 0.35, expo: 0.45),
        yaw: ControllerAxisRates(sensitivity: 0.5, superRate: 0.3, expo: 0.4),
        throttle: ControllerThrottleCurve(mid: 0.5, expo: 0.2, idle: 0.04)
    )

    /// Everything the airframe has, with the sharpness pushed to the ends of the travel.
    static let sharp = ControllerRateProfile(
        roll: ControllerAxisRates(sensitivity: 1, superRate: 0.75, expo: 0.2),
        pitch: ControllerAxisRates(sensitivity: 1, superRate: 0.75, expo: 0.2),
        yaw: ControllerAxisRates(sensitivity: 1, superRate: 0.6, expo: 0.2),
        throttle: ControllerThrottleCurve(mid: 0.5, expo: 0, idle: 0.05)
    )

    func rates(for function: ControllerAxisFunction) -> ControllerAxisRates? {
        switch function {
        case .roll: return roll
        case .pitch: return pitch
        case .yaw: return yaw
        default: return nil
        }
    }

    mutating func setRates(_ rates: ControllerAxisRates, for function: ControllerAxisFunction) {
        switch function {
        case .roll: roll = rates
        case .pitch: pitch = rates
        case .yaw: yaw = rates
        default: break
        }
    }
}
