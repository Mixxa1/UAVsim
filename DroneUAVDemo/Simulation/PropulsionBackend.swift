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
    let inlet: HighSpeedInletModel

    init?(
        powerplant: UAVPowerplantSpec?,
        cruiseSpeedMps: Float,
        inletOverride: UAVInletType? = nil
    ) {
        guard let powerplant, powerplant.energySource == .fuel else { return nil }
        self.powerplant = powerplant
        self.propeller = PropellerModel.resolve(
            powerplant: powerplant,
            cruiseSpeedMps: cruiseSpeedMps
        )
        // A frame that states its own intake overrides whatever the powerplant descriptor
        // implies. That ordering is right round: the intake is part of the airframe, not
        // part of the engine — the same engine behind a pitot intake and behind a variable
        // ramp is two different aircraft above Mach 1.5, and it is the airframe that decides
        // which one was built.
        self.inlet = inletOverride.map { HighSpeedInletModel(type: $0) }
            ?? HighSpeedInletModel(powerplant: powerplant)
    }

    // MARK: - Jet thrust against flight condition

    /// Uninstalled thrust of a turbojet relative to its static sea-level rating, as a
    /// function of Mach at ideal (loss-free) intake recovery.
    ///
    /// A table, because a thrust map is a table. The shape is the one every turbojet
    /// shares and it is not monotonic: accelerating from rest the engine first loses
    /// thrust, because the momentum drag of the air it swallows (`ṁ·V₀`) grows faster
    /// than the momentum of what it throws out. Somewhere around Mach 0.8 ram
    /// compression starts winning and thrust climbs past its static value, reaching
    /// half again as much by Mach 2. Past about Mach 2.5 the air arrives so hot that
    /// the turbine temperature limit forces the fuel back, and the curve turns over.
    ///
    /// That non-monotonic dip is why a marginal aircraft can be unable to accelerate
    /// through the transonic even though it has thrust to spare at both ends — the
    /// drag rise and the thrust minimum happen at the same place.
    /// The high-Mach half of this curve was raised after the reference aircraft were
    /// flown against their published performance. It first read 1.58 at Mach 2, which is
    /// low against the corrected-thrust data for engines of this class — a J85 at Mach 2
    /// makes closer to twice its altitude-corrected static thrust, because the intake is
    /// by then doing more compression than the compressor is. The original figure was an
    /// estimate; the published maximum speeds it was measured against are data, and where
    /// the two disagree the data wins.
    private static let turbojetRamCurve = BreakpointTable1D([
        (0.00, 1.00),
        (0.30, 0.94),
        (0.50, 0.90),
        (0.70, 0.91),
        (0.90, 0.98),
        (1.20, 1.22),
        (1.50, 1.50),
        (2.00, 1.95),
        (2.50, 2.20),
        (3.00, 2.05),
        (3.50, 1.55),
        (4.00, 0.95)
    ])

    /// Ramjet thrust relative to its own rated figure, against Mach.
    ///
    /// Zero below the light-off Mach and it is a hard zero, not a small number: with no
    /// compressor there is nothing to raise the pressure but the aircraft's own speed,
    /// so at rest a ramjet is a pipe. The curve peaks in the Mach 3–3.5 region, which
    /// is what the engine exists for.
    private static let ramjetCurve = BreakpointTable1D([
        (0.00, 0.00),
        (1.00, 0.00),
        (1.60, 0.06),
        (2.00, 0.32),
        (2.50, 0.68),
        (3.00, 0.93),
        (3.50, 1.00),
        (4.00, 0.92),
        (4.50, 0.74),
        (5.00, 0.48)
    ])

    /// Lowest Mach at which a ramjet can sustain combustion at all.
    static let ramjetMinimumOperableMach: Float = 1.6

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

    /// Thrust from an engine with no propeller — turbojet or ramjet.
    ///
    /// What this replaces was `rated × spool² × densityRatio`: an engine that produced
    /// exactly the same thrust standing on the runway as it did at Mach 2, because
    /// nothing in the expression knew how fast the aircraft was going. That is the one
    /// thing the plan singles out as unacceptable — "the same throttle does not mean the
    /// same thrust in all conditions" — and it is also why the only jet in the catalogue
    /// flew acceptably: it never accelerated far enough for the error to show.
    ///
    /// Four independent factors now decide the answer, and they pull in different
    /// directions, which is the point:
    ///
    ///  - **Spool.** How much of its rated speed the engine is actually turning.
    ///  - **Ambient pressure.** Thrust follows the pressure ratio δ, not the density
    ///    ratio. At 15 km δ is 0.12 while ρ/ρ₀ is 0.19; using density flattered every
    ///    jet at altitude by more than half.
    ///  - **Ram.** The flight-speed curve — a dip through the low subsonic, then real
    ///    growth as the intake starts doing the compressor's job for it.
    ///  - **Intake recovery.** What survives of the total pressure, which is where a
    ///    plain hole and a variable ramp part company entirely.
    func jetOutput(
        engine: EngineRuntimeState,
        flow: CompressibleFlowState,
        angleOfAttackRad: Float = 0.0
    ) -> PropulsionOutput {
        let atmosphere = flow.atmosphere
        let ratedThrust = powerplant.totalRatedThrustN ?? 0.0
        let envelope = EngineOperatingEnvelope.envelope(for: powerplant.engineType)
        let ratedRPM = max(1.0, powerplant.ratedShaftRPM ?? 30_000.0)
        let mach = flow.mach

        // Ambient pressure ratio. A jet's thrust is set by the mass flow it can swallow,
        // and that follows pressure far more closely than it follows density.
        let pressureRatio = min(
            1.2,
            max(0.0, atmosphere.pressurePa / AtmosphereModel.seaLevelPressurePa)
        )
        let recovery = inlet.pressureRecovery(mach: mach, angleOfAttackRad: angleOfAttackRad)

        let thrust: Float
        let clearedForLaunch: Bool

        switch powerplant.engineType {
        case .ramjet:
            // No spool, no shaft, no start sequence — a ramjet either has the flight
            // condition to burn or it does not. Fuel is admitted only inside the
            // envelope, and below the light-off Mach the answer is a hard zero rather
            // than a small number, because there is no mechanism to make anything at all.
            let inEnvelope = mach >= Self.ramjetMinimumOperableMach
                && inlet.isWithinEnvelope(mach: mach)
            let commanded = engine.runState.isFiring ? 1.0 : Float(0.0)
            thrust = inEnvelope
                ? ratedThrust
                    * Self.ramjetCurve.sample(mach)
                    * pressureRatio
                    * recovery
                    * commanded
                : 0.0
            // A ramjet can never clear a launch by itself: whatever gets the aircraft to
            // its light-off Mach is not this engine.
            clearedForLaunch = false

        case .turbojet:
            let speed = engine.speedFraction(ratedRPM: ratedRPM)
            let above = max(0.0, speed - envelope.idleSpeedFraction)
                / max(0.05, 1.0 - envelope.idleSpeedFraction)
            let spool = engine.runState.isFiring ? (0.06 + 0.94 * above * above) : 0.0
            // Outside the intake's envelope the shock system is expelled and the engine
            // loses most of its air at once. The full unstart dynamics are future work;
            // what is modelled is that leaving the envelope costs most of the thrust
            // rather than nothing.
            let envelopePenalty: Float = inlet.isWithinEnvelope(mach: mach) ? 1.0 : 0.35
            thrust = ratedThrust
                * spool
                * pressureRatio
                * Self.turbojetRamCurve.sample(mach)
                * recovery
                * envelopePenalty
            clearedForLaunch = engine.runState.isClearedForLaunch

        case .electricMotor, .pistonTwoStroke, .pistonFourStroke, .wankelRotary, .turboprop:
            // Not reachable: these all drive a propeller and never arrive here. Written
            // out rather than defaulted so that adding an engine type stays a compile
            // error in this switch.
            thrust = 0.0
            clearedForLaunch = engine.runState.isClearedForLaunch
        }

        return PropulsionOutput(
            thrustNewtons: max(0.0, thrust),
            shaftRPM: engine.shaftRPM,
            shaftPowerKW: engine.shaftPowerKW,
            propellerEfficiency: 0.0,
            advanceRatio: 0.0,
            runState: engine.runState,
            temperatureC: engine.temperatureC,
            isClearedForLaunch: clearedForLaunch
        )
    }

    func output(
        engine: EngineRuntimeState,
        airspeedMps: Float,
        atmosphere: AtmosphereState
    ) -> PropulsionOutput {
        let density = atmosphere.airDensity

        guard let propeller else {
            return jetOutput(
                engine: engine,
                flow: CompressibleFlowState(
                    atmosphere: atmosphere,
                    trueAirspeedMps: airspeedMps
                )
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
