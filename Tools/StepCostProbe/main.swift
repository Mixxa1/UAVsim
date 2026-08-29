import Foundation
import simd

// Headless physics-cost probe.
//
// Sizes time acceleration. Fast-forward cannot be done by handing the integrator a bigger `dt` —
// `SimpleDronePhysicsEngine.step` clamps the requested delta to 1/20 s and walks it in fixed
// 1/90 s substeps, so a larger delta silently loses the extra time. The only correct way to run
// the world faster is to run *more* substeps per rendered frame, and that costs CPU in direct
// proportion to the multiplier.
//
// So the question this answers is: how much wall time does one second of simulated flight cost in
// the integrator alone? Multiply by the desired speed to get the per-second budget, and compare
// against the frame budget the app has left after rendering.
//
// This is a FLOOR, not the whole cost. It measures `engine.step` only. The app's simulation tick
// also runs the autopilot, collision analysis and obstacle queries, all of which would have to be
// re-run per substep; read `physicsTimeMs` and `renderTimeMs` in the app's Diagnostics module for
// the real split.
//
// Run: Tools/StepCostProbe/run.sh

let repository = LIPODroneModelRepository()
let engine = SimpleDronePhysicsEngine()
let dt: Float = 1.0 / 90.0
let simulatedSeconds: Double = 20.0
let ticks = Int(simulatedSeconds / Double(dt))

print("Cost of one simulated second inside the integrator")
print("us/step = microseconds per 1/90 s substep. ms/simsec = wall milliseconds per simulated second.")
print("max x  = speed multiplier that fits a 16.7 ms frame budget using the WHOLE frame for physics.")
print("")
print(String(
    format: "%-28@ %9@ %11@ %8@",
    "profile" as NSString, "us/step" as NSString, "ms/simsec" as NSString, "max x" as NSString
))
print(String(repeating: "-", count: 62))

/// One representative of each class that behaves differently in the step: a fuel aircraft with the
/// engine/propeller chain, a plain electric fixed wing, a multirotor and a VTOL in transition.
let wanted = [
    "mq-9a-reaper",
    "senseFly eBee TAC",
    "Wingcopter 198",
    "WingtraOne GEN II",
]

var rows: [(String, Double, Double)] = []

for profile in repository.allProfiles {
    let matches = wanted.contains(profile.id) || wanted.contains(profile.displayName)
    guard matches else { continue }

    let massModel = VehicleMassModel.baseline(for: profile, uavProfile: nil)
    let fuelState: FuelSystemState? = profile.resolvedUAVProfile?.powerplant?.fuel.map {
        .full(capacityKg: $0.usableFuelMassKg, reserveFraction: $0.reserveFraction)
    }
    let backend = FuelPropulsionBackend(
        powerplant: profile.resolvedUAVProfile?.powerplant,
        cruiseSpeedMps: profile.fixedWingParameters?.cruiseSpeedMps ?? 20.0
    )
    let cruise = profile.fixedWingParameters?.cruiseSpeedMps ?? 12.0

    var state = DroneState(
        position: SIMD3<Float>(0, 400, 0),
        velocity: SIMD3<Float>(0, 0, -cruise),
        orientation: .zero,
        angularVelocity: .zero,
        throttle: 0.7,
        motorThrottle: 0.7,
        rotorAngularSpeed: .zero,
        forwardAirspeed: cruise,
        physicalState: .airborne,
        mode: .autoPath
    )
    state.armState = .armed
    if let backend {
        var warm = EngineRuntimeState.cold(ambientTemperatureC: 15.0)
        warm.runState = .ready
        warm.shaftRPM = (backend.powerplant.ratedShaftRPM ?? 6000.0) * 0.9
        warm.temperatureC = EngineOperatingEnvelope
            .envelope(for: backend.powerplant.engineType).operatingTemperatureC
        state.engineRuntime = warm
    }

    let control = DroneControlInput(
        targetPosition: SIMD3<Float>(0, 400, -1000),
        targetOrientation: SIMD3<Float>(0.2, 0.0, 0.0),
        yawIntent: 0.0,
        throttle: 0.7,
        isArmed: true,
        mode: .autoPath,
        controlMode: .stabilized
    )

    // Warm up, so the measurement is steady-state flight rather than first-call costs.
    for _ in 0..<200 {
        let context = DroneSimulationContext(
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
        )
        state = engine.step(state: state, control: control, context: context, deltaTime: dt)
    }

    let started = Date()
    for _ in 0..<ticks {
        let context = DroneSimulationContext(
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
        )
        state = engine.step(state: state, control: control, context: context, deltaTime: dt)
    }
    let elapsed = Date().timeIntervalSince(started)

    let microsecondsPerStep = elapsed / Double(ticks) * 1_000_000.0
    let msPerSimSecond = elapsed / simulatedSeconds * 1000.0
    let maxMultiplier = 16.7 / msPerSimSecond
    rows.append((profile.displayName, msPerSimSecond, maxMultiplier))

    print(String(
        format: "%-28@ %8.1f %10.2f %7.0fx",
        profile.displayName as NSString, microsecondsPerStep, msPerSimSecond, maxMultiplier
    ))
}

print("")
if let worst = rows.min(by: { $0.2 < $1.2 }) {
    print(String(
        format: "Worst case %@: %.2f ms of integrator per simulated second.",
        worst.0 as NSString, worst.1
    ))
    print("")
    print("Budget at 60 fps (16.7 ms/frame), integrator only:")
    for speed in [2.0, 4.0, 8.0, 16.0, 32.0, 64.0] {
        // At Nx, one rendered frame must advance N frames' worth of simulated time.
        let costPerFrame = worst.1 * speed / 60.0
        let verdict = costPerFrame < 16.7 ? "fits" : "over budget"
        print(String(format: "  %5.0fx  %7.2f ms/frame  %@", speed, costPerFrame, verdict as NSString))
    }
    print("")
    print("⚠️ Integrator only. The app's tick also re-runs the autopilot, collision analysis and")
    print("   obstacle queries per step; read physicsTimeMs/renderTimeMs in Diagnostics for the rest.")
}
