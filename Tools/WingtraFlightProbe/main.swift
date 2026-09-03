import Foundation
import simd

// Closed-loop Wingtra tailsitter flight regression.
//
// The static ground probe proves contact placement, but cannot catch an
// attitude feedback loop that becomes singular only after AUTO requests a
// course while the aircraft is nose-up.  This probe flies the production
// Wingtra profile and physics at 60 Hz and checks these contracts:
//
// 1. a large hover-heading request converges on the physical tailsitter
//    heading (body -Y), without rolling through vertical;
// 2. a one-degree pitch overshoot past 90 degrees returns to vertical rather
//    than being driven farther through it;
// 3. Euler telemetry follows the quaternion-derived hover heading through
//    wrap and through the near-vertical extraction threshold;
// 4. after a vertical-departure brake and heading capture, a commanded
//    transition physically crosses a short-leg waypoint sphere without a
//    tumble or an unbounded height loss.
//
// Run: Tools/WingtraFlightProbe/run.sh

private let dt: Float = 1.0 / 60.0
private var failures: [String] = []

private func radians(_ degrees: Float) -> Float {
    degrees * .pi / 180.0
}

private func degrees(_ radians: Float) -> Float {
    radians * 180.0 / .pi
}

private func wrap(_ value: Float) -> Float {
    var result = value
    while result > .pi { result -= 2.0 * .pi }
    while result < -.pi { result += 2.0 * .pi }
    return result
}

private func orientation(yaw: Float, pitch: Float, roll: Float = 0.0) -> simd_quatf {
    let yawQ = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
    let pitchQ = simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
    let rollQ = simd_quatf(angle: roll, axis: SIMD3<Float>(0, 0, 1))
    return yawQ * pitchQ * rollQ
}

private func hoverHeading(_ q: simd_quatf) -> Float {
    let direction = -simd_act(q, SIMD3<Float>(0, 1, 0))
    return atan2(-direction.x, -direction.z)
}

private func horizontalForwardMagnitude(_ q: simd_quatf) -> Float {
    let forward = simd_act(q, SIMD3<Float>(0, 0, -1))
    return simd_length(SIMD2<Float>(forward.x, forward.z))
}

private func tailsitterTelemetryHeading(_ q: simd_quatf) -> Float {
    let forward = simd_act(q, SIMD3<Float>(0, 0, -1))
    let horizontalForward = simd_length(SIMD2<Float>(forward.x, forward.z))
    let hoverGauge = hoverHeading(q)
    let forwardGauge = horizontalForward > 1e-5
        ? atan2(-forward.x, -forward.z)
        : hoverGauge
    let rawBlend = min(1.0, max(0.0, (horizontalForward - 0.02) / 0.055))
    let blend = rawBlend * rawBlend * (3.0 - 2.0 * rawBlend)
    return wrap(hoverGauge + wrap(forwardGauge - hoverGauge) * blend)
}

private func forwardHeading(_ q: simd_quatf) -> Float? {
    let forward = simd_act(q, SIMD3<Float>(0, 0, -1))
    let horizontal = SIMD2<Float>(forward.x, forward.z)
    guard simd_length_squared(horizontal) > 1e-8 else { return nil }
    return atan2(-forward.x, -forward.z)
}

private func quaternionDistance(_ lhs: simd_quatf, _ rhs: simd_quatf) -> Float {
    let lhsLength = simd_length(lhs.vector)
    let rhsLength = simd_length(rhs.vector)
    guard lhsLength > 1e-6, rhsLength > 1e-6 else { return .infinity }
    let cosine = abs(simd_dot(lhs.vector / lhsLength, rhs.vector / rhsLength))
    return 2.0 * acos(min(1.0, max(0.0, cosine)))
}

private func sweptPlanarDistance(
    from start: SIMD3<Float>,
    to end: SIMD3<Float>,
    point: SIMD3<Float>
) -> Float {
    let startPlanar = SIMD2<Float>(start.x, start.z)
    let endPlanar = SIMD2<Float>(end.x, end.z)
    let pointPlanar = SIMD2<Float>(point.x, point.z)
    let segment = endPlanar - startPlanar
    let lengthSquared = simd_length_squared(segment)
    guard lengthSquared > 1e-8 else { return simd_distance(startPlanar, pointPlanar) }
    let fraction = min(1.0, max(0.0, simd_dot(pointPlanar - startPlanar, segment) / lengthSquared))
    return simd_distance(startPlanar + segment * fraction, pointPlanar)
}

