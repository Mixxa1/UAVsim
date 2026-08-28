import Foundation

/// Live fuel quantity for a fuel-burning aircraft.
///
/// Deliberately a real mass in kilograms rather than a percentage: the whole point
/// of the fuel work is that burning fuel makes the aircraft lighter, and a
/// percentage cannot do that. `consumedKg` is what the physics engine subtracts
/// from the airframe's resolved mass, so at full tanks it is zero and every
/// aircraft weighs exactly what it did before this model existed.
struct FuelSystemState: Hashable {
    /// Usable fuel at full tanks.
    let capacityKg: Float
    /// Fraction of `capacityKg` a mission planner should treat as untouchable.
    let reserveFraction: Float
    var remainingKg: Float
    /// Instantaneous mass flow.
    var flowKgPerSec: Float
    /// True once usable fuel is exhausted — the fuel-side equivalent of
    /// `BatteryState.isDepleted`.
    var isStarved: Bool
    /// Steady loss from a punctured tank or line, independent of engine demand.
    var leakKgPerSec: Float

    static func full(capacityKg: Float, reserveFraction: Float) -> FuelSystemState {
        FuelSystemState(
            capacityKg: max(0.0, capacityKg),
            reserveFraction: min(max(reserveFraction, 0.0), 0.5),
            remainingKg: max(0.0, capacityKg),
            flowKgPerSec: 0.0,
            isStarved: false,
            leakKgPerSec: 0.0
        )
    }

    /// Fuel already gone — burned or leaked. This is the term that changes mass.
    var consumedKg: Float {
        max(0.0, capacityKg - remainingKg)
    }

    var fractionRemaining: Float {
        capacityKg > 0.0001 ? (remainingKg / capacityKg).clampedUnit() : 0.0
    }

    var reserveKg: Float {
        capacityKg * reserveFraction
    }

    /// Fuel available before biting into the declared reserve.
    var usableAboveReserveKg: Float {
        max(0.0, remainingKg - reserveKg)
    }

    var isBelowReserve: Bool {
        remainingKg <= reserveKg
    }

    var flowKgPerHour: Float {
        flowKgPerSec * 3600.0
    }

    /// Seconds of flight left at the current flow. `nil` while the engine is not
    /// consuming anything, because an endurance figure from a zero flow is a
    /// division by zero dressed up as data.
    var estimatedEnduranceSec: Float? {
        guard flowKgPerSec > 1.0e-7 else { return nil }
        return remainingKg / flowKgPerSec
    }

    var estimatedEnduranceToReserveSec: Float? {
        guard flowKgPerSec > 1.0e-7 else { return nil }
        return usableAboveReserveKg / flowKgPerSec
    }
}

struct FuelBurnInput {
    let powerplant: UAVPowerplantSpec
    /// Commanded/achieved throttle, 0...1. Only used when no engine model is
    /// supplying real shaft power.
    let throttle: Float
    /// True while the engine should be consuming fuel at all.
    let engineRunning: Bool
    let atmosphere: AtmosphereState
    /// Extra loss from tank or line damage, kg/s.
    let leakKgPerSec: Float
    /// Shaft power the engine is actually delivering, kW.
    ///
    /// When present this replaces the throttle-to-power proxy entirely, which is
    /// the whole point: consumption is `BSFC × shaft power`, and the shaft power is
    /// now a real number produced by the engine/propeller torque balance rather
    /// than a curve fitted to the lever position.
    let shaftPowerKW: Float?

    init(
        powerplant: UAVPowerplantSpec,
        throttle: Float,
        engineRunning: Bool,
        atmosphere: AtmosphereState,
        leakKgPerSec: Float,
        shaftPowerKW: Float? = nil
    ) {
        self.powerplant = powerplant
        self.throttle = throttle
        self.engineRunning = engineRunning
        self.atmosphere = atmosphere
        self.leakKgPerSec = leakKgPerSec
        self.shaftPowerKW = shaftPowerKW
    }
}

