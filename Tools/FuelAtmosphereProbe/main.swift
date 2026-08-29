import Foundation
import simd

// Headless probe for the atmosphere model and the fuel-burn model.
//
// Three questions, none of which a flight log can answer:
//
//  1. Does `AtmosphereModel` reproduce the International Standard Atmosphere? A
//     density curve that is subtly wrong changes every aerodynamic force in the
//     simulation at once, so it is checked against published ISA values rather
//     than against itself.
//  2. Does each fuel aircraft's tank, engine rating and specific consumption
//     actually add up to the endurance its catalogue entry claims? These three
//     numbers were sourced independently, so agreeing is evidence, not tautology.
//  3. Does burning fuel really make the aircraft lighter in the physics engine,
//     and does the flight model respond to it?
//
// Run: Tools/FuelAtmosphereProbe/run.sh

var failures: [String] = []

// MARK: - 1. Atmosphere against published ISA values

print("ISA check — modelled vs published standard atmosphere")
print(String(repeating: "-", count: 76))
print(String(format: "%8@ %10@ %10@ %10@ %10@ %8@",
             "alt m" as NSString, "T model" as NSString, "T ref" as NSString,
             "rho model" as NSString, "rho ref" as NSString, "err %" as NSString))

// Published ISA (US Standard Atmosphere 1976): geometric altitude m, temperature K,
// density kg/m3.
//
// The rows above 11 km were added with the supersonic scope. They are not decoration:
// every reference aircraft in that scope works between 13 km and 21 km, and the model
// used to continue the tropopause isotherm all the way up — which is right to 20 km
// and wrong above it, in the direction that makes air colder, denser and slower-
// sounding than it is. A one-per-cent error in the speed of sound is a one-per-cent
// error in the Mach number the whole stage is judged on.
let isaReference: [(Float, Float, Float)] = [
    (0, 288.15, 1.2250),
    (500, 284.90, 1.1673),
    (1000, 281.65, 1.1117),
    (2000, 275.15, 1.0066),
    (3000, 268.65, 0.9093),
    (5000, 255.65, 0.7364),
    (8000, 236.15, 0.5258),
    // 0.36480, not the 0.3639 this row used to carry. Published ISA tables are indexed
    // by geopotential altitude, and geopotential 11,000 m is geometric 11,019 m — the
    // old value was simply one row of a different index. It mattered for nothing while
    // the model also ignored the distinction; now that the model converts, the two have
    // to be quoted against the same altitude or the check reports a 0.25 % error that
    // belongs to the table rather than to the code.
    (11000, 216.77, 0.36480),
    (13700, 216.65, 0.23884),   // Firebee II supersonic dash altitude
    (15000, 216.65, 0.19475),
    (16800, 216.65, 0.14684),   // BQM-34F ceiling
    (18300, 216.65, 0.11606),   // AQM-35A ceiling
    (20000, 216.65, 0.08891),
    (21300, 217.88, 0.07216),   // AQM-35B ceiling — first row above the inversion
    (25000, 221.55, 0.04008),
    (30000, 226.51, 0.01841)
]

let atmosphere = AtmosphereModel.standard
for (altitude, refTemperature, refDensity) in isaReference {
    let modelled = atmosphere.state(altitudeMeters: altitude)
    let error = abs(modelled.airDensity - refDensity) / refDensity * 100.0
    if error > 0.5 {
        failures.append(String(format: "ISA density at %.0f m is off by %.2f%%", altitude, error))
    }
    if abs(modelled.temperatureK - refTemperature) > 0.5 {
        failures.append(String(format: "ISA temperature at %.0f m is off by %.2f K",
                               altitude, abs(modelled.temperatureK - refTemperature)))
    }
    print(String(format: "%8.0f %10.2f %10.2f %10.4f %10.4f %8.2f",
                 altitude, modelled.temperatureK, refTemperature,
                 modelled.airDensity, refDensity, error))
}

