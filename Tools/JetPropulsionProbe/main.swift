import Foundation
import simd

// Headless probe for the jet thrust map, the intake model and the ramjet.
//
// The question the plan puts at the centre of this work is one sentence long: the same
// throttle must not mean the same thrust in all conditions. Before this, it did — a
// turbojet's output was `rated × spool² × densityRatio`, and nothing in that expression
// knows how fast the aircraft is going. An engine like that produces exactly as much
// thrust at Mach 2 as it does standing on the runway, which is not a small error; it is
// the difference between an aircraft that can accelerate through the transonic drag
// rise and one that cannot.
//
// What is checked here:
//
//  1. Thrust really varies with Mach *and* altitude, in the right directions, with the
//     characteristic dip through the low subsonic that makes the transonic hard.
//  2. The intake matters. A plain pitot hole and a variable ramp are not interchangeable
//     above Mach 1.5, and the numbers have to show it.
//  3. A ramjet makes nothing at rest and cannot be started — only arrived at.
//  4. What the change costs the one real turbojet already in the catalogue.
//
// Run: Tools/JetPropulsionProbe/run.sh

var failures: [String] = []

let atmosphere = AtmosphereModel.standard

/// A generic supersonic turbojet, sized so the numbers are readable.
func testPowerplant(
    engineType: UAVEngineType = .turbojet,
    inlet: UAVInletType,
    designMach: Float = 2.0,
    thrustN: Float = 40_000.0
) -> UAVPowerplantSpec {
    UAVPowerplantSpec(
        engineType: engineType,
        engineDesignation: "probe",
        ratedThrustN: thrustN,
        ratedShaftRPM: 30_000.0,
        starter: .electricStarter,
        startPolicy: engineType == .ramjet ? .airStartAfterBoost : .groundStartBeforeLaunch,
        fuel: UAVFuelSpec(fuelType: .turbineKerosene, usableFuelMassKg: 500.0),
        inletType: inlet,
        inletDesignMach: designMach
    )
}

/// An engine already spooled to its rated speed, so the map rather than the start
/// sequence is what is being measured.
func spooledEngine(for powerplant: UAVPowerplantSpec) -> EngineRuntimeState {
    var engine = EngineRuntimeState.cold(ambientTemperatureC: 15.0)
    engine.runState = .ready
    engine.shaftRPM = powerplant.ratedShaftRPM ?? 30_000.0
    engine.temperatureC = EngineOperatingEnvelope
        .envelope(for: powerplant.engineType).operatingTemperatureC
    return engine
}

// MARK: - 1. Thrust against Mach and altitude

print("Turbojet thrust map — variable ramp intake, full throttle, kN")
print(String(repeating: "-", count: 92))
print(String(format: "%-10@ %10@ %10@ %10@ %10@ %10@ %10@ %10@",
             "altitude" as NSString, "M 0.0" as NSString, "M 0.5" as NSString,
             "M 0.9" as NSString, "M 1.2" as NSString, "M 1.8" as NSString,
             "M 2.5" as NSString, "M 3.2" as NSString))

let rampPowerplant = testPowerplant(inlet: .variableRamp, designMach: 2.5)
let rampBackend = FuelPropulsionBackend(powerplant: rampPowerplant, cruiseSpeedMps: 250.0)!
let rampEngine = spooledEngine(for: rampPowerplant)

let probeAltitudes: [Float] = [0, 6_000, 12_000, 18_000]
let probeMachs: [Float] = [0.0, 0.5, 0.9, 1.2, 1.8, 2.5, 3.2]
var thrustGrid: [Float: [Float: Float]] = [:]

for altitude in probeAltitudes {
    let air = atmosphere.state(altitudeMeters: altitude)
    var row: [Float: Float] = [:]
    var cells: [Float] = []
    for mach in probeMachs {
        let flow = CompressibleFlowState(
            atmosphere: air,
            trueAirspeedMps: mach * air.speedOfSoundMps
        )
        let thrust = rampBackend.jetOutput(engine: rampEngine, flow: flow).thrustNewtons
        row[mach] = thrust
        cells.append(thrust / 1000.0)
        if !thrust.isFinite || thrust < 0.0 {
            failures.append(String(format: "thrust is %.1f N at %.0f m, Mach %.1f",
                                   thrust, altitude, mach))
        }
    }
    thrustGrid[altitude] = row
    print(String(format: "%8.0f m %10.2f %10.2f %10.2f %10.2f %10.2f %10.2f %10.2f",
                 altitude, cells[0], cells[1], cells[2], cells[3], cells[4], cells[5], cells[6]))
}

