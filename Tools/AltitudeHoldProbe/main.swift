import Foundation
import simd

// Headless altitude-hold probe, flown in the orbit trap.
//
// Reproduces the condition the operator's logs died in: a fixed wing chasing a waypoint it cannot
// reach, so it holds a sustained near-limit bank, while the altitude loop tries to keep its height.
// That is where the single-loop altitude hold limit-cycled — commanded and achieved pitch in
// antiphase, vertical speed swinging −9 to +15 m/s on a ~3 s period, until a trough hit the ground.
//
// The assist controller lives in `Simulation/`, so unlike the guidance in the view model it can be
// closed-loop flown here: assist output → control input → physics → state → assist.
//
//   drift    metres between the lowest and highest altitude after settling. This is the number
//            that killed the aircraft: the loop only has to dip far enough once.
//   |vy|max  worst vertical speed. The log's figure was 15 m/s.
//   mean err mean altitude error, which says whether it is holding the right height at all.
//
// Run: Tools/AltitudeHoldProbe/run.sh

let repository = LIPODroneModelRepository()
let engine = SimpleDronePhysicsEngine()
let controller = FixedWingAssistController()
let dt: Float = 1.0 / 90.0
let holdAltitude: Float = 400.0

struct Outcome {
    let drift: Float
    let worstVerticalSpeed: Float
    let meanError: Float
    let survived: Bool
}