// Speed of sound at sea level is 340.29 m/s.
let seaLevel = atmosphere.state(altitudeMeters: 0)
if abs(seaLevel.speedOfSoundMps - 340.29) > 0.5 {
    failures.append(String(format: "sea-level speed of sound is %.2f, expected 340.29",
                           seaLevel.speedOfSoundMps))
}
print(String(format: "\nsea level: a = %.2f m/s, mu = %.3e Pa.s, rho = %.4f",
             seaLevel.speedOfSoundMps, seaLevel.dynamicViscosityPaS, seaLevel.airDensity))

// Speed of sound is checked separately from density because it is what the whole
// supersonic scope is scored against: Mach is TAS over this number, so an error here
// is an error in every acceptance criterion at once. The dash-altitude rows are the
// ones the reference aircraft are actually judged at.
print("\nSpeed of sound and the true airspeed that puts each reference point on Mach")
print(String(repeating: "-", count: 76))
let speedOfSoundReference: [(Float, Float, String)] = [
    (13700, 295.07, "BQM-34F dash, M 1.78"),
    (18300, 295.07, "AQM-35A ceiling, M 1.55"),
    (21300, 295.91, "AQM-35B ceiling, M 2.0"),
    (12200, 295.07, "HiMAT M 1.4 point"),
    (13650, 295.07, "X-10 ceiling, M 2.05")
]
for (altitude, referenceSpeed, label) in speedOfSoundReference {
    let modelled = atmosphere.state(altitudeMeters: altitude)
    let error = abs(modelled.speedOfSoundMps - referenceSpeed)
    if error > 0.6 {
        failures.append(String(format: "speed of sound at %.0f m is %.2f, expected %.2f",
                               altitude, modelled.speedOfSoundMps, referenceSpeed))
    }
    // Round-trips the accessor that used to return the Mach number of a 1 m/s aircraft.
    let machAtRef = modelled.machNumber(trueAirspeedMps: referenceSpeed * 1.5)
    if abs(machAtRef - 1.5) > 0.01 {
        failures.append(String(format: "machNumber at %.0f m returned %.3f for M 1.5",
                               altitude, machAtRef))
    }
    print(String(format: "%8.0f m  a = %6.2f (ref %6.2f)  err %.2f m/s   %@",
                 altitude, modelled.speedOfSoundMps, referenceSpeed, error,
                 label as NSString))
}

// MARK: - 2. Does tank + engine + BSFC reproduce the declared endurance?

print("\n\nFuel budget — burning at the cruise throttle each profile is tuned for")
print(String(repeating: "-", count: 96))
print(String(format: "%-22@ %8@ %9@ %10@ %10@ %10@ %7@",
             "profile" as NSString, "fuel kg" as NSString, "thr" as NSString,
             "kg/h" as NSString, "burn h" as NSString, "decl h" as NSString,
             "ratio" as NSString))

let repository = LIPODroneModelRepository()
let burnService = FuelBurnService()