// The plan's own wording: the same throttle must not mean the same thrust.
if let sea = thrustGrid[0], let high = thrustGrid[12_000] {
    let staticSea = sea[0.0] ?? 0.0
    let staticHigh = high[0.0] ?? 0.0
    if staticHigh >= staticSea * 0.75 {
        failures.append("thrust barely falls with altitude — the pressure lapse is not reaching the map")
    }
    let dip = sea[0.5] ?? 0.0
    if dip >= staticSea {
        failures.append("no momentum-drag dip: thrust does not fall as the aircraft accelerates from rest")
    }
    let supersonic = sea[1.8] ?? 0.0
    if supersonic <= staticSea {
        failures.append("no ram rise: thrust supersonic is not above the static rating")
    }
}

// MARK: - 2. The intake is not a detail

print("\n\nIntake pressure recovery — what reaches the engine, by arrangement")
print(String(repeating: "-", count: 92))
print(String(format: "%-16@ %9@ %9@ %9@ %9@ %9@ %9@",
             "inlet" as NSString, "M 0.8" as NSString, "M 1.2" as NSString,
             "M 1.6" as NSString, "M 2.0" as NSString, "M 2.5" as NSString,
             "M 3.0" as NSString))

let inletCases: [(String, HighSpeedInletModel)] = [
    ("pitot", HighSpeedInletModel(type: .pitot)),
    ("fixed ramp M2.0", HighSpeedInletModel(type: .fixedRamp, designMach: 2.0)),
    ("variable ramp", HighSpeedInletModel(type: .variableRamp, designMach: 2.5))
]
let recoveryMachs: [Float] = [0.8, 1.2, 1.6, 2.0, 2.5, 3.0]
var recoveryByName: [String: [Float]] = [:]

for (name, inlet) in inletCases {
    let values = recoveryMachs.map { inlet.pressureRecovery(mach: $0) }
    recoveryByName[name] = values
    print(String(format: "%-16@ %9.3f %9.3f %9.3f %9.3f %9.3f %9.3f",
                 name as NSString, values[0], values[1], values[2],
                 values[3], values[4], values[5]))
}

if let pitot = recoveryByName["pitot"], let variable = recoveryByName["variable ramp"] {
    // At Mach 3 a normal shock keeps about a third of the total pressure and a staged
    // intake keeps four fifths. If the model does not reproduce that gap it is not
    // modelling an intake, it is applying a fudge factor.
    if pitot[5] > 0.45 {
        failures.append(String(format: "a pitot intake keeps %.2f of total pressure at Mach 3 — far too generous",
                               pitot[5]))
    }
    if variable[5] < 0.70 {
        failures.append(String(format: "a variable ramp keeps only %.2f at Mach 3 — too pessimistic",
                               variable[5]))
    }
    if variable[5] - pitot[5] < 0.25 {
        failures.append("pitot and variable-ramp intakes barely differ at Mach 3 — the arrangement is not being modelled")
    }
}

// A fixed ramp must be best at the Mach it was cut for and worse either side of it.
let fixedRamp = HighSpeedInletModel(type: .fixedRamp, designMach: 2.0)
let atDesign = fixedRamp.pressureRecovery(mach: 2.0)
let below = fixedRamp.pressureRecovery(mach: 1.5)
let above = fixedRamp.pressureRecovery(mach: 2.6)
let variableAtDesign = HighSpeedInletModel(type: .variableRamp, designMach: 2.0)
    .pressureRecovery(mach: 2.6)
if above >= variableAtDesign {
    failures.append("a fixed ramp is not penalised above its design Mach")
}
print(String(format: "\nfixed ramp cut for M2.0: %.3f at M1.5, %.3f at design, %.3f at M2.6 (variable would hold %.3f)",
             below, atDesign, above, variableAtDesign))

// MARK: - 3. The ramjet cannot be started, only reached

print("\n\nRamjet — thrust and state against Mach at 18 km, throttle open throughout")
print(String(repeating: "-", count: 92))
print(String(format: "%-10@ %14@ %14@ %16@", "Mach" as NSString, "thrust kN" as NSString,
             "state" as NSString, "after 5 s" as NSString))

