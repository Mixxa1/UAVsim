import Foundation
import simd

// Production-engine regression for Wingtra rotor-borne translation.
//
// A tailsitter at transitionProgress == 0 still has to consume the ordinary
// MulticopterAutopilotController roll/pitch commands: they tilt its fixed body
// -Z thrust vector while the airframe otherwise remains in nose-up hover.

private let dt: Float = 1.0 / 60.0
private var failures: [String] = []

private func radians(_ degrees: Float) -> Float {
    degrees * .pi / 180.0
}

private func degrees(_ radians: Float) -> Float {
    radians * 180.0 / .pi
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures.append(message)
        print("FAIL: \(message)")
    }
}

private func isFinite(_ value: SIMD3<Float>) -> Bool {
    value.x.isFinite && value.y.isFinite && value.z.isFinite
}

private func isFinite(_ value: simd_quatf) -> Bool {
    value.vector.x.isFinite && value.vector.y.isFinite &&
        value.vector.z.isFinite && value.vector.w.isFinite
}

private func hoverOrientation(yaw: Float) -> simd_quatf {
    simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)) *
        simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
}

private func thrustTilt(_ orientation: simd_quatf) -> Float {
    let thrust = simd_normalize(simd_act(orientation, SIMD3<Float>(0, 0, -1)))
    return acos(min(1.0, max(-1.0, simd_dot(thrust, SIMD3<Float>(0, 1, 0)))))
}

private let repository = LIPODroneModelRepository()
guard let profile = repository.allProfiles.first(where: { $0.id == "wingtraone-gen-ii" }) else {
    print("RESULT: FAIL - Wingtra runtime profile is missing")
    exit(1)
}
guard profile.airframeStyle == .tailsitterVTOL else {
    print("RESULT: FAIL - Wingtra fixture is no longer a tailsitter")
    exit(1)
}

private let massModel = VehicleMassModel.baseline(for: profile, uavProfile: nil)
private let baseline = FlightBaselineResolver.resolve(
    runtimeProfile: profile,
    activeUAVProfile: nil,
    vehicleMassModel: massModel,
    flightMode: .autoPath
)
private let context = DroneSimulationContext(
    profile: profile,
    activeUAVProfile: nil,
    weather: .normal,
    damageState: .pristine,
    batteryState: .full,
    collisionRisk: 0.0,
    windVector: .zero,
    vehicleMassModel: massModel
)

private func initialState(altitude: Float, heading: Float) -> DroneState {
    var state = DroneState(
        position: SIMD3<Float>(0, altitude, 0),
        velocity: .zero,
        orientation: SIMD3<Float>(0, .pi / 2, heading),
        angularVelocity: .zero,
        throttle: baseline.hoverLockThrottle,
        motorThrottle: baseline.hoverLockThrottle,
        rotorAngularSpeed: .zero,
        forwardAirspeed: 0.0,
        physicalState: .airborne,
        mode: .autoPath
    )
    state.armState = .armed
    state.motionState = .airborne
    state.fixedWingOrientationQuat = hoverOrientation(yaw: heading)
    state.bodyAngularVelocity = .zero
    state.propulsionUnits = profile.propulsionUnitTemplate
    state.vtolTransitionProgress = 0.0
    state.vtolWingborneBlend = 0.0
    return state
}

private func trackingContext(
    state: DroneState,
    target: SIMD3<Float>,
    targetAltitude: Float,
    heading: Float
) -> AutopilotTrackingContext {
    AutopilotTrackingContext(
        state: state,
        physicalState: .airborne,
        target: target,
        targetAltitude: targetAltitude,
        speedScale: 0.84,
        yawAlignToHome: false,
        yawOverrideRadians: heading,
        deltaTime: dt,
        flightBaseline: baseline,
        verticalVelocityDampingGain: 0.075
    )
}

private func control(from command: AutopilotControlCommand) -> DroneControlInput {
    DroneControlInput(
        targetPosition: command.positionTarget,
        targetOrientation: SIMD3<Float>(
            radians(command.rollDegrees),
            radians(command.pitchDegrees),
            radians(command.yawDegrees)
        ),
        yawIntent: 0.0,
        throttle: command.throttle,
        isArmed: true,
        mode: .autoPath,
        controlMode: .stabilized,
        vtolTransitionLever: 0.0
    )
}

// MARK: Forward hover translation from production lateral commands

