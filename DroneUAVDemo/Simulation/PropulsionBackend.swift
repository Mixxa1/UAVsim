import Foundation
import simd

/// What the flight model consumes from any propulsion installation, whatever kind
/// it is. The plan's `PropulsionOutput`: the solver takes a force and some
/// telemetry and never asks what is making it.
struct PropulsionOutput: Hashable {
    /// Net axial force along the aircraft's thrust line, N. Negative when a stopped
    /// propeller is windmilling.
    let thrustNewtons: Float
    let shaftRPM: Float
    let shaftPowerKW: Float
    /// Propulsive efficiency at this operating point, 0...1. Zero for a turbojet.
    let propellerEfficiency: Float
    let advanceRatio: Float
    let runState: EngineRunState
    let temperatureC: Float
    /// May the launch sequence proceed?
    let isClearedForLaunch: Bool

    static let inert = PropulsionOutput(
        thrustNewtons: 0.0,
        shaftRPM: 0.0,
        shaftPowerKW: 0.0,
        propellerEfficiency: 0.0,
        advanceRatio: 0.0,
        runState: .off,
        temperatureC: 15.0,
        isClearedForLaunch: false
    )
}

/// Engine + propeller (or turbojet) chain for fuel-burning aircraft.
///
/// This is the backend that replaces `wingborneThrustMagnitude` for fuel aircraft.
/// That helper stays exactly as it was and remains the only backend for every
/// battery-electric profile, because it is calibrated against their tuned cruise
/// and climb figures and nothing here should re-open that calibration.
///
/// The difference that matters: calibrated thrust is derived from the airframe's
/// own weight, so shedding fuel removed thrust in the same proportion and burning
/// it bought nothing. Here thrust comes from `Ct·rho·n²·D⁴` with `n` set by the
/// engine/disc torque balance, so weight does not appear in it at all — a lighter
/// aircraft simply needs less lift, and climbs.
struct FuelPropulsionBackend {
    let powerplant: UAVPowerplantSpec
    let propeller: PropellerModel?

    init?(powerplant: UAVPowerplantSpec?, cruiseSpeedMps: Float) {
        guard let powerplant, powerplant.energySource == .fuel else { return nil }
        self.powerplant = powerplant
        self.propeller = PropellerModel.resolve(
            powerplant: powerplant,
            cruiseSpeedMps: cruiseSpeedMps
        )
    }

    /// Power the disc is demanding at the shaft's current speed — fed back into the
    /// engine so the two find their equilibrium.
    func propellerLoadWatts(
        engine: EngineRuntimeState,
        airspeedMps: Float,
        airDensity: Float
    ) -> Float {
        guard let propeller, engine.runState.isFiring else { return 0.0 }
        // A governed disc absorbs whatever the engine delivers by definition, so
        // there is no separate load to feed back — reporting the fixed-pitch curve's
        // demand here would only re-open the torque balance the governor replaces.
        guard !propeller.isConstantSpeed else { return engine.shaftPowerKW * 1000.0 }
        return propeller.absorbedPowerWatts(
            airspeedMps: airspeedMps,
            shaftRPM: engine.shaftRPM,
            airDensity: airDensity
        )
    }

    func output(
        engine: EngineRuntimeState,
        airspeedMps: Float,
        atmosphere: AtmosphereState
    ) -> PropulsionOutput {
        let density = atmosphere.airDensity

        guard let propeller else {
            // Turbojet: thrust scales with the square of spool fraction above idle
            // and falls with density, which is why a jet on a hot high day is
            // sluggish and why a spooling engine makes almost nothing.
            let ratedThrust = powerplant.totalRatedThrustN ?? 0.0
            let envelope = EngineOperatingEnvelope.envelope(for: powerplant.engineType)
            let ratedRPM = max(1.0, powerplant.ratedShaftRPM ?? 30_000.0)
            let speed = engine.speedFraction(ratedRPM: ratedRPM)
            let above = max(0.0, speed - envelope.idleSpeedFraction)
                / max(0.05, 1.0 - envelope.idleSpeedFraction)
            let spoolThrust = engine.runState.isFiring
                ? ratedThrust * (0.06 + 0.94 * above * above) * atmosphere.densityRatio
                : 0.0
            return PropulsionOutput(
                thrustNewtons: max(0.0, spoolThrust),
                shaftRPM: engine.shaftRPM,
                shaftPowerKW: engine.shaftPowerKW,
                propellerEfficiency: 0.0,
                advanceRatio: 0.0,
                runState: engine.runState,
                temperatureC: engine.temperatureC,
                isClearedForLaunch: engine.runState.isClearedForLaunch
            )
        }

        guard engine.runState.isFiring else {
            // Dead engine: the disc keeps turning in the airflow and costs drag.
            return PropulsionOutput(
                thrustNewtons: -propeller.windmillingDragNewtons(
                    airspeedMps: airspeedMps,
                    airDensity: density
                ),
                shaftRPM: engine.shaftRPM,
                shaftPowerKW: 0.0,
                propellerEfficiency: 0.0,
                advanceRatio: 0.0,
                runState: engine.runState,
                temperatureC: engine.temperatureC,
                isClearedForLaunch: false
            )
        }

        let advanceRatio = propeller.advanceRatio(
            airspeedMps: airspeedMps,
            shaftRPM: engine.shaftRPM
        )
        let thrust = propeller.thrustNewtons(
            airspeedMps: airspeedMps,
            shaftRPM: engine.shaftRPM,
            shaftPowerW: engine.shaftPowerKW * 1000.0,
            airDensity: density
        )
        return PropulsionOutput(
            thrustNewtons: thrust,
            shaftRPM: engine.shaftRPM,
            shaftPowerKW: engine.shaftPowerKW,
            // A governed disc's efficiency is measured, not looked up: the Ct/Cp
            // curve describes a blade angle it is not holding.
            propellerEfficiency: propeller.isConstantSpeed
                ? min(0.95, max(0.0, engine.shaftPowerKW > 0.001
                    ? thrust * airspeedMps / (engine.shaftPowerKW * 1000.0)
                    : 0.0))
                : propeller.efficiency(advanceRatio: advanceRatio),
            advanceRatio: advanceRatio,
            runState: engine.runState,
            temperatureC: engine.temperatureC,
            isClearedForLaunch: engine.runState.isClearedForLaunch
        )
    }
}