// A variable ramp cut for Mach 3.5, which is what a ramjet aircraft would actually
// carry. The fixed-ramp case is exercised separately below, because losing the intake
// is a distinct behaviour worth seeing rather than an inconvenience to design around.
let ramjetPowerplant = testPowerplant(engineType: .ramjet, inlet: .variableRamp, designMach: 3.5)
let ramjetBackend = FuelPropulsionBackend(powerplant: ramjetPowerplant, cruiseSpeedMps: 900.0)!
let engineService = EngineRuntimeService()
let ramjetAir = atmosphere.state(altitudeMeters: 18_000.0)

for mach in [Float(0.0), 0.9, 1.4, 1.8, 2.5, 3.2, 4.0] {
    let airspeed = mach * ramjetAir.speedOfSoundMps
    // Five seconds of holding this condition with the throttle open: long enough for
    // the light-off delay to elapse if the flame can take at all.
    var engine = EngineRuntimeState.cold(ambientTemperatureC: -56.0)
    var elapsed: Float = 0.0
    while elapsed < 5.0 {
        engine = engineService.update(
            current: engine,
            input: EngineUpdateInput(
                powerplant: ramjetPowerplant,
                throttle: 1.0,
                startRequested: true,
                atmosphere: ramjetAir,
                airspeedMps: airspeed,
                isAirborne: true,
                hasFuel: true,
                healthFactor: 1.0,
                propellerAbsorbedPowerW: 0.0
            ),
            deltaTime: 1.0 / 60.0
        )
        elapsed += 1.0 / 60.0
    }
    let flow = CompressibleFlowState(atmosphere: ramjetAir, trueAirspeedMps: airspeed)
    let thrust = ramjetBackend.jetOutput(engine: engine, flow: flow).thrustNewtons

    if mach < 1.0 && thrust > 0.0 {
        failures.append(String(format: "ramjet produced %.0f N at Mach %.1f — it has nothing to compress with",
                               thrust, mach))
    }
    if mach < 1.0 && engine.runState.isFiring {
        failures.append(String(format: "ramjet reports firing at Mach %.1f", mach))
    }
    if mach >= 2.5 && thrust <= 0.0 {
        failures.append(String(format: "ramjet made no thrust at Mach %.1f, where it should be at its best",
                               mach))
    }
    print(String(format: "%8.1f %14.2f %14@ %16@",
                 mach, thrust / 1000.0, engine.runState.rawValue as NSString,
                 (engine.runState.isFiring ? "burning" : "out") as NSString))
}

// A ramjet must never clear a launch by itself — whatever gets the aircraft to its
// light-off Mach is not this engine.
let litRamjet: EngineRuntimeState = {
    var engine = EngineRuntimeState.cold(ambientTemperatureC: -56.0)
    engine.runState = .ready
    return engine
}()
let litFlow = CompressibleFlowState(
    atmosphere: ramjetAir,
    trueAirspeedMps: 3.0 * ramjetAir.speedOfSoundMps
)
if ramjetBackend.jetOutput(engine: litRamjet, flow: litFlow).isClearedForLaunch {
    failures.append("a ramjet cleared the aircraft for launch — nothing can be launched on ram pressure it does not have")
}

// Flying a fixed-ramp intake past what its geometry can swallow. Not a corner case to
// be avoided — it is the reason aircraft that fly beyond one Mach number carry moving
// ramps, and the model has to show the cost rather than quietly scaling something down.
let fixedRampRamjet = testPowerplant(engineType: .ramjet, inlet: .fixedRamp, designMach: 3.0)
let fixedRampBackend = FuelPropulsionBackend(powerplant: fixedRampRamjet, cruiseSpeedMps: 900.0)!
let unstartFlow = CompressibleFlowState(
    atmosphere: ramjetAir,
    trueAirspeedMps: 4.0 * ramjetAir.speedOfSoundMps
)
let unstartThrust = fixedRampBackend.jetOutput(engine: litRamjet, flow: unstartFlow).thrustNewtons
let inEnvelopeFlow = CompressibleFlowState(
    atmosphere: ramjetAir,
    trueAirspeedMps: 3.0 * ramjetAir.speedOfSoundMps
)
let inEnvelopeThrust = fixedRampBackend.jetOutput(engine: litRamjet, flow: inEnvelopeFlow).thrustNewtons
print(String(format: "\nfixed ramp cut for M3.0 on a ramjet: %.2f kN at its design Mach, %.2f kN at M4.0 (intake unstarted)",
             inEnvelopeThrust / 1000.0, unstartThrust / 1000.0))
if unstartThrust >= inEnvelopeThrust {
    failures.append("a fixed-ramp intake flown past its envelope costs the engine nothing")
}

