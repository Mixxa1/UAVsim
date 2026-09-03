import Foundation
import simd

// Production-engine regression suite for tailsitter stop-and-pivot heading control.
//
// `WingtraRotorTranslationProbe` drives the same engine but always passes
// `yawOverrideRadians` equal to the aircraft's *current* heading, so it never exercises a
// turn — which is why it stayed green through a flight that spent its entire duration in
// `vtol_stop_and_pivot_align` with the heading walking monotonically away
// (roll +40.5 -> +125.6 deg while `rollCmd` grew 4.1 -> 6.2) until the aircraft struck a
// building. Heading convergence is the contract this file covers, from several directions:
// magnitude and sign of the turn, absolute heading of the aircraft, the stop-and-pivot gate
// that consumes the result, station keeping during the turn, a target that moves mid-turn,
// and the null case where no turn was requested at all.

private let dt: Float = 1.0 / 60.0
private let maximumSeconds: Float = 15.0
private let maximumSteps = Int(maximumSeconds / dt)

// Both thresholds are `HybridVTOLStopAndPivotGate`'s own release conditions. A turn that
// cannot meet them is a turn the gate will hold forever.
private let headingToleranceRadians = HybridVTOLStopAndPivotGate.maximumHeadingErrorRadians
private let yawRateTolerance = HybridVTOLStopAndPivotGate.maximumYawRateRadiansPerSecond
private let settleHoldSeconds: Float = 0.5

private var failures: [String] = []

private func radians(_ degrees: Float) -> Float { degrees * .pi / 180.0 }
private func degrees(_ radians: Float) -> Float { radians * 180.0 / .pi }

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures.append(message)
        print("FAIL: \(message)")
    }
}

private func wrapAngle(_ value: Float) -> Float {
    var angle = value
    while angle > .pi { angle -= 2.0 * .pi }
    while angle < -.pi { angle += 2.0 * .pi }
    return angle
}

private func isFinite(_ value: SIMD3<Float>) -> Bool {
    value.x.isFinite && value.y.isFinite && value.z.isFinite
}

private func isFinite(_ value: simd_quatf) -> Bool {
    value.vector.x.isFinite && value.vector.y.isFinite &&
        value.vector.z.isFinite && value.vector.w.isFinite
}

/// Angle between the airframe's thrust axis and vertical — how far the aircraft can lean to brake.
private func thrustTilt(_ orientation: simd_quatf) -> Float {
    let thrust = simd_normalize(simd_act(orientation, SIMD3<Float>(0, 0, -1)))
    return acos(min(1.0, max(-1.0, simd_dot(thrust, SIMD3<Float>(0, 1, 0)))))
}

private func hoverOrientation(yaw: Float) -> simd_quatf {
    simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)) *
        simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0))
}

