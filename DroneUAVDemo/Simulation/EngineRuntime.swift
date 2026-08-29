import Foundation

/// Where an engine is in its start sequence.
///
/// A fuel engine does not go from "armed" to "making thrust" in one tick, and
/// modelling it that way is what let an aircraft be launched off a catapult with a
/// dead engine. The published sequences differ by engine class but share this
/// shape, so one state machine covers all of them with different parameters:
///
///  * Spark-ignition piston (Lycoming EL-005 on the Aerosonde): the ECU meters the
///    prime itself — there is no manual choke — then the starter cranks, the engine
///    fires and warms up.
///  * Rotary (UEL AR-741 on the RQ-7B): electric starter, otherwise the same.
///  * Turboprop (Honeywell TPE331-10 on the MQ-9A): the starter spins the rotor,
///    ignition and fuel come in at about 10 % speed, the 18–28 % band must be
///    passed without hanging or the start is aborted, and the starter and igniters
///    drop out around 50–60 %.
///  * Small turbojet (AMT on the BWB DELTA): starter spool, glow-plug ignition on
///    start gas, light-off, then acceleration to a stable idle — under 30 s.
enum EngineRunState: String, Hashable, CaseIterable {
    /// Cold and still.
    case off
    /// Fuel on and the charge being metered in. Skipped by turbines.
    case priming
    /// Starter turning the engine, below the speed at which it can light.
    case cranking
    /// It has fired but is not yet self-sustaining at idle.
    case lightOff
    /// Self-sustaining, but still cold.
    case warmingUp
    /// At operating temperature and free to be given power.
    case ready
    /// A start attempt failed — flooded, hung, or the starter gave up.
    case startAborted
    /// Ran and then stopped: fuel exhaustion, damage, or commanded shutdown.
    case stopped

    /// Is the engine turning under its own combustion?
    var isFiring: Bool {
        switch self {
        case .lightOff, .warmingUp, .ready: return true
        case .off, .priming, .cranking, .startAborted, .stopped: return false
        }
    }

    /// May the aircraft be launched? Idle alone is not enough — a cold engine that
    /// is asked for full power on a catapult stroke is how a real one bogs down.
    var isClearedForLaunch: Bool { self == .ready }

    var localizationKey: String { "engine.state.\(rawValue)" }
}

/// Live engine state: where it is in the start sequence, how fast it is turning
/// and how hot it is.
struct EngineRuntimeState: Hashable {
    var runState: EngineRunState
    /// Output-shaft speed, rev/min. For a turbojet this is the rotor speed.
    var shaftRPM: Float
    /// Shaft power actually delivered this tick, kW. Zero unless firing.
    var shaftPowerKW: Float
    /// A single lumped engine temperature, °C.
    var temperatureC: Float
    /// Seconds spent in the current state.
    var phaseElapsed: Float
    /// How many times a start has been attempted, to enforce a cartridge's one shot.
    var startAttempts: Int
    /// Operator/autopilot request: should the engine be running at all?
    var startRequested: Bool

    static func cold(ambientTemperatureC: Float = 15.0) -> EngineRuntimeState {
        EngineRuntimeState(
            runState: .off,
            shaftRPM: 0.0,
            shaftPowerKW: 0.0,
            temperatureC: ambientTemperatureC,
            phaseElapsed: 0.0,
            startAttempts: 0,
            startRequested: false
        )
    }

    /// Speed as a fraction of rated, which is how every start threshold below is
    /// expressed — it is the only form that is the same number for a 5,500 rpm
    /// two-stroke and a 41,730 rpm gas generator.
    func speedFraction(ratedRPM: Float) -> Float {
        ratedRPM > 1.0 ? min(2.0, max(0.0, shaftRPM / ratedRPM)) : 0.0
    }

    var isProducingPower: Bool { runState.isFiring && shaftPowerKW > 0.0 }
}

