import Foundation
import simd

// Headless steady-cruise speed probe.
//
// Recorded flights showed hybrid VTOLs cruising far above their published speed — a Quantum
// Trinity with a 17 m/s cruise measured at 44.4 m/s, a Wingcopter 198 with a 22 m/s cruise at
// 40.1 m/s. Turn radius goes as the square of speed, so every geometric margin the autopilot
// derives from the profile's cruise figure (turn radius, cruise entry/exit distance, waypoint
// capture radius) was wrong by 4-7x in radius, and the aircraft flew into buildings it had
// "planned" to turn around.
//
// This probe removes the autopilot from the question. It holds the transition lever at cruise and
// a *fixed* throttle, flies the production physics, and reports the speed the airframe settles at.
// Fixed wings run the same test as a control: they share the aero model and the drag term with the
// VTOLs and differ only in how thrust is sized, so if they settle on speed and the VTOLs do not,
// the thrust map is the difference.
//
// Run: Tools/VTOLCruiseSpeedProbe/run.sh

private let dt: Float = 1.0 / 60.0
private var failures: [String] = []

private func check(_ condition: Bool, _ message: String) {
    if !condition { failures.append(message) }
}

private struct CruiseResult {
    var settledSpeed: Float
    var peakSpeed: Float
    var settledAltitude: Float
    var settledSinkRate: Float
    var settledPitchDegrees: Float
    var wingborneBlend: Float
    var transitionProgress: Float
}

