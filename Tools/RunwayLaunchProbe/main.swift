import Foundation
import simd

// Headless probe for the runway takeoff — the launch mode that, until now, was
// declared on five aircraft and implemented for none of them.
//
// It answers the three questions a runway launch actually turns on:
//
//  1. Does the aircraft reach its own rotation speed, and inside the strip its
//     own catalogue claims it needs?
//  2. Does it stay on the runway while it does — wings level, tracking its
//     heading, not tipping onto a wingtip? This is the failure the user flew: a
//     four-tonne MQ-9A that rolled to 70 degrees during its ground roll, shed its
//     gear and both wings, and crashed without ever leaving the ground.
//  3. Does the sequence hand a flying aircraft over, rather than timing out?
//
// Run: Tools/RunwayLaunchProbe/run.sh

var failures: [String] = []
let repository = LIPODroneModelRepository()
let physics = SimpleDronePhysicsEngine()
let dt: Float = 1.0 / 90.0
let verbose = CommandLine.arguments.contains("-v")

print("Runway takeoff — brakes off to handover, full power")
print(String(repeating: "-", count: 110))
print(String(format: "%-22@ %8@ %9@ %9@ %9@ %9@ %9@ %10@",
             "profile" as NSString, "Vr m/s" as NSString, "decl m" as NSString,
             "roll m" as NSString, "unstick" as NSString, "|roll|deg" as NSString,
             "alt m" as NSString, "outcome" as NSString))

