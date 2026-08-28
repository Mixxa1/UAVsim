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

// MARK: - Disturbed ground roll
//
// The run above starts wings level in still air and asks whether a bank appears
// out of nothing. It never asked the opposite question — whether a bank that
// already exists goes away — and that is the one the operator's aircraft failed:
// a heavy airframe that got a wing down at speed stayed down and slid along on
// the wingtip. The gap was in `wheelLoad`, which measured how much lift the wing
// was *making* rather than how much of it pointed up, so a banked aircraft
// reported an unloaded undercarriage exactly when it was leaning on one wheel.

print("\n\nDisturbed ground roll — does a wing that goes down come back up?")
print(String(repeating: "-", count: 88))
print(String(format: "%-24@ %9@ %9@ %9@ %9@ %9@",
             "profile" as NSString, "speed" as NSString, "bank in" as NSString,
             "after 2s" as NSString, "after 6s" as NSString, "y m" as NSString))

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
    let dryMass = max(0.2, massModel.resolvedCurrentTotalMass)
    let span = (uav?.dimensions.wingspanMillimeters ?? 2000.0) / 1000.0
    let length = (uav?.dimensions.fuselageLengthMillimeters ?? span * 550.0) / 1000.0
    // Contact spheres out at the wingtips, at the visual's own scale — the shape
    // that lets a banked airframe rest on a tip instead of on its gear.
    let sceneSpan = Float(profile.dimensionsUnfoldedMm.x) / 1000.0
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
            VehicleContactSphere(componentID: "wing.left", offset: SIMD3<Float>(-sceneSpan * 0.5, 0, 0), radius: 0.06),
            VehicleContactSphere(componentID: "wing.right", offset: SIMD3<Float>(sceneSpan * 0.5, 0, 0), radius: 0.06)
        ],
        boundingRadius: max(0.5, sceneSpan * 0.5)
    )

    // Fast enough that the wing is carrying most of the weight, which is exactly
    // where the aircraft were when they went over.
    let rollSpeed = wing.minSustainableSpeedMps * 1.35
    let bankIn: Float = 18.0
    var state = DroneState(
        position: .zero,
        velocity: SIMD3<Float>(0, 0, -rollSpeed),
        orientation: SIMD3<Float>(bankIn * .pi / 180.0, 0, 0),
        angularVelocity: .zero,
        throttle: 1.0,
        motorThrottle: 1.0,
        rotorAngularSpeed: .zero,
        forwardAirspeed: rollSpeed,
        physicalState: .takeoffTransition,
        mode: .manual
    )
    state.armState = UAVArmState.armed
    if let backend {
        var warm = EngineRuntimeState.cold(ambientTemperatureC: 15.0)
        warm.runState = .ready
        warm.shaftRPM = (backend.powerplant.ratedShaftRPM ?? 6000.0) * 0.95
        warm.temperatureC = EngineOperatingEnvelope
            .envelope(for: backend.powerplant.engineType).operatingTemperatureC
        state.engineRuntime = warm
    }

    var bankAtTwo: Float = 0.0
    for tick in 0..<(90 * 6) {
        let control = DroneControlInput(
            targetPosition: SIMD3<Float>(0, 0, -600),
            targetOrientation: .zero,
            yawIntent: 0.0,
            throttle: 1.0,
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
            vehicleMassProperties: massProperties,
            contactProfile: contactProfile,
            fuelState: fuelState,
            engineState: state.engineRuntime,
            fuelPropulsion: backend
        )
        state = physics.step(state: state, control: control, context: context, deltaTime: dt)
        if tick == 90 * 2 { bankAtTwo = state.orientation.x * 180.0 / .pi }
    }
    let bankOut = state.orientation.x * 180.0 / .pi
    print(String(format: "%-24@ %9.1f %9.1f %9.1f %9.1f %9.2f",
                 profile.displayName as NSString, rollSpeed, bankIn,
                 bankAtTwo, bankOut, state.position.y))

    if abs(bankOut) > bankIn * 0.5 {
        failures.append(String(format: "%@ held %.0f deg of bank on the ground after six seconds",
                               profile.displayName, abs(bankOut)))
    }
}

// MARK: - Scene-scale mass properties
//
// ⚠️ The blind spot that let a fifty-fold inertia error reach a flight test.
//
// Every section above builds `inertiaDiagonal` from the catalogue's real wingspan,
// so the harness has always fed the solver a physically correct tensor. The app
// does not: it feeds the tensor measured on the component graph, which is measured
// on the *visual*, and for the aircraft carrying a `runtimeSceneDimensionsOverride`
// the visual is a three-metre stand-in for a twenty-four-metre aeroplane. Inertia
// goes with the square of length, so those three airframes were being flown with
// about one fiftieth of their real roll inertia while their aerodynamic moments
// came from the real wing — and they departed in roll from nothing at all.
//
// This section therefore feeds the scene-scale tensor deliberately, exactly as the
// app does, and requires the aircraft to fly straight anyway.