for runtimeProfile in repository.allProfiles {
    guard let uavProfile = runtimeProfile.resolvedUAVProfile,
          let powerplant = uavProfile.powerplant,
          powerplant.energySource == .fuel,
          let fuel = powerplant.fuel else { continue }

    let baseline = FlightBaselineResolver.resolve(
        runtimeProfile: runtimeProfile,
        activeUAVProfile: uavProfile,
        vehicleMassModel: VehicleMassModel.baseline(for: runtimeProfile, uavProfile: uavProfile),
        flightMode: .autoPath
    )
    let cruiseThrottle = baseline.cruiseReferenceThrottle

    // Burn the tanks dry at a fixed cruise throttle, one simulated minute per step.
    var fuelState = FuelSystemState.full(
        capacityKg: fuel.usableFuelMassKg,
        reserveFraction: fuel.reserveFraction
    )
    let step: Float = 60.0
    var seconds: Float = 0.0
    var firstFlow: Float = 0.0
    // Each aircraft's endurance is burned at *its own* working altitude.
    //
    // 1,500 m is right for the propeller fleet and badly wrong for a high-altitude
    // turbojet: a jet's thrust follows ambient pressure, so the same throttle at 1.5 km
    // burns six times what it burns at 14 km, and every published turbojet endurance is a
    // high-altitude figure. Judged down low the Firebee II emptied its tanks in
    // twenty-eight minutes against a published seventy-three, which said nothing about the
    // aircraft and everything about where the test was standing.
    let cruiseAltitude = uavProfile.nominalCruiseAltitudeMeters ?? 1_500.0
    let cruiseAtmosphere = atmosphere.state(altitudeMeters: cruiseAltitude)
    while !fuelState.isStarved && seconds < 60.0 * 60.0 * 60.0 {
        fuelState = burnService.update(
            current: fuelState,
            input: FuelBurnInput(
                powerplant: powerplant,
                throttle: cruiseThrottle,
                engineRunning: true,
                atmosphere: cruiseAtmosphere,
                leakKgPerSec: 0.0
            ),
            deltaTime: step
        )
        if firstFlow == 0.0 { firstFlow = fuelState.flowKgPerHour }
        seconds += step
    }

    let modelledHours = seconds / 3600.0
    let declaredHours = (uavProfile.nominalFlightTimeSec ?? 0.0) / 3600.0
    let ratio = declaredHours > 0.01 ? modelledHours / declaredHours : 0.0
    // Half to double the declared endurance is the bar here: specific consumption
    // and cruise power fraction are both engineering estimates, so agreement
    // inside a factor of two says the three sourced numbers are consistent.
    // Anything outside that means one of them is wrong.
    if ratio < 0.5 || ratio > 2.0 {
        failures.append(String(format: "%@ burns its tanks in %.2f h against a declared %.2f h",
                               runtimeProfile.displayName, modelledHours, declaredHours))
    }
    print(String(format: "%-22@ %8.1f %9.2f %10.2f %10.2f %10.2f %6.0f%%",
                 runtimeProfile.displayName as NSString, fuel.usableFuelMassKg,
                 cruiseThrottle, firstFlow, modelledHours, declaredHours, ratio * 100.0))
}

// MARK: - 3. Does burnt fuel actually reach the flight model?

print("\n\nMass coupling — flying the same aircraft with full and with empty tanks")
print(String(repeating: "-", count: 84))
print(String(format: "%-22@ %10@ %10@ %10@ %10@ %10@",
             "profile" as NSString, "mass full" as NSString, "mass dry" as NSString,
             "climb full" as NSString, "climb dry" as NSString, "delta" as NSString))

let engine = SimpleDronePhysicsEngine()
let dt: Float = 1.0 / 60.0

func measureClimb(
    runtimeProfile: DroneModelProfile,
    uavProfile: UAVProfile,
    fuelState: FuelSystemState?
) -> (climb: Float, mass: Float) {
    guard let wing = runtimeProfile.fixedWingParameters else { return (0, 0) }
    let massModel = VehicleMassModel.baseline(for: runtimeProfile, uavProfile: uavProfile)
    var state = DroneState(
        position: SIMD3<Float>(0, 300, 0),
        velocity: SIMD3<Float>(0, 0, -wing.climbAirspeed),
        orientation: .zero,
        angularVelocity: .zero,
        throttle: 1.0,
        motorThrottle: 1.0,
        rotorAngularSpeed: .zero,
        forwardAirspeed: wing.climbAirspeed,
        physicalState: .airborne,
        mode: .autoPath
    )
    state.armState = .armed

    var samples: [Float] = []
    for tick in 0..<(60 * 40) {
        let control = DroneControlInput(
            targetPosition: SIMD3<Float>(state.position.x, state.position.y + 500, state.position.z),
            targetOrientation: SIMD3<Float>(0, wing.initialClimbPitchDeg * .pi / 180.0, 0),
            yawIntent: 0.0,
            throttle: 1.0,
            isArmed: true,
            mode: .autoPath,
            controlMode: .stabilized
        )
        let context = DroneSimulationContext(
            profile: runtimeProfile,
            activeUAVProfile: uavProfile,
            weather: .normal,
            damageState: .pristine,
            batteryState: .full,
            collisionRisk: 0.0,
            windVector: .zero,
            vehicleMassModel: massModel,
            fuelState: fuelState
        )
        state = engine.step(state: state, control: control, context: context, deltaTime: dt)
        if tick > 60 * 30 { samples.append(state.velocity.y) }
    }
    let climb = samples.isEmpty ? 0 : samples.reduce(0, +) / Float(samples.count)
    let mass = massModel.resolvedCurrentTotalMass + (fuelState?.remainingKg ?? 0.0)
    return (climb, mass)
}