func flyOrbit(profile: DroneModelProfile, wing: FixedWingParameters) -> Outcome? {
    let massModel = VehicleMassModel.baseline(for: profile, uavProfile: nil)
    let fuelState: FuelSystemState? = profile.resolvedUAVProfile?.powerplant?.fuel.map {
        .full(capacityKg: $0.usableFuelMassKg, reserveFraction: $0.reserveFraction)
    }
    let backend = FuelPropulsionBackend(
        powerplant: profile.resolvedUAVProfile?.powerplant,
        cruiseSpeedMps: wing.cruiseSpeedMps
    )
    let baseline = FlightBaselineResolver.resolve(
        runtimeProfile: profile,
        activeUAVProfile: profile.resolvedUAVProfile,
        vehicleMassModel: massModel,
        flightMode: .manual
    )

    var state = DroneState(
        position: SIMD3<Float>(0, holdAltitude, 0),
        velocity: SIMD3<Float>(0, 0, -wing.cruiseSpeedMps),
        orientation: .zero,
        angularVelocity: .zero,
        throttle: 0.6,
        motorThrottle: 0.6,
        rotorAngularSpeed: .zero,
        forwardAirspeed: wing.cruiseSpeedMps,
        physicalState: .airborne,
        mode: .manual
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

    // A target set half a turn radius off the nose is inside the aircraft's own turn circle: the
    // orbit trap by construction, which is what puts the aircraft in the sustained bank this probe
    // exists to measure.
    let turnRadius = wing.minimumTurnRadius(airspeed: wing.cruiseSpeedMps)
    let target = SIMD2<Float>(turnRadius * 0.5, -turnRadius * 0.5)

    var assistState = FixedWingAssistState.manual
    assistState = controller.engage(
        .waypointIntercept,
        from: state,
        selectedWaypointID: UUID(),
        currentState: assistState
    )
    assistState.targetAltitudeMeters = holdAltitude
    assistState.autoAdvanceEnabled = false

    var altitudes: [Float] = []
    var verticalSpeeds: [Float] = []
    let totalTicks = Int(90.0 / Double(dt))
    let settleTicks = Int(20.0 / Double(dt))

    for tick in 0..<totalTicks {
        guard let output = controller.update(
            assistState: assistState,
            aircraftState: state,
            wing: wing,
            baseline: baseline,
            currentControls: DroneControlValues(),
            interceptTarget: target,
            captureTarget: target,
            interceptDebugContext: FixedWingAssistInterceptDebugContext(
                activeTargetSource: "probe",
                segmentCountAfterValidation: 1,
                activeRouteIncludesHome: false,
                selectedWaypointID: assistState.selectedWaypointID,
                guidanceTargetType: "probe",
                guidanceTargetPoint: target,
                currentLegStart: SIMD2<Float>(0, 0),
                currentLegEnd: target
            ),
            turnOverrideActive: false,
            altitudeOverrideActive: false,
            heightAboveSurfaceMeters: state.position.y
        ) else { return nil }

        assistState = output.state
        // The assist does not own altitude *target*, only the tracking of it.
        assistState.targetAltitudeMeters = holdAltitude
        assistState.interceptCompleted = false

        let control = DroneControlInput(
            targetPosition: SIMD3<Float>(state.position.x, holdAltitude, state.position.z),
            targetOrientation: SIMD3<Float>(
                output.rollDegrees * .pi / 180.0,
                output.pitchDegrees * .pi / 180.0,
                output.yawDegrees * .pi / 180.0
            ),
            yawIntent: 0.0,
            throttle: output.throttle,
            isArmed: true,
            mode: .manual,
            controlMode: .stabilized
        )
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

        guard state.position.y.isFinite else { return nil }
        if state.position.y <= 1.0 {
            return Outcome(drift: .infinity, worstVerticalSpeed: .infinity, meanError: .infinity, survived: false)
        }
        if tick > settleTicks {
            altitudes.append(state.position.y)
            verticalSpeeds.append(state.velocity.y)
        }
    }

    guard !altitudes.isEmpty else { return nil }
    let drift = (altitudes.max() ?? 0) - (altitudes.min() ?? 0)
    let worst = verticalSpeeds.map(abs).max() ?? 0
    let meanError = altitudes.map { abs($0 - holdAltitude) }.reduce(0, +) / Float(altitudes.count)
    return Outcome(drift: drift, worstVerticalSpeed: worst, meanError: meanError, survived: true)
}

// ---------------------------------------------------------------------------------------------
// Level cruise, no bank.
//
// The orbit case above passes, and `PitchTrackingProbe`'s header records the belief that the
// oscillation "only appears in the turn". An operator log from a 8192 m map disagrees: an MQ-9B
// straight and level at 87 m/s, `rollCmd=0.0 roll=-0.0` for the whole cruise, held `state=headingHold`
// and still oscillated y 19↔27 m with vy ±8 and `pitchCmd` slamming between its clamps, for the
// entire flight. So the turn is not the ingredient — this measures the same loop with the bank
// removed.
//
// The altitude loop commands a pitch *angle* from gains fixed in degrees:
//     pitch = altitudeError × 0.85 − verticalSpeed × 1.6      (deg, clamped −7…+9)
// but a pitch angle buys climb rate in proportion to airspeed: dvy/dθ = V·π/180. So the rate
// feedback's loop gain is 1.6 × V·π/180 — 0.8 at 30 m/s, 2.4 at 87 m/s. The `dvy/dθ` column below
// is that plant sensitivity; `clamp%` says whether the command is spending its time saturated,
// which is what turns a too-high gain into a limit cycle rather than a mere overshoot.
//
//   step     the loop is trimmed level, then the hold altitude is stepped +5 m and given 20 s.
//   drift    peak-to-peak altitude over the 40 s *after* that settling time. A settled loop is ~0.
//   period   seconds per cycle if it is still moving, from mean crossings. Blank if settled.

struct LevelOutcome {
    let drift: Float
    let worstVerticalSpeed: Float
    let meanError: Float
    let periodSeconds: Float?
    let clampedFraction: Float
    let pitchSensitivity: Float
    let survived: Bool
}

func flyLevel(
    profile: DroneModelProfile,
    wing: FixedWingParameters,
    startAltitude: Float
) -> LevelOutcome? {
    let massModel = VehicleMassModel.baseline(for: profile, uavProfile: nil)
    let fuelState: FuelSystemState? = profile.resolvedUAVProfile?.powerplant?.fuel.map {
        .full(capacityKg: $0.usableFuelMassKg, reserveFraction: $0.reserveFraction)
    }
    let backend = FuelPropulsionBackend(
        powerplant: profile.resolvedUAVProfile?.powerplant,
        cruiseSpeedMps: wing.cruiseSpeedMps
    )
    let baseline = FlightBaselineResolver.resolve(
        runtimeProfile: profile,
        activeUAVProfile: profile.resolvedUAVProfile,
        vehicleMassModel: massModel,
        flightMode: .manual
    )

    var state = DroneState(
        position: SIMD3<Float>(0, startAltitude, 0),
        velocity: SIMD3<Float>(0, 0, -wing.cruiseSpeedMps),
        orientation: .zero,
        angularVelocity: .zero,
        throttle: 0.6,
        motorThrottle: 0.6,
        rotorAngularSpeed: .zero,
        forwardAirspeed: wing.cruiseSpeedMps,
        physicalState: .airborne,
        mode: .manual
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

    var assistState = FixedWingAssistState.manual
    assistState = controller.engage(
        .headingHold,
        from: state,
        selectedWaypointID: nil,
        currentState: assistState
    )
    assistState.autoAdvanceEnabled = false

    let trimTicks = Int(15.0 / Double(dt))
    let settleTicks = Int(20.0 / Double(dt))
    let measureTicks = Int(40.0 / Double(dt))
    let totalTicks = trimTicks + settleTicks + measureTicks
    let steppedTarget = startAltitude + 5.0

    var altitudes: [Float] = []
    var verticalSpeeds: [Float] = []
    var clampedSamples = 0
    var measuredSamples = 0

    for tick in 0..<totalTicks {
        let target = tick < trimTicks ? startAltitude : steppedTarget
        assistState.targetAltitudeMeters = target
        guard let output = controller.update(
            assistState: assistState,
            aircraftState: state,
            wing: wing,
            baseline: baseline,
            currentControls: DroneControlValues(),
            interceptTarget: nil,
            captureTarget: nil,
            interceptDebugContext: FixedWingAssistInterceptDebugContext(
                activeTargetSource: "probe",
                segmentCountAfterValidation: 0,
                activeRouteIncludesHome: false,
                selectedWaypointID: nil,
                guidanceTargetType: "none",
                guidanceTargetPoint: nil,
                currentLegStart: nil,
                currentLegEnd: nil
            ),
            turnOverrideActive: false,
            altitudeOverrideActive: false,
            heightAboveSurfaceMeters: state.position.y
        ) else { return nil }

        assistState = output.state
        assistState.targetAltitudeMeters = target

        let control = DroneControlInput(
            targetPosition: SIMD3<Float>(state.position.x, target, state.position.z),
            targetOrientation: SIMD3<Float>(
                output.rollDegrees * .pi / 180.0,
                output.pitchDegrees * .pi / 180.0,
                output.yawDegrees * .pi / 180.0
            ),
            yawIntent: 0.0,
            throttle: output.throttle,
            isArmed: true,
            mode: .manual,
            controlMode: .stabilized
        )
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

        guard state.position.y.isFinite else { return nil }
        if state.position.y <= 1.0 {
            return LevelOutcome(
                drift: .infinity, worstVerticalSpeed: .infinity, meanError: .infinity,
                periodSeconds: nil, clampedFraction: 1.0,
                pitchSensitivity: wing.cruiseSpeedMps * .pi / 180.0, survived: false
            )
        }
        if tick >= trimTicks + settleTicks {
            altitudes.append(state.position.y)
            verticalSpeeds.append(state.velocity.y)
            measuredSamples += 1
            // At roll 0 the coordinated-turn compensation is nil, so the ceiling is the bare
            // `pitchUpClampDeg`. Reading the clamp off the output keeps the probe from restating
            // the controller's private constants.
            if output.pitchDegrees >= 8.99 || output.pitchDegrees <= -6.99 {
                clampedSamples += 1
            }
        }
    }

    guard !altitudes.isEmpty else { return nil }
    let drift = (altitudes.max() ?? 0) - (altitudes.min() ?? 0)
    let worst = verticalSpeeds.map(abs).max() ?? 0
    let meanError = altitudes.map { abs($0 - steppedTarget) }.reduce(0, +) / Float(altitudes.count)

    // Period from crossings of the window mean. Only meaningful if the thing is actually moving;
    // a settled loop crosses on numerical noise and would report a nonsense period.
    var period: Float?
    if drift > 1.0 {
        let mean = altitudes.reduce(0, +) / Float(altitudes.count)
        var crossings = 0
        for pair in zip(altitudes, altitudes.dropFirst())
        where (pair.0 - mean) * (pair.1 - mean) < 0 {
            crossings += 1
        }
        if crossings >= 2 {
            period = 2.0 * 40.0 / Float(crossings)
        }
    }

    return LevelOutcome(
        drift: drift,
        worstVerticalSpeed: worst,
        meanError: meanError,
        periodSeconds: period,
        clampedFraction: measuredSamples > 0
            ? Float(clampedSamples) / Float(measuredSamples)
            : 0.0,
        pitchSensitivity: wing.cruiseSpeedMps * .pi / 180.0,
        survived: true
    )
}

print("Altitude hold in a sustained orbit (the condition the aircraft was crashing in)")
print("")
print(String(
    format: "%-24@ %9@ %10@ %10@",
    "profile" as NSString, "drift" as NSString, "|vy|max" as NSString, "mean err" as NSString
))
print(String(repeating: "-", count: 58))

let wanted = ["mq-9b-skyguardian", "mq-9a-reaper", "Hermes 900", "FT5 Łoś", "senseFly eBee TAC"]
var failures: [String] = []

for profile in repository.allProfiles where profile.airframeClass == .fixedWing {
    guard wanted.contains(profile.id) || wanted.contains(profile.displayName),
          let wing = profile.fixedWingParameters else { continue }
    guard let outcome = flyOrbit(profile: profile, wing: wing) else {
        print(String(format: "%-24@   (no result)", profile.displayName as NSString))
        continue
    }
    if !outcome.survived {
        failures.append(profile.displayName + " — flew into the ground")
        print(String(format: "%-24@   FLEW INTO THE GROUND", profile.displayName as NSString))
        continue
    }
    if outcome.drift > 40.0 {
        failures.append(String(format: "%@ — %.0f m of drift", profile.displayName, outcome.drift))
    }
    print(String(
        format: "%-24@ %8.1fm %9.1f %9.1fm",
        profile.displayName as NSString,
        outcome.drift, outcome.worstVerticalSpeed, outcome.meanError
    ))
}

for altitude in [Float(25.0), Float(400.0)] {
    print("")
    print(String(format: "Level cruise, no bank, +5 m step at %.0f m", altitude))
    print("")
    print(String(
        format: "%-24@ %8@ %9@ %9@ %8@ %7@ %9@",
        "profile" as NSString, "drift" as NSString, "|vy|max" as NSString,
        "mean err" as NSString, "period" as NSString, "clamp%" as NSString,
        "dvy/dθ" as NSString
    ))
    print(String(repeating: "-", count: 82))

    for profile in repository.allProfiles where profile.airframeClass == .fixedWing {
        guard wanted.contains(profile.id) || wanted.contains(profile.displayName),
              let wing = profile.fixedWingParameters else { continue }
        guard let outcome = flyLevel(profile: profile, wing: wing, startAltitude: altitude) else {
            print(String(format: "%-24@   (no result)", profile.displayName as NSString))
            continue
        }
        if !outcome.survived {
            failures.append(String(
                format: "%@ — flew into the ground in level cruise at %.0f m",
                profile.displayName, altitude
            ))
            print(String(format: "%-24@   FLEW INTO THE GROUND", profile.displayName as NSString))
            continue
        }
        // A hold that keeps moving after 20 s of settling is not holding. One metre is the
        // resolution the operator's own log distinguishes, and a settled loop measures ~0.
        if outcome.drift > 1.0 {
            failures.append(String(
                format: "%@ — %.1f m peak-to-peak in level cruise at %.0f m",
                profile.displayName, outcome.drift, altitude
            ))
        }
        print(String(
            format: "%-24@ %7.1fm %8.1f %8.1fm %7@ %6.0f%% %8.2f",
            profile.displayName as NSString,
            outcome.drift, outcome.worstVerticalSpeed, outcome.meanError,
            (outcome.periodSeconds.map { String(format: "%.1fs", $0) } ?? "—") as NSString,
            outcome.clampedFraction * 100.0,
            outcome.pitchSensitivity
        ))
    }
}

print("")
if failures.isEmpty {
    print("PASS: every airframe held its altitude, in the orbit and in level cruise.")
} else {
    print("FAIL:")
    for f in failures { print("  " + f) }
}
