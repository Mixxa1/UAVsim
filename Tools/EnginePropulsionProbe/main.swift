import Foundation
import simd

// Headless probe for the engine start sequence and the engine/propeller chain.
//
// Four questions:
//
//  1. Does each engine actually run through its start sequence in a plausible
//     time, and does a turbine abort rather than sit in its hang band?
//  2. Does the self-calibrated propeller absorb its engine's rated power at the
//     design point? That is the constraint the whole propeller sizing rests on —
//     if the disc cannot absorb the power, the shaft runs away; if it absorbs too
//     much, the engine bogs and the aircraft never flies.
//  3. Can the propeller produce more thrust at cruise than the airframe's drag?
//     This is the one that decides whether these aircraft fly at all.
//  4. Does burning fuel now IMPROVE climb? It could not with the calibrated
//     backend, because that derived thrust from weight. This is the check that
//     says the physical chain actually replaced it.
//
// Run: Tools/EnginePropulsionProbe/run.sh

var failures: [String] = []
let repository = LIPODroneModelRepository()
let engineService = EngineRuntimeService()
let atmosphere = AtmosphereModel.standard
let seaLevel = atmosphere.state(altitudeMeters: 0)

struct Subject {
    let runtime: DroneModelProfile
    let uav: UAVProfile
    let powerplant: UAVPowerplantSpec
    let backend: FuelPropulsionBackend
}

let subjects: [Subject] = repository.allProfiles.compactMap { runtime in
    guard let uav = runtime.resolvedUAVProfile,
          let powerplant = uav.powerplant,
          powerplant.energySource == .fuel,
          let backend = FuelPropulsionBackend(
              powerplant: powerplant,
              cruiseSpeedMps: runtime.fixedWingParameters?.cruiseSpeedMps ?? 30.0
          ) else { return nil }
    return Subject(runtime: runtime, uav: uav, powerplant: powerplant, backend: backend)
}

// MARK: - 1. Start sequence

print("Engine start — seconds spent reaching each state at full throttle demand")
print(String(repeating: "-", count: 96))
print(String(format: "%-22@ %-14@ %8@ %8@ %8@ %9@ %9@",
             "profile" as NSString, "engine" as NSString, "crank" as NSString,
             "light" as NSString, "idle" as NSString, "ready" as NSString, "rpm" as NSString))

let dt: Float = 1.0 / 90.0

for subject in subjects {
    var engine = EngineRuntimeState.cold(ambientTemperatureC: 15.0)
    var timeToState: [EngineRunState: Float] = [:]
    var elapsed: Float = 0.0
    while elapsed < 180.0 {
        let load = subject.backend.propellerLoadWatts(
            engine: engine,
            airspeedMps: 0.0,
            airDensity: seaLevel.airDensity
        )
        engine = engineService.update(
            current: engine,
            input: EngineUpdateInput(
                powerplant: subject.powerplant,
                throttle: 0.0,           // start at idle, as a real start is run
                startRequested: true,
                atmosphere: seaLevel,
                airspeedMps: 0.0,
                isAirborne: false,
                hasFuel: true,
                healthFactor: 1.0,
                propellerAbsorbedPowerW: load
            ),
            deltaTime: dt
        )
        elapsed += dt
        if timeToState[engine.runState] == nil { timeToState[engine.runState] = elapsed }
        if engine.runState == .ready || engine.runState == .startAborted { break }
    }

    func stamp(_ state: EngineRunState) -> String {
        timeToState[state].map { String(format: "%.1f", $0) } ?? "-"
    }
    print(String(format: "%-22@ %-14@ %8@ %8@ %8@ %9@ %9.0f",
                 subject.runtime.displayName as NSString,
                 subject.powerplant.engineType.rawValue as NSString,
                 stamp(.cranking) as NSString, stamp(.lightOff) as NSString,
                 stamp(.warmingUp) as NSString, stamp(.ready) as NSString,
                 engine.shaftRPM))

    if engine.runState != .ready {
        failures.append("\(subject.runtime.displayName): engine never reached ready (\(engine.runState.rawValue))")
    }
    // A start that takes over two minutes is not a start.
    if let readyAt = timeToState[.ready], readyAt > 120.0 {
        failures.append(String(format: "%@ took %.0f s to start", subject.runtime.displayName, readyAt))
    }
}

