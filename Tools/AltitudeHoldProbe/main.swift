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

print("")
if failures.isEmpty {
    print("PASS: every airframe held its altitude through the orbit.")
} else {
    print("FAIL:")
    for f in failures { print("  " + f) }
}