/// The same non-singular heading gauge the view model and the engine both use: body -Y
/// projected onto the ground plane. Euler yaw is gimbal-locked at the nose-up hover attitude
/// and cannot be used here.
private func hoverHeading(_ orientation: simd_quatf) -> Float {
    let direction = -simd_act(orientation, SIMD3<Float>(0, 1, 0))
    let planar = SIMD2<Float>(direction.x, direction.z)
    guard simd_length_squared(planar) > 1e-8 else { return .nan }
    return atan2(-planar.x, -planar.y)
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
    state.attitudeQuat = hoverOrientation(yaw: heading)
    state.bodyAngularVelocity = .zero
    state.propulsionUnits = profile.propulsionUnitTemplate
    state.vtolTransitionProgress = 0.0
    state.vtolWingborneBlend = 0.0
    return state
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

private struct PivotOutcome {
    var settleSeconds: Float?
    var finalErrorRadians: Float
    var worstErrorAfterStartRadians: Float
    var overshootRadians: Float
    var peakYawRate: Float
    var finalYawRate: Float
    var maximumDriftMeters: Float
    var maximumLateralCommandDegrees: Float
    var altitudeLossMeters: Float
    var gateReleasedSeconds: Float?
    var remainedFinite: Bool
}

/// Reproduces a `vtol_stop_and_pivot_align` tick exactly: the position target is the latched
/// hold (the aircraft's own position at the start of the pivot) while the yaw override is the
/// bearing to a route node that is still far away.
private func runPivot(
    startHeading: Float,
    commandedHeading: @escaping (Float) -> Float,
    nodeDistance: Float = 200.0,
    label: String
) -> PivotOutcome {
    let engine = SimpleDronePhysicsEngine()
    let autopilot = MulticopterAutopilotController()
    var gate = HybridVTOLStopAndPivotGate()
    let altitude: Float = 33.8
    var state = initialState(altitude: altitude, heading: startHeading)
    let hold = state.position

    var outcome = PivotOutcome(
        settleSeconds: nil,
        finalErrorRadians: .nan,
        worstErrorAfterStartRadians: 0.0,
        overshootRadians: 0.0,
        peakYawRate: 0.0,
        finalYawRate: 0.0,
        maximumDriftMeters: 0.0,
        maximumLateralCommandDegrees: 0.0,
        altitudeLossMeters: 0.0,
        gateReleasedSeconds: nil,
        remainedFinite: true
    )

    let initialError = wrapAngle(commandedHeading(0.0) - startHeading)
    let turnSign: Float = initialError >= 0 ? 1.0 : -1.0
    var settledFor: Float = 0.0
    var elapsed: Float = 0.0

    for step in 0..<maximumSteps {
        elapsed = Float(step) * dt
        let target = commandedHeading(elapsed)
        let command = autopilot.command(for: AutopilotTrackingContext(
            state: state,
            physicalState: .airborne,
            target: hold,
            targetAltitude: altitude,
            speedScale: 0.28,
            yawAlignToHome: false,
            yawOverrideRadians: target,
            deltaTime: dt,
            flightBaseline: baseline,
            verticalVelocityDampingGain: 0.075
        ))
        outcome.maximumLateralCommandDegrees = max(
            outcome.maximumLateralCommandDegrees,
            abs(command.rollDegrees),
            abs(command.pitchDegrees)
        )
        state = engine.step(
            state: state,
            control: control(from: command),
            context: context,
            deltaTime: dt
        )

        let heading = hoverHeading(state.attitudeQuat)
        let error = wrapAngle(target - heading)
        // `stopAndPivotYawRate` is what the production gate reads, so read the same channel.
        let yawRate = HybridVTOLFlightPolicy.stopAndPivotYawRate(
            isTailsitter: true,
            tailsitterBodyXRate: state.bodyAngularVelocity.x,
            conventionalYawRate: state.angularVelocity.z
        )
        let planarSpeed = simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))

        // Overshoot is turning *past* the target in the direction the turn started.
        let signedRemaining = error * turnSign
        if signedRemaining < 0 {
            outcome.overshootRadians = max(outcome.overshootRadians, -signedRemaining)
        }
        // Ignore the first tenth of a second: the command has not reached the airframe yet.
        if elapsed > 0.1 {
            outcome.worstErrorAfterStartRadians = max(outcome.worstErrorAfterStartRadians, abs(error))
        }
        outcome.peakYawRate = max(outcome.peakYawRate, abs(yawRate))
        outcome.finalErrorRadians = error
        outcome.finalYawRate = yawRate
        outcome.maximumDriftMeters = max(
            outcome.maximumDriftMeters,
            simd_length(SIMD2<Float>(state.position.x - hold.x, state.position.z - hold.z))
        )
        outcome.altitudeLossMeters = max(outcome.altitudeLossMeters, altitude - state.position.y)
        outcome.remainedFinite = outcome.remainedFinite &&
            isFinite(state.position) && isFinite(state.velocity) &&
            isFinite(state.bodyAngularVelocity) && isFinite(state.attitudeQuat) &&
            heading.isFinite

        if abs(error) <= headingToleranceRadians && abs(yawRate) <= yawRateTolerance {
            settledFor += dt
            if settledFor >= settleHoldSeconds, outcome.settleSeconds == nil {
                outcome.settleSeconds = elapsed
            }
        } else {
            settledFor = 0.0
        }

        // The production gate, fed the production signals. `.translate` means it released.
        let guidance = gate.update(
            traversalMode: .stopAndPivotVTOL,
            routeIdentifier: "probe-route",
            routeIndex: 1,
            position: state.position,
            planarSpeed: planarSpeed,
            headingErrorRadians: error,
            yawRateRadiansPerSecond: yawRate
        )
        if !guidance.shouldHold, outcome.gateReleasedSeconds == nil, elapsed > 0.0 {
            outcome.gateReleasedSeconds = elapsed
        }
    }

    _ = nodeDistance
    _ = label
    return outcome
}