// A turbine held in its hang band must abort rather than cook.
if let turboprop = subjects.first(where: { $0.powerplant.engineType == .turboprop }) {
    var engine = EngineRuntimeState.cold()
    engine.runState = .lightOff
    let envelope = EngineOperatingEnvelope.envelope(for: .turboprop)
    let ratedRPM = turboprop.powerplant.ratedShaftRPM ?? 1591.0
    engine.shaftRPM = ratedRPM * ((envelope.hangBand?.lowerBound ?? 0.2) + 0.01)
    var elapsed: Float = 0.0
    // Zero power available: the shaft cannot accelerate out of the band.
    while elapsed < 90.0 && engine.runState == .lightOff {
        engine = engineService.update(
            current: engine,
            input: EngineUpdateInput(
                // A badly derated engine: enough health to keep running, not
                // enough to accelerate out of the band. Zeroing health instead
                // would simply shut the engine down, which tests nothing.
                powerplant: turboprop.powerplant, throttle: 0.0, startRequested: true,
                atmosphere: seaLevel, airspeedMps: 0.0, isAirborne: false,
                hasFuel: true, healthFactor: 0.04, propellerAbsorbedPowerW: 0.0
            ),
            deltaTime: dt
        )
        elapsed += dt
    }
    print(String(format: "\nturboprop held in its 18-28%% hang band: %@ after %.1f s",
                 engine.runState.rawValue as NSString, elapsed))
    if engine.runState != .startAborted {
        failures.append("a turboprop hung in its start band did not abort the start")
    }
}

// MARK: - 2 & 3. Propeller power balance and cruise thrust against drag

print("\n\nPropeller — design point power balance, and cruise thrust against airframe drag")
print(String(repeating: "-", count: 104))
print(String(format: "%-22@ %7@ %7@ %8@ %10@ %10@ %10@ %8@",
             "profile" as NSString, "D m" as NSString, "J des" as NSString, "Cp des" as NSString,
             "absorbed kW" as NSString, "rated kW" as NSString, "thrust N" as NSString,
             "drag N" as NSString))

for subject in subjects {
    guard let propeller = subject.backend.propeller,
          let wing = subject.runtime.fixedWingParameters else { continue }
    let ratedRPM = subject.powerplant.ratedShaftRPM ?? 6000.0
    let ratedKW = subject.powerplant.ratedShaftPowerKW ?? 0.0
    let cruise = wing.cruiseSpeedMps

    let absorbedKW = propeller.absorbedPowerWatts(
        airspeedMps: cruise, shaftRPM: ratedRPM, airDensity: seaLevel.airDensity
    ) / 1000.0
    // A governed disc absorbs its engine's output; a fixed-pitch one absorbs
    // whatever its blade angle demands at this speed.
    let shaftPowerW = propeller.isConstantSpeed ? ratedKW * 1000.0 : absorbedKW * 1000.0
    let thrust = propeller.thrustNewtons(
        airspeedMps: cruise,
        shaftRPM: ratedRPM,
        shaftPowerW: shaftPowerW,
        airDensity: seaLevel.airDensity
    )

    // Airframe drag at cruise, from the same aero model the solver uses.
    let massModel = VehicleMassModel.baseline(for: subject.runtime, uavProfile: subject.uav)
    let fuelMass = subject.powerplant.fuel?.usableFuelMassKg ?? 0.0
    let mass = massModel.resolvedCurrentTotalMass + fuelMass
    let span = (subject.uav.dimensions.wingspanMillimeters ?? 2000.0) / 1000.0
    let length = (subject.uav.dimensions.fuselageLengthMillimeters ?? (span * 550.0)) / 1000.0
    let height = (subject.uav.dimensions.heightMillimeters ?? (span * 120.0)) / 1000.0
    let aero = FixedWingAerodynamics.build(
        family: wing.family, massKg: mass,
        wingSpanM: span, fuselageLengthM: length, heightM: height,
        turnAuthority: wing.turnAuthority, minSustainableSpeedMps: wing.minSustainableSpeedMps
    )
    let q = seaLevel.dynamicPressure(airspeedMps: cruise)
    // Trim angle of attack: the alpha at which lift carries the weight.
    var low: Float = 0.0
    var high: Float = 0.25
    for _ in 0..<24 {
        let mid = (low + high) * 0.5
        if q * aero.wingArea * aero.liftDrag(alphaRad: mid).cl < mass * 9.81 { low = mid } else { high = mid }
    }
    let drag = q * aero.wingArea * aero.liftDrag(alphaRad: (low + high) * 0.5).cd

    print(String(format: "%-22@ %7.2f %7.2f %8.3f %10.1f %10.1f %10.1f %8.1f",
                 subject.runtime.displayName as NSString,
                 propeller.diameterM, propeller.designAdvanceRatio,
                 propeller.designPowerCoefficient,
                 absorbedKW, ratedKW, thrust, drag))

    // The disc must absorb roughly what the engine makes at the design point.
    let balance = ratedKW > 0.01 ? absorbedKW / ratedKW : 0.0
    if balance < 0.45 || balance > 1.8 {
        failures.append(String(format: "%@: disc absorbs %.0f%% of rated power at the design point",
                               subject.runtime.displayName, balance * 100.0))
    }
    // And it must out-pull the airframe at cruise, or the aircraft cannot fly.
    if thrust <= drag {
        failures.append(String(format: "%@: cruise thrust %.1f N does not clear drag %.1f N",
                               subject.runtime.displayName, thrust, drag))
    }
}