/// Turns throttle into a real fuel mass flow.
///
/// This is the specific-consumption half of the plan's fuel model: flow is
/// `BSFC × shaft power` for anything with a propeller and `TSFC × thrust` for a
/// turbojet, not a percentage per minute. It is deliberately *not* a full engine
/// model — there is no RPM state, no torque map and no spool dynamics yet, so
/// shaft power is taken as a throttle-to-power curve off the engine's rating.
/// That is enough to make endurance, range and the mass change physical, and it
/// leaves the engine's own dynamics to the propulsion subsystem that replaces the
/// calibrated thrust backend.
final class FuelBurnService {
    /// Brake specific fuel consumption, kg per kWh of shaft work.
    static func brakeSpecificConsumptionKgPerKWh(for engineType: UAVEngineType) -> Float {
        switch engineType {
        case .electricMotor:
            return 0.0
        case .pistonTwoStroke:
            // Two-strokes lose fuel out of the exhaust port during scavenging.
            return 0.45
        case .pistonFourStroke:
            return 0.32
        case .wankelRotary:
            return 0.40
        case .turboprop:
            return 0.30
        case .turbojet:
            return 0.0
        }
    }

    /// Thrust specific fuel consumption, kg per newton-hour. Small turbojets are
    /// dramatically thirstier per unit thrust than the metre-class engines that
    /// power cruise missiles and target drones, so this is not one number.
    static func thrustSpecificConsumptionKgPerNH(ratedThrustN: Float) -> Float {
        ratedThrustN < 400.0 ? 0.18 : 0.11
    }

    /// Fraction of rated output an engine delivers at a given throttle. The floor
    /// is idle: a running engine burns fuel at closed throttle.
    static func outputFraction(throttle: Float, engineType: UAVEngineType) -> Float {
        let idle: Float
        switch engineType {
        case .turbojet, .turboprop:
            idle = 0.12
        default:
            idle = 0.06
        }
        let commanded = throttle.clampedUnit()
        return (idle + (1.0 - idle) * commanded).clampedUnit()
    }

    func update(
        current: FuelSystemState,
        input: FuelBurnInput,
        deltaTime: Float
    ) -> FuelSystemState {
        var next = current
        let dt = max(0.0, deltaTime)

        var burnKgPerSec: Float = 0.0
        if input.engineRunning && !current.isStarved {
            let fraction = Self.outputFraction(
                throttle: input.throttle,
                engineType: input.powerplant.engineType
            )
            if input.powerplant.engineType == .turbojet {
                let ratedThrust = input.powerplant.totalRatedThrustN ?? 0.0
                let tsfc = Self.thrustSpecificConsumptionKgPerNH(
                    ratedThrustN: input.powerplant.ratedThrustN ?? ratedThrust
                )
                // A turbojet's thrust falls roughly with density, and so does the
                // fuel it burns making it.
                let thrust = ratedThrust * fraction * input.atmosphere.densityRatio
                burnKgPerSec = tsfc * thrust / 3600.0
            } else {
                let bsfc = Self.brakeSpecificConsumptionKgPerKWh(for: input.powerplant.engineType)
                let shaftPowerKW: Float
                if let measured = input.shaftPowerKW {
                    // Real delivered power from the engine model. An idling engine
                    // still burns, so there is a floor rather than a hard zero.
                    let ratedPowerKW = input.powerplant.totalRatedShaftPowerKW ?? 0.0
                    shaftPowerKW = max(measured, ratedPowerKW * 0.04)
                } else {
                    let ratedPowerKW = input.powerplant.totalRatedShaftPowerKW ?? 0.0
                    // A naturally aspirated piston engine loses power with density
                    // almost one-for-one; a turboprop is flat-rated far higher and
                    // barely notices the altitudes this simulation flies at.
                    let altitudeFactor: Float
                    switch input.powerplant.engineType {
                    case .turboprop:
                        altitudeFactor = max(0.55, pow(input.atmosphere.densityRatio, 0.35))
                    default:
                        altitudeFactor = max(0.25, input.atmosphere.densityRatio)
                    }
                    shaftPowerKW = ratedPowerKW * fraction * altitudeFactor
                }
                burnKgPerSec = bsfc * shaftPowerKW / 3600.0
            }
        }

        let leak = max(0.0, input.leakKgPerSec)
        next.leakKgPerSec = leak
        next.flowKgPerSec = burnKgPerSec
        next.remainingKg = max(0.0, current.remainingKg - (burnKgPerSec + leak) * dt)
        // Starvation latches: an engine that has run the tanks dry does not
        // restart because the aircraft pitched down and sloshed a litre forward.
        next.isStarved = current.isStarved || next.remainingKg <= 0.0
        if next.isStarved {
            next.flowKgPerSec = 0.0
        }
        return next
    }
}

private extension Float {
    func clampedUnit() -> Float {
        Swift.min(1.0, Swift.max(0.0, self))
    }
}