/// Per-class start and running parameters.
struct EngineOperatingEnvelope: Hashable {
    /// Fraction of rated speed the starter can drag the engine to.
    let crankSpeedFraction: Float
    /// Above this fraction the engine can light.
    let lightOffSpeedFraction: Float
    /// Self-sustaining speed once lit.
    let idleSpeedFraction: Float
    /// Starter and igniters drop out here.
    let starterCutoutFraction: Float
    /// Seconds of priming before cranking. Zero for turbines.
    let primeSeconds: Float
    /// Seconds the starter needs to reach crank speed.
    let crankSeconds: Float
    /// Seconds from light-off to a stable idle.
    let lightOffSeconds: Float
    /// Seconds at idle before the engine is cleared for full power.
    let warmupSeconds: Float
    /// Speed band a turbine must not linger in during the start. Empty for pistons.
    let hangBand: ClosedRange<Float>?
    /// Operating temperature, °C. `ready` waits for this.
    let operatingTemperatureC: Float
    /// Temperature above which the engine derates.
    let deratingTemperatureC: Float
    /// Rotational inertia of the whole turning assembly on the output shaft,
    /// kg·m² — crank/rotor **and** the propeller, since on a direct-drive UAV the
    /// disc usually dominates. Sized so the torque balance settles in a physical
    /// time at the engine's 1/90 s substep rather than oscillating.
    let shaftInertia: Float

    static func envelope(for engineType: UAVEngineType) -> EngineOperatingEnvelope {
        switch engineType {
        case .electricMotor:
            // An electric motor has no start sequence worth the name.
            return EngineOperatingEnvelope(
                crankSpeedFraction: 1.0, lightOffSpeedFraction: 0.0, idleSpeedFraction: 0.0,
                starterCutoutFraction: 0.0, primeSeconds: 0.0, crankSeconds: 0.0,
                lightOffSeconds: 0.0, warmupSeconds: 0.0, hangBand: nil,
                operatingTemperatureC: 20.0, deratingTemperatureC: 110.0, shaftInertia: 0.002
            )
        case .pistonTwoStroke:
            return EngineOperatingEnvelope(
                crankSpeedFraction: 0.14, lightOffSpeedFraction: 0.10, idleSpeedFraction: 0.30,
                starterCutoutFraction: 0.22, primeSeconds: 1.2, crankSeconds: 1.6,
                lightOffSeconds: 1.4, warmupSeconds: 18.0, hangBand: nil,
                operatingTemperatureC: 95.0, deratingTemperatureC: 165.0, shaftInertia: 0.012
            )
        case .pistonFourStroke:
            return EngineOperatingEnvelope(
                crankSpeedFraction: 0.16, lightOffSpeedFraction: 0.11, idleSpeedFraction: 0.28,
                starterCutoutFraction: 0.24, primeSeconds: 1.6, crankSeconds: 2.0,
                lightOffSeconds: 1.6, warmupSeconds: 26.0, hangBand: nil,
                operatingTemperatureC: 90.0, deratingTemperatureC: 160.0, shaftInertia: 0.060
            )
        case .wankelRotary:
            // Rotaries light readily and warm quickly — little reciprocating mass.
            return EngineOperatingEnvelope(
                crankSpeedFraction: 0.15, lightOffSpeedFraction: 0.10, idleSpeedFraction: 0.26,
                starterCutoutFraction: 0.22, primeSeconds: 0.8, crankSeconds: 1.4,
                lightOffSeconds: 1.2, warmupSeconds: 14.0, hangBand: nil,
                operatingTemperatureC: 105.0, deratingTemperatureC: 180.0, shaftInertia: 0.100
            )
        case .turboprop:
            // TPE331 figures: fuel and ignition at 10 %, do not linger between
            // 18 % and 28 %, starter and igniters out at 50–60 %, idle around 65 %.
            return EngineOperatingEnvelope(
                crankSpeedFraction: 0.10, lightOffSpeedFraction: 0.10, idleSpeedFraction: 0.65,
                starterCutoutFraction: 0.55, primeSeconds: 0.0, crankSeconds: 6.0,
                lightOffSeconds: 22.0, warmupSeconds: 30.0, hangBand: 0.18...0.28,
                operatingTemperatureC: 320.0, deratingTemperatureC: 700.0, shaftInertia: 25.0
            )
        case .turbojet:
            return EngineOperatingEnvelope(
                crankSpeedFraction: 0.08, lightOffSpeedFraction: 0.07, idleSpeedFraction: 0.30,
                starterCutoutFraction: 0.28, primeSeconds: 0.0, crankSeconds: 4.0,
                lightOffSeconds: 12.0, warmupSeconds: 10.0, hangBand: 0.12...0.20,
                operatingTemperatureC: 420.0, deratingTemperatureC: 780.0, shaftInertia: 0.06
            )
        case .ramjet:
            // A ramjet has no shaft, so almost every field here is a formality: there is
            // nothing to crank, nothing to spool and no speed fraction that means
            // anything. What it does have is an ignition delay and a running
            // temperature, and those are real. Every speed fraction is zero so that
            // `speedFraction` arithmetic elsewhere treats it as permanently "at idle
            // speed" rather than as an engine that has failed to spool.
            return EngineOperatingEnvelope(
                crankSpeedFraction: 0.0, lightOffSpeedFraction: 0.0, idleSpeedFraction: 0.0,
                starterCutoutFraction: 0.0, primeSeconds: 0.0, crankSeconds: 0.0,
                lightOffSeconds: 1.5, warmupSeconds: 0.0, hangBand: nil,
                operatingTemperatureC: 900.0, deratingTemperatureC: 1_500.0, shaftInertia: 0.001
            )
        }
    }
}

