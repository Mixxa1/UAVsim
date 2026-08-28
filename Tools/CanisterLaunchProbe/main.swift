import Foundation
import simd

// Headless probe for the canister launch — the mode the operator reported as
// impossible to fly at all.
//
// Two halves, because the failure could be in either:
//
//  1. **Configuration.** Does the launch preview the view model validates against
//     actually accept a canister the operator placed on the map? The Harpy family
//     is the only one in the catalogue whose supported-mode list does not contain
//     `.standard`, which makes it the only one where the mode that arms the
//     launcher and the mode stored in the draft can disagree.
//  2. **Flight.** Does the booster get the airframe out of the tube, does the
//     engine light in the air afterwards, and does the sequence hand over a
//     flying aircraft?
//
// Run: Tools/CanisterLaunchProbe/run.sh

var failures: [String] = []
let repository = LIPODroneModelRepository()
let physics = SimpleDronePhysicsEngine()
let previewBuilder = MissionPreviewBuilder()
let draftBuilder = MissionDraftBuilder()
let dt: Float = 1.0 / 90.0
let verbose = CommandLine.arguments.contains("-v")

var viewport = MapViewportState.empty
viewport.worldHalfExtent = 800.0
viewport.hardWorldBoundsRadius = 800.0
viewport.airframeClass = .fixedWing

/// The view model's own answer to "which launch mode is in force" — a stored mode
/// the airframe does not support is replaced by one it does.
func resolvedLaunchMode(stored: LaunchMode, profile: DroneModelProfile) -> LaunchMode {
    let supported = profile.supportedLaunchModes
    if stored.isRuntimeImplemented, supported.contains(stored) { return stored }
    return supported.first(where: { $0.isRuntimeImplemented }) ?? .standard
}

print("Canister configuration — does the preflight accept a placed canister?")
print(String(repeating: "-", count: 104))
print(String(format: "%-18@ %-10@ %-10@ %7@ %7@ %7@ %7@ %8@",
             "profile" as NSString, "stored" as NSString, "in force" as NSString,
             "angle" as NSString, "bounds" as NSString, "margin" as NSString,
             "zones" as NSString, "verdict" as NSString))

let canisterProfiles = repository.allProfiles.filter {
    $0.fixedWingParameters?.supportedLaunchModes.contains(.canister) == true
}

for profile in canisterProfiles {
    let wing = profile.fixedWingParameters!
    // Exactly what a map tap produces: the object is placed, and the draft's mode
    // follows the object type.
    var draft = MissionDraft.empty
    draft = draftBuilder.upsertLaunchObject(
        at: SIMD2<Float>(0, 0),
        headingDegrees: 0.0,
        type: .launchCanister,
        in: draft,
        viewport: viewport
    )

    // Then the operator leaves the map, and the flight side asks the profile which
    // mode is in force. A default project that was never re-committed still holds
    // `.standard` here — the case that broke.
    for storedMode in [LaunchMode.standard, .canister] {
        var testDraft = draft
        testDraft.selectedLaunchMode = storedMode
        let inForce = resolvedLaunchMode(stored: storedMode, profile: profile)
        var validatedDraft = testDraft
        validatedDraft.selectedLaunchMode = inForce

        let preview = previewBuilder.buildLaunchPreview(
            draft: validatedDraft,
            viewport: viewport,
            fixedWingParameters: wing,
            supportedLaunchModes: profile.supportedLaunchModes
        )
        // The regression this locks: validating the *stored* mode instead of the
        // one in force produced no preview at all on a default project, and the
        // view model reported that as an invalid launch corridor.
        let storedModePreview = previewBuilder.buildLaunchPreview(
            draft: testDraft,
            viewport: viewport,
            fixedWingParameters: wing,
            supportedLaunchModes: profile.supportedLaunchModes
        )
        if storedModePreview == nil, preview?.isValid == true, verbose {
            print("   (validating the stored mode '\(storedMode.rawValue)' would have refused this)")
        }
        let verdict = preview.map { $0.isValid ? "ok" : "invalid" } ?? "no preview"
        print(String(format: "%-18@ %-10@ %-10@ %7@ %7@ %7@ %7@ %8@",
                     profile.displayName as NSString,
                     storedMode.rawValue as NSString,
                     inForce.rawValue as NSString,
                     (preview.map { $0.hasValidLaunchAngle ? "y" : "N" } ?? "-") as NSString,
                     (preview.map { $0.isWithinWorldBounds ? "y" : "N" } ?? "-") as NSString,
                     (preview.map { $0.hasSafeEdgeMargin ? "y" : "N" } ?? "-") as NSString,
                     (preview.map { $0.avoidsNoFlyZones ? "y" : "N" } ?? "-") as NSString,
                     verdict as NSString))
        if preview?.isValid != true {
            failures.append("\(profile.displayName) canister preflight = \(verdict) "
                            + "(stored \(storedMode.rawValue), in force \(inForce.rawValue))")
        }
    }
}