private func summarize(_ label: String, _ outcome: PivotOutcome) {
    print(String(
        format: "%@ settle %@ s, gate %@ s, err %+.2f deg (worst %.2f), overshoot %.2f, rate peak %.3f final %.3f, drift %.2f m, lateral cmd %.2f deg, dY %.2f m",
        label as NSString,
        outcome.settleSeconds.map { String(format: "%.2f", $0) } as NSString? ?? "never",
        outcome.gateReleasedSeconds.map { String(format: "%.2f", $0) } as NSString? ?? "never",
        degrees(outcome.finalErrorRadians),
        degrees(outcome.worstErrorAfterStartRadians),
        degrees(outcome.overshootRadians),
        outcome.peakYawRate,
        outcome.finalYawRate,
        outcome.maximumDriftMeters,
        outcome.maximumLateralCommandDegrees,
        outcome.altitudeLossMeters
    ))
}

// MARK: A. Heading convergence across turn magnitude, sign and absolute heading
//
// A pivot is not "a turn to the right by 90 degrees" — the same command has to work from any
// heading the previous leg left the aircraft at. The flight that motivated this file walked
// through +40 -> +125 deg without ever converging, so both the magnitude and the absolute
// starting heading are varied here.

private let turnMagnitudes: [Float] = [30.0, -30.0, 90.0, -90.0, 150.0, -150.0, 179.0, -179.0]
private let startHeadings: [Float] = [0.0, 47.0, -113.0, 170.0]

print("--- A. heading convergence ---")
for start in startHeadings {
    for turn in turnMagnitudes {
        let startRadians = radians(start)
        let commanded = wrapAngle(startRadians + radians(turn))
        let outcome = runPivot(
            startHeading: startRadians,
            commandedHeading: { _ in commanded },
            label: "A"
        )
        let label = String(format: "A start %+7.1f turn %+7.1f:", start, turn)
        summarize(label, outcome)

        check(
            outcome.settleSeconds != nil,
            String(format: "pivot from %+.0f by %+.0f deg never settled within %.0f s (final error %+.2f deg, rate %.3f)",
                   start, turn, maximumSeconds, degrees(outcome.finalErrorRadians), outcome.finalYawRate)
        )
        check(
            abs(outcome.finalErrorRadians) <= headingToleranceRadians,
            String(format: "pivot from %+.0f by %+.0f deg ended %+.2f deg off the commanded heading",
                   start, turn, degrees(outcome.finalErrorRadians))
        )
        // The gate holds until the aircraft is stopped and aligned; a pivot that never
        // releases it is the observed "align forever" failure.
        check(
            outcome.gateReleasedSeconds != nil,
            String(format: "stop-and-pivot gate never released after a %+.0f deg turn from %+.0f", turn, start)
        )
        // Turning the long way round is a real defect for an aircraft holding station beside
        // a building: it sweeps the wing through geometry the short turn would have avoided.
        check(
            outcome.worstErrorAfterStartRadians <= abs(radians(turn)) + radians(12.0),
            String(format: "pivot from %+.0f by %+.0f deg increased its heading error to %.1f deg (took the long way or diverged)",
                   start, turn, degrees(outcome.worstErrorAfterStartRadians))
        )
        check(
            outcome.overshootRadians <= radians(25.0),
            String(format: "pivot from %+.0f by %+.0f deg overshot by %.1f deg",
                   start, turn, degrees(outcome.overshootRadians))
        )
        check(outcome.remainedFinite, String(format: "pivot from %+.0f by %+.0f deg produced a non-finite state", start, turn))
    }
}

// MARK: B. Station keeping while pivoting
//
// `vtol_stop_and_pivot_align` latches a hold position precisely so the aircraft turns in
// place. Drifting while turning is what puts a wingtip into a facade, and the flight log
// showed a lateral command growing from 4.1 to 6.2 deg with the aircraft nominally stopped.