private func flyLevelCruise(
    profile: DroneModelProfile,
    throttle: Float,
    seconds: Float,
    targetAltitudeDrop: Float = 0.0
) -> CruiseResult {
    let massModel = VehicleMassModel.baseline(for: profile, uavProfile: nil)
    let baseline = FlightBaselineResolver.resolve(
        runtimeProfile: profile,
        activeUAVProfile: nil,
        vehicleMassModel: massModel,
        flightMode: .autoPath
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
    let wing = profile.fixedWingParameters!
    let startAltitude: Float = 400.0
    let entrySpeed = max(wing.cruiseSpeedMps, wing.minSustainableSpeedMps)

    // Level, already wing-borne, already at the published cruise speed. The question is only
    // whether the airframe *stays* there — a model whose cruise throttle balances cruise drag
    // holds this trim, one whose thrust is sized off parasite drag alone runs away from it.
    var state = DroneState(
        position: SIMD3<Float>(0, startAltitude, 0),
        velocity: SIMD3<Float>(0, 0, -entrySpeed),
        orientation: .zero,
        angularVelocity: .zero,
        throttle: throttle,
        motorThrottle: throttle,
        rotorAngularSpeed: .zero,
        forwardAirspeed: entrySpeed,
        physicalState: .airborne,
        mode: .autoPath
    )
    state.armState = .armed
    state.motionState = .airborne
    state.fixedWingOrientationQuat = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    state.bodyAngularVelocity = .zero
    state.propulsionUnits = profile.propulsionUnitTemplate.map { unit in
        var tilted = unit
        // Start fully transitioned: this probe is about the cruise trim, not the transition.
        if unit.role == .tiltRotor {
            tilted.tiltAngleRad = .pi / 2
            tilted.targetTiltAngleRad = .pi / 2
        }
        return tilted
    }
    state.vtolTransitionProgress = profile.airframeClass == .hybridVTOL ? 1.0 : 0.0
    state.vtolWingborneBlend = profile.airframeClass == .hybridVTOL ? 1.0 : 0.0

    let engine = SimpleDronePhysicsEngine()
    let ticks = Int(seconds / dt)
    var peakSpeed: Float = 0.0
    for _ in 0..<ticks {
        // Aim far ahead, at the entry altitude or below it, and never touch the throttle: it is
        // the independent variable of this experiment.
        let control = DroneControlInput(
            targetPosition: SIMD3<Float>(
                state.position.x,
                startAltitude - targetAltitudeDrop,
                state.position.z - 5000.0
            ),
            targetOrientation: .zero,
            yawIntent: 0.0,
            throttle: throttle,
            isArmed: true,
            mode: .autoPath,
            controlMode: .hoverAssist,
            vtolTransitionLever: profile.airframeClass == .hybridVTOL ? 1.0 : 0.0
        )
        state = engine.step(state: state, control: control, context: context, deltaTime: dt)
        peakSpeed = max(peakSpeed, max(state.forwardAirspeed, simd_length(state.velocity)))
    }

    return CruiseResult(
        settledSpeed: max(state.forwardAirspeed, simd_length(state.velocity)),
        peakSpeed: peakSpeed,
        settledAltitude: state.position.y,
        settledSinkRate: -state.velocity.y,
        settledPitchDegrees: state.orientation.y * 180.0 / .pi,
        wingborneBlend: state.vtolWingborneBlend,
        transitionProgress: state.vtolTransitionProgress
    )
}

private let repository = LIPODroneModelRepository()
private let winged = repository.allProfiles.filter {
    ($0.airframeClass == .hybridVTOL || $0.airframeClass == .fixedWing)
        && $0.fixedWingParameters != nil
}
guard !winged.isEmpty else {
    print("RESULT: FAIL - no winged profiles in the repository")
    exit(1)
}

// What this probe can and cannot assert.
//
// Open-loop trim speed is *not* cruise speed and cannot be made to equal it. There is no airspeed
// hold in the loop here (there is none in the VTOL guidance either — `targetAirspeed` is computed
// and never read), and the airframe is free to trade a little height for speed. At these lift-to-
// drag ratios that trade is not small: a Quantum Trinity settling with a 0.9 m/s sink at 25 m/s is
// descending about 2 deg, and the along-path component of its own weight is then roughly the same
// size as the engine's thrust. So a correctly sized thrust map still trims well above the book
// cruise figure in open loop, and demanding otherwise would be demanding the wrong thing.
//
// What the probe *is* good for is catching a runaway: a thrust map that lets an airframe reach
// twice its published cruise on cruise-reference throttle has lost its anchor, and turn radius —
// which every route margin is derived from — is then off by four. That is the line drawn here.
// Judgement, stated plainly rather than dressed up as a measurement.
private let tolerance: Float = 1.0

// A commanded descent is the condition the recorded flights were actually in when they overspeed:
// the route altitude drops between legs and the aircraft noses over to meet it. Nothing in the
// VTOL guidance limits airspeed or sink rate while it does — `VTOLAutopilotDecision.targetAirspeed`
// and `.maxSinkRate` are both computed and then never read by the consumer — so the only thing
// that stops the aircraft is drag.
private let descentDrop: Float = 60.0

// Where the drag bucket sits relative to the published cruise speed, and whether the throttle floor
// leaves the speed loop anywhere to go.
//
// Level-flight drag is D(v) = q·S·cd0 + k·W²/(q·S): parasite rising with v², induced falling. If
// the published cruise speed sits *below* the minimum of that curve, thrust anchored on D(cruise)
// has two equilibria and only the fast one is stable — nudge the speed up and drag drops, so the
// aircraft runs away to the far root. No thrust *sizing* can pin cruise there; only a speed loop
// with authority to pull power below the cruise reference can.
print("airframe                          cruise  vMinDrag  D_trim(N)  D_alpha0(N)  ratio  refThr  floor")
for profile in winged.sorted(by: { $0.displayName < $1.displayName }) {
    let wing = profile.fixedWingParameters!
    let massModel = VehicleMassModel.baseline(for: profile, uavProfile: nil)
    let baseline = FlightBaselineResolver.resolve(
        runtimeProfile: profile,
        activeUAVProfile: nil,
        vehicleMassModel: massModel,
        flightMode: .autoPath
    )
    let span = profile.dimensionsUnfoldedMm.x / 1000.0
    let aero = FixedWingAerodynamics.build(
        family: wing.family,
        massKg: massModel.effectiveMass,
        wingSpanM: span,
        fuselageLengthM: span * 0.55,
        heightM: span * 0.12,
        turnAuthority: wing.turnAuthority,
        minSustainableSpeedMps: wing.minSustainableSpeedMps
    )
    let weight = massModel.effectiveMass * 9.81
    func levelDrag(_ v: Float) -> Float {
        let q = 0.5 * 1.225 * v * v
        guard q * aero.wingArea > 0.0001 else { return .infinity }
        // Solve the trim alpha the same way the engine does, then read its drag.
        var low: Float = 0.0
        var high: Float = 12.0 * .pi / 180.0
        for _ in 0..<12 {
            let mid = (low + high) * 0.5
            if q * aero.wingArea * aero.liftDrag(alphaRad: mid).cl < weight { low = mid } else { high = mid }
        }
        return q * aero.wingArea * aero.liftDrag(alphaRad: (low + high) * 0.5).cd
    }
    var minDragSpeed: Float = wing.minSustainableSpeedMps
    var minDrag = Float.infinity
    var v = max(3.0, wing.minSustainableSpeedMps * 0.5)
    while v <= 140.0 {
        let d = levelDrag(v)
        if d < minDrag { minDrag = d; minDragSpeed = v }
        v += 0.25
    }
    // What the VTOL steppers used to size thrust with: drag at alpha 0, parasite only. The ratio
    // is how much thrust the cruise-reference throttle was short of level flight at cruise.
    let cruise = max(wing.cruiseSpeedMps, wing.minSustainableSpeedMps)
    let qCruise = 0.5 * 1.225 * cruise * cruise
    let parasiteAtCruise = qCruise * aero.wingArea * aero.liftDrag(alphaRad: 0.0).cd
    print(String(
        format: "%-33@ %6.1f  %8.1f  %9.1f  %11.1f  %5.2f  %6.2f  %5.2f",
        profile.displayName as NSString,
        Double(wing.cruiseSpeedMps),
        Double(minDragSpeed),
        Double(levelDrag(cruise)),
        Double(parasiteAtCruise),
        Double(levelDrag(cruise) / max(0.0001, parasiteAtCruise)),
        Double(baseline.cruiseReferenceThrottle),
        Double(max(baseline.cruiseReferenceThrottle, baseline.effectiveMinimumSafeFlightThrottle))
    ))
}
print("")

print("airframe                          class      cruise  level  descend  peak   idle   sink  pitch   prog    wb  ratio")
var overspeedingLevel: [String] = []
var overspeedingDescent: [String] = []
var cannotDecelerate: [String] = []
// An airframe that cannot hold flying speed at all has no cruise trim to measure, and including it
// in the assertions below made this probe flaky rather than informative — its settled speed wanders
// run to run because it is falling, not flying. `ClimbProbe` already reports these by name
// ("CANNOT SUSTAIN FLIGHT at full power"); they are the scene-scale dimension-override aircraft
// flagged at SimpleDronePhysicsEngine.swift:583. Reported here, asserted on there.
var cannotSustainFlight: [String] = []

for profile in winged.sorted(by: { $0.displayName < $1.displayName }) {
    let wing = profile.fixedWingParameters!
    let massModel = VehicleMassModel.baseline(for: profile, uavProfile: nil)
    let baseline = FlightBaselineResolver.resolve(
        runtimeProfile: profile,
        activeUAVProfile: nil,
        vehicleMassModel: massModel,
        flightMode: .autoPath
    )
    let referenceThrottle = max(0.2, baseline.cruiseReferenceThrottle)
    let level = flyLevelCruise(profile: profile, throttle: referenceThrottle, seconds: 90.0)
    // Can it slow down at all? Wing-borne, at cruise, throttle commanded to idle. While the
    // wing-borne throttle floor sat at `cruiseReferenceThrottle` the physics step clamped this
    // straight back up to cruise power, so the answer was no — which is why no speed loop and no
    // stop-at-waypoint braking could work no matter what they commanded.
    let idled = flyLevelCruise(profile: profile, throttle: 0.0, seconds: 30.0)
    let descending = flyLevelCruise(
        profile: profile,
        throttle: referenceThrottle,
        seconds: 90.0,
        targetAltitudeDrop: descentDrop
    )
    let levelRatio = level.settledSpeed / max(0.1, wing.cruiseSpeedMps)
    let descentRatio = descending.peakSpeed / max(0.1, wing.cruiseSpeedMps)

    print(String(
        format: "%-33@ %-9@ %6.1f %6.1f  %6.1f  %6.1f %6.1f %5.1f %6.1f  %5.2f %5.2f  %5.2fx",
        profile.displayName as NSString,
        (profile.airframeClass == .hybridVTOL ? "VTOL" : "fixedwing") as NSString,
        Double(wing.cruiseSpeedMps),
        Double(level.settledSpeed),
        Double(descending.settledSpeed),
        Double(descending.peakSpeed),
        Double(idled.settledSpeed),
        Double(descending.settledSinkRate),
        Double(descending.settledPitchDegrees),
        Double(level.transitionProgress),
        Double(level.wingborneBlend),
        Double(descentRatio)
    ))

    guard level.settledSpeed.isFinite, descending.peakSpeed.isFinite else {
        failures.append("\(profile.displayName): non-finite settled speed")
        continue
    }
    guard level.settledSpeed >= wing.minSustainableSpeedMps else {
        cannotSustainFlight.append(profile.displayName)
        continue
    }
    if levelRatio > 1.0 + tolerance {
        overspeedingLevel.append(profile.displayName)
    }
    if descentRatio > 1.0 + tolerance {
        overspeedingDescent.append(profile.displayName)
    }
    // Idle from cruise must actually decelerate. A wing-borne airframe that cannot shed speed with
    // the throttle closed has a floor where a limit should be.
    if idled.settledSpeed >= level.settledSpeed - 0.5 {
        cannotDecelerate.append(profile.displayName)
    }
}

print("")
print("above 2x published cruise, level:   \(overspeedingLevel.isEmpty ? "none" : overspeedingLevel.joined(separator: ", "))")
print("above 2x published cruise, descent: \(overspeedingDescent.isEmpty ? "none" : overspeedingDescent.joined(separator: ", "))")

check(
    overspeedingLevel.isEmpty,
    "\(overspeedingLevel.count) airframe(s) exceed twice their published cruise speed in level open-loop trim"
)
print("cannot decelerate at idle:          \(cannotDecelerate.isEmpty ? "none" : cannotDecelerate.joined(separator: ", "))")
print("cannot sustain flight (not asserted, see ClimbProbe): \(cannotSustainFlight.isEmpty ? "none" : cannotSustainFlight.joined(separator: ", "))")
check(
    cannotDecelerate.isEmpty,
    "\(cannotDecelerate.count) airframe(s) cannot shed speed with the throttle closed"
)
check(
    overspeedingDescent.isEmpty,
    "\(overspeedingDescent.count) airframe(s) exceed twice their published cruise speed in a commanded descent"
)

if failures.isEmpty {
    print("RESULT: PASS - no winged airframe runs away from its published cruise speed")
} else {
    for failure in failures {
        print("  - \(failure)")
    }
    print("RESULT: FAIL - cruise thrust has lost its anchor")
    exit(1)
}