for runtimeProfile in repository.allProfiles where runtimeProfile.airframeClass == .fixedWing {
    guard let uavProfile = runtimeProfile.resolvedUAVProfile,
          let fuel = uavProfile.powerplant?.fuel,
          fuel.usableFuelMassKg > 0.0 else { continue }

    let full = FuelSystemState.full(
        capacityKg: fuel.usableFuelMassKg,
        reserveFraction: fuel.reserveFraction
    )
    var empty = full
    empty.remainingKg = 0.0
    empty.isStarved = false   // isolate the mass effect from the thrust cut-off

    let withFuel = measureClimb(runtimeProfile: runtimeProfile, uavProfile: uavProfile, fuelState: full)
    let withoutFuel = measureClimb(runtimeProfile: runtimeProfile, uavProfile: uavProfile, fuelState: empty)

    if abs(withFuel.mass - withoutFuel.mass - fuel.usableFuelMassKg) > 0.05 {
        failures.append("\(runtimeProfile.displayName): burnt fuel did not reach the flight model's mass")
    }
    // The climb columns are a DIAGNOSTIC, not an assertion, and the sign is
    // expected to be inconsistent for now.
    //
    // A lighter aircraft should climb better, and these will not reliably do so,
    // because thrust still comes from `wingborneThrustMagnitude` — a calibrated
    // backend that sizes full-throttle thrust from the aircraft's own weight
    // (`dragAtCruise + W * climbRate / cruiseSpeed`). Burning fuel therefore
    // removes weight and the thrust that was derived from it in the same breath,
    // and the two largely cancel. Mass reaching the flight model is what this
    // phase delivers and is what is asserted; making the benefit of burning it
    // appear needs thrust to come from an engine and a propeller instead of from
    // the weight, which is the propulsion-backend work.
    print(String(format: "%-22@ %10.1f %10.1f %10.2f %10.2f %+10.2f",
                 runtimeProfile.displayName as NSString,
                 withFuel.mass, withoutFuel.mass,
                 withFuel.climb, withoutFuel.climb,
                 withoutFuel.climb - withFuel.climb))
}

// Starvation must cut propulsion.
if let starvedProfile = repository.allProfiles.first(where: { $0.id == "rq-7b-shadow" }),
   let uavProfile = starvedProfile.resolvedUAVProfile,
   let fuel = uavProfile.powerplant?.fuel {
    var starved = FuelSystemState.full(capacityKg: fuel.usableFuelMassKg, reserveFraction: fuel.reserveFraction)
    starved.remainingKg = 0.0
    starved.isStarved = true
    let dead = measureClimb(runtimeProfile: starvedProfile, uavProfile: uavProfile, fuelState: starved)
    print(String(format: "\nRQ-7B with starved tanks: vertical rate %.2f m/s (must be a descent)", dead.climb))
    if dead.climb >= 0.0 {
        failures.append("fuel starvation did not stop the engine")
    }
}

print("")
if failures.isEmpty {
    print("RESULT: PASS - atmosphere matches ISA, fuel budgets are self-consistent, burnt fuel reaches the flight model")
    exit(0)
}
for failure in failures {
    print("FAIL: \(failure)")
}
exit(1)