print("--- B. station keeping while pivoting ---")
for turn in [Float(90.0), -90.0, 179.0] {
    let outcome = runPivot(
        startHeading: radians(12.0),
        commandedHeading: { _ in wrapAngle(radians(12.0) + radians(turn)) },
        label: "B"
    )
    summarize(String(format: "B turn %+6.1f:", turn), outcome)
    check(
        outcome.maximumDriftMeters <= 2.5,
        String(format: "pivot of %+.0f deg drifted %.2f m off the latched hold", turn, outcome.maximumDriftMeters)
    )
    check(
        outcome.altitudeLossMeters <= 2.0,
        String(format: "pivot of %+.0f deg lost %.2f m of altitude", turn, outcome.altitudeLossMeters)
    )
}

// MARK: C. Null case — no turn requested
//
// The aircraft must not start rotating when it is already pointing where it was told to. The
// flight showed a heading walking away with no commanded change, so the null case is a test.

print("--- C. null case ---")
for start in startHeadings {
    let startRadians = radians(start)
    let outcome = runPivot(
        startHeading: startRadians,
        commandedHeading: { _ in startRadians },
        label: "C"
    )
    summarize(String(format: "C start %+7.1f:", start), outcome)
    check(
        outcome.worstErrorAfterStartRadians <= radians(3.0),
        String(format: "aircraft rotated %.2f deg away from an already-correct heading at %+.0f",
               degrees(outcome.worstErrorAfterStartRadians), start)
    )
    check(
        outcome.peakYawRate <= 0.25,
        String(format: "aircraft span up to %.3f rad/s with no turn commanded at %+.0f", outcome.peakYawRate, start)
    )
    check(
        outcome.gateReleasedSeconds != nil,
        String(format: "stop-and-pivot gate never released with no turn required at %+.0f", start)
    )
    check(
        outcome.maximumDriftMeters <= 1.0,
        String(format: "aircraft drifted %.2f m while holding an already-correct heading at %+.0f",
               outcome.maximumDriftMeters, start)
    )
}

// MARK: D. Target that moves mid-pivot
//
// A replan hands the guidance a new bearing partway through the turn. The aircraft has to
// re-aim, not accumulate the two commands into a spin.

print("--- D. commanded heading changes mid-pivot ---")
do {
    let start = radians(-30.0)
    let first = wrapAngle(start + radians(120.0))
    let second = wrapAngle(start - radians(70.0))
    let outcome = runPivot(
        startHeading: start,
        commandedHeading: { elapsed in elapsed < 2.0 ? first : second },
        label: "D"
    )
    summarize("D replan mid-turn:", outcome)
    check(
        outcome.settleSeconds != nil,
        String(format: "pivot never settled after the commanded heading changed mid-turn (final error %+.2f deg)",
               degrees(outcome.finalErrorRadians))
    )
    check(
        abs(outcome.finalErrorRadians) <= headingToleranceRadians,
        String(format: "pivot ended %+.2f deg off after a mid-turn replan", degrees(outcome.finalErrorRadians))
    )
    check(outcome.remainedFinite, "mid-turn replan produced a non-finite state")
}

// MARK: E. Slewing target
//
// Tracking a node whose bearing changes continuously (the aircraft is drifting, or the node
// is being re-projected every replan) must not turn into a chase that never converges.

print("--- E. slewing commanded heading ---")
do {
    let start = radians(90.0)
    let outcome = runPivot(
        startHeading: start,
        // 4 deg/s, well inside any sane yaw authority.
        commandedHeading: { elapsed in wrapAngle(start + radians(60.0) + radians(4.0) * elapsed) },
        label: "E"
    )
    summarize("E slewing 4 deg/s:", outcome)
    check(
        abs(outcome.finalErrorRadians) <= radians(12.0),
        String(format: "aircraft failed to track a 4 deg/s slewing heading (final error %+.2f deg)",
               degrees(outcome.finalErrorRadians))
    )
    check(outcome.remainedFinite, "slewing heading produced a non-finite state")
}