do {
    let engine = SimpleDronePhysicsEngine()
    let autopilot = MulticopterAutopilotController()
    let altitude: Float = 12.0
    let heading = radians(73.0)
    let forward = SIMD2<Float>(-sin(heading), -cos(heading))
    let right = SIMD2<Float>(cos(heading), -sin(heading))
    var state = initialState(altitude: altitude, heading: heading)
    let start = state.position
    let target = SIMD3<Float>(
        start.x + forward.x * 30.0,
        altitude,
        start.z + forward.y * 30.0
    )

    var minimumPitchCommand: Float = 0.0
    var initialRollCommand: Float?
    var maximumRollCommand: Float = 0.0
    var maximumTilt: Float = 0.0
    var minimumAltitude = altitude
    var maximumAlongTrack: Float = 0.0
    var maximumCrossTrack: Float = 0.0
    var remainedFinite = true

    for _ in 0..<(60 * 7) {
        let command = autopilot.command(for: trackingContext(
            state: state,
            target: target,
            targetAltitude: altitude,
            heading: heading
        ))
        if initialRollCommand == nil {
            initialRollCommand = command.rollDegrees
        }
        minimumPitchCommand = min(minimumPitchCommand, command.pitchDegrees)
        maximumRollCommand = max(maximumRollCommand, abs(command.rollDegrees))
        state = engine.step(
            state: state,
            control: control(from: command),
            context: context,
            deltaTime: dt
        )

        let displacement = SIMD2<Float>(state.position.x - start.x, state.position.z - start.z)
        maximumAlongTrack = max(maximumAlongTrack, simd_dot(displacement, forward))
        maximumCrossTrack = max(maximumCrossTrack, abs(simd_dot(displacement, right)))
        maximumTilt = max(maximumTilt, thrustTilt(state.fixedWingOrientationQuat))
        minimumAltitude = min(minimumAltitude, state.position.y)
        remainedFinite = remainedFinite && isFinite(state.position) && isFinite(state.velocity) &&
            isFinite(state.bodyAngularVelocity) && isFinite(state.fixedWingOrientationQuat)
    }

    let displacement = SIMD2<Float>(state.position.x - start.x, state.position.z - start.z)
    let finalAlongTrack = simd_dot(displacement, forward)
    print(String(
        format: "lateral: cmd pitch %.1f/roll initial %.2f max %.2f deg, along %.2f m (max %.2f), cross %.2f m, tilt %.2f deg, minY %.2f m, progress %.3f",
        minimumPitchCommand, initialRollCommand ?? .infinity, maximumRollCommand, finalAlongTrack, maximumAlongTrack,
        maximumCrossTrack, degrees(maximumTilt), minimumAltitude, state.vtolTransitionProgress
    ))
    check(minimumPitchCommand < -8.0, "production autopilot did not request forward hover pitch")
    check(abs(initialRollCommand ?? .infinity) < 0.5, "aligned forward waypoint started with a lateral roll command")
    check(maximumAlongTrack > 6.0, "Wingtra did not translate toward the rotor-borne waypoint")
    check(finalAlongTrack > 4.0, "Wingtra reversed away from the rotor-borne waypoint")
    check(maximumCrossTrack < 2.0, "rotor-borne translation accumulated excessive cross-track motion")
    check(maximumTilt <= radians(18.5), "rotor-borne attitude exceeded the bounded tilt envelope")
    check(minimumAltitude >= altitude - 1.5, "rotor-borne translation lost excessive altitude")
    check(state.vtolTransitionProgress < 0.02, "horizontal hover translation advanced the wing transition")
    check(remainedFinite, "rotor-borne translation produced a non-finite state")
}

// MARK: Blocked route remains a vertical zero-command hold

do {
    let engine = SimpleDronePhysicsEngine()
    let autopilot = MulticopterAutopilotController()
    let altitude: Float = 6.0
    let heading = radians(-121.0)
    var state = initialState(altitude: altitude, heading: heading)
    let start = state.position

    var maximumLateralCommand: Float = 0.0
    var maximumTilt: Float = 0.0
    var maximumDrift: Float = 0.0
    var minimumAltitude = altitude
    var maximumAltitude = altitude
    var remainedFinite = true

    for _ in 0..<(60 * 5) {
        // A protected-route blocked hold deliberately supplies no planar
        // bearing: the target tracks the current X/Z while altitude stays
        // fixed. The production controller must therefore emit zero lateral
        // command and the tailsitter target must remain exactly nose-up.
        let target = SIMD3<Float>(state.position.x, altitude, state.position.z)
        let command = autopilot.command(for: trackingContext(
            state: state,
            target: target,
            targetAltitude: altitude,
            heading: heading
        ))
        maximumLateralCommand = max(
            maximumLateralCommand,
            abs(command.rollDegrees),
            abs(command.pitchDegrees)
        )
        state = engine.step(
            state: state,
            control: control(from: command),
            context: context,
            deltaTime: dt
        )

        maximumTilt = max(maximumTilt, thrustTilt(state.fixedWingOrientationQuat))
        maximumDrift = max(
            maximumDrift,
            simd_length(SIMD2<Float>(state.position.x - start.x, state.position.z - start.z))
        )
        minimumAltitude = min(minimumAltitude, state.position.y)
        maximumAltitude = max(maximumAltitude, state.position.y)
        remainedFinite = remainedFinite && isFinite(state.position) && isFinite(state.velocity) &&
            isFinite(state.bodyAngularVelocity) && isFinite(state.fixedWingOrientationQuat)
    }

    print(String(
        format: "blocked: lateral cmd %.4f deg, drift %.3f m, tilt %.3f deg, Y %.3f...%.3f m, rate %.4f, progress %.3f",
        maximumLateralCommand, maximumDrift, degrees(maximumTilt), minimumAltitude,
        maximumAltitude, simd_length(state.bodyAngularVelocity), state.vtolTransitionProgress
    ))
    check(maximumLateralCommand < 0.001, "blocked hold emitted a nonzero lateral command")
    check(maximumTilt < radians(0.5), "zero-command blocked hold tipped away from vertical")
    check(maximumDrift < 0.5, "zero-command blocked hold drifted horizontally")
    check(minimumAltitude >= altitude - 0.5, "zero-command blocked hold lost ground clearance")
    check(simd_length(state.bodyAngularVelocity) < 0.03, "zero-command blocked hold retained body rotation")
    check(state.vtolTransitionProgress < 0.02, "blocked hold advanced the wing transition")
    check(remainedFinite, "blocked hold produced a non-finite state")
}

if failures.isEmpty {
    print("RESULT: PASS - Wingtra rotor-borne translation is bounded and blocked hold stays vertical")
    exit(0)
}

print("RESULT: FAIL - \(failures.count) rotor-borne contract(s) violated")
exit(1)