for profile in repository.allProfiles where profile.airframeClass == .fixedWing {
    guard let wing = profile.fixedWingParameters,
          wing.supportedLaunchModes.contains(.runway) else { continue }

    let uav = profile.resolvedUAVProfile
    let massModel = VehicleMassModel.baseline(for: profile, uavProfile: uav)
    var fuelState: FuelSystemState? = uav?.powerplant?.fuel.map {
        .full(capacityKg: $0.usableFuelMassKg, reserveFraction: $0.reserveFraction)
    }
    let backend = FuelPropulsionBackend(
        powerplant: uav?.powerplant,
        cruiseSpeedMps: wing.cruiseSpeedMps
    )

    // The same graph mass and contact profile the app always runs with. Leaving
    // them out is what let a centre-of-mass regression pass this harness while
    // standing the whole fuel fleet on its tail in the app.
    let dryMass = max(0.2, massModel.resolvedCurrentTotalMass)
    let span = (uav?.dimensions.wingspanMillimeters ?? 2000.0) / 1000.0
    let length = (uav?.dimensions.fuselageLengthMillimeters ?? span * 550.0) / 1000.0
    let massProperties = VehicleMassProperties(
        totalMassKg: dryMass,
        centerOfMassOffset: SIMD3<Float>(0.0, -0.02, 0.05),
        inertiaDiagonal: SIMD3<Float>(
            dryMass * span * span / 12.0,
            dryMass * length * length / 12.0,
            dryMass * (span * span + length * length) / 12.0
        )
    )
    let contactProfile = VehicleContactProfile(
        spheres: [
            VehicleContactSphere(componentID: "gear.main", offset: SIMD3<Float>(0, -0.25, 0), radius: 0.25),
            VehicleContactSphere(componentID: "tail", offset: SIMD3<Float>(0, -0.15, -0.6), radius: 0.15)
        ],
        boundingRadius: max(0.5, span * 0.5)
    )

    let origin = SIMD3<Float>(0, 0, 0)
    let runway = RunwayLaunchAsset(
        id: UUID(),
        position: SIMD2<Float>(0, 0),
        headingDegrees: 0.0,
        groundAttitudeDegrees: 3.0,
        // Exactly the strip the app builds, so an abort here means the same
        // thing it would mean in flight.
        usableLengthMeters: FixedWingRunwayGeometry.stripLength(for: wing)
    )

    let controller = FixedWingLaunchController()
    guard controller.begin(
        mode: .runway,
        asset: .runway(runway),
        origin: origin,
        wing: wing,
        nominalLaunchMassKg: profile.takeoffMassKg
    ) else {
        failures.append("\(profile.displayName) refused a runway launch configuration")
        continue
    }

    var state = DroneState(
        position: origin,
        velocity: .zero,
        orientation: SIMD3<Float>(0, 3.0 * .pi / 180.0, runway.worldYawRadians),
        angularVelocity: .zero,
        throttle: 0.0,
        motorThrottle: 0.0,
        rotorAngularSpeed: .zero,
        forwardAirspeed: 0.0,
        physicalState: .takeoffTransition,
        mode: .autoPath
    )
    state.armState = .armed

    var brakeReleaseDistance: Float?
    var rotationDistance: Float?
    var unstickDistance: Float?
    var worstRoll: Float = 0.0
    var outcome = "timeout"
    var snapshot = FixedWingLaunchRuntimeSnapshot.idle
    var ticks = 0

    for _ in 0..<(90 * 240) {
        snapshot = controller.update(
            aircraftState: state,
            windVector: .zero,
            isArmed: true,
            batteryAvailable: true,
            engineState: state.engineRuntime,
            deltaTime: dt
        )

        let travelled = simd_dot(state.position - origin, runway.direction3D)
        if snapshot.state == .assistedAcceleration, brakeReleaseDistance == nil {
            brakeReleaseDistance = travelled
        }
        if snapshot.state == .rotation, rotationDistance == nil {
            rotationDistance = travelled
        }
        if state.position.y > 0.6, unstickDistance == nil {
            unstickDistance = travelled
        }

        // The pitch the view model commands in each state, reduced to its essentials:
        // hold the ground attitude on the roll, then the profile's own initial-climb
        // attitude from rotation onward.
        let commandedPitchDeg: Float
        switch snapshot.state {
        case .rotation, .initialClimb, .transitionToFlight, .completed:
            commandedPitchDeg = wing.initialClimbPitchDeg
        default:
            commandedPitchDeg = 3.0
        }

        let control = DroneControlInput(
            // Ahead along the runway, not along -Z. A tactical heading of 0 points
            // at +Z, so a target written in raw axes turned every aircraft round
            // and flew the takeoff backwards down its own strip.
            targetPosition: origin + runway.direction3D * 600.0 + SIMD3<Float>(0, 200, 0),
            // The commanded heading lives in `targetOrientation.z` and reaches the
            // rudder directly. Leaving it at zero while the runway heading is 180°
            // commanded a half-turn: the MQ-9A rolled sixty metres, swung round on
            // its own tyres and taxied back down its own strip.
            targetOrientation: SIMD3<Float>(
                0,
                commandedPitchDeg * .pi / 180.0,
                runway.worldYawRadians
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
            vehicleMassProperties: massProperties,
            contactProfile: contactProfile,
            fuelState: fuelState,
            engineState: state.engineRuntime,
            fuelPropulsion: backend
        )
        state = physics.step(state: state, control: control, context: context, deltaTime: dt)

        if let fuel = fuelState, let flow = state.engineRuntime?.shaftPowerKW {
            fuelState?.remainingKg = max(0.0, fuel.remainingKg - flow * 0.00008 * dt)
        }
        if state.position.y < 3.0 {
            worstRoll = max(worstRoll, abs(state.orientation.x) * 180.0 / .pi)
        }

        if verbose, ticks % 90 == 0 {
            print(String(format: "   t=%5.1f  %-22@ d=%7.1f  Vlong=%6.1f  prog=%.3f  y=%6.1f  pitch=%5.1f",
                         Float(ticks) * dt, snapshot.state.rawValue as NSString, travelled,
                         snapshot.longitudinalAirspeedMps, snapshot.railProgress,
                         state.position.y, state.orientation.y * 180.0 / .pi))
        }
        ticks += 1

        if snapshot.state == .completed { outcome = "flying"; break }
        if snapshot.state == .aborted {
            outcome = snapshot.transitionReason ?? "aborted"
            break
        }
    }

    let rollDistance = (rotationDistance ?? -1.0) - (brakeReleaseDistance ?? 0.0)
    print(String(format: "%-22@ %8.0f %9.0f %9.0f %9.0f %9.1f %9.0f %10@",
                 profile.displayName as NSString,
                 wing.takeoffRotationSpeed,
                 wing.runwayTakeoffDistance,
                 rollDistance,
                 (unstickDistance ?? -1.0) - (brakeReleaseDistance ?? 0.0),
                 worstRoll,
                 state.position.y,
                 outcome as NSString))

    if outcome != "flying" {
        failures.append("\(profile.displayName) runway launch ended as \(outcome)")
    }
    // The failure the user flew. A ground roll is a straight line on two wheels;
    // anything past a few degrees of bank means a wingtip is about to touch.
    if worstRoll > 8.0 {
        failures.append(String(format: "%@ rolled to %.0f deg during its takeoff roll",
                               profile.displayName, worstRoll))
    }
    // The declared roll distance is what the preflight corridor check reserves, so
    // a model that needs materially more than the catalogue claims would let an
    // aircraft be cleared into ground it cannot clear. Half again is the tolerance:
    // published takeoff distances are quoted at conditions no simulation reproduces
    // exactly, and demanding an exact match would be demanding a fitted number.
    if rollDistance > wing.runwayTakeoffDistance * 1.5 {
        failures.append(String(format: "%@ needed %.0f m to reach Vr against a declared %.0f m",
                               profile.displayName, rollDistance, wing.runwayTakeoffDistance))
    }
}

print("")
if failures.isEmpty {
    print("RESULT: PASS - every runway aircraft reaches rotation speed on its own strip, "
          + "tracks straight, and is handed over flying")
} else {
    for failure in failures { print("FAIL: \(failure)") }
    print("\nRESULT: FAIL")
}
