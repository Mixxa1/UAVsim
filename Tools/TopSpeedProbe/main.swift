import Foundation
import simd

// Level-acceleration probe: what top speed does each fixed wing actually reach at full
// throttle, against the maximum its own catalogue entry declares?
//
// Written to compile against the pre-supersonic tree as well as the current one, so the
// two can be compared directly. It therefore uses nothing newer than
// `SimpleDronePhysicsEngine.step` and computes Mach itself from the atmosphere rather
// than reading it off the state.
//
// The question matters because the plan forbids the easy answer. An aircraft must be
// held to its speed by the balance of thrust and drag, not by a clamp — so if the
// balance is wrong, the aircraft simply flies faster than the real one and nothing in
// the simulation objects. That is a defect the flight model cannot report on itself.
//
// Run: Tools/TopSpeedProbe/run.sh

let repository = LIPODroneModelRepository()
let engine = SimpleDronePhysicsEngine()
let atmosphere = AtmosphereModel.standard
let dt: Float = 1.0 / 60.0
let testAltitude: Float = 200.0
let seconds = 180

print("Level acceleration at full throttle, 200 m, still air")
print(String(repeating: "-", count: 84))
print(String(format: "%-24@ %10@ %10@ %9@ %9@",
             "profile" as NSString, "declared" as NSString, "reached" as NSString,
             "ratio" as NSString, "Mach" as NSString))

let air = atmosphere.state(altitudeMeters: testAltitude)
var overspeeding: [String] = []

for profile in repository.allProfiles where profile.airframeClass == .fixedWing {
    guard let wing = profile.fixedWingParameters else { continue }
    let massModel = VehicleMassModel.baseline(for: profile, uavProfile: profile.resolvedUAVProfile)
    let fuelState: FuelSystemState? = profile.resolvedUAVProfile?.powerplant?.fuel.map {
        .full(capacityKg: $0.usableFuelMassKg, reserveFraction: $0.reserveFraction)
    }
    let backend = FuelPropulsionBackend(
        powerplant: profile.resolvedUAVProfile?.powerplant,
        cruiseSpeedMps: wing.cruiseSpeedMps
    )

    var state = DroneState(
        position: SIMD3<Float>(0, testAltitude, 0),
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
    if let backend {
        var warm = EngineRuntimeState.cold(ambientTemperatureC: 15.0)
        warm.runState = .ready
        warm.shaftRPM = (backend.powerplant.ratedShaftRPM ?? 6_000.0) * 0.95
        warm.temperatureC = EngineOperatingEnvelope
            .envelope(for: backend.powerplant.engineType).operatingTemperatureC
        state.engineRuntime = warm
    }

    var peak: Float = 0.0
    for _ in 0..<(60 * seconds) {
        let control = DroneControlInput(
            targetPosition: SIMD3<Float>(state.position.x, testAltitude, state.position.z - 5_000),
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
                profile: profile,
                activeUAVProfile: profile.resolvedUAVProfile,
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
            deltaTime: dt
        )
        peak = max(peak, state.forwardAirspeed)
    }

    // ⚠️ Compare against what the CATALOGUE publishes, not against `wing.maxAirspeed` — that one is
    // derived (cruise × 1.35) whenever a profile does not state it, and it lands below the real
    // published maximum. A senseFly eBee TAC is catalogued at 30 m/s, reached 30.9, and was
    // reported as flying at 117% because the yardstick said 26.3.
    let declared = max(1.0, max(wing.maxAirspeed, profile.maxHorizontalSpeedMps))
    let ratio = peak / declared
    let mach = peak / air.speedOfSoundMps
    if ratio > 1.15 {
        overspeeding.append(String(format: "%@ %.0f%%", profile.displayName, ratio * 100.0))
    }
    print(String(format: "%-24@ %10.1f %10.1f %8.0f%% %9.2f",
                 profile.displayName as NSString, declared, peak, ratio * 100.0, mach))
}

print("\n" + String(repeating: "=", count: 84))
if overspeeding.isEmpty {
    print("\nEvery aircraft is held to within 15 % of its declared maximum by drag alone.")
} else {
    print("\nFlying faster than their own catalogue entry by more than 15 %:")
    for entry in overspeeding { print("  - \(entry)") }
    print("""

    This is a report, not a clamp. The plan forbids limiting an aircraft with a hard
    maximum-speed clamp in place of a physical thrust/drag/envelope balance, so the
    number stands and the balance is what has to be corrected.
    """)
}