// MARK: G. Entering the pivot with speed on
//
// Every test above starts from a dead hover, so there is nothing to arrest and the gate's
// `planarSpeed <= 0.55 m/s` release condition is satisfied on tick one. A real pivot is
// entered from translation: the cursor reaches a node, the gate latches a hold, and the
// aircraft still carries its leg speed. In the flight this file comes from the HUD read
// 2.3 / 3.6 / 3.8 / 3.3 m/s throughout `vtol_stop_and_pivot_align` and the node distance kept
// falling (214.9 -> 192.8 m) — the aircraft was moving the whole time it claimed to be
// stopped and aligning, which is both why the gate never released and why it reached a
// facade. What matters is the stopping distance: in a street that is metres of margin.

print("--- G. entering the pivot with speed on ---")
for entrySpeed in [Float(2.0), 4.0, 8.0, 14.0] {
    let engine = SimpleDronePhysicsEngine()
    let autopilot = MulticopterAutopilotController()
    var gate = HybridVTOLStopAndPivotGate()
    let altitude: Float = 33.8
    let start = radians(35.0)
    let commanded = wrapAngle(start + radians(85.0))
    var state = initialState(altitude: altitude, heading: start)
    // Carried over from the leg that just ended, along the current nose.
    let forward = SIMD2<Float>(-sin(start), -cos(start))
    state.velocity = SIMD3<Float>(forward.x * entrySpeed, 0.0, forward.y * entrySpeed)
    let latch = state.position

    // Braking is projected into body axes built from Euler yaw, which is gimbal-locked at the
    // nose-up hover attitude. If that projection is wrong the aircraft sheds speed sideways
    // instead of along its travel, so cross-track is measured separately from stopping distance.
    let right = SIMD2<Float>(cos(start), -sin(start))
    var maximumCrossTrack: Float = 0.0
    var stoppedSeconds: Float?
    var gateReleasedSeconds: Float?
    var stoppingDistance: Float = 0.0
    var maximumSpeed = entrySpeed
    var peakCommandedTilt: Float = 0.0
    var peakAchievedTilt: Float = 0.0
    var peakWingborne: Float = 0.0
    var peakProgress: Float = 0.0
    var remainedFinite = true
    var hold = state.position
    var haveHold = false

    for step in 0..<maximumSteps {
        let elapsed = Float(step) * dt
        let heading = hoverHeading(state.attitudeQuat)
        let error = wrapAngle(commanded - heading)
        let yawRate = HybridVTOLFlightPolicy.stopAndPivotYawRate(
            isTailsitter: true,
            tailsitterBodyXRate: state.bodyAngularVelocity.x,
            conventionalYawRate: state.angularVelocity.z
        )
        let planarSpeed = simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
        maximumSpeed = max(maximumSpeed, planarSpeed)

        let guidance = gate.update(
            traversalMode: .stopAndPivotVTOL,
            routeIdentifier: "probe-entry",
            routeIndex: 1,
            position: state.position,
            planarSpeed: planarSpeed,
            headingErrorRadians: error,
            yawRateRadiansPerSecond: yawRate
        )
        // Follow the gate's hold every tick. Latching it once here would test a hold the production
        // gate does not command — it re-anchors a still-moving aircraft rather than flying it back.
        if let latched = guidance.holdPosition {
            hold = latched
            haveHold = true
        }
        if !guidance.shouldHold, gateReleasedSeconds == nil {
            gateReleasedSeconds = elapsed
        }
        if planarSpeed <= HybridVTOLStopAndPivotGate.maximumPlanarSpeedMps, stoppedSeconds == nil {
            stoppedSeconds = elapsed
        }

        let command = autopilot.command(for: AutopilotTrackingContext(
            state: state,
            physicalState: .airborne,
            target: hold,
            targetAltitude: altitude,
            speedScale: 0.28,
            yawAlignToHome: false,
            yawOverrideRadians: commanded,
            deltaTime: dt,
            flightBaseline: baseline,
            verticalVelocityDampingGain: 0.075
        ))
        // What actually bounds the deceleration: the commanded tilt, the tilt the airframe reaches,
        // and whether the wing has started carrying (which takes the aircraft out of the
        // rotor-borne regime this braking law assumes).
        peakCommandedTilt = max(peakCommandedTilt, max(abs(command.rollDegrees), abs(command.pitchDegrees)))
        peakAchievedTilt = max(peakAchievedTilt, degrees(thrustTilt(state.attitudeQuat)))
        peakWingborne = max(peakWingborne, state.vtolWingborneBlend)
        peakProgress = max(peakProgress, state.vtolTransitionProgress)
        state = engine.step(
            state: state,
            control: control(from: command),
            context: context,
            deltaTime: dt
        )
        let displacement = SIMD2<Float>(state.position.x - latch.x, state.position.z - latch.z)
        if stoppedSeconds == nil {
            stoppingDistance = max(stoppingDistance, simd_length(displacement))
        }
        maximumCrossTrack = max(maximumCrossTrack, abs(simd_dot(displacement, right)))
        remainedFinite = remainedFinite && isFinite(state.position) &&
            isFinite(state.velocity) && isFinite(state.attitudeQuat)
    }

    print(String(
        format: "G entry %5.1f m/s: stop %@ s, gate %@ s, stopping distance %.1f m, cross-track %.2f m, peak speed %.1f m/s",
        entrySpeed,
        stoppedSeconds.map { String(format: "%.2f", $0) } as NSString? ?? "never",
        gateReleasedSeconds.map { String(format: "%.2f", $0) } as NSString? ?? "never",
        stoppingDistance,
        maximumCrossTrack,
        maximumSpeed
    ))
    print(String(
        format: "                  tilt cmd %.1f deg, achieved %.1f deg, wingborne %.2f, progress %.2f",
        peakCommandedTilt, peakAchievedTilt, peakWingborne, peakProgress
    ))
    // Braking must shed speed along the direction of travel. A large cross-track means the
    // body-axis projection disagrees with the direction the airframe actually accelerates.
    check(
        maximumCrossTrack <= max(2.0, stoppingDistance * 0.35),
        String(format: "pivot entered at %.1f m/s braked %.1f m sideways over %.1f m of travel",
               entrySpeed, maximumCrossTrack, stoppingDistance)
    )
    check(
        stoppedSeconds != nil,
        String(format: "pivot entered at %.1f m/s never slowed below the gate's %.2f m/s release speed",
               entrySpeed, HybridVTOLStopAndPivotGate.maximumPlanarSpeedMps)
    )
    check(
        gateReleasedSeconds != nil,
        String(format: "stop-and-pivot gate never released after entering at %.1f m/s", entrySpeed)
    )
    // Stopping distance has to grow with entry speed — a flat limit would be a physics claim,
    // not a control one. Rotor-borne braking authority is capped by the tilt envelope, so the
    // achievable distance is roughly linear in entry speed rather than quadratic. This budget
    // leaves ~20% headroom over measured behaviour at every speed, and every pre-fix number
    // (14.2 m at 4 m/s, 26.7 m at 8, 32.3 m at 14) sits well outside it.
    let stoppingBudget = 2.5 + entrySpeed * 1.4
    check(
        stoppingDistance <= stoppingBudget,
        String(format: "pivot entered at %.1f m/s coasted %.1f m past its latched hold (budget %.1f m)",
               entrySpeed, stoppingDistance, stoppingBudget)
    )
    check(
        maximumSpeed <= entrySpeed + 0.5,
        String(format: "pivot entered at %.1f m/s accelerated to %.1f m/s instead of arresting", entrySpeed, maximumSpeed)
    )
    check(remainedFinite, String(format: "pivot entered at %.1f m/s produced a non-finite state", entrySpeed))
}

