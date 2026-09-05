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

extension Float {
    func clamped(to lower: Float, _ upper: Float) -> Float { Swift.min(upper, Swift.max(lower, self)) }
}

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
    // Full tanks. A declared climb rate is quoted for a departing aircraft, and a
    // fuel profile's catalogue mass is now its DRY mass — measuring one of these
    // without fuel would flatter it by the whole tank.
    let fuelState: FuelSystemState? = profile.resolvedUAVProfile?.powerplant?.fuel.map {
        .full(capacityKg: $0.usableFuelMassKg, reserveFraction: $0.reserveFraction)
    }
    // Fuel aircraft fly on the engine/propeller chain; electric ones keep the
    // calibrated thrust backend, which this probe must not disturb.
    let backend = FuelPropulsionBackend(
        powerplant: profile.resolvedUAVProfile?.powerplant,
        cruiseSpeedMps: wing.cruiseSpeedMps
    )
    let baseline = FlightBaselineResolver.resolve(
        runtimeProfile: profile,
        activeUAVProfile: profile.resolvedUAVProfile,
        vehicleMassModel: massModel,
        flightMode: .autoPath
    )

    // 300 m, not 3000. Declared climb rates are sea-level figures, and now that
    // `AtmosphereModel` makes density fall with altitude, measuring at 3 km and
    // comparing against a sea-level number is not a like-for-like test — it
    // charges every airframe an altitude penalty its own datasheet never claimed.
    // 300 m is also the altitude the question actually matters at: whether the
    // aircraft can climb over a city before reaching the first building.
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
    if let backend {
        // Seeded already running: this probe measures climb, not the start sequence.
        var warm = EngineRuntimeState.cold(ambientTemperatureC: 15.0)
        warm.runState = .ready
        warm.shaftRPM = (backend.powerplant.ratedShaftRPM ?? 6000.0) * 0.9
        warm.temperatureC = EngineOperatingEnvelope
            .envelope(for: backend.powerplant.engineType).operatingTemperatureC
        state.engineRuntime = warm
    }

    // Full power, climb pitch held at the profile's own initial-climb attitude; let it settle,
    // then average the vertical rate over the following ten seconds.
    var samples: [Float] = []
    var speedSamples: [Float] = []
    var climbPitchCommand = wing.initialClimbPitchDeg * .pi / 180.0
    for tick in 0..<(60 * 40) {
        // Pitch for speed: nose up when fast, nose down when slow, bounded to sane attitudes.
        let speedError = state.forwardAirspeed - wing.climbAirspeed
        climbPitchCommand = (climbPitchCommand + speedError * 0.02 * dt)
            .clamped(to: -0.10, 0.45)
        let control = DroneControlInput(
            targetPosition: SIMD3<Float>(state.position.x, state.position.y + 500, state.position.z),
            // ⚠️ Fly the climb SPEED, not a fixed pitch attitude. A best-rate climb is defined at a
            // particular airspeed, and holding an attitude instead lets the aircraft accelerate to
            // wherever thrust and drag happen to balance — measured at 89 m/s on an MQ-9B whose
            // climb speed is 65. Now that thrust falls with airspeed (constant-power propeller),
            // that difference is most of the climb rate. A real autopilot pitches for speed; so
            // does this probe.
            targetOrientation: SIMD3<Float>(0, climbPitchCommand, 0),
            yawIntent: 0.0,
            throttle: 1.0,
            isArmed: true,
            mode: .autoPath,
            controlMode: .stabilized
        )
        // The catalogue profile is NOT optional context here. `stepFixedWingAerodynamic` reads the
        // real wingspan from it and only falls back to `profile.dimensionsUnfoldedMm` when it is
        // absent — and for the aircraft that carry a `runtimeSceneDimensionsOverride` (MQ-9B,
        // Hermes 900, MQ-9A) that fallback is the *scene asset* size, a few metres instead of
        // fifteen to twenty-four. Passing nil therefore undersized their wing area, and with it
        // the drag-sized thrust, and the probe reported them as unable to sustain flight at full
        // power — a defect in the harness, not in the airframes. The app has always passed the
        // real profile.
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


// MARK: - The other end of the throttle
//
// A climb probe only ever asks whether full power climbs. It never asked whether
// *no* power descends — and it did not: the physics floors a fixed wing's throttle
// at `effectiveMinimumSafeFlightThrottle` above 15 cm, which on the MQ-9B turned a
// commanded 0 % into 46 % against a 51 % cruise baseline. An aircraft the operator
// had throttled to idle went on climbing at ten metres per second and gained two
// hundred metres at a time. Closing the throttle is not an error state for an
// aeroplane: it is how it descends, glides and lands.

print("\n\nThrottle closed in flight — does it come down?")
print(String(repeating: "-", count: 72))
print(String(format: "%-26@ %10@ %10@ %10@ %8@",
             "profile" as NSString, "start m" as NSString, "after 40s" as NSString,
             "sink m/s" as NSString, "L/D" as NSString))

var wouldNotDescend: [String] = []

for profile in repository.allProfiles where profile.airframeClass == .fixedWing {
    guard let wing = profile.fixedWingParameters else { continue }
    let uav = profile.resolvedUAVProfile
    let massModel = VehicleMassModel.baseline(for: profile, uavProfile: uav)
    let fuelState: FuelSystemState? = uav?.powerplant?.fuel.map {
        .full(capacityKg: $0.usableFuelMassKg, reserveFraction: $0.reserveFraction)
    }
    let backend = FuelPropulsionBackend(
        powerplant: uav?.powerplant,
        cruiseSpeedMps: wing.cruiseSpeedMps
    )

    var state = DroneState(
        position: SIMD3<Float>(0, 400, 0),
        velocity: SIMD3<Float>(0, 0, -wing.cruiseAirspeed),
        orientation: .zero,
        angularVelocity: .zero,
        throttle: 0.0,
        motorThrottle: 0.0,
        rotorAngularSpeed: .zero,
        forwardAirspeed: wing.cruiseAirspeed,
        physicalState: .airborne,
        mode: .manual
    )
    state.armState = .armed
    if let backend {
        // Running, but at idle — a closed throttle does not stop the engine.
        var idle = EngineRuntimeState.cold(ambientTemperatureC: 15.0)
        idle.runState = .ready
        idle.shaftRPM = (backend.powerplant.ratedShaftRPM ?? 6000.0) * 0.4
        idle.temperatureC = EngineOperatingEnvelope
            .envelope(for: backend.powerplant.engineType).operatingTemperatureC
        state.engineRuntime = idle
    }

    let start = state.position.y
    var speedSum: Float = 0.0
    var samples = 0
    // 120 seconds, not 40.
    //
    // The run starts at the airframe's cruise airspeed, and for a high-altitude jet that
    // figure is far above what it can sustain down at 400 m — so the first thing it does
    // with the throttle closed is trade the excess speed for height. That is a zoom, not a
    // failure to descend, and forty seconds was not long enough for the two supersonic
    // aircraft with the highest cruise speeds to finish it. Over two minutes the zoom
    // completes and what is measured is the steady glide. Aircraft that start near their
    // trim speed — which is the whole subsonic fleet — are unaffected.
    let glideSeconds = 120
    for _ in 0..<(60 * glideSeconds) {
        let control = DroneControlInput(
            targetPosition: SIMD3<Float>(0, 400, -4000),
            targetOrientation: .zero,
            yawIntent: 0.0,
            throttle: 0.0,
            isArmed: true,
            mode: .manual,
            controlMode: .stabilized
        )
        let context = DroneSimulationContext(
            profile: profile,
            activeUAVProfile: uav,
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
        speedSum += state.forwardAirspeed
        samples += 1
    }
    let sink = (start - state.position.y) / Float(glideSeconds)
    let meanSpeed = samples > 0 ? speedSum / Float(samples) : 1.0
    let glideRatio = sink > 0.01 ? meanSpeed / sink : 0.0
    print(String(format: "%-26@ %10.0f %10.0f %10.2f %8.1f",
                 profile.displayName as NSString, start, state.position.y, sink, glideRatio))

    if sink <= 0.0 {
        wouldNotDescend.append(profile.displayName)
    }
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
if !wouldNotDescend.isEmpty {
    print("THROTTLE CLOSED AND STILL NOT DESCENDING: \(wouldNotDescend.joined(separator: ", "))")
}
let healthy = sinking.isEmpty && underDelivering.isEmpty && wouldNotDescend.isEmpty
print(healthy
    ? "RESULT: PASS - every profile delivers its declared climb"
    : "RESULT: FAIL - see the categories above")
exit(healthy ? 0 : 1)
