import Foundation
import simd

// Headless climb-performance probe.
//
// Measures what every fixed-wing profile actually achieves at full power against the climb rate
// its own catalogue entry declares. This is the number that decides whether an aircraft can get
// above a city before it reaches the first building — and no flight log can separate "the
// autopilot is not commanding a climb" from "the airframe cannot deliver one".
//
// Run: Tools/ClimbProbe/run.sh

let repository = LIPODroneModelRepository()
let engine = SimpleDronePhysicsEngine()
let dt: Float = 1.0 / 60.0

print(String(
    format: "%-28@  %7@ %7@ %7@ %7@",
    "profile" as NSString, "decl" as NSString, "meas" as NSString,
    "ratio" as NSString, "grad" as NSString
))
print(String(repeating: "-", count: 66))

var worstRatio = Float.greatestFiniteMagnitude
var worstName = ""
var sinking: [String] = []
var underDelivering: [String] = []

for profile in repository.allProfiles where profile.airframeClass == .fixedWing {
    guard let wing = profile.fixedWingParameters else { continue }
    let massModel = VehicleMassModel.baseline(for: profile, uavProfile: nil)
    let baseline = FlightBaselineResolver.resolve(
        runtimeProfile: profile,
        activeUAVProfile: nil,
        vehicleMassModel: massModel,
        flightMode: .autoPath
    )

    var state = DroneState(
        position: SIMD3<Float>(0, 3000, 0),
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

    // Full power, climb pitch held at the profile's own initial-climb attitude; let it settle,
    // then average the vertical rate over the following ten seconds.
    var samples: [Float] = []
    var speedSamples: [Float] = []
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
            profile: profile,
            activeUAVProfile: nil,
            weather: .normal,
            damageState: .pristine,
            batteryState: .full,
            collisionRisk: 0.0,
            windVector: .zero,
            vehicleMassModel: massModel
        )
        state = engine.step(state: state, control: control, context: context, deltaTime: dt)
        if tick > 60 * 30 {
            samples.append(state.velocity.y)
            speedSamples.append(state.forwardAirspeed)
        }
    }

    let measured = samples.isEmpty ? 0 : samples.reduce(0, +) / Float(samples.count)
    let speed = speedSamples.isEmpty ? 1 : speedSamples.reduce(0, +) / Float(speedSamples.count)
    let declared = wing.nominalClimbRateMps
    let ratio = declared > 0 ? measured / declared : 0
    let gradient = speed > 0.1 ? measured / speed * 100.0 : 0
    if measured < 0.0 {
        sinking.append(profile.displayName)
    } else if ratio < 0.75 {
        underDelivering.append(profile.displayName)
    }
    if ratio < worstRatio {
        worstRatio = ratio
        worstName = profile.displayName
    }
    print(String(
        format: "%-28@  %6.2f  %6.2f  %5.0f%%  %5.1f%%",
        profile.displayName as NSString, declared, measured, ratio * 100.0, gradient
    ))
    _ = baseline
}

print("")
if !sinking.isEmpty {
    // Not a climb-rate shortfall: these lose height at full power and climb attitude, which is a
    // different defect from thrust sizing and needs its own investigation.
    print("CANNOT SUSTAIN FLIGHT at full power: \(sinking.joined(separator: ", "))")
}
if !underDelivering.isEmpty {
    print("BELOW 75% of declared climb: \(underDelivering.joined(separator: ", "))")
}
print("")
print("A 6% gradient needs 800 m of travel to gain 50 m; 15% needs 330 m.")
let healthy = sinking.isEmpty && underDelivering.isEmpty
print(healthy
    ? "RESULT: PASS - every profile delivers its declared climb"
    : "RESULT: FAIL - see the categories above")
exit(healthy ? 0 : 1)