struct EngineUpdateInput {
    let powerplant: UAVPowerplantSpec
    /// 0...1 power lever. Only obeyed once the engine is running.
    let throttle: Float
    /// Operator/autopilot wants the engine running.
    let startRequested: Bool
    let atmosphere: AtmosphereState
    /// True airspeed, m/s — a stopped engine can be windmill-restarted in flight.
    let airspeedMps: Float
    let isAirborne: Bool
    /// Fuel is available to burn.
    let hasFuel: Bool
    /// Functional health from the component-failure runtime, 0...1.
    let healthFactor: Float
    /// Power the propeller demanded of the shaft at last tick's speed, W.
    ///
    /// This is what closes the loop. A running propeller engine's speed is not a
    /// filtered copy of the throttle lever — it is wherever engine torque and disc
    /// torque balance, and since disc power grows with the cube of speed while
    /// engine power does not, that equilibrium is stable and finds itself. It is
    /// also why the same engine turns slower on a coarser disc and speeds up as the
    /// aircraft accelerates and the disc unloads. Zero for a turbojet, which has no
    /// propeller to load it.
    let propellerAbsorbedPowerW: Float
}

/// Turns a start request and a throttle lever into shaft speed, shaft power and a
/// temperature — the layer that has to exist before "throttle" can mean anything
/// physical for a fuel aircraft.
final class EngineRuntimeService {
    /// Fraction of rated power available at a given shaft speed. An engine below
    /// idle makes essentially nothing; power then rises with speed and falls away
    /// past rated as a real torque curve does.
    static func powerFractionForSpeed(_ speedFraction: Float, idleFraction: Float) -> Float {
        guard speedFraction > idleFraction * 0.5 else { return 0.0 }
        let span = max(0.05, 1.0 - idleFraction)
        let normalized = ((speedFraction - idleFraction) / span).clamped(to: -1.0...1.6)
        if normalized <= 0.0 {
            // Between the sustaining speed and idle it only makes enough to keep
            // itself turning.
            return max(0.0, 0.06 + 0.10 * (1.0 + normalized))
        }
        // Rises to rated at rated speed, then droops — overspeeding a piston or a
        // fixed-geometry turbine does not keep buying power.
        let rising = 0.16 + 0.84 * min(1.0, normalized)
        let droop = normalized > 1.0 ? max(0.55, 1.0 - (normalized - 1.0) * 0.7) : 1.0
        return rising * droop
    }

    /// How much of its sea-level rating the engine can make in the air it is in.
    static func altitudeFactor(engineType: UAVEngineType, densityRatio: Float) -> Float {
        switch engineType {
        case .electricMotor:
            return 1.0
        case .turboprop:
            // Flat-rated well above the altitudes flown here.
            return max(0.55, pow(densityRatio, 0.35))
        case .turbojet:
            return max(0.20, densityRatio)
        default:
            // A naturally aspirated piston loses power almost one-for-one with density.
            return max(0.20, densityRatio)
        }
    }