// MARK: - 4. What this costs the catalogue's one real turbojet

print("\n\nHESA Karrar — level acceleration at full throttle from 200 m, to terminal speed")
print(String(repeating: "-", count: 92))

let repository = LIPODroneModelRepository()
if let karrar = repository.allProfiles.first(where: { $0.id == "hesa-karrar" }),
   let wing = karrar.fixedWingParameters,
   let powerplant = karrar.resolvedUAVProfile?.powerplant,
   let backend = FuelPropulsionBackend(powerplant: powerplant, cruiseSpeedMps: wing.cruiseSpeedMps) {

    let massModel = VehicleMassModel.baseline(for: karrar, uavProfile: karrar.resolvedUAVProfile)
    let fuelState: FuelSystemState? = powerplant.fuel.map {
        .full(capacityKg: $0.usableFuelMassKg, reserveFraction: $0.reserveFraction)
    }
    let engine = SimpleDronePhysicsEngine()
    var state = DroneState(
        position: SIMD3<Float>(0, 200, 0),
        velocity: SIMD3<Float>(0, 0, -wing.cruiseAirspeed),
        orientation: .zero,
        angularVelocity: .zero,
        throttle: 1.0,
        motorThrottle: 1.0,
        rotorAngularSpeed: .zero,
        forwardAirspeed: wing.cruiseAirspeed,
        physicalState: .airborne,
        mode: .autoPath
    )
    state.armState = .armed
    state.engineRuntime = spooledEngine(for: powerplant)

    var peakSpeed: Float = 0.0
    var peakMach: Float = 0.0
    for _ in 0..<(60 * 180) {
        let control = DroneControlInput(
            targetPosition: SIMD3<Float>(state.position.x, 200, state.position.z - 5_000),
            targetOrientation: .zero,
            yawIntent: 0.0,
            throttle: 1.0,
            isArmed: true,
            mode: .autoPath,
            controlMode: .stabilized
        )
        state = engine.step(
            state: state,
            control: control,
            context: DroneSimulationContext(
                profile: karrar,
                activeUAVProfile: karrar.resolvedUAVProfile,
                weather: .normal,
                damageState: .pristine,
                batteryState: .full,
                collisionRisk: 0.0,
                windVector: .zero,
                vehicleMassModel: massModel,
                fuelState: fuelState,
                engineState: state.engineRuntime,
                fuelPropulsion: backend
            ),
            deltaTime: 1.0 / 60.0
        )
        peakSpeed = max(peakSpeed, state.forwardAirspeed)
        peakMach = max(peakMach, state.machNumber)
    }

    let declared = wing.maxAirspeed
    print(String(format: "declared max %.0f m/s · reached %.0f m/s (Mach %.2f) · %.0f%% of declared",
                 declared, peakSpeed, peakMach, peakSpeed / max(1.0, declared) * 100.0))
    print(String(format: "thrust at that point: %.2f kN · intake recovery %.3f",
                 state.propulsionThrustNewtons / 1000.0, state.inletPressureRecovery))

    // The published figure is 900 km/h — a subsonic target drone. An aircraft that
    // cannot get within a fifth of its own catalogue entry has had something taken away
    // from it that it should have had.
    if peakSpeed < declared * 0.80 {
        failures.append(String(format: "Karrar reaches only %.0f m/s of a declared %.0f", peakSpeed, declared))
    }
    // The other direction is a real defect too, but not one this phase created: measured
    // against the pre-supersonic tree the same run reached 399 m/s at Mach 1.17 — the
    // model had a subsonic target drone going supersonic. The compressible drag rise and
    // the Mach-dependent thrust map together took 62 m/s off that. What remains is the
    // whole fleet's high-speed drag/thrust balance, which `Tools/TopSpeedProbe` measures
    // across every airframe and which the flight envelope in the next phase is for.
    if peakSpeed > declared * 1.15 {
        print(String(format: "note: still %.0f%% of the declared maximum. Pre-supersonic tree: 399 m/s (Mach 1.17), 160%%.",
                     peakSpeed / declared * 100.0))
    }
} else {
    failures.append("HESA Karrar is missing from the catalogue")
}

print("\n" + String(repeating: "=", count: 92))
if failures.isEmpty {
    print("""

    RESULT: PASS — thrust depends on Mach, altitude and intake recovery; the intake \
    arrangement changes the answer; a ramjet makes nothing at rest.
    """)
} else {
    print("\nRESULT: FAIL")
    for failure in failures { print("  - \(failure)") }
    exit(1)
}