// MARK: - 4. Does burning fuel finally buy climb?

print("\n\nMass coupling through the physical chain — full tanks against dry")
print(String(repeating: "-", count: 84))
print(String(format: "%-22@ %10@ %10@ %10@ %10@ %10@",
             "profile" as NSString, "mass full" as NSString, "mass dry" as NSString,
             "climb full" as NSString, "climb dry" as NSString, "delta" as NSString))

let physics = SimpleDronePhysicsEngine()

func measureClimb(
    _ subject: Subject,
    fuelState: FuelSystemState?,
    sampleFrom: Float = 45.0,
    sampleTo: Float = 60.0
) -> (climb: Float, mass: Float, finalAltitude: Float) {
    guard let wing = subject.runtime.fixedWingParameters else { return (0, 0, 0) }
    let massModel = VehicleMassModel.baseline(for: subject.runtime, uavProfile: subject.uav)
    var state = DroneState(
        position: SIMD3<Float>(0, 300, 0),
        velocity: SIMD3<Float>(0, 0, -wing.climbAirspeed),
        orientation: .zero, angularVelocity: .zero,
        throttle: 1.0, motorThrottle: 1.0, rotorAngularSpeed: .zero,
        forwardAirspeed: wing.climbAirspeed,
        physicalState: .airborne, mode: .autoPath
    )
    state.armState = .armed
    // Start already running, so the measurement is of the chain and not of the
    // start sequence.
    var warm = EngineRuntimeState.cold(ambientTemperatureC: 15.0)
    warm.runState = .ready
    warm.shaftRPM = (subject.powerplant.ratedShaftRPM ?? 6000.0) * 0.9
    warm.temperatureC = EngineOperatingEnvelope.envelope(for: subject.powerplant.engineType).operatingTemperatureC
    state.engineRuntime = warm

    var samples: [Float] = []
    for tick in 0..<(90 * 60) {
        let control = DroneControlInput(
            targetPosition: SIMD3<Float>(state.position.x, state.position.y + 500, state.position.z),
            targetOrientation: SIMD3<Float>(0, wing.initialClimbPitchDeg * .pi / 180.0, 0),
            yawIntent: 0.0, throttle: 1.0, isArmed: true,
            mode: .autoPath, controlMode: .stabilized
        )
        let context = DroneSimulationContext(
            profile: subject.runtime, activeUAVProfile: subject.uav,
            weather: .normal, damageState: .pristine, batteryState: .full,
            collisionRisk: 0.0, windVector: .zero, vehicleMassModel: massModel,
            fuelState: fuelState,
            engineState: state.engineRuntime,
            fuelPropulsion: subject.backend
        )
        state = physics.step(state: state, control: control, context: context, deltaTime: dt)
        let seconds = Float(tick) * dt
        if seconds >= sampleFrom && seconds <= sampleTo { samples.append(state.velocity.y) }
    }
    let climb = samples.isEmpty ? 0 : samples.reduce(0, +) / Float(samples.count)
    return (climb, massModel.resolvedCurrentTotalMass + (fuelState?.remainingKg ?? 0.0), state.position.y)
}