    func update(
        current: EngineRuntimeState,
        input: EngineUpdateInput,
        deltaTime: Float
    ) -> EngineRuntimeState {
        var next = current
        let dt = max(0.0001, deltaTime)
        let envelope = EngineOperatingEnvelope.envelope(for: input.powerplant.engineType)
        let ratedRPM = max(1.0, input.powerplant.ratedShaftRPM ?? 6000.0)
        next.startRequested = input.startRequested
        next.phaseElapsed += dt

        // An electric motor is commanded, not started.
        if input.powerplant.engineType == .electricMotor {
            next.runState = input.startRequested ? .ready : .off
            next.shaftRPM = input.startRequested ? ratedRPM * input.throttle.clampedUnit() : 0.0
            next.shaftPowerKW = (input.powerplant.ratedShaftPowerKW ?? 0.0) * input.throttle.clampedUnit()
            return next
        }

        // A ramjet is not started, it is *arrived at*. It has no shaft to crank and no
        // idle to settle at, so the shaft-speed state machine below has nothing to work
        // with; running it through that machine would have it cranking a rotor it does
        // not have and aborting the start when the rotor failed to spin up.
        //
        // What it does have is a flight condition. Below its light-off Mach there is no
        // compression, no combustion and no thrust — not a small thrust, none — and if
        // the aircraft ever drops back below that Mach the flame goes out again.
        if input.powerplant.engineType == .ramjet {
            return updateRamjet(next, input: input, envelope: envelope, deltaTime: dt)
        }

        let ambient = input.atmosphere.temperatureK - 273.15
        let speedFraction = next.speedFraction(ratedRPM: ratedRPM)

        // A commanded shutdown, running dry, or a dead engine all stop it.
        let mustStop = !input.startRequested || !input.hasFuel || input.healthFactor <= 0.02
        if mustStop && current.runState.isFiring {
            next = transition(next, to: .stopped)
        }

        switch next.runState {
        case .off, .stopped, .startAborted:
            if input.startRequested && input.hasFuel && input.healthFactor > 0.02 {
                let canRestart = input.powerplant.starter.supportsRestart || next.startAttempts == 0
                // Enough airspeed will windmill a dead engine back up even when the
                // starter is spent — the standard fallback for a cartridge start.
                let canWindmill = input.isAirborne && input.airspeedMps > 25.0
                if canRestart || canWindmill {
                    next.startAttempts += 1
                    next = transition(next, to: envelope.primeSeconds > 0.0 ? .priming : .cranking)
                }
            }
            // Spin down.
            next.shaftRPM = max(0.0, next.shaftRPM - ratedRPM * dt * 0.6)
            next.shaftPowerKW = 0.0

        case .priming:
            next.shaftPowerKW = 0.0
            if next.phaseElapsed >= envelope.primeSeconds {
                next = transition(next, to: .cranking)
            }

        case .cranking:
            // The starter drags the engine toward crank speed.
            let target = ratedRPM * envelope.crankSpeedFraction
            let rate = target / max(0.2, envelope.crankSeconds)
            next.shaftRPM = min(target, next.shaftRPM + rate * dt)
            next.shaftPowerKW = 0.0
            if speedFraction >= envelope.lightOffSpeedFraction {
                next = transition(next, to: .lightOff)
            } else if next.phaseElapsed > envelope.crankSeconds * 3.0 + 2.0 {
                next = transition(next, to: .startAborted)
            }

        case .lightOff:
            // Accelerating on its own combustion up to idle. The rate is scaled by
            // the power actually available, so a sick or badly loaded engine really
            // does accelerate more slowly instead of following a scripted ramp.
            //
            // That matters for more than realism: with a fixed ramp the hang-band
            // check below could never fire, because the engine always passed
            // through the band on schedule no matter what state it was in. The band
            // was decorative. Tying the ramp to available power makes hanging a
            // thing that can actually happen.
            let target = ratedRPM * envelope.idleSpeedFraction
            let accelerationAuthority = (input.healthFactor.clampedUnit()
                * Self.altitudeFactor(
                    engineType: input.powerplant.engineType,
                    densityRatio: input.atmosphere.densityRatio
                )).clamped(to: 0.0...1.0)
            let rate = max(1.0, (target - ratedRPM * envelope.lightOffSpeedFraction))
                / max(0.2, envelope.lightOffSeconds)
            next.shaftRPM = min(target, next.shaftRPM + rate * accelerationAuthority * dt)
            next.shaftPowerKW = 0.0
            // A turbine that sits in its hang band is not accelerating and the start
            // must be cut — sitting there is how one is cooked. Published TPE331
            // guidance is explicit: do not operate between 18 % and 28 % during the
            // start, and abort if the acceleration stalls there.
            if let hangBand = envelope.hangBand,
               hangBand.contains(speedFraction),
               next.phaseElapsed > envelope.lightOffSeconds * 0.9 {
                next = transition(next, to: .startAborted)
            } else if speedFraction >= envelope.idleSpeedFraction * 0.98 {
                next = transition(next, to: .warmingUp)
            } else if next.phaseElapsed > envelope.lightOffSeconds * 2.5 + 3.0 {
                next = transition(next, to: .startAborted)
            }

        case .warmingUp, .ready:
            let altitude = Self.altitudeFactor(
                engineType: input.powerplant.engineType,
                densityRatio: input.atmosphere.densityRatio
            )
            let overheat = next.temperatureC > envelope.deratingTemperatureC
                ? max(0.35, 1.0 - (next.temperatureC - envelope.deratingTemperatureC) / 220.0)
                : 1.0
            let ratedPowerW = max(1.0, (input.powerplant.ratedShaftPowerKW ?? 0.0) * 1000.0)
            // Wide-open-throttle power at this shaft speed, then throttled back.
            // The idle floor is what stops a closed throttle from stopping the
            // engine dead.
            let wideOpenPowerW = ratedPowerW
                * Self.powerFractionForSpeed(
                    next.speedFraction(ratedRPM: ratedRPM),
                    idleFraction: envelope.idleSpeedFraction
                )
                * altitude * overheat * input.healthFactor.clampedUnit()
            let leverAuthority = 0.10 + 0.90 * input.throttle.clampedUnit()
            let enginePowerW = max(0.0, wideOpenPowerW * leverAuthority)

            if input.powerplant.hasConstantSpeedPropeller {
                // Governed installation: the propeller governor, not the disc's
                // torque, sets shaft speed. It coarsens the blades as the aircraft
                // accelerates and fines them off at low speed, so the shaft holds
                // its commanded speed and the disc absorbs whatever the engine
                // makes. Modelling this one as a fixed-pitch torque balance is what
                // pinned the MQ-9A at half its rated speed and an eighth of its
                // rated power for an entire takeoff roll — the engine could not
                // out-torque a disc that only unloads once the aircraft is already
                // fast. The lever reaches governed speed well before it reaches
                // full power, which is why a turboprop run-up sounds like it does.
                let commanded = envelope.idleSpeedFraction
                    + (1.0 - envelope.idleSpeedFraction)
                    * min(1.0, input.throttle.clampedUnit() * 3.0)
                let targetRPM = ratedRPM * commanded
                let governorTau: Float = 1.4
                next.shaftRPM += (targetRPM - next.shaftRPM) * min(1.0, dt / governorTau)
            } else if input.powerplant.drivesPropeller {
                // Torque balance against the disc. Semi-implicit and clamped, so a
                // stiff combination cannot run away between substeps.
                let omega = max(1.0, next.shaftRPM * Float.pi / 30.0)
                let engineTorque = enginePowerW / omega
                let propellerTorque = max(0.0, input.propellerAbsorbedPowerW) / omega
                let inertia = max(0.001, envelope.shaftInertia)
                let omegaNext = omega + dt * (engineTorque - propellerTorque) / inertia
                // A running engine cannot be dragged below its sustaining speed by
                // the disc; below that it would simply stall, which is a separate
                // failure and not something a cruise throttle should cause.
                let minimumOmega = ratedRPM * envelope.idleSpeedFraction * 0.72 * Float.pi / 30.0
                let maximumOmega = ratedRPM * 1.25 * Float.pi / 30.0
                next.shaftRPM = omegaNext.clamped(to: minimumOmega...maximumOmega) * 30.0 / Float.pi
            } else {
                // No disc to load a turbojet: the rotor follows the lever through
                // its own spool inertia.
                let commanded = envelope.idleSpeedFraction
                    + (1.0 - envelope.idleSpeedFraction) * input.throttle.clampedUnit()
                let targetRPM = ratedRPM * commanded
                let spoolTau = (envelope.shaftInertia * ratedRPM * ratedRPM / ratedPowerW)
                    .clamped(to: 0.30...8.0)
                next.shaftRPM += (targetRPM - next.shaftRPM) * min(1.0, dt / spoolTau)
            }

            next.shaftPowerKW = enginePowerW / 1000.0

            if next.runState == .warmingUp,
               next.temperatureC >= envelope.operatingTemperatureC * 0.92
                   || next.phaseElapsed >= envelope.warmupSeconds {
                next = transition(next, to: .ready)
            }
        }

        // --- Thermal node. Heat in with load, out with airspeed and density.
        let loadFraction = (input.powerplant.ratedShaftPowerKW ?? 0.0) > 0.01
            ? (next.shaftPowerKW / (input.powerplant.ratedShaftPowerKW ?? 1.0)).clampedUnit()
            : 0.0
        let steadyTemperature = next.runState.isFiring
            ? ambient + (envelope.operatingTemperatureC - 15.0) * (0.55 + 0.75 * loadFraction)
            : ambient
        // Cooling improves with the mass flow over the engine, which is airspeed
        // times density — a stationary engine on a hot ramp runs hotter than the
        // same engine in the cruise.
        let coolingAirflow = 1.0 + (input.airspeedMps * input.atmosphere.densityRatio) / 45.0
        let thermalTau = (next.runState.isFiring ? 22.0 : 55.0) / coolingAirflow
        next.temperatureC += (steadyTemperature - next.temperatureC) * min(1.0, dt / max(0.5, thermalTau))

        return next
    }