print("\n\nScene-scale mass properties — does the solver still fly the real airframe?")
print(String(repeating: "-", count: 96))
print(String(format: "%-24@ %10@ %10@ %11@ %10@",
             "profile" as NSString, "visual m" as NSString, "real m" as NSString,
             "raw ratio" as NSString, "overshoot" as NSString))

for profile in repository.allProfiles where profile.airframeClass == .fixedWing {
    guard let wing = profile.fixedWingParameters,
          let uav = profile.resolvedUAVProfile,
          let realSpanMm = uav.dimensions.wingspanMillimeters else { continue }
    let visualSpanMm = profile.dimensionsUnfoldedMm.x
    let spanRatio = realSpanMm / max(1.0, visualSpanMm)

    let massModel = VehicleMassModel.baseline(for: profile, uavProfile: uav)
    let fuelState: FuelSystemState? = uav.powerplant?.fuel.map {
        .full(capacityKg: $0.usableFuelMassKg, reserveFraction: $0.reserveFraction)
    }
    let backend = FuelPropulsionBackend(
        powerplant: uav.powerplant,
        cruiseSpeedMps: wing.cruiseSpeedMps
    )
    let dryMass = max(0.2, massModel.resolvedCurrentTotalMass)
    // Measured on the visual, as the component graph measures it.
    let visualSpan = visualSpanMm / 1000.0
    let visualLength = profile.dimensionsUnfoldedMm.y / 1000.0
    let massProperties = VehicleMassProperties(
        totalMassKg: dryMass,
        centerOfMassOffset: SIMD3<Float>(0.0, -0.02, 0.05),
        inertiaDiagonal: SIMD3<Float>(
            dryMass * visualSpan * visualSpan / 12.0,
            dryMass * visualLength * visualLength / 12.0,
            dryMass * (visualSpan * visualSpan + visualLength * visualLength) / 12.0
        )
    )
    let contactProfile = VehicleContactProfile(
        spheres: [
            VehicleContactSphere(componentID: "gear.main", offset: SIMD3<Float>(0, -0.25, 0), radius: 0.25)
        ],
        boundingRadius: max(0.5, visualSpan * 0.5)
    )

    // A roll step, not straight-and-level. Holding wings level exposes nothing —
    // the attitude loop is strong enough to do that on any inertia at all, which is
    // why a fifty-fold error sat there unseen. What the error changes is how the
    // airframe *responds*: the same aileron on a fiftieth of the inertia is fifty
    // times the angular acceleration, and the rate-damping term is sized for the
    // real number. So command a bank and measure the overshoot past it.
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
    state.armState = UAVArmState.armed
    if let backend {
        var warm = EngineRuntimeState.cold(ambientTemperatureC: 15.0)
        warm.runState = .ready
        warm.shaftRPM = (backend.powerplant.ratedShaftRPM ?? 6000.0) * 0.95
        warm.temperatureC = EngineOperatingEnvelope
            .envelope(for: backend.powerplant.engineType).operatingTemperatureC
        state.engineRuntime = warm
    }

    let commandedBank: Float = 20.0
    var worstRoll: Float = 0.0
    for _ in 0..<(90 * 25) {
        let control = DroneControlInput(
            targetPosition: SIMD3<Float>(0, 800, -4000),
            targetOrientation: SIMD3<Float>(
                commandedBank * .pi / 180.0,
                wing.initialClimbPitchDeg * .pi / 180.0,
                0
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
            vehicleMassProperties: massProperties,
            contactProfile: contactProfile,
            fuelState: fuelState,
            engineState: state.engineRuntime,
            fuelPropulsion: backend
        )
        state = physics.step(state: state, control: control, context: context, deltaTime: dt)
        worstRoll = max(worstRoll, abs(state.orientation.x) * 180.0 / .pi)
    }

    let overshoot = worstRoll - commandedBank
    print(String(format: "%-24@ %10.1f %10.1f %11.1f %10.1f",
                 profile.displayName as NSString, visualSpan, realSpanMm / 1000.0,
                 spanRatio * spanRatio, overshoot))

    // A well-damped roll axis overshoots its command by a few degrees. Half the
    // command again is an airframe with far less inertia than it should have.
    if overshoot > commandedBank * 0.5 {
        failures.append(String(format: "%@ overshot a %.0f deg bank by %.0f deg on scene-scale mass properties",
                               profile.displayName, commandedBank, overshoot))
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