for subject in subjects {
    guard let fuel = subject.powerplant.fuel, fuel.usableFuelMassKg > 0.0 else { continue }
    let full = FuelSystemState.full(capacityKg: fuel.usableFuelMassKg, reserveFraction: fuel.reserveFraction)
    // Nearly dry, NOT dry. At exactly zero the engine correctly stops, so a
    // comparison against it measures engine-out, not mass. Two per cent left keeps
    // it running and isolates the thing being tested.
    var nearlyDry = full
    nearlyDry.remainingKg = fuel.usableFuelMassKg * 0.02

    let withFuel = measureClimb(subject, fuelState: full)
    let nearEmpty = measureClimb(subject, fuelState: nearlyDry)
    print(String(format: "%-22@ %10.1f %10.1f %10.2f %10.2f %+10.2f",
                 subject.runtime.displayName as NSString,
                 withFuel.mass, nearEmpty.mass,
                 withFuel.climb, nearEmpty.climb,
                 nearEmpty.climb - withFuel.climb))
    if nearEmpty.climb <= withFuel.climb {
        failures.append("\(subject.runtime.displayName): burning fuel still does not improve climb")
    }
}

// MARK: - 5. Fuel exhaustion must stop the engine and cost real drag

print("\n\nEngine-out — tanks run dry in flight")
print(String(repeating: "-", count: 72))
for subject in subjects {
    guard let fuel = subject.powerplant.fuel, fuel.usableFuelMassKg > 0.0 else { continue }
    var dry = FuelSystemState.full(capacityKg: fuel.usableFuelMassKg, reserveFraction: fuel.reserveFraction)
    dry.remainingKg = 0.0
    dry.isStarved = true
    // Sample the first seconds: a heavy aircraft with a dead engine reaches the
    // ground well inside a sixty-second window, and averaging after that measures
    // a parked aircraft rather than a glide.
    // Net altitude lost, not an averaged vertical rate. A light high-lift airframe
    // holds height for the first seconds by trading speed, and a heavy one reaches
    // the ground well inside the window and then reads zero — either way an
    // instantaneous rate at a fixed instant answers the wrong question. Whether the
    // aircraft ended up lower than it started does not.
    let dead = measureClimb(subject, fuelState: dry, sampleFrom: 10.0, sampleTo: 20.0)
    let windmilling = subject.backend.propeller.map {
        $0.windmillingDragNewtons(airspeedMps: 30.0, airDensity: seaLevel.airDensity)
    } ?? 0.0
    let altitudeLost = 300.0 - dead.finalAltitude
    print(String(format: "%-22@ lost %6.1f m of 300, windmilling drag at 30 m/s %6.1f N",
                 subject.runtime.displayName as NSString, altitudeLost, windmilling))
    if altitudeLost <= 5.0 {
        failures.append(String(format: "%@: a dry aircraft lost only %.1f m in a minute",
                               subject.runtime.displayName, altitudeLost))
    }
}

// MARK: - 6. The launch sequence must wait for the engine

print("\n\nLaunch gating — does prelaunchCheck actually check anything?")
print(String(repeating: "-", count: 84))

