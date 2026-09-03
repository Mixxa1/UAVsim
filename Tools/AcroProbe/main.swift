import Foundation
import simd

// Headless acro/rate-mode probe.
//
// Acro is the one mode where the pilot's stick reaches the airframe with nothing in between, so
// every defect in the rate path shows up as a handling complaint rather than as a log line. This
// probe measures the four things a rate mode has to get right, on the real engine:
//
//   A. Rate tracking     — does full stick actually produce the angular rate it asks for?
//   B. Body-axis fidelity — does a pitch command rotate about the *body* pitch axis at any
//                           attitude, or does it drift toward a world axis as the aircraft banks?
//   C. Thrust available   — what thrust-to-weight does the airframe actually fly at, and does its
//                           declared hover throttle hold altitude?
//   D. Surface travel     — can a fixed wing reach full elevator/aileron in a rate mode?
//   E. Angle mode         — regression guard: the attitude modes share this controller and must
//                           not move when the rate path is worked on.
//
// B is the one that cannot be felt as a number in flight: a pilot experiences it as "the aircraft
// went somewhere else", and only a measured axis error says why.
//
// Run: Tools/AcroProbe/run.sh

let repository = LIPODroneModelRepository()
let engine = SimpleDronePhysicsEngine()
let dt: Float = 1.0 / 90.0

// The engine reads `targetOrientation.roll/pitch` in a rate mode as a normalized stick position
// clamped to ±1, so 1.0 is full deflection by contract. What the *view model* actually delivers
// at full stick is a separate question and is reported alongside.
let fullStick: Float = 1.0