print("\n\nCanister launch — booster out of the tube, engine lit in the air")
print(String(repeating: "-", count: 104))
print(String(format: "%-18@ %9@ %9@ %9@ %9@ %11@ %12@",
             "profile" as NSString, "exit m/s" as NSString, "peak alt" as NSString,
             "engine@s" as NSString, "min alt" as NSString, "end spd" as NSString,
             "outcome" as NSString))

for profile in canisterProfiles {
    let wing = profile.fixedWingParameters!
    let uav = profile.resolvedUAVProfile
    let massModel = VehicleMassModel.baseline(for: profile, uavProfile: uav)
    var fuelState: FuelSystemState? = uav?.powerplant?.fuel.map {
        .full(capacityKg: $0.usableFuelMassKg, reserveFraction: $0.reserveFraction)
    }
    let backend = FuelPropulsionBackend(
        powerplant: uav?.powerplant,
        cruiseSpeedMps: wing.cruiseSpeedMps
    )

    let canister = CanisterLaunchAsset(
        position: SIMD2<Float>(0, 0),
        headingDegrees: 0.0,
        elevationDegrees: 45.0
    )
    let origin = SIMD3<Float>(0, 1.4, 0)
    let controller = FixedWingLaunchController()
    guard controller.begin(
        mode: .canister,
        asset: .canister(canister),
        origin: origin,
        wing: wing,
        nominalLaunchMassKg: profile.takeoffMassKg
    ) else {
        failures.append("\(profile.displayName) refused a canister launch configuration")
        continue
    }

    var state = DroneState(
        position: origin,
        velocity: .zero,
        orientation: SIMD3<Float>(0, 45.0 * .pi / 180.0, MissionLaunchGeometry.worldYawRadians(headingDegrees: canister.headingDegrees)),
        angularVelocity: .zero,
        throttle: 0.0,
        motorThrottle: 0.0,
        rotorAngularSpeed: .zero,
        forwardAirspeed: 0.0,
        physicalState: .takeoffTransition,
        mode: .autoPath
    )
    state.armState = UAVArmState.armed

    var exitSpeed: Float = 0.0
    var peakAltitude: Float = 0.0
    var minAltitudeAfterBoost = Float.greatestFiniteMagnitude
    var engineRunningAt: Float?
    var outcome = "timeout"
    var snapshot = FixedWingLaunchRuntimeSnapshot.idle
    var elapsed: Float = 0.0

    for tick in 0..<(90 * 90) {
        snapshot = controller.update(
            aircraftState: state,
            windVector: .zero,
            isArmed: true,
            batteryAvailable: true,
            engineState: state.engineRuntime,
            deltaTime: dt
        )

        let commandedPitchDeg: Float
        switch snapshot.state {
        case .rotation, .initialClimb, .transitionToFlight, .completed:
            commandedPitchDeg = wing.initialClimbPitchDeg
        default:
            commandedPitchDeg = 45.0
        }
        let control = DroneControlInput(
            targetPosition: origin + MissionLaunchGeometry.direction3D(headingDegrees: canister.headingDegrees, pitchDegrees: 0.0) * 600.0
                + SIMD3<Float>(0, 250, 0),
            targetOrientation: SIMD3<Float>(
                0,
                commandedPitchDeg * .pi / 180.0,
                MissionLaunchGeometry.worldYawRadians(headingDegrees: canister.headingDegrees)
            ),
            yawIntent: 0.0,
            throttle: 1.0,
            isArmed: true,
            mode: .autoPath,
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
            fixedWingLaunchDynamics: snapshot.dynamics,
            fuelState: fuelState,
            engineState: state.engineRuntime,
            fuelPropulsion: backend
        )
        state = physics.step(state: state, control: control, context: context, deltaTime: dt)
        if let fuel = fuelState, let power = state.engineRuntime?.shaftPowerKW {
            fuelState?.remainingKg = max(0.0, fuel.remainingKg - power * 0.00008 * dt)
        }
        elapsed += dt

        if snapshot.dynamics == nil, exitSpeed <= 0.0, state.forwardAirspeed > 0.5 {
            exitSpeed = state.forwardAirspeed
        }
        peakAltitude = max(peakAltitude, state.position.y - origin.y)
        if exitSpeed > 0.0 {
            minAltitudeAfterBoost = min(minAltitudeAfterBoost, state.position.y - origin.y)
        }
        if engineRunningAt == nil, state.engineRuntime?.runState.isFiring == true {
            engineRunningAt = elapsed
        }

        if verbose, tick % 45 == 0 {
            print(String(format: "   t=%5.1f %-20@ spd=%6.1f alt=%7.1f pitch=%6.1f engine=%@",
                         elapsed, snapshot.state.rawValue as NSString,
                         state.forwardAirspeed, state.position.y - origin.y,
                         state.orientation.y * 180.0 / .pi,
                         (state.engineRuntime?.runState.rawValue ?? "-") as NSString))
        }

        if snapshot.state == .completed { outcome = "flying"; break }
        if snapshot.state == .aborted {
            outcome = snapshot.transitionReason ?? "aborted"
            break
        }
        if state.physicalState == DronePhysicalState.crashed { outcome = "crashed"; break }
    }

    print(String(format: "%-18@ %9.1f %9.1f %9@ %9.1f %11.1f %12@",
                 profile.displayName as NSString,
                 exitSpeed,
                 peakAltitude,
                 (engineRunningAt.map { String(format: "%.1f", $0) } ?? "never") as NSString,
                 minAltitudeAfterBoost == .greatestFiniteMagnitude ? 0.0 : minAltitudeAfterBoost,
                 state.forwardAirspeed,
                 outcome as NSString))

    if outcome != "flying" {
        failures.append("\(profile.displayName) canister launch ended as \(outcome)")
    }
    // The booster exists to give the airframe flying speed. Leaving the tube below
    // the stall is a launch that ends in the dirt beside the truck.
    if exitSpeed < wing.minSafeAirspeed * 0.85 {
        failures.append(String(format: "%@ left the tube at %.1f m/s against a minimum safe %.1f",
                               profile.displayName, exitSpeed, wing.minSafeAirspeed))
    }
    // It must light its own engine on the way up; a canister airframe that never
    // starts is a ballistic dart.
    if engineRunningAt == nil {
        failures.append("\(profile.displayName) never lit its engine after the boost")
    }
    // And it must not sink back onto the launcher while it does.
    if minAltitudeAfterBoost < 0.0 {
        failures.append(String(format: "%@ sank %.1f m below the launcher after the boost",
                               profile.displayName, -minAltitudeAfterBoost))
    }
}

print("")
if failures.isEmpty {
    print("RESULT: PASS - a placed canister passes preflight, the booster clears the tube, "
          + "and the engine lights in the air")
} else {
    for failure in failures { print("FAIL: \(failure)") }
    print("\nRESULT: FAIL")
}