func runLaunch(_ subject: Subject, seedEngine: EngineRunState) -> (state: LaunchState, seconds: Float, reason: String?) {
    guard let wing = subject.runtime.fixedWingParameters else { return (.idle, 0, nil) }
    let controller = FixedWingLaunchController()
    var engine = EngineRuntimeState.cold(ambientTemperatureC: 15.0)
    engine.runState = seedEngine
    engine.shaftRPM = (subject.powerplant.ratedShaftRPM ?? 6000.0)
        * (seedEngine.isFiring ? 0.9 : 0.0)

    var aircraft = DroneState(
        position: .zero, velocity: .zero, orientation: .zero, angularVelocity: .zero,
        throttle: 0.0, motorThrottle: 0.0, rotorAngularSpeed: .zero,
        forwardAirspeed: 0.0, physicalState: .armedOnGround, mode: .takeoff
    )
    aircraft.armState = .armed
    aircraft.engineRuntime = engine

    let mode = subject.runtime.preferredLaunchMode
    let asset: LaunchAsset
    switch mode {
    case .canister:
        asset = .canister(CanisterLaunchAsset(
            position: .zero, headingDegrees: 0.0, elevationDegrees: 45.0
        ))
    case .catapult:
        asset = .catapult(CatapultLaunchAsset(
            position: .zero,
            rail: LaunchRailConfiguration(
                headingDegrees: 0.0,
                railAngleDegrees: wing.catapultRailAngleDegrees,
                launchDirectionDegrees: 0.0,
                railLengthMeters: wing.catapultRailLengthMeters,
                usesRocketBooster: wing.catapultUsesRocketBooster
            )
        ))
    case .runway:
        asset = .runway(RunwayLaunchAsset(
            position: .zero,
            headingDegrees: 0.0,
            groundAttitudeDegrees: 3.0,
            usableLengthMeters: FixedWingRunwayGeometry.stripLength(for: wing)
        ))
    default:
        asset = .handLaunch(HandLaunchAsset(
            position: .zero, headingDegrees: 0.0, launchAngleDegrees: 10.0
        ))
    }
    _ = controller.begin(
        mode: mode, asset: asset, origin: .zero,
        wing: wing, nominalLaunchMassKg: subject.runtime.takeoffMassKg
    )

    var elapsed: Float = 0.0
    var snapshot = FixedWingLaunchRuntimeSnapshot.idle
    while elapsed < 8.0 {
        snapshot = controller.update(
            aircraftState: aircraft, windVector: .zero, isArmed: true,
            batteryAvailable: true, engineState: engine, deltaTime: dt
        )
        elapsed += dt
        if snapshot.state != .prelaunchCheck { break }
    }
    return (snapshot.state, elapsed, snapshot.transitionReason)
}

for subject in subjects {
    let mode = subject.runtime.preferredLaunchMode
    // `.standard` aircraft never enter the launch controller — they are placed
    // and flown, with no launcher to gate.
    guard mode != .standard else {
        print(String(format: "%-22@ mode=standard      (no launcher to gate)",
                     subject.runtime.displayName as NSString))
        continue
    }
    let cold = runLaunch(subject, seedEngine: .off)
    let ready = runLaunch(subject, seedEngine: .ready)
    print(String(format: "%-22@ mode=%-10@ cold engine -> %-16@ ready engine -> %@",
                 subject.runtime.displayName as NSString,
                 mode.rawValue as NSString,
                 cold.state.rawValue as NSString,
                 ready.state.rawValue as NSString))

    if mode.requiresRunningEngineBeforeRelease {
        if cold.state != .prelaunchCheck {
            failures.append("\(subject.runtime.displayName): a cold engine did not hold the launch")
        }
        if ready.state == .prelaunchCheck {
            failures.append("\(subject.runtime.displayName): a ready engine did not release the launch")
        }
    } else if cold.state == .prelaunchCheck {
        // A canister launch must NOT wait for an engine it cannot start in the tube.
        failures.append("\(subject.runtime.displayName): a canister launch waited for a ground engine start")
    }
}

// MARK: - 7. Ground run: full throttle from a standing start must not tip it over
//
// Every one of these reproduces a failure seen in the app. A HESA Karrar rolled
// past 70 degrees at 3 m/s; an MQ-9A flipped during its ground roll at 34 m/s;
// the whole Harpy family sat at full throttle and never moved at all.

// A component graph with a non-zero centre-of-mass offset and a real contact
// profile — the configuration the app always runs in, and the one this probe was
// blind to. Without it the graph mass path never engaged, so a moment applied
// through the centre-of-mass lever produced nothing here while it stood the whole
// fleet on its tail in the app.
func groundTestMassProperties(_ subject: Subject) -> (VehicleMassProperties, VehicleContactProfile) {
    let massModel = VehicleMassModel.baseline(for: subject.runtime, uavProfile: subject.uav)
    let dryMass = max(0.2, massModel.resolvedCurrentTotalMass)
    let span = (subject.uav.dimensions.wingspanMillimeters ?? 2000.0) / 1000.0
    let length = (subject.uav.dimensions.fuselageLengthMillimeters ?? span * 0.55) / 1000.0
    let properties = VehicleMassProperties(
        totalMassKg: dryMass,
        // Slightly low and slightly aft, as a real build comes out.
        centerOfMassOffset: SIMD3<Float>(0.0, -0.02, 0.05),
        inertiaDiagonal: SIMD3<Float>(
            dryMass * span * span / 12.0,
            dryMass * length * length / 12.0,
            dryMass * (span * span + length * length) / 12.0
        )
    )
    let profile = VehicleContactProfile(
        spheres: [
            VehicleContactSphere(componentID: "gear.main", offset: SIMD3<Float>(0, -0.25, 0), radius: 0.25),
            VehicleContactSphere(componentID: "tail", offset: SIMD3<Float>(0, -0.15, -0.6), radius: 0.15)
        ],
        boundingRadius: max(0.5, span * 0.5)
    )
    return (properties, profile)
}