func orientationQuaternion(from euler: SIMD3<Float>) -> simd_quatf {
    let yaw = simd_quatf(angle: euler.z, axis: SIMD3<Float>(0, 1, 0))
    let pitch = simd_quatf(angle: euler.y, axis: SIMD3<Float>(1, 0, 0))
    let roll = simd_quatf(angle: euler.x, axis: SIMD3<Float>(0, 0, 1))
    return yaw * pitch * roll
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func padLeft(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

func makeContext(_ profile: DroneModelProfile, mass: VehicleMassModel) -> DroneSimulationContext {
    DroneSimulationContext(
        profile: profile,
        activeUAVProfile: profile.resolvedUAVProfile,
        weather: .normal,
        damageState: .pristine,
        batteryState: .full,
        collisionRisk: 0.0,
        windVector: .zero,
        vehicleMassModel: mass
    )
}

func makeState(
    _ profile: DroneModelProfile,
    orientation: SIMD3<Float>,
    throttle: Float,
    velocity: SIMD3<Float> = .zero,
    altitude: Float = 300.0
) -> DroneState {
    var state = DroneState(
        position: SIMD3<Float>(0, altitude, 0),
        velocity: velocity,
        orientation: orientation,
        angularVelocity: .zero,
        throttle: throttle,
        // Seeded spooled-up: this probe measures the control response, not the spool ramp.
        motorThrottle: throttle,
        rotorAngularSpeed: .zero,
        forwardAirspeed: simd_length(SIMD2<Float>(velocity.x, velocity.z)),
        physicalState: .airborne,
        mode: .manual
    )
    state.armState = .armed
    state.attitudeQuat = orientationQuaternion(from: orientation)
    return state
}

func acroControl(
    roll: Float,
    pitch: Float,
    yawIntent: Float,
    throttle: Float,
    state: DroneState
) -> DroneControlInput {
    DroneControlInput(
        targetPosition: state.position,
        targetOrientation: SIMD3<Float>(roll, pitch, state.orientation.z),
        yawIntent: yawIntent,
        throttle: throttle,
        isArmed: true,
        mode: .manual,
        controlMode: .acro
    )
}

let multirotors = repository.allProfiles.filter { $0.airframeClass == .multirotor }
let fixedWings = repository.allProfiles.filter { $0.airframeClass == .fixedWing }

// MARK: - A. Rate tracking

print("A. RATE TRACKING — full stick, settled body rate (deg/s)")
print(pad("profile", 30) + padLeft("roll", 8) + padLeft("pitch", 8) + padLeft("yaw", 8) + "   class expectation")
print(String(repeating: "-", count: 84))

/// Settled rate on one axis, in deg/s, measured from the change in attitude rather than from the
/// state's own rate field — what the airframe *did*, not what the controller believes.
func settledRate(
    _ profile: DroneModelProfile,
    roll: Float,
    pitch: Float,
    yawIntent: Float
) -> Float {
    let mass = VehicleMassModel.baseline(for: profile, uavProfile: profile.resolvedUAVProfile)
    let context = makeContext(profile, mass: mass)
    let hover = FlightBaselineResolver.resolve(
        runtimeProfile: profile,
        activeUAVProfile: profile.resolvedUAVProfile,
        vehicleMassModel: mass,
        flightMode: .manual
    ).hoverLockThrottle
    var state = makeState(profile, orientation: .zero, throttle: hover)

    // Settle for 1.5 s, then measure the rotation accumulated over the following 0.2 s.
    for _ in 0..<Int(1.5 / Double(dt)) {
        state = engine.step(
            state: state,
            control: acroControl(roll: roll, pitch: pitch, yawIntent: yawIntent, throttle: hover, state: state),
            context: context,
            deltaTime: dt
        )
    }
    let before = state.attitudeQuat
    let window = 0.2
    for _ in 0..<Int(window / Double(dt)) {
        state = engine.step(
            state: state,
            control: acroControl(roll: roll, pitch: pitch, yawIntent: yawIntent, throttle: hover, state: state),
            context: context,
            deltaTime: dt
        )
    }
    let after = state.attitudeQuat
    let delta = simd_normalize(before.conjugate * after)
    let angle = 2.0 * acos(min(1.0, abs(delta.real)))
    return angle / Float(window) * 180.0 / .pi
}

var rateFindings: [String] = []
for profile in multirotors {
    let roll = settledRate(profile, roll: fullStick, pitch: 0, yawIntent: 0)
    let pitch = settledRate(profile, roll: 0, pitch: fullStick, yawIntent: 0)
    let yaw = settledRate(profile, roll: 0, pitch: 0, yawIntent: 1.0)
    // An acro-class airframe is expected to reach several hundred deg/s; a camera platform is not.
    let isAcroClass = profile.visualClass == .miniCompact && profile.hoverThrottle < 0.35
    let expectation = isAcroClass ? "acro: 600-1200" : "camera: 200-400"
    print(pad(profile.displayName, 30)
        + padLeft(String(format: "%.0f", roll), 8)
        + padLeft(String(format: "%.0f", pitch), 8)
        + padLeft(String(format: "%.0f", yaw), 8)
        + "   " + expectation)
    if isAcroClass, roll < 600.0 {
        rateFindings.append(String(format: "%@ rolls at %.0f deg/s, an acro airframe needs 600+", profile.displayName, roll))
    }
}

// MARK: - B. Body-axis fidelity

print("")
print("B. BODY-AXIS FIDELITY — one stick axis at a time, from a non-level attitude")
print("   error = angle between the axis the aircraft actually rotated about and the body axis")
print("   that stick owns. 0° is correct; 180° means the control is inverted; 90° means it has")
print("   been handed to a different axis entirely.")
print(pad("profile", 30) + padLeft("bank 90, pitch", 15) + padLeft("inverted, pitch", 16) + padLeft("nose-up, yaw", 14))
print(String(repeating: "-", count: 76))

/// Angle between the axis the airframe rotated about over a short window and the body axis the
/// commanded stick is supposed to own. Signed: an inverted control reads 180°, not 0°.
func bodyAxisError(
    _ profile: DroneModelProfile,
    startEuler: SIMD3<Float>,
    roll: Float = 0,
    pitch: Float = 0,
    yawIntent: Float = 0,
    expectedBodyAxis: SIMD3<Float>
) -> Float {
    let mass = VehicleMassModel.baseline(for: profile, uavProfile: profile.resolvedUAVProfile)
    let context = makeContext(profile, mass: mass)
    let hover = FlightBaselineResolver.resolve(
        runtimeProfile: profile,
        activeUAVProfile: profile.resolvedUAVProfile,
        vehicleMassModel: mass,
        flightMode: .manual
    ).hoverLockThrottle
    var state = makeState(profile, orientation: startEuler, throttle: hover)

    let q0 = state.attitudeQuat
    for _ in 0..<Int(0.3 / Double(dt)) {
        state = engine.step(
            state: state,
            control: acroControl(roll: roll, pitch: pitch, yawIntent: yawIntent, throttle: hover, state: state),
            context: context,
            deltaTime: dt
        )
    }
    let q1 = state.attitudeQuat
    // Rotation expressed in the body frame it started in.
    let deltaBody = simd_normalize(q0.conjugate * q1)
    let axis = deltaBody.axis
    guard simd_length(axis).isFinite, simd_length(axis) > 0.0001 else { return 0.0 }
    // `simd_quatf.angle` is always non-negative, so the direction of travel lives in the axis —
    // which is exactly what an inversion flips, and why this must NOT take an absolute value.
    let cosine = min(1.0, max(-1.0, simd_dot(simd_normalize(axis), simd_normalize(expectedBodyAxis))))
    return acos(cosine) * 180.0 / .pi
}

// Engine rate order is roll = body Z, pitch = body X, yaw = body Y.
let bodyPitchAxis = SIMD3<Float>(1, 0, 0)
let bodyYawAxis = SIMD3<Float>(0, 1, 0)

var axisFindings: [String] = []
for profile in multirotors {
    // A pitch command from 90° of bank: in a real acro machine this is the first half of every
    // turn, and it must still rotate about the body pitch axis.
    let bank = bodyAxisError(
        profile,
        startEuler: SIMD3<Float>(.pi / 2, 0, 0),
        pitch: fullStick,
        expectedBodyAxis: bodyPitchAxis
    )
    // The same command inverted — the case where a world-axis controller reverses the stick.
    let inverted = bodyAxisError(
        profile,
        startEuler: SIMD3<Float>(.pi, 0, 0),
        pitch: fullStick,
        expectedBodyAxis: bodyPitchAxis
    )
    // Yaw at a near-vertical attitude: the Euler singularity, where yaw and roll collapse onto
    // the same axis and the rudder command has nowhere left to go.
    let noseUpYaw = bodyAxisError(
        profile,
        startEuler: SIMD3<Float>(0, .pi / 2 * 0.98, 0),
        yawIntent: 1.0,
        expectedBodyAxis: bodyYawAxis
    )
    print(pad(profile.displayName, 30)
        + padLeft(String(format: "%.1f°", bank), 15)
        + padLeft(String(format: "%.1f°", inverted), 16)
        + padLeft(String(format: "%.1f°", noseUpYaw), 14))
    let worst = max(bank, max(inverted, noseUpYaw))
    if worst > 5.0 {
        axisFindings.append(String(
            format: "%@ rotates up to %.0f° away from the body axis the stick commands",
            profile.displayName, worst
        ))
    }
}

// MARK: - C. Thrust available

print("")
print("C. THRUST AVAILABLE — measured at the airframe, not read off the profile")
print(pad("profile", 30) + padLeft("T/W", 8) + padLeft("hover thr", 11) + padLeft("hover drift", 14))
print(String(repeating: "-", count: 64))

var thrustFindings: [String] = []
for profile in multirotors {
    let mass = VehicleMassModel.baseline(for: profile, uavProfile: profile.resolvedUAVProfile)
    let context = makeContext(profile, mass: mass)
    let baseline = FlightBaselineResolver.resolve(
        runtimeProfile: profile,
        activeUAVProfile: profile.resolvedUAVProfile,
        vehicleMassModel: mass,
        flightMode: .manual
    )
    let hover = baseline.hoverLockThrottle

    // Full throttle, level, from rest: the first substep's vertical acceleration is thrust minus
    // weight with no drag yet, so T/W falls straight out of it.
    var full = makeState(profile, orientation: .zero, throttle: 1.0)
    let beforeV = full.velocity.y
    full = engine.step(
        state: full,
        control: acroControl(roll: 0, pitch: 0, yawIntent: 0, throttle: 1.0, state: full),
        context: context,
        deltaTime: dt
    )
    let accel = (full.velocity.y - beforeV) / dt
    let twr = accel / 9.81 + 1.0

    // Declared hover throttle, held for 3 s: how far does it actually drift?
    var held = makeState(profile, orientation: .zero, throttle: hover)
    for _ in 0..<Int(3.0 / Double(dt)) {
        held = engine.step(
            state: held,
            control: acroControl(roll: 0, pitch: 0, yawIntent: 0, throttle: hover, state: held),
            context: context,
            deltaTime: dt
        )
    }
    let drift = held.position.y - 300.0
    print(pad(profile.displayName, 30)
        + padLeft(String(format: "%.2f", twr), 8)
        + padLeft(String(format: "%.3f", hover), 11)
        + padLeft(String(format: "%+.1f m", drift), 14))
    if abs(drift) > 1.5 {
        thrustFindings.append(String(
            format: "%@ drifts %+.1f m in 3 s at its own declared hover throttle",
            profile.displayName, drift
        ))
    }
}

// MARK: - E. Angle-mode regression

print("")
print("E. ANGLE MODE — stabilized bank command, achieved bank and heading kept")
print("   Not an acro measurement: this is the mode every camera platform and every autopilot")
print("   actually flies in, and it shares the attitude controller acro changed. It has to stay")
print("   where it was.")
print(pad("profile", 30) + padLeft("cmd", 8) + padLeft("achieved", 10) + padLeft("heading drift", 15))
print(String(repeating: "-", count: 64))

var angleFindings: [String] = []
let commandedBankDeg: Float = 25.0
for profile in multirotors {
    let mass = VehicleMassModel.baseline(for: profile, uavProfile: profile.resolvedUAVProfile)
    let context = makeContext(profile, mass: mass)
    let hover = FlightBaselineResolver.resolve(
        runtimeProfile: profile,
        activeUAVProfile: profile.resolvedUAVProfile,
        vehicleMassModel: mass,
        flightMode: .manual
    ).hoverLockThrottle
    var state = makeState(profile, orientation: .zero, throttle: hover)

    for _ in 0..<Int(4.0 / Double(dt)) {
        let control = DroneControlInput(
            targetPosition: state.position,
            targetOrientation: SIMD3<Float>(commandedBankDeg * .pi / 180.0, 0, 0),
            yawIntent: 0.0,
            throttle: hover,
            isArmed: true,
            mode: .manual,
            controlMode: .stabilized
        )
        state = engine.step(state: state, control: control, context: context, deltaTime: dt)
    }
    let achieved = state.orientation.x * 180.0 / .pi
    let headingDrift = abs(state.orientation.z) * 180.0 / .pi
    print(pad(profile.displayName, 30)
        + padLeft(String(format: "%.0f°", commandedBankDeg), 8)
        + padLeft(String(format: "%.1f°", achieved), 10)
        + padLeft(String(format: "%.1f°", headingDrift), 15))
    if abs(achieved - commandedBankDeg) > 3.0 {
        angleFindings.append(String(
            format: "%@ holds %.1f° of bank against a %.0f° command in stabilized",
            profile.displayName, achieved, commandedBankDeg
        ))
    }
    if headingDrift > 5.0 {
        angleFindings.append(String(
            format: "%@ drifts %.1f° of heading while simply holding bank",
            profile.displayName, headingDrift
        ))
    }
}

// MARK: - D. Fixed-wing surface travel

print("")
print("D. SURFACE TRAVEL — fraction of elevator/aileron a rate-mode stick reaches")
print(pad("profile", 30) + padLeft("elevator", 10) + padLeft("aileron", 10))
print(String(repeating: "-", count: 52))

var surfaceFindings: [String] = []
for profile in fixedWings {
    guard let wing = profile.fixedWingParameters else { continue }
    let mass = VehicleMassModel.baseline(for: profile, uavProfile: profile.resolvedUAVProfile)
    let context = makeContext(profile, mass: mass)
    var state = makeState(
        profile,
        orientation: .zero,
        throttle: 0.6,
        velocity: SIMD3<Float>(0, 0, -wing.cruiseSpeedMps)
    )
    // Surfaces slew at 4/s, so half a second is enough to reach whatever ceiling applies.
    for _ in 0..<Int(0.5 / Double(dt)) {
        state = engine.step(
            state: state,
            control: acroControl(roll: fullStick, pitch: fullStick, yawIntent: 0, throttle: 0.6, state: state),
            context: context,
            deltaTime: dt
        )
    }
    print(pad(profile.displayName, 30)
        + padLeft(String(format: "%.2f", abs(state.elevatorDeflection)), 10)
        + padLeft(String(format: "%.2f", abs(state.aileronDeflection)), 10))
    if abs(state.elevatorDeflection) < 0.9 {
        surfaceFindings.append(String(
            format: "%@ reaches only %.0f%% elevator at full stick",
            profile.displayName, abs(state.elevatorDeflection) * 100.0
        ))
    }
}

// MARK: - F. Speed envelope

print("")
print("F. SPEED ENVELOPE — reached by the drag balance, not by a clamp")
print("   Level speed is flown at the lean the mode allows, on the throttle that holds altitude —")
print("   a published top speed is level flight, not a climb. The dive is nose-down at full")
print("   throttle, which a real quad takes well past its descent rating.")
print(pad("profile", 30) + padLeft("level", 9) + padLeft("spec", 8) + padLeft("descent", 10) + padLeft("spec", 8) + padLeft("dive", 9))
print(String(repeating: "-", count: 76))

var speedFindings: [String] = []
for profile in multirotors {
    let mass = VehicleMassModel.baseline(for: profile, uavProfile: profile.resolvedUAVProfile)
    let context = makeContext(profile, mass: mass)
    let baseline = FlightBaselineResolver.resolve(
        runtimeProfile: profile,
        activeUAVProfile: profile.resolvedUAVProfile,
        vehicleMassModel: mass,
        flightMode: .manual
    )
    let twr = baseline.effectiveStabilizationThrust + 0.35
    let sustainableLean = acos(min(0.999, max(0.02, 1.0 / twr)))
    // Each class is measured in the mode its published speed belongs to: an acro machine's figure
    // is a rate-mode number (48° of lean), a camera platform's is its sport mode (36°).
    let isAcroClass = profile.visualClass == .miniCompact && profile.hoverThrottle < 0.35
    let referenceLeanDeg: Float = isAcroClass ? 48.0 : 36.0
    let levelLean = min(referenceLeanDeg * Float.pi / 180.0, sustainableLean)

    // Level run: hold the steepest sustainable lean at full throttle and let speed settle.
    // Level flight, not a climb: the vertical component of thrust has to carry the weight, so the
    // throttle rises with the lean exactly as a pilot's would.
    let levelThrottle = min(1.0, baseline.hoverLockThrottle / max(0.2, cos(levelLean)))
    var level = makeState(profile, orientation: SIMD3<Float>(0, -levelLean, 0), throttle: levelThrottle, altitude: 1500.0)
    for _ in 0..<Int(60.0 / Double(dt)) {
        var control = acroControl(roll: 0, pitch: 0, yawIntent: 0, throttle: levelThrottle, state: level)
        if isAcroClass {
            // A rate mode has no attitude command, so the probe flies the stick the way a pilot
            // does: a proportional correction on the angle error, which is what holding a lean in
            // acro actually is.
            let pitchError = (-levelLean) - level.orientation.y
            control.targetOrientation = SIMD3<Float>(0, min(1.0, max(-1.0, pitchError * 3.0)), level.orientation.z)
        } else {
            control.controlMode = .stabilized
            control.targetOrientation = SIMD3<Float>(0, -levelLean, level.orientation.z)
        }
        level = engine.step(state: level, control: control, context: context, deltaTime: dt)
    }
    let levelSpeed = simd_length(SIMD2<Float>(level.velocity.x, level.velocity.z))

    // Unpowered descent: throttle closed, level, terminal velocity.
    var falling = makeState(profile, orientation: .zero, throttle: 0.0, altitude: 4000.0)
    for _ in 0..<Int(30.0 / Double(dt)) {
        falling = engine.step(
            state: falling,
            control: acroControl(roll: 0, pitch: 0, yawIntent: 0, throttle: 0.0, state: falling),
            context: context,
            deltaTime: dt
        )
    }
    let descentSpeed = -falling.velocity.y

    // Powered dive: nose straight down, full throttle — thrust adds to gravity.
    var diving = makeState(profile, orientation: SIMD3<Float>(0, -.pi / 2 * 0.98, 0), throttle: 1.0, altitude: 4000.0)
    for _ in 0..<Int(30.0 / Double(dt)) {
        var control = acroControl(roll: 0, pitch: 0, yawIntent: 0, throttle: 1.0, state: diving)
        control.controlMode = .stabilized
        control.targetOrientation = SIMD3<Float>(0, -.pi / 2 * 0.98, diving.orientation.z)
        diving = engine.step(state: diving, control: control, context: context, deltaTime: dt)
    }
    let diveSpeed = simd_length(diving.velocity)

    print(pad(profile.displayName, 30)
        + padLeft(String(format: "%.1f", levelSpeed), 9)
        + padLeft(String(format: "%.0f", profile.maxHorizontalSpeedMps), 8)
        + padLeft(String(format: "%.1f", descentSpeed), 10)
        + padLeft(String(format: "%.0f", profile.maxDescentSpeedMps), 8)
        + padLeft(String(format: "%.1f", diveSpeed), 9))

    let levelError = abs(levelSpeed - profile.maxHorizontalSpeedMps) / max(1.0, profile.maxHorizontalSpeedMps)
    if levelError > 0.25 {
        speedFindings.append(String(
            format: "%@ settles at %.1f m/s against a catalogued %.0f m/s",
            profile.displayName, levelSpeed, profile.maxHorizontalSpeedMps
        ))
    }
    let descentError = abs(descentSpeed - profile.maxDescentSpeedMps) / max(1.0, profile.maxDescentSpeedMps)
    if descentError > 0.25 {
        speedFindings.append(String(
            format: "%@ falls at %.1f m/s against a catalogued %.0f m/s",
            profile.displayName, descentSpeed, profile.maxDescentSpeedMps
        ))
    }
}

// MARK: - Summary

print("")
print(String(repeating: "=", count: 84))
let allFindings = rateFindings + axisFindings + thrustFindings + angleFindings + surfaceFindings + speedFindings
if allFindings.isEmpty {
    print("No findings.")
} else {
    print("FINDINGS (\(allFindings.count)):")
    for finding in allFindings {
        print("  - \(finding)")
    }
}