    /// The ramjet's whole state machine: is the aircraft fast enough, and has the flame
    /// had time to take hold?
    ///
    /// Three states rather than eight. `off` while it is too slow or not commanded,
    /// `lightOff` for the ignition delay once it is fast enough, `ready` while it burns.
    /// Dropping below the light-off Mach is a flameout, and re-lighting means going
    /// through the delay again — a ramjet that falls out of its envelope does not simply
    /// pick up where it left off.
    private func updateRamjet(
        _ current: EngineRuntimeState,
        input: EngineUpdateInput,
        envelope: EngineOperatingEnvelope,
        deltaTime: Float
    ) -> EngineRuntimeState {
        var next = current
        let mach = input.atmosphere.machNumber(trueAirspeedMps: input.airspeedMps)
        let hasRam = mach >= FuelPropulsionBackend.ramjetMinimumOperableMach
        let commanded = input.startRequested && input.hasFuel && input.healthFactor > 0.02
        let ambient = input.atmosphere.temperatureK - 273.15

        // No rotor. Reporting a shaft speed would invite every consumer that divides by
        // rated RPM to believe there is one.
        next.shaftRPM = 0.0
        next.shaftPowerKW = 0.0

        if !commanded || !hasRam {
            if current.runState.isFiring {
                next = transition(next, to: .stopped)
            } else if current.runState != .stopped {
                next = transition(next, to: .off)
            }
            // Cools toward ambient once the flame is out.
            next.temperatureC += (ambient - next.temperatureC) * min(1.0, deltaTime * 0.12)
            return next
        }

        switch next.runState {
        case .off, .stopped, .startAborted, .priming, .cranking:
            next = transition(next, to: .lightOff)
        case .lightOff:
            if next.phaseElapsed >= envelope.lightOffSeconds {
                next = transition(next, to: .ready)
            }
        case .warmingUp, .ready:
            next.runState = .ready
        }

        // Total temperature is the physical target: the air arrives already heated by
        // its own deceleration, and combustion adds to that. It is why a ramjet's
        // structure is a materials problem before it is an aerodynamic one.
        let totalTemperatureC = CompressibleFlowState(
            atmosphere: input.atmosphere,
            trueAirspeedMps: input.airspeedMps
        ).totalTemperatureK - 273.15
        let target = next.runState.isFiring
            ? max(envelope.operatingTemperatureC, totalTemperatureC)
            : ambient
        next.temperatureC += (target - next.temperatureC) * min(1.0, deltaTime * 0.35)
        return next
    }

    private func transition(_ state: EngineRuntimeState, to next: EngineRunState) -> EngineRuntimeState {
        guard state.runState != next else { return state }
        var updated = state
        updated.runState = next
        updated.phaseElapsed = 0.0
        return updated
    }
}

private extension Float {
    func clampedUnit() -> Float { Swift.min(1.0, Swift.max(0.0, self)) }
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