// Sixty seconds, not thirty. A TPE331 needs twenty-seven of them just to reach
// operating speed, so a thirty-second window measured an engine start and called
// it a failed takeoff roll.
let groundRunSeconds = 60

print("\n\nGround run — full throttle from rest, sixty seconds")
print(String(repeating: "-", count: 96))
print(String(format: "%-22@ %10@ %10@ %10@ %9@ %12@",
             "profile" as NSString, "speed m/s" as NSString, "|roll| deg" as NSString,
             "|pitch| deg" as NSString, "gear" as NSString, "engine" as NSString))

for subject in subjects {
    guard let wing = subject.runtime.fixedWingParameters,
          let fuel = subject.powerplant.fuel else { continue }
    let massModel = VehicleMassModel.baseline(for: subject.runtime, uavProfile: subject.uav)
    var state = DroneState(
        position: .zero, velocity: .zero, orientation: .zero, angularVelocity: .zero,
        throttle: 0.0, motorThrottle: 0.0, rotorAngularSpeed: .zero,
        forwardAirspeed: 0.0, physicalState: .armedOnGround, mode: .manual
    )
    state.armState = .armed
    var fuelState = FuelSystemState.full(
        capacityKg: fuel.usableFuelMassKg, reserveFraction: fuel.reserveFraction
    )

    let (groundMass, groundContact) = groundTestMassProperties(subject)
    var worstRoll: Float = 0.0
    var worstPitch: Float = 0.0
    for _ in 0..<(90 * groundRunSeconds) {
        let control = DroneControlInput(
            targetPosition: .zero,
            targetOrientation: .zero,
            yawIntent: 0.0, throttle: 1.0, isArmed: true,
            mode: .manual, controlMode: .stabilized
        )
        let context = DroneSimulationContext(
            profile: subject.runtime, activeUAVProfile: subject.uav,
            weather: .normal, damageState: .pristine, batteryState: .full,
            collisionRisk: 0.0, windVector: .zero, vehicleMassModel: massModel,
            vehicleMassProperties: groundMass,
            contactProfile: groundContact,
            fuelState: fuelState,
            engineState: state.engineRuntime,
            fuelPropulsion: subject.backend
        )
        state = physics.step(state: state, control: control, context: context, deltaTime: dt)
        // Only judge attitude while still on the ground; once it flies, bank is fine.
        if state.position.y < 3.0 {
            worstRoll = max(worstRoll, abs(state.orientation.x) * 180.0 / .pi)
            worstPitch = max(worstPitch, abs(state.orientation.y) * 180.0 / .pi)
        }
        fuelState.remainingKg = max(0.0, fuelState.remainingKg - 0.001 * dt)
    }

    let engineState = state.engineRuntime?.runState.rawValue ?? "-"
    let wheeled = wing.hasWheeledUndercarriage
    print(String(format: "%-22@ %10.1f %10.1f %10.1f %9@ %12@",
                 subject.runtime.displayName as NSString,
                 state.forwardAirspeed, worstRoll, worstPitch,
                 (wheeled ? "wheels" : "skid") as NSString,
                 engineState as NSString))

    if worstRoll > 35.0 {
        failures.append(String(format: "%@ rolled to %.0f deg on the ground at full throttle",
                               subject.runtime.displayName, worstRoll))
    }
    // Rearing onto the tail. Every fuel aircraft did this once a moment was applied
    // through the centre-of-mass lever: pitch ran away while the aircraft was still
    // doing well under a metre per second, with no airspeed to damp it.
    if worstPitch > 25.0 {
        failures.append(String(format: "%@ pitched to %.0f deg on the ground at full throttle",
                               subject.runtime.displayName, worstPitch))
    }
    // Full power must actually move the aircraft. The Harpy family managed zero
    // because a canister start policy refused to run the engine anywhere but in
    // the air.
    //
    // Only a wheeled airframe is held to a takeoff-roll standard. A skid-borne
    // catapult or canister UAV genuinely cannot take off from the ground — it
    // drags its belly at a friction coefficient an order of magnitude above a
    // tyre's — and asserting that it reaches a fifth of its stall speed would be
    // asserting something false about the aircraft, not about the code. It still
    // has to break away and accelerate, which is what caught the start-policy bug.
    let minimumGroundSpeed = wing.hasWheeledUndercarriage
        ? max(4.0, wing.minSustainableSpeedMps * 0.20)
        : 3.0
    if state.forwardAirspeed < minimumGroundSpeed {
        failures.append(String(format: "%@ reached only %.1f m/s after %d s at full throttle",
                               subject.runtime.displayName, state.forwardAirspeed, groundRunSeconds))
    }
}