private func isFinite(_ value: SIMD3<Float>) -> Bool {
    value.x.isFinite && value.y.isFinite && value.z.isFinite
}

private func isFinite(_ value: simd_quatf) -> Bool {
    value.vector.x.isFinite && value.vector.y.isFinite &&
        value.vector.z.isFinite && value.vector.w.isFinite
}

private func verticalError(_ q: simd_quatf) -> Float {
    let forward = simd_normalize(simd_act(q, SIMD3<Float>(0, 0, -1)))
    let cosine = min(1.0, max(-1.0, simd_dot(forward, SIMD3<Float>(0, 1, 0))))
    return acos(cosine)
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures.append(message)
        print("FAIL: \(message)")
    }
}

private let repository = LIPODroneModelRepository()
guard let profile = repository.allProfiles.first(where: {
    $0.id == "wingtraone-gen-ii" || $0.displayName.contains("WingtraOne")
}) else {
    print("RESULT: FAIL - Wingtra runtime profile is missing")
    exit(1)
}
guard profile.airframeStyle == .tailsitterVTOL else {
    print("RESULT: FAIL - Wingtra fixture is no longer a tailsitter")
    exit(1)
}
guard let wing = profile.fixedWingParameters else {
    print("RESULT: FAIL - Wingtra fixed-wing parameters are missing")
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

private func initialState(yaw: Float = 0.0, pitch: Float = .pi / 2) -> DroneState {
    var state = DroneState(
        position: SIMD3<Float>(0, 100, 0),
        velocity: .zero,
        orientation: SIMD3<Float>(0, pitch, yaw),
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
    state.attitudeQuat = orientation(yaw: yaw, pitch: pitch)
    state.bodyAngularVelocity = .zero
    state.propulsionUnits = profile.propulsionUnitTemplate
    state.vtolTransitionProgress = 0.0
    state.vtolWingborneBlend = 0.0
    return state
}

private func control(
    for state: DroneState,
    targetHeading: Float,
    transitionLever: Float,
    throttle: Float? = nil,
    targetPosition: SIMD3<Float>? = nil
) -> DroneControlInput {
    DroneControlInput(
        targetPosition: targetPosition ?? SIMD3<Float>(state.position.x, 100, state.position.z),
        targetOrientation: SIMD3<Float>(0, 0, targetHeading),
        yawIntent: 0.0,
        throttle: throttle ?? baseline.hoverLockThrottle,
        isArmed: true,
        mode: .autoPath,
        controlMode: .hoverAssist,
        vtolTransitionLever: transitionLever
    )
}

// MARK: Hover heading capture

do {
    let engine = SimpleDronePhysicsEngine()
    var state = initialState()
    let target = radians(149)
    var maximumVerticalError: Float = 0.0
    var maximumHorizontalDisplacement: Float = 0.0
    var maximumTelemetryHeadingError: Float = 0.0
    var nearVerticalTelemetrySamples = 0
    var previousAbsoluteHeadingError = abs(wrap(target - hoverHeading(state.attitudeQuat)))
    var finalWindowMonotonicViolations = 0

    for tick in 0..<(60 * 12) {
        state = engine.step(
            state: state,
            control: control(for: state, targetHeading: target, transitionLever: 0.0),
            context: context,
            deltaTime: dt
        )
        maximumVerticalError = max(maximumVerticalError, verticalError(state.attitudeQuat))
        maximumHorizontalDisplacement = max(
            maximumHorizontalDisplacement,
            simd_length(SIMD2<Float>(state.position.x, state.position.z))
        )
        if horizontalForwardMagnitude(state.attitudeQuat) < 0.08 {
            nearVerticalTelemetrySamples += 1
            maximumTelemetryHeadingError = max(
                maximumTelemetryHeadingError,
                abs(wrap(state.orientation.z - hoverHeading(state.attitudeQuat)))
            )
        }
        let error = abs(wrap(target - hoverHeading(state.attitudeQuat)))
        if tick >= 60 * 8, error > previousAbsoluteHeadingError + radians(0.15) {
            finalWindowMonotonicViolations += 1
        }
        previousAbsoluteHeadingError = error
    }

    let headingError = abs(wrap(target - hoverHeading(state.attitudeQuat)))
    print(String(
        format: "hover: heading error %.2f deg, telemetry %.3f deg, vertical error max %.2f deg, drift %.2f m, rate %.3f rad/s",
        degrees(headingError), degrees(maximumTelemetryHeadingError),
        degrees(maximumVerticalError), maximumHorizontalDisplacement,
        simd_length(state.bodyAngularVelocity)
    ))
    check(headingError < radians(3.0), "hover heading did not converge to the requested course")
    check(maximumVerticalError < radians(4.0), "heading capture tipped the tailsitter away from vertical")
    check(maximumHorizontalDisplacement < 4.0, "heading capture produced horizontal runaway")
    check(simd_length(state.bodyAngularVelocity) < 0.12, "hover rotation did not settle")
    check(finalWindowMonotonicViolations < 4, "settled hover heading oscillates or diverges")
    check(nearVerticalTelemetrySamples > 60, "hover did not exercise the near-vertical Euler fallback")
    check(
        maximumTelemetryHeadingError < radians(0.25),
        "state.orientation.z diverged from quaternion hover heading near vertical"
    )
}

// MARK: Hover-heading wrap continuity

do {
    let engine = SimpleDronePhysicsEngine()
    let initialHeading = radians(179.0)
    let targetHeading = radians(-179.0)
    var state = initialState(yaw: initialHeading)
    var previousTelemetryHeading = state.orientation.z
    var unwrappedTelemetryTravel: Float = 0.0
    var maximumTelemetryHeadingError: Float = 0.0
    var maximumVerticalError: Float = 0.0
    var crossedPositivePi = false

    for _ in 0..<(60 * 6) {
        state = engine.step(
            state: state,
            control: control(for: state, targetHeading: targetHeading, transitionLever: 0.0),
            context: context,
            deltaTime: dt
        )
        let telemetryStep = wrap(state.orientation.z - previousTelemetryHeading)
        unwrappedTelemetryTravel += telemetryStep
        if previousTelemetryHeading > radians(170.0), state.orientation.z < radians(-170.0) {
            crossedPositivePi = true
        }
        previousTelemetryHeading = state.orientation.z
        maximumTelemetryHeadingError = max(
            maximumTelemetryHeadingError,
            abs(wrap(state.orientation.z - hoverHeading(state.attitudeQuat)))
        )
        maximumVerticalError = max(maximumVerticalError, verticalError(state.attitudeQuat))
    }

    let finalHeadingError = abs(wrap(targetHeading - hoverHeading(state.attitudeQuat)))
    print(String(
        format: "heading wrap: travel %+.2f deg, final error %.3f deg, telemetry %.3f deg, crossed=%@",
        degrees(unwrappedTelemetryTravel), degrees(finalHeadingError),
        degrees(maximumTelemetryHeadingError), (crossedPositivePi ? "yes" : "no") as NSString
    ))
    check(crossedPositivePi, "hover heading failed to cross the +179/-179 telemetry wrap")
    check(
        unwrappedTelemetryTravel > 0.0 && unwrappedTelemetryTravel < radians(8.0),
        "hover heading took the long or wrong direction across +/-pi"
    )
    check(finalHeadingError < radians(0.5), "wrapped hover heading did not settle on -179 degrees")
    check(
        maximumTelemetryHeadingError < radians(0.25),
        "state.orientation.z lost quaternion heading across +/-pi"
    )
    check(maximumVerticalError < radians(1.0), "wrapped heading capture tipped the tailsitter")
}

// MARK: Vertical overshoot recovery

do {
    let engine = SimpleDronePhysicsEngine()
    var state = initialState(pitch: radians(91.0))
    let initialError = verticalError(state.attitudeQuat)
    var maximumError = initialError

    for _ in 0..<(60 * 4) {
        state = engine.step(
            state: state,
            control: control(for: state, targetHeading: 0.0, transitionLever: 0.0),
            context: context,
            deltaTime: dt
        )
        maximumError = max(maximumError, verticalError(state.attitudeQuat))
    }

    let finalError = verticalError(state.attitudeQuat)
    print(String(
        format: "overshoot: initial %.2f deg, final %.3f deg, max %.2f deg",
        degrees(initialError), degrees(finalError), degrees(maximumError)
    ))
    check(finalError < radians(0.35), "pitch >90 degrees did not recover to nose-up hover")
    check(maximumError < radians(2.0), "pitch overshoot was driven farther through vertical")
}

// MARK: Rotor-borne blocked-route altitude hold

do {
    let engine = SimpleDronePhysicsEngine()
    var state = initialState()
    state.velocity.y = profile.maxAscentSpeedMps
    let holdAltitude = state.position.y
    var maximumAltitude = state.position.y
    var minimumAltitude = state.position.y
    var maximumVerticalSpeed = state.velocity.y
    var minimumVerticalSpeed = state.velocity.y

    for _ in 0..<(60 * 7) {
        let altitudeError = holdAltitude - state.position.y
        let verticalComp = (
            altitudeError * 0.06 - state.velocity.y * 0.075
        ) * baseline.effectiveVerticalResponseFactor
        let brakingThrottle = min(
            0.90,
            max(0.18, baseline.hoverLockThrottle + verticalComp)
        )
        var holdControl = control(
            for: state,
            targetHeading: 0.0,
            transitionLever: 0.0,
            throttle: brakingThrottle
        )
        holdControl.targetPosition.y = holdAltitude
        state = engine.step(
            state: state,
            control: holdControl,
            context: context,
            deltaTime: dt
        )
        maximumAltitude = max(maximumAltitude, state.position.y)
        minimumAltitude = min(minimumAltitude, state.position.y)
        maximumVerticalSpeed = max(maximumVerticalSpeed, state.velocity.y)
        minimumVerticalSpeed = min(minimumVerticalSpeed, state.velocity.y)
    }

    print(String(
        format: "blocked hold: range %+.2f...%+.2f m, vy %.2f...%.2f (final %.2f), motor %.2f, progress %.2f",
        minimumAltitude - holdAltitude, maximumAltitude - holdAltitude,
        minimumVerticalSpeed, maximumVerticalSpeed, state.velocity.y,
        state.motorThrottle, state.vtolTransitionProgress
    ))
    check(maximumAltitude - holdAltitude < 8.0, "blocked hover continued an unbounded vertical climb")
    check(abs(state.velocity.y) < 0.65, "blocked hover failed to arrest vertical speed")
    check(state.vtolTransitionProgress < 0.02, "blocked hover advanced the wing transition")
}

// MARK: Vertical-departure handoff and 54 m waypoint capture

do {
    let engine = SimpleDronePhysicsEngine()
    var state = initialState()
    state.velocity.y = profile.maxAscentSpeedMps
    let departureAltitude = state.position.y
    let targetHeading = radians(55.0)
    var minimumAltitude = state.position.y
    var maximumDepartureAltitude = state.position.y
    var maximumVerticalErrorDuringAlignment: Float = 0.0
    var handoffTick: Int?
    var handoffVerticalSpeed: Float = .infinity

    // A vertical departure reaches the ascent governor before route guidance
    // asks for forward flight.  Hold the departure altitude and align first;
    // transition authority is not handed over until the climb is arrested.
    for tick in 0..<(60 * 14) {
        let altitudeError = departureAltitude - state.position.y
        let verticalComp = (
            altitudeError * 0.06 - state.velocity.y * 0.075
        ) * baseline.effectiveVerticalResponseFactor
        let brakingThrottle = min(
            0.90,
            max(0.18, baseline.hoverLockThrottle + verticalComp)
        )
        let departureTarget = SIMD3<Float>(state.position.x, departureAltitude, state.position.z)
        state = engine.step(
            state: state,
            control: control(
                for: state,
                targetHeading: targetHeading,
                transitionLever: 0.0,
                throttle: brakingThrottle,
                targetPosition: departureTarget
            ),
            context: context,
            deltaTime: dt
        )
        maximumDepartureAltitude = max(maximumDepartureAltitude, state.position.y)
        maximumVerticalErrorDuringAlignment = max(
            maximumVerticalErrorDuringAlignment,
            verticalError(state.attitudeQuat)
        )
        let headingError = abs(wrap(targetHeading - hoverHeading(state.attitudeQuat)))
        if abs(state.position.y - departureAltitude) <= 2.25,
           abs(state.velocity.y) <= 0.45,
           headingError < radians(6.0) {
            handoffTick = tick + 1
            handoffVerticalSpeed = state.velocity.y
            break
        }
    }

    let legDistance: Float = 54.0
    let captureRadius = wing.waypointCaptureRadius(airspeed: wing.cruiseAirspeed)
    let precisionRadius = max(
        16.0,
        captureRadius * 1.10,
        min(wing.minimumTurnRadius(airspeed: wing.cruiseAirspeed) * 0.65, captureRadius * 2.6)
    )
    let routeDirection = SIMD3<Float>(-sin(targetHeading), 0, -cos(targetHeading))
    let legStart = state.position
    let waypoint = SIMD3<Float>(
        legStart.x + routeDirection.x * legDistance,
        departureAltitude,
        legStart.z + routeDirection.z * legDistance
    )
    let requiresTransition = HybridVTOLFlightPolicy.tailsitterValidatedLegRequiresWingTransition(
        isTailsitter: true,
        routeIsValidated: true,
        isFinalSegment: true,
        finalPlanarDistance: legDistance,
        precisionRadius: precisionRadius
    )
    let alignmentAltitudeError = state.position.y - departureAltitude
    let alignmentVerticalSpeed = state.velocity.y
    let alignmentHeadingError = abs(wrap(targetHeading - hoverHeading(state.attitudeQuat)))

    var previousPosition = state.position
    var previousTelemetryHeading = state.orientation.z
    var previousHorizontalForward = horizontalForwardMagnitude(state.attitudeQuat)
    var thresholdCrossed = false
    var crossingYawStep: Float = .infinity
    var crossingForwardHeadingError: Float = .infinity
    var maximumNearVerticalTelemetryError: Float = 0.0
    var maximumHoverGaugeError: Float = 0.0
    var maximumBlendedGaugeError: Float = 0.0
    var maximumForwardGaugeError: Float = 0.0
    var hoverGaugeSamples = 0
    var blendedGaugeSamples = 0
    var forwardGaugeSamples = 0
    var minimumSweptDistance = simd_distance(
        SIMD2<Float>(state.position.x, state.position.z),
        SIMD2<Float>(waypoint.x, waypoint.z)
    )
    var captured = minimumSweptDistance <= captureRadius
    var captureProgress: Float = captured ? state.vtolTransitionProgress : 0.0
    var captureSpeed: Float = captured ? state.forwardAirspeed : 0.0
    var maximumProgressBeforeCapture = state.vtolTransitionProgress
    var maximumAirspeedBeforeCapture = state.forwardAirspeed
    var maximumAttitudeError: Float = 0.0
    var maximumBodyRate: Float = 0.0
    var minimumForwardY: Float = 1.0
    var remainedFinite = true
    let transitionAutopilot = MulticopterAutopilotController()

    for _ in 0..<(60 * 18) {
        let planarRoute = SIMD2<Float>(waypoint.x - state.position.x, waypoint.z - state.position.z)
        let planarDistance = simd_length(planarRoute)
        let direction = planarDistance > 0.01
            ? planarRoute / planarDistance
            : SIMD2<Float>(-sin(targetHeading), -cos(targetHeading))
        let lookahead = min(planarDistance, min(max(planarDistance * 0.45, 12.0), 25.6))
        let transitionTarget = SIMD3<Float>(
            state.position.x + direction.x * lookahead,
            departureAltitude,
            state.position.z + direction.y * lookahead
        )
        let trackingContext = AutopilotTrackingContext(
            state: state,
            physicalState: .airborne,
            target: transitionTarget,
            targetAltitude: departureAltitude,
            speedScale: 0.84,
            yawAlignToHome: false,
            yawOverrideRadians: targetHeading,
            deltaTime: dt,
            flightBaseline: baseline,
            verticalVelocityDampingGain: 0.075
        )
        var command = transitionAutopilot.command(for: trackingContext)
        let attitudeScale = min(1.0, max(0.25, 1.0 - state.vtolTransitionProgress * 0.65))
        command.rollDegrees *= attitudeScale
        command.pitchDegrees *= attitudeScale
        command.throttle = max(
            command.throttle,
            baseline.hoverLockThrottle,
            baseline.cruiseReferenceThrottle
        )
        if state.position.y < departureAltitude - 0.30 {
            command.throttle = max(command.throttle, baseline.takeoffThrottleReference)
        }
        let transitionControl = DroneControlInput(
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
            vtolTransitionLever: 1.0
        )
        state = engine.step(
            state: state,
            control: transitionControl,
            context: context,
            deltaTime: dt
        )

        let horizontalForward = horizontalForwardMagnitude(state.attitudeQuat)
        if horizontalForward < 0.08 {
            maximumNearVerticalTelemetryError = max(
                maximumNearVerticalTelemetryError,
                abs(wrap(state.orientation.z - tailsitterTelemetryHeading(state.attitudeQuat)))
            )
        }
        if horizontalForward <= 0.02 {
            hoverGaugeSamples += 1
            maximumHoverGaugeError = max(
                maximumHoverGaugeError,
                abs(wrap(state.orientation.z - hoverHeading(state.attitudeQuat)))
            )
        } else if horizontalForward < 0.075 {
            blendedGaugeSamples += 1
            maximumBlendedGaugeError = max(
                maximumBlendedGaugeError,
                abs(wrap(state.orientation.z - tailsitterTelemetryHeading(state.attitudeQuat)))
            )
        } else if let heading = forwardHeading(state.attitudeQuat) {
            forwardGaugeSamples += 1
            maximumForwardGaugeError = max(
                maximumForwardGaugeError,
                abs(wrap(state.orientation.z - heading))
            )
        }
        if !thresholdCrossed, previousHorizontalForward < 0.08, horizontalForward >= 0.08 {
            thresholdCrossed = true
            crossingYawStep = abs(wrap(state.orientation.z - previousTelemetryHeading))
            if let heading = forwardHeading(state.attitudeQuat) {
                crossingForwardHeadingError = abs(wrap(state.orientation.z - heading))
            }
        }
        previousHorizontalForward = horizontalForward
        previousTelemetryHeading = state.orientation.z

        let expectedPitch = (1.0 - state.vtolTransitionProgress) * (.pi / 2) +
            state.vtolTransitionProgress * radians(command.pitchDegrees)
        maximumAttitudeError = max(
            maximumAttitudeError,
            quaternionDistance(
                state.attitudeQuat,
                orientation(
                    yaw: radians(command.yawDegrees),
                    pitch: expectedPitch,
                    roll: radians(command.rollDegrees)
                )
            )
        )
        maximumBodyRate = max(maximumBodyRate, simd_length(state.bodyAngularVelocity))
        let forward = simd_act(state.attitudeQuat, SIMD3<Float>(0, 0, -1))
        minimumForwardY = min(minimumForwardY, forward.y)
        remainedFinite = remainedFinite &&
            isFinite(state.position) && isFinite(state.velocity) &&
            isFinite(state.bodyAngularVelocity) && isFinite(state.attitudeQuat)

        let distance = sweptPlanarDistance(from: previousPosition, to: state.position, point: waypoint)
        minimumSweptDistance = min(minimumSweptDistance, distance)
        if !captured {
            maximumProgressBeforeCapture = max(maximumProgressBeforeCapture, state.vtolTransitionProgress)
            maximumAirspeedBeforeCapture = max(maximumAirspeedBeforeCapture, state.forwardAirspeed)
        }
        if !captured, distance <= captureRadius {
            captured = true
            captureProgress = state.vtolTransitionProgress
            captureSpeed = state.forwardAirspeed
        }
        previousPosition = state.position
        minimumAltitude = min(minimumAltitude, state.position.y)
    }

    let forward = simd_act(state.attitudeQuat, SIMD3<Float>(0, 0, -1))
    let planarForward = SIMD2<Float>(forward.x, forward.z)
    let course = atan2(-planarForward.x, -planarForward.y)
    let courseError = abs(wrap(targetHeading - course))
    print(String(
        format: "54m leg: radius %.2f/precision %.2f m, handoff %.2fs/vy %.2f (align dY %+.2f/vy %+.2f/hdg %.2fdeg), capture=%@ minDist %.2f m at prog %.2f/%.1f mps, threshold yawStep %.3f deg/fwdErr %.3f deg, attitude %.1f deg",
        captureRadius, precisionRadius, Float(handoffTick ?? -1) * dt, handoffVerticalSpeed,
        alignmentAltitudeError, alignmentVerticalSpeed, degrees(alignmentHeadingError),
        (captured ? "yes" : "no") as NSString, minimumSweptDistance,
        captureProgress, captureSpeed, degrees(crossingYawStep),
        degrees(crossingForwardHeadingError), degrees(maximumAttitudeError)
    ))
    print(String(
        format: "transition: progress %.2f, wing %.2f, speed %.2f m/s, minY %.2f m, course error %.1f deg, maxRate %.2f rad/s",
        state.vtolTransitionProgress, state.vtolWingborneBlend, state.forwardAirspeed,
        minimumAltitude, degrees(courseError), maximumBodyRate
    ))
    print(String(
        format: "heading gauge: hover %.3f deg (%d), blend %.3f deg (%d), forward %.3f deg (%d)",
        degrees(maximumHoverGaugeError), hoverGaugeSamples,
        degrees(maximumBlendedGaugeError), blendedGaugeSamples,
        degrees(maximumForwardGaugeError), forwardGaugeSamples
    ))
    check(handoffTick != nil, "vertical departure never reached the safe transition handoff")
    check(maximumDepartureAltitude - departureAltitude < 8.0, "departure braking overshot altitude without bound")
    check(maximumVerticalErrorDuringAlignment < radians(4.0), "pre-transition heading alignment tumbled")
    check(requiresTransition, "validated 54 m Wingtra leg was not classified for wing transition")
    check(abs(captureRadius - 15.95) < 0.15, "Wingtra waypoint sphere radius changed unexpectedly")
    check(thresholdCrossed, "transition never crossed horizontalForward = 0.08")
    check(crossingYawStep < radians(2.0), "Euler heading jumped at the near-vertical extraction threshold")
    check(crossingForwardHeadingError < radians(0.25), "Euler heading disagreed with quaternion forward course after threshold")
    check(
        maximumNearVerticalTelemetryError < radians(0.25),
        "Euler heading disagreed with the quaternion-derived near-vertical gauge"
    )
    check(hoverGaugeSamples > 0, "transition did not exercise the <=0.02 hover-heading gauge zone")
    check(blendedGaugeSamples > 0, "transition did not exercise the 0.02...0.075 smooth-gauge zone")
    check(forwardGaugeSamples > 0, "transition did not exercise the >=0.075 forward-heading gauge zone")
    check(maximumHoverGaugeError < radians(0.25), "hover gauge diverged from quaternion body -Y heading")
    check(maximumBlendedGaugeError < radians(0.25), "smooth gauge diverged from the shortest-arc blend")
    check(maximumForwardGaugeError < radians(0.25), "forward gauge diverged from quaternion body -Z course")
    check(captured, "physical swept trajectory missed the 54 m waypoint sphere")
    check(maximumProgressBeforeCapture > 0.30, "waypoint sphere was reached before a committed wing transition")
    check(maximumAirspeedBeforeCapture > 8.0, "waypoint sphere was reached without usable forward airspeed")
    check(remainedFinite, "54 m transition produced non-finite flight state")
    check(maximumAttitudeError < radians(60.0), "Wingtra tumbled away from the transition attitude")
    check(maximumBodyRate < 2.5, "Wingtra developed tumble-rate angular velocity")
    check(minimumForwardY > -0.35, "Wingtra pitched through the horizon into a tumble")
    check(state.vtolTransitionProgress > 0.70, "Wingtra never advanced into cruise transition")
    check(state.forwardAirspeed > 8.0, "Wingtra transition did not build usable airspeed")
    check(minimumAltitude > 82.0, "Wingtra lost excessive altitude during transition")
    check(courseError < radians(18.0), "Wingtra transition departed far from the requested course")
}

if failures.isEmpty {
    print("RESULT: PASS - Wingtra hover and transition feedback remain stable")
    exit(0)
}

print("RESULT: FAIL - \(failures.count) Wingtra flight contract(s) violated")
exit(1)