// MARK: H. Closing on a node — the capture must actually happen
//
// Reaching a node is not the same as capturing it. `HybridVTOLRouteCursor` advances only when the
// aircraft is simultaneously inside `stopAndPivotCaptureRadiusMeters` (0.70 m) and at or below
// `HybridVTOLStopAndPivotGate.maximumPlanarSpeedMps`. A position loop that limit-cycles around the
// node satisfies each condition alternately and neither together: measured on a stalled flight,
// the node distance oscillated 0.2, 1.6, 1.4, 0.6, 1.2, 1.7, 0.3 m with the aircraft otherwise
// stationary, and the mission stopped on a node it was already sitting on.
//
// These thresholds are the safety contract — a hover leg may not begin a metre inside a corner —
// so this group asserts the aircraft can meet them as written, rather than relaxing them.

print("--- H. node capture, not just node arrival ---")
for approach in [Float(3.0), 12.0, 45.0] {
    let engine = SimpleDronePhysicsEngine()
    let autopilot = MulticopterAutopilotController()
    let altitude: Float = 32.4
    let heading = radians(-64.0)
    var state = initialState(altitude: altitude, heading: heading)
    let origin = state.position
    let forward = SIMD2<Float>(-sin(heading), -cos(heading))
    let node = SIMD3<Float>(
        origin.x + forward.x * approach,
        altitude,
        origin.z + forward.y * approach
    )
    let nodePlanar = SIMD2<Float>(node.x, node.z)

    var captureSeconds: Float?
    var settledDistance: Float = .infinity
    // Residual oscillation is a property of the *settled* state, so it is measured over the last
    // five seconds only — including the approach would just report how far away the aircraft
    // started.
    let totalSteps = 60 * 45
    let settlingWindowStart = totalSteps - 60 * 5
    var minimumSettled: Float = .infinity
    var maximumSettled: Float = 0.0
    var remainedFinite = true

    for step in 0..<totalSteps {
        let elapsed = Float(step) * dt
        let planar = SIMD2<Float>(state.position.x, state.position.z)
        let toNode = nodePlanar - planar
        let distance = simd_length(toNode)
        let planarSpeed = simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
        let bearing = distance > 0.5 ? atan2(-toNode.x, -toNode.y) : heading

        if step >= settlingWindowStart {
            minimumSettled = min(minimumSettled, distance)
            maximumSettled = max(maximumSettled, distance)
            settledDistance = distance
        }
        // The production capture test, verbatim.
        if distance <= HybridVTOLRouteCursor.stopAndPivotCaptureRadiusMeters,
           planarSpeed <= HybridVTOLStopAndPivotGate.maximumPlanarSpeedMps,
           captureSeconds == nil {
            captureSeconds = elapsed
        }

        let command = autopilot.command(for: AutopilotTrackingContext(
            state: state,
            physicalState: .airborne,
            target: node,
            targetAltitude: altitude,
            speedScale: 0.52,
            yawAlignToHome: false,
            yawOverrideRadians: bearing,
            deltaTime: dt,
            flightBaseline: baseline,
            verticalVelocityDampingGain: 0.075
        ))
        state = engine.step(
            state: state,
            control: control(from: command),
            context: context,
            deltaTime: dt
        )
        remainedFinite = remainedFinite && isFinite(state.position) &&
            isFinite(state.velocity) && isFinite(state.attitudeQuat)
    }

    let amplitude = maximumSettled - minimumSettled
    print(String(
        format: "H approach %5.1f m: capture %@ s, settled %.2f m, last-5s band %.2f...%.2f m (amplitude %.2f)",
        approach,
        captureSeconds.map { String(format: "%.2f", $0) } as NSString? ?? "never",
        settledDistance,
        minimumSettled,
        maximumSettled,
        amplitude
    ))
    check(
        captureSeconds != nil,
        String(format: "node %.1f m away was never captured: needs <= %.2f m and <= %.2f m/s at the same instant",
               approach,
               HybridVTOLRouteCursor.stopAndPivotCaptureRadiusMeters,
               HybridVTOLStopAndPivotGate.maximumPlanarSpeedMps)
    )
    check(
        settledDistance <= HybridVTOLRouteCursor.stopAndPivotCaptureRadiusMeters,
        String(format: "aircraft settled %.2f m from a node %.1f m away instead of on it", settledDistance, approach)
    )
    // A limit cycle wider than the capture radius is the failure mode itself: each condition is
    // met on alternate ticks and the cursor never advances.
    check(
        amplitude <= HybridVTOLRouteCursor.stopAndPivotCaptureRadiusMeters,
        String(format: "approach of %.1f m left a %.2f m limit cycle around the node", approach, amplitude)
    )
    check(remainedFinite, String(format: "approach of %.1f m produced a non-finite state", approach))
}