// MARK: - 8. A catapult launch must survive a slow engine start
//
// The global launch backstop fires at sixteen seconds. A rotary engine needs
// 16.9 s to reach `ready`, so the sequence was scrubbed a second before its own
// gate would have cleared it, and the RQ-7B was released inverted.

print("\n\nLaunch endurance — does the sequence outlast the engine start?")
print(String(repeating: "-", count: 76))

for subject in subjects {
    let mode = subject.runtime.preferredLaunchMode
    guard mode == .catapult, let wing = subject.runtime.fixedWingParameters else { continue }

    let controller = FixedWingLaunchController()
    var engine = EngineRuntimeState.cold(ambientTemperatureC: 15.0)
    var aircraft = DroneState(
        position: .zero, velocity: .zero, orientation: .zero, angularVelocity: .zero,
        throttle: 0.0, motorThrottle: 0.0, rotorAngularSpeed: .zero,
        forwardAirspeed: 0.0, physicalState: .armedOnGround, mode: .takeoff
    )
    aircraft.armState = .armed

    _ = controller.begin(
        mode: mode,
        asset: .catapult(CatapultLaunchAsset(
            position: .zero,
            rail: LaunchRailConfiguration(
                headingDegrees: 0.0,
                railAngleDegrees: wing.catapultRailAngleDegrees,
                launchDirectionDegrees: 0.0,
                railLengthMeters: wing.catapultRailLengthMeters,
                usesRocketBooster: wing.catapultUsesRocketBooster
            )
        )),
        origin: .zero, wing: wing,
        nominalLaunchMassKg: subject.runtime.takeoffMassKg
    )

    var elapsed: Float = 0.0
    var snapshot = FixedWingLaunchRuntimeSnapshot.idle
    var readyAt: Float?
    while elapsed < 90.0 {
        engine = engineService.update(
            current: engine,
            input: EngineUpdateInput(
                powerplant: subject.powerplant, throttle: 0.0, startRequested: true,
                atmosphere: seaLevel, airspeedMps: 0.0, isAirborne: false,
                hasFuel: true, healthFactor: 1.0,
                propellerAbsorbedPowerW: subject.backend.propellerLoadWatts(
                    engine: engine, airspeedMps: 0.0, airDensity: seaLevel.airDensity
                )
            ),
            deltaTime: dt
        )
        if readyAt == nil && engine.runState == .ready { readyAt = elapsed }
        snapshot = controller.update(
            aircraftState: aircraft, windVector: .zero, isArmed: true,
            batteryAvailable: true, engineState: engine, deltaTime: dt
        )
        elapsed += dt
        if snapshot.state == .aborted { break }
        if snapshot.state != .prelaunchCheck && readyAt != nil { break }
    }

    print(String(format: "%-22@ engine ready at %5.1f s, launch state %@ after %.1f s",
                 subject.runtime.displayName as NSString,
                 readyAt ?? -1.0, snapshot.state.rawValue as NSString, elapsed))
    if snapshot.state == .aborted {
        failures.append(String(format: "%@ launch was scrubbed while its engine was still starting",
                               subject.runtime.displayName))
    }
}

print("")
if failures.isEmpty {
    print("RESULT: PASS - engines start, discs balance their engines, thrust clears drag, and burning fuel buys climb")
    exit(0)
}
for failure in failures { print("FAIL: \(failure)") }
exit(1)