// MARK: F. Full stop-and-pivot leg — pivot, then translate to the node
//
// The gate releasing is only useful if translation then actually closes on the node. In the
// flight, node distance sat at 192.8 -> 193.6 m and never fell.

print("--- F. pivot then translate ---")
do {
    let engine = SimpleDronePhysicsEngine()
    let autopilot = MulticopterAutopilotController()
    var gate = HybridVTOLStopAndPivotGate()
    let altitude: Float = 33.8
    let start = radians(140.0)
    var state = initialState(altitude: altitude, heading: start)
    let origin = state.position
    // A node 60 m away on a bearing 110 deg off the current nose.
    let nodeBearing = wrapAngle(start + radians(110.0))
    let node = SIMD3<Float>(
        origin.x - sin(nodeBearing) * 60.0,
        altitude,
        origin.z - cos(nodeBearing) * 60.0
    )
    var hold = origin
    var released = false
    var releaseSeconds: Float?
    var minimumDistance = simd_distance(
        SIMD2<Float>(origin.x, origin.z),
        SIMD2<Float>(node.x, node.z)
    )
    let initialDistance = minimumDistance
    var remainedFinite = true

    for step in 0..<(60 * 40) {
        let elapsed = Float(step) * dt
        let planar = SIMD2<Float>(state.position.x, state.position.z)
        let toNode = SIMD2<Float>(node.x, node.z) - planar
        let distance = simd_length(toNode)
        minimumDistance = min(minimumDistance, distance)
        let bearing = distance > 0.5 ? atan2(-toNode.x, -toNode.y) : nodeBearing
        let heading = hoverHeading(state.attitudeQuat)
        let error = wrapAngle(bearing - heading)
        let yawRate = HybridVTOLFlightPolicy.stopAndPivotYawRate(
            isTailsitter: true,
            tailsitterBodyXRate: state.bodyAngularVelocity.x,
            conventionalYawRate: state.angularVelocity.z
        )
        let planarSpeed = simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
        let guidance = gate.update(
            traversalMode: .stopAndPivotVTOL,
            routeIdentifier: "probe-leg",
            routeIndex: 1,
            position: state.position,
            planarSpeed: planarSpeed,
            headingErrorRadians: error,
            yawRateRadiansPerSecond: yawRate
        )
        if !guidance.shouldHold, !released {
            released = true
            releaseSeconds = elapsed
        }
        if let latched = guidance.holdPosition, guidance.shouldHold {
            hold = latched
        }
        // Exactly the production branch split: hold while the gate holds, otherwise track.
        let target = guidance.shouldHold ? hold : node
        let command = autopilot.command(for: AutopilotTrackingContext(
            state: state,
            physicalState: .airborne,
            target: target,
            targetAltitude: altitude,
            speedScale: guidance.shouldHold ? 0.28 : 0.52,
            yawAlignToHome: false,
            yawOverrideRadians: bearing,
            deltaTime: dt,
            flightBaseline: baseline,
            verticalVelocityDampingGain: 0.075
        ))
        state = engine.step(
            state: state,
            control: control(from: command),
            context: context,
            deltaTime: dt
        )
        remainedFinite = remainedFinite && isFinite(state.position) &&
            isFinite(state.velocity) && isFinite(state.attitudeQuat)
    }

    let finalDistance = simd_distance(
        SIMD2<Float>(state.position.x, state.position.z),
        SIMD2<Float>(node.x, node.z)
    )
    print(String(
        format: "F leg: release %@ s, distance %.1f -> %.1f m (closest %.1f)",
        releaseSeconds.map { String(format: "%.2f", $0) } as NSString? ?? "never",
        initialDistance, finalDistance, minimumDistance
    ))
    check(released, "stop-and-pivot gate never released on a full leg, so translation never began")
    check(
        minimumDistance < initialDistance - 20.0,
        String(format: "aircraft closed only %.1f m of a %.1f m leg", initialDistance - minimumDistance, initialDistance)
    )
    check(remainedFinite, "full stop-and-pivot leg produced a non-finite state")
}

if failures.isEmpty {
    print("RESULT: PASS - tailsitter stop-and-pivot heading control converges across the suite")
    exit(0)
}

print("RESULT: FAIL - \(failures.count) stop-and-pivot heading contract(s) violated")
exit(1)
