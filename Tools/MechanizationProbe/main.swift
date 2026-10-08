import Foundation
import simd

// Headless probe of flaps and retractable undercarriage.
//
// What it measures, in the order these things were argued about:
//
//  1. Individual characteristics. Every airframe's flap lift, drag and trim change, limit
//     speeds, travel times and undercarriage drag — printed, and checked not to be one set
//     of numbers shared by the fleet.
//  2. The polar and the moments actually move by those numbers, and by how much that changes
//     each aircraft's glide.
//  3. The undercarriage is the operator's. It never moves without its lever — not near the
//     ground, not in the landing mode — and it obeys the lever on the ground.
//  4. Nothing overrules a flap selection. Above the limit speed the flaps still travel; the
//     air load is reported, and at the ultimate load a panel leaves the aircraft and rolls it.
//  5. Undercarriage failures: doors and the fore-and-aft folding leg above the limit speed,
//     and legs caught unlocked between the aircraft and the ground.
//  6. Cost. The contact profile is rebuilt when a leg locks, unlocks or fails — counted over
//     a whole flight — and never per substep.
//
// Run: Tools/MechanizationProbe/run.sh

var failures: [String] = []
func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition {
        failures.append(message())
        print("  FAIL  \(message())")
    }
}
func pad(_ text: String, _ width: Int) -> String { text.padding(toLength: width, withPad: " ", startingAt: 0) }
func num(_ value: Float, _ format: String = "%.3f") -> String { String(format: format, value) }

let repository = LIPODroneModelRepository()
let dt: Float = 1.0 / 60.0

struct Airframe {
    let profile: DroneModelProfile
    let wing: FixedWingParameters
    let model: AircraftMechanizationModel
    var c: AircraftMechanizationCharacteristics { model.characteristics }
    var name: String { profile.displayName }
}

let airframes: [Airframe] = repository.allProfiles.compactMap { profile in
    guard let wing = profile.fixedWingParameters,
          let model = AircraftMechanizationModel.shared(for: profile, uav: profile.resolvedUAVProfile) else { return nil }
    return Airframe(profile: profile, wing: wing, model: model)
}.sorted { $0.c.designMassKg < $1.c.designMassKg }

guard !airframes.isEmpty else {
    print("No airframe in the installed library declares flaps or a retractable undercarriage.")
    print("Install the models (Tools/UAVModelAssets/install_expansion.py) and run again.")
    exit(1)
}
let flapped = airframes.filter { $0.model.configuration.hasFlaps }
let geared = airframes.filter { $0.model.configuration.retractableGear }
for a in flapped {
    check(a.model.configuration.flapGeometry != nil, "\(a.name): installed manifest is missing its panel geometry")
    check(!a.c.flapPanels.isEmpty, "\(a.name): polar still uses the generic flap footprint")
    let geometry = a.model.configuration.flapGeometry
    check(abs((geometry?.panels.reduce(Float(0)) { $0+$1.coveredAreaFraction } ?? 0)-a.c.flappedAreaRatio) < 0.0001,
        "\(a.name): polar and USDZ use different covered wing areas")
}
let plain = flapped.filter { $0.c.flapType == .plain }
for (index,a) in plain.enumerated() {
    for b in plain[(index+1)...] {
        check(abs(a.c.flappedAreaRatio-b.c.flappedAreaRatio)>0.001 || abs(a.c.flapChordRatio-b.c.flapChordRatio)>0.001,
            "\(a.name) and \(b.name) still share one plain-flap geometry")
    }
}

// MARK: - Harness

func aerodynamics(_ a: Airframe, state: AircraftMechanizationState) -> FixedWingAerodynamics {
    let uav = a.profile.resolvedUAVProfile
    let span = (uav?.dimensions.wingspanMillimeters ?? a.profile.dimensionsUnfoldedMm.x) / 1000
    return FixedWingAerodynamics.build(
        family: a.wing.family, massKg: a.c.designMassKg, wingSpanM: span,
        fuselageLengthM: (uav?.dimensions.fuselageLengthMillimeters ?? span * 550) / 1000,
        heightM: (uav?.dimensions.heightMillimeters ?? span * 120) / 1000,
        turnAuthority: a.wing.turnAuthority, minSustainableSpeedMps: a.wing.minSustainableSpeedMps,
        designMassKg: a.c.designMassKg, profileID: a.profile.id,
        engineering: a.profile.engineeringAerodynamics
    ).applyingMechanization(a.model, state: state)
}

/// Contacts shaped like the ones the graph builder measures: a sphere under each leg, a
/// fuselage that hangs between them, and the wing tips.
func contacts(for a: Airframe) -> VehicleContactProfile {
    var spheres: [VehicleContactSphere] = []
    let legHeight = a.model.hinges.map(\.center.y).min() ?? 0.5
    let span = a.c.wingSpanM
    for hinge in a.model.hinges {
        var sphere = VehicleContactSphere(componentID: "gear.main",
            offset: SIMD3<Float>(hinge.center.x, 0.12, hinge.center.z), radius: 0.12)
        sphere.isGroundSupport = true
        spheres.append(sphere)
    }
    let bellyRadius = max(0.15, legHeight * 0.25)
    let bellyY = legHeight * 0.75 + bellyRadius
    for z in [-span * 0.18, 0, span * 0.18] {
        spheres.append(VehicleContactSphere(componentID: "fuselage", offset: SIMD3<Float>(0, bellyY, z), radius: bellyRadius))
    }
    for x in [-span / 2, span / 2] {
        spheres.append(VehicleContactSphere(componentID: "wing", offset: SIMD3<Float>(x, legHeight + 0.4, 0), radius: 0.1))
    }
    var profile = VehicleContactProfile(spheres: spheres, boundingRadius: span / 2 + 0.2)
    profile.referenceGroundOffset = profile.lowestPointOffset(orientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))
    return profile
}

/// One aircraft flown the way the view model flies it: the contact profile is kept in step
/// with the undercarriage by the caller, on the tick the mask changes.
final class Flight {
    let a: Airframe
    let engine = SimpleDronePhysicsEngine()
    let massModel: VehicleMassModel
    let backend: FuelPropulsionBackend?
    let fuelState: FuelSystemState?
    let neutral: VehicleContactProfile
    /// ⚠️ With a contact profile present the solver takes mass and inertia from here, and the
    /// context's default is one kilogram. Left at the default this harness flew every
    /// aircraft as a 1 kg airframe carrying its fuel.
    let massProperties: VehicleMassProperties
    let landingBaseline: ResolvedFlightBaseline
    var applied: VehicleContactProfile
    var appliedMask: UInt8 = 0
    var state: DroneState
    var pitchCommand: Float = 0
    var guidance = FixedWingFlapLandingGuidance()
    let stallAlphaRad: Float
    private var speedIntegral: Float = 0

    init(_ a: Airframe, altitude: Float, speed: Float, grounded: Bool = false) {
        self.a = a
        massModel = VehicleMassModel.baseline(for: a.profile, uavProfile: nil)
        fuelState = a.profile.resolvedUAVProfile?.powerplant?.fuel.map {
            .full(capacityKg: $0.usableFuelMassKg, reserveFraction: $0.reserveFraction)
        }
        backend = FuelPropulsionBackend(powerplant: a.profile.resolvedUAVProfile?.powerplant,
                                        cruiseSpeedMps: a.wing.cruiseSpeedMps)
        neutral = contacts(for: a)
        applied = neutral
        // Rate-ordered (roll, pitch, yaw) from the aerodynamics, stored as body-axis (Ixx, Iyy, Izz):
        // pitch is about X, yaw about Y, roll about Z.
        let inertia = aerodynamics(a, state: AircraftMechanizationState()).inertiaTensor
        stallAlphaRad = aerodynamics(a, state: AircraftMechanizationState()).stallAlphaRad
        let legHeight = a.model.hinges.map(\.center.y).min() ?? 0.5
        massProperties = VehicleMassProperties(
            totalMassKg: massModel.resolvedCurrentTotalMass,
            centerOfMassOffset: SIMD3<Float>(0, legHeight, 0),
            inertiaDiagonal: SIMD3<Float>(inertia.y, inertia.z, inertia.x))
        landingBaseline = FlightBaselineResolver.resolve(
            runtimeProfile: a.profile, activeUAVProfile: a.profile.resolvedUAVProfile,
            vehicleMassModel: massModel, flightMode: .landing)
        state = DroneState(
            position: SIMD3<Float>(0, altitude, 0),
            velocity: SIMD3<Float>(0, 0, -speed),
            orientation: .zero, angularVelocity: .zero,
            throttle: 0, motorThrottle: 0, rotorAngularSpeed: .zero,
            forwardAirspeed: speed,
            physicalState: grounded ? .landed : .airborne,
            mode: .manual)
        state.armState = grounded ? .disarmed : .armed
        if let backend, !grounded {
            var warm = EngineRuntimeState.cold(ambientTemperatureC: 15.0)
            warm.runState = .ready
            warm.shaftRPM = (backend.powerplant.ratedShaftRPM ?? 6000.0) * 0.9
            warm.temperatureC = EngineOperatingEnvelope.envelope(for: backend.powerplant.engineType).operatingTemperatureC
            state.engineRuntime = warm
        }
    }

    /// `holdSpeed` pitches for an airspeed, the way a glide or an approach is flown.
    func step(throttle: Float = 0, flaps: Float? = nil, gearDown: Bool? = nil,
              mode: DroneFlightMode = .manual, holdSpeed: Float? = nil, armed: Bool = true,
              throttleCeiling: Float? = nil) {
        if let holdSpeed {
            // Pitch for speed, proportional plus integral: nose up when fast.
            let error = state.forwardAirspeed - holdSpeed
            let path = atan2(state.velocity.y, max(1,simd_length(SIMD2<Float>(state.velocity.x,state.velocity.z))))
            // A speed-hold experiment must stay on the attached-flow branch.
            // Pitch is an attitude; stall is an angle to the flight path.
            let upper = min(Float(0.35),path+stallAlphaRad*0.75)
            let lower = max(Float(-0.6),path-stallAlphaRad*0.5)
            let unbounded = speedIntegral+error*0.02
            if unbounded > lower && unbounded < upper {
                speedIntegral = min(0.5,max(-0.6,speedIntegral+error*0.012*dt))
            }
            pitchCommand = min(upper,max(lower,speedIntegral+error*0.02))
        }
        var control = DroneControlInput(
            targetPosition: state.position, targetOrientation: SIMD3<Float>(0, pitchCommand, 0),
            yawIntent: 0, throttle: throttle, isArmed: armed, mode: mode, controlMode: .stabilized)
        control.flapCommand = flaps
        control.landingGearDownCommand = gearDown
        var context = DroneSimulationContext(
            profile: a.profile, activeUAVProfile: a.profile.resolvedUAVProfile,
            weather: .normal, damageState: .pristine, batteryState: .full,
            collisionRisk: 0, windVector: .zero, vehicleMassModel: massModel,
            fixedWingThrottleCeiling: throttleCeiling,
            vehicleMassProperties: massProperties,
            contactProfile: applied,
            fuelState: fuelState, engineState: state.engineRuntime, fuelPropulsion: backend)
        context.neutralContactProfile = neutral
        context.mechanization = a.model
        state = engine.step(state: state, control: control, context: context, deltaTime: dt)
        if state.mechanization.gearUnsupportedMask != appliedMask {
            appliedMask = state.mechanization.gearUnsupportedMask
            applied = a.model.contacts(neutral, unsupportedMask: appliedMask)
        }
    }

    /// One tick of the landing mode as the view model flies it: `land()`'s attitude and power,
    /// replaced by the flap guidance whenever the flaps are down.
    func stepLanding(flaps: Float? = nil, gearDown: Bool? = nil) {
        let stock = landingBaseline.landingThrottleReference
        var throttle = stock
        var ceiling: Float?
        if let command = guidance.command(
            state: state, heightAboveGroundM: state.position.y, characteristics: a.c,
            maximumThrottle: 1.0, dt: dt) {
            pitchCommand = command.pitchRad
            throttle = command.throttle
            ceiling = command.throttle
        }
        step(throttle: throttle, flaps: flaps, gearDown: gearDown, mode: .landing, throttleCeiling: ceiling)
    }
}

func condition(speed: Float, yawRate: Float = 0, height: Float = 500) -> AircraftMechanizationFlightCondition {
    AircraftMechanizationFlightCondition(dynamicPressurePa: 0.5 * 1.225 * speed * speed, airspeedMps: speed,
                                         yawRateRadPerSec: yawRate, heightAboveGroundM: height)
}

// MARK: - 1. Individual characteristics

print("1. Characteristics derived per airframe")
print(String(repeating: "-", count: 118))
print(pad("airframe", 26) + pad("MTOW kg", 9) + pad("S m²", 7) + pad("flap", 9) + pad("ΔCL", 7) + pad("ΔCD", 8)
      + pad("ΔCm", 8) + pad("Vs→Vsf", 12) + pad("VFE", 7) + pad("t flap", 8) + pad("gear ΔCD", 10) + pad("VLE", 7) + "t gear")
for a in airframes {
    let c = a.c
    let hasFlaps = a.model.configuration.hasFlaps, hasGear = a.model.configuration.retractableGear
    let lift = hasFlaps ? c.flapLift(deployment: 1) : 0
    print(pad(a.name, 26) + pad(num(c.designMassKg, "%.0f"), 9) + pad(num(c.wingAreaM2, "%.1f"), 7)
          + pad(hasFlaps ? c.flapType.rawValue.prefix(7).description : "—", 9)
          + pad(hasFlaps ? num(lift) : "—", 7)
          + pad(hasFlaps ? num(c.flapDrag(deployment: 1), "%.4f") : "—", 8)
          + pad(hasFlaps ? num(c.flapPitchRatio * lift) : "—", 8)
          + pad(hasFlaps ? "\(num(c.stallSpeedCleanMps, "%.1f"))→\(num(c.stallSpeedFlapsMps, "%.1f"))" : "—", 12)
          + pad(hasFlaps ? num(c.flapLimitSpeedMps, "%.1f") : "—", 7)
          + pad(hasFlaps ? num(c.flapTravelSeconds, "%.1f s") : "—", 8)
          + pad(hasGear ? num(c.gearDragCoefficient, "%.4f") : "—", 10)
          + pad(hasGear ? num(c.gearLimitSpeedMps, "%.1f") : "—", 7)
          + (hasGear ? num(c.gearTravelSeconds + 2 * c.doorTravelSeconds, "%.1f s") : "—"))
}

func distinct(_ values: [Float], tolerance: Float = 0.005) -> Int {
    var seen: [Float] = []
    for value in values where !seen.contains(where: { abs($0 - value) <= tolerance * max(abs(value), 1e-6) }) { seen.append(value) }
    return seen.count
}
check(distinct(flapped.map { $0.c.flapLift(deployment: 1) }) >= 3, "flap lift is not individual: fewer than three distinct values across \(flapped.count) airframes")
// Two airframes with one stall speed and one flap construction share a limit speed by rule;
// what must not happen is two airframes sharing the whole set.
for (index, a) in flapped.enumerated() {
    for b in flapped[(index + 1)...] {
        let same = abs(a.c.flapLift(deployment: 1) - b.c.flapLift(deployment: 1)) < 0.001
            && abs(a.c.flapLimitSpeedMps - b.c.flapLimitSpeedMps) < 0.05
            && abs(a.c.flapTravelSeconds - b.c.flapTravelSeconds) < 0.05
        check(!same, "\(a.name) and \(b.name) have identical flap characteristics")
    }
}
check(distinct(flapped.map(\.c.flapTravelSeconds)) == flapped.count || flapped.count < 2, "two airframes share a flap travel time")
check(distinct(geared.map(\.c.gearDragCoefficient)) == geared.count, "two airframes share an undercarriage drag coefficient")
check(distinct(geared.map(\.c.gearLimitSpeedMps)) == geared.count, "two airframes share an undercarriage limit speed")
for a in flapped {
    check(a.c.flapLimitSpeedMps > a.c.stallSpeedCleanMps * 1.39, "\(a.name): VFE below 1.4·VS")
    check(a.c.stallSpeedFlapsMps < a.c.stallSpeedCleanMps, "\(a.name): flaps do not lower the stall speed")
}

// MARK: - 2. The polar and the moments

print("\n2. What the solver's coefficients do with them (α = 5°)")
print(String(repeating: "-", count: 104))
print(pad("airframe", 26) + pad("CL clean", 10) + pad("CL flaps", 10) + pad("CD clean", 10) + pad("CD flaps", 10)
      + pad("CD +gear", 10) + pad("Cm flaps−clean", 16) + "L/D clean → landing")
let alpha: Float = 5 * .pi / 180
for a in airframes {
    var down = AircraftMechanizationState()
    down.gearExtension = 0
    var clean = down
    clean.flapDeployment = 0
    var flaps = down
    flaps.flapDeployment = a.model.configuration.hasFlaps ? 1 : 0
    var landing = flaps
    landing.gearExtension = 1
    let aeroClean = aerodynamics(a, state: clean), aeroFlaps = aerodynamics(a, state: flaps)
    let aeroLanding = aerodynamics(a, state: landing)
    let c0 = aeroClean.liftDrag(alphaRad: alpha), c1 = aeroFlaps.liftDrag(alphaRad: alpha), c2 = aeroLanding.liftDrag(alphaRad: alpha)
    let cm = aeroFlaps.pitchMoment(alphaRad: alpha, elevatorFraction: 0, qHat: 0)
        - aeroClean.pitchMoment(alphaRad: alpha, elevatorFraction: 0, qHat: 0)
    print(pad(a.name, 26) + pad(num(c0.cl), 10) + pad(num(c1.cl), 10) + pad(num(c0.cd, "%.4f"), 10)
          + pad(num(c1.cd, "%.4f"), 10) + pad(num(c2.cd, "%.4f"), 10) + pad(num(cm, "%+.4f"), 16)
          + "\(num(c0.cl / c0.cd, "%.1f")) → \(num(c2.cl / c2.cd, "%.1f"))")
    if a.model.configuration.hasFlaps {
        check(abs((c1.cl - c0.cl) - a.c.flapLift(deployment: 1)) < 0.002, "\(a.name): the polar's flap lift is not the derived one")
        if AircraftMechanizationCharacteristics.trimCompensatedFlaps.contains(a.profile.id) {
            check(abs(cm) < 0.005, "\(a.name): the forward flap does not cancel the trim change (ΔCm = \(cm))")
        } else {
            check(cm < -0.01, "\(a.name): flaps give no nose-down trim change")
        }
        check(c1.cd > c0.cd + a.c.flapDrag(deployment: 1) * 0.99, "\(a.name): flap drag missing from the polar")
    }
    if a.model.configuration.retractableGear {
        check(abs((c2.cd - c1.cd) - a.c.gearDragCoefficient) < 1e-5, "\(a.name): undercarriage drag missing from the polar")
    }
    // A clean airframe with everything stowed must fly on exactly the coefficients it had.
    let bare = aerodynamics(a, state: clean)
    check(bare.mechanization.isNeutral, "\(a.name): stowed mechanization is not neutral")
}

print("\n   Trimmed power-off glide from the solver's own polar, design weight, sea level:")
print("   clean at 1.3·VS against flaps and undercarriage down at 1.3·VS0")
print("   " + String(repeating: "-", count: 92))
print("   " + pad("airframe", 26) + pad("clean m/s", 11) + pad("sink m/s", 10) + pad("L/D", 7) + pad("landing m/s", 13) + pad("sink m/s", 10) + pad("L/D", 7) + "path steeper by")
for a in airframes {
    /// Angle of attack at which the wing carries the weight at this speed, then L/D there.
    func glide(_ aero: FixedWingAerodynamics, speed: Float) -> (sink: Float, ratio: Float)? {
        let required = 2 * a.c.designMassKg * 9.81 / (1.225 * speed * speed * aero.wingArea)
        var low: Float = -0.1, high = aero.stallAlphaRad
        guard aero.liftDrag(alphaRad: high).cl >= required else { return nil }
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if aero.liftDrag(alphaRad: middle).cl < required { low = middle } else { high = middle }
        }
        let point = aero.liftDrag(alphaRad: high)
        return (speed * point.cd / point.cl, point.cl / point.cd)
    }
    var stowed = AircraftMechanizationState()
    stowed.gearExtension = 0
    var landing = AircraftMechanizationState()
    landing.flapDeployment = a.model.configuration.hasFlaps ? 1 : 0
    let cleanSpeed = a.c.stallSpeedCleanMps * 1.3
    let landingSpeed = a.c.stallSpeed(deployment: landing.flapDeployment) * 1.3
    guard let clean = glide(aerodynamics(a, state: stowed), speed: cleanSpeed),
          let dirty = glide(aerodynamics(a, state: landing), speed: landingSpeed) else {
        check(false, "\(a.name): the polar cannot carry the design weight at 1.3·VS")
        continue
    }
    print("   " + pad(a.name, 26) + pad(num(cleanSpeed, "%.1f"), 11) + pad(num(clean.sink, "%.2f"), 10) + pad(num(clean.ratio, "%.1f"), 7)
          + pad(num(landingSpeed, "%.1f"), 13) + pad(num(dirty.sink, "%.2f"), 10) + pad(num(dirty.ratio, "%.1f"), 7)
          + num((clean.ratio / dirty.ratio - 1) * 100, "%.0f %%"))
    check(dirty.ratio < clean.ratio * 0.95, "\(a.name): the landing configuration does not steepen the glide")
    check(landingSpeed < cleanSpeed, "\(a.name): the landing configuration does not lower the approach speed")
}

// MARK: - 3. The undercarriage is the operator's

print("\n3. Undercarriage: lever only")
print(String(repeating: "-", count: 104))
for a in geared {
    let speed = min(a.c.gearLimitSpeedMps * 0.9, a.wing.cruiseSpeedMps)
    // Lever up, then a low pass in the landing mode: nothing may extend it.
    var flight = Flight(a, altitude: 300, speed: speed)
    var upAt: Float?
    for tick in 0..<(60 * 30) {
        flight.step(throttle: 0.6, gearDown: false, holdSpeed: speed)
        if upAt == nil, flight.state.mechanization.gearExtension <= 0, !flight.state.mechanization.gearInTransit { upAt = Float(tick + 1) * dt }
    }
    let expected = a.c.gearTravelSeconds + 2 * a.c.doorTravelSeconds
    check(upAt != nil, "\(a.name): lever up did not retract the undercarriage")
    check(abs((upAt ?? 0) - expected) < 0.2, "\(a.name): retraction took \(num(upAt ?? 0, "%.2f")) s, its own cycle is \(num(expected, "%.2f")) s")
    flight.state.position.y = 4
    flight.state.velocity.y = 0
    var movedLow = false
    for _ in 0..<(60 * 20) {
        flight.state.position.y = max(flight.state.position.y, 3)
        flight.step(throttle: 0.5, gearDown: false, mode: .landing, holdSpeed: speed)
        if flight.state.mechanization.gearExtension > 0 || flight.state.mechanization.gearInTransit { movedLow = true }
    }
    check(!movedLow, "\(a.name): the undercarriage moved by itself at 3 m in the landing mode")

    // Lever down again.
    var downAt: Float?
    for tick in 0..<(60 * 30) {
        flight.state.position.y = max(flight.state.position.y, 50)
        flight.step(throttle: 0.6, gearDown: true, holdSpeed: speed)
        if downAt == nil, flight.state.mechanization.gearDownAndLocked, !flight.state.mechanization.gearInTransit { downAt = Float(tick + 1) * dt }
    }
    check(downAt != nil, "\(a.name): lever down did not lock the undercarriage")

    // An untouched lever is down, and stays there through a whole flight.
    flight = Flight(a, altitude: 300, speed: speed)
    var movedUntouched = false
    for _ in 0..<(60 * 20) {
        flight.step(throttle: 0.6, holdSpeed: speed)
        if !flight.state.mechanization.gearDownAndLocked { movedUntouched = true }
    }
    check(!movedUntouched, "\(a.name): the undercarriage moved with its lever untouched")

    // Lever up on the ground: the aircraft is put down on its fuselage and the legs are gone.
    flight = Flight(a, altitude: 0, speed: 0, grounded: true)
    for _ in 0..<60 { flight.step(armed: false) }
    let standing = flight.state.position.y
    for _ in 0..<(60 * 25) { flight.step(gearDown: false, armed: false) }
    let lying = flight.state.position.y
    let crushed = flight.state.mechanization.gearCrushedOnGround
    for _ in 0..<(60 * 25) { flight.step(gearDown: true, armed: false) }
    print(pad(a.name, 26) + "up \(num(upAt ?? -1, "%.2f")) s (own \(num(expected, "%.2f")) s), down \(num(downAt ?? -1, "%.2f")) s; "
          + "on the ground: stood at \(num(standing, "%.2f")) m, lever up → \(num(lying, "%.2f")) m, legs crushed: \(crushed)")
    check(standing > -0.05 && standing < 0.05, "\(a.name): does not stand on its undercarriage (y = \(standing))")
    check(lying < standing - 0.3, "\(a.name): lever up on the ground did not put the aircraft on its fuselage")
    check(crushed, "\(a.name): legs folded under the aircraft were not damaged")
    check(!flight.state.mechanization.gearDownAndLocked, "\(a.name): crushed legs locked down again")
}

// MARK: - 4. Flaps: nothing overrules the lever

print("\n4. Flaps above the limit speed")
print(String(repeating: "-", count: 104))
for a in flapped {
    let c = a.c
    // 10 % above VFE: the flaps must still travel all the way and the load must be reported.
    // The limit is an equivalent airspeed, so the load is checked against the EAS flown.
    let over = c.flapLimitSpeedMps * 1.10
    let flight = Flight(a, altitude: 150, speed: over)
    var peak: Float = 0, expected: Float = 0
    for _ in 0..<Int((c.flapTravelSeconds + 1) * 60) {
        flight.state.velocity = simd_normalize(flight.state.velocity) * over
        flight.state.position.y = 150
        flight.step(throttle: 0.7, flaps: 1)
        peak = max(peak, flight.state.mechanization.flapLoadRatio)
        expected = pow(flight.state.equivalentAirspeedMps / c.flapLimitSpeedMps, 2)
    }
    let deployed = flight.state.mechanization.flapDeployment
    check(deployed > 0.999, "\(a.name): flaps stopped at \(num(deployed)) above VFE — the lever was overruled")
    check(peak > 1.1 && abs(peak - expected) < 0.03, "\(a.name): load at 1.10·VFE reads \(num(peak)), EAS says \(num(expected))")
    check(!flight.state.mechanization.hasFailure, "\(a.name): flaps failed below the ultimate load")

    // Straight and level through the ultimate load: both panels carry the same load and go together.
    var state = AircraftMechanizationState()
    state.flapDeployment = 1
    state.flapAngleRadians = c.flapMaxRad
    var control = DroneControlInput(targetPosition: .zero, targetOrientation: .zero, yawIntent: 0,
                                    throttle: 0, isArmed: true, mode: .manual, controlMode: .stabilized)
    control.flapCommand = 1
    func advance(_ s: AircraftMechanizationState, speed: Float, yawRate: Float) -> AircraftMechanizationState {
        a.model.advance(s, control: control,
            condition: AircraftMechanizationFlightCondition(dynamicPressurePa: 0.5*1.225*speed*speed,
                airspeedMps: speed, yawRateRadPerSec: yawRate, heightAboveGroundM: 100),
            actuatorAuthority: 1, isDestroyed: false, dt: dt)
    }
    let failSpeed = c.flapLimitSpeedMps * sqrt(AircraftMechanizationModel.ultimateLoadFactor)
    let below = advance(state, speed: failSpeed * 0.99, yawRate: 0)
    let above = advance(state, speed: failSpeed * 1.01, yawRate: 0)
    check(!below.hasFailure, "\(a.name): panel lost below the ultimate load")
    check(above.flapPanelHealth == .zero, "\(a.name): symmetric overload did not take both panels")

    // In a turn the outer wing is faster. Just under the ultimate load, the outer panel alone
    // goes. The yaw rate is the one that makes the outer panel 1 % faster than the centreline.
    let turnSpeed = failSpeed * 0.998
    let yawRate = 0.01 * turnSpeed / (c.wingSpanM * c.flapLateralArm)
    let turning = advance(state, speed: turnSpeed, yawRate: yawRate)
    let outerOnly = turning.flapPanelHealth.y <= 0.5 && turning.flapPanelHealth.x > 0.5
    let aero = aerodynamics(a, state: turning)
    let roll = aero.rollMoment(alphaRad: alpha, betaRad: 0, aileronFraction: 0, pHat: 0)
    let fullAileron = abs(aero.clDeltaA)
    print(pad(a.name, 26) + "VFE \(num(c.flapLimitSpeedMps, "%.1f")) m/s; at 1.10·VFE flaps reach \(num(deployed * 100, "%.0f")) %, load \(num(peak, "%.2f")); "
          + "panels fail at \(num(failSpeed, "%.1f")) m/s; one panel gone: Cl \(num(roll, "%+.4f")) = \(num(abs(roll) / max(1e-6, fullAileron) * 100, "%.0f")) % of full aileron")
    check(outerOnly, "\(a.name): in a turn the outer panel did not fail first (\(turning.flapPanelHealth))")
    // Left panel still down, right gone: the left wing lifts more and the aircraft rolls right-wing-down.
    check(roll < -0.002, "\(a.name): a lost right panel does not roll the aircraft toward it (Cl = \(roll))")
    // Retracting what is left removes the asymmetry the flap made; the missing area stays.
    var retracted = turning
    retracted.flapDeployment = 0
    retracted.flapAngleRadians = 0
    let residual = aerodynamics(a, state: retracted).rollMoment(alphaRad: alpha, betaRad: 0, aileronFraction: 0, pHat: 0)
    check(abs(residual) < abs(roll), "\(a.name): retracting the remaining flap does not reduce the roll")
}

// MARK: - 5. Undercarriage failures

print("\n5. Undercarriage above the limit speed")
print(String(repeating: "-", count: 104))
for a in geared {
    let c = a.c
    var control = DroneControlInput(targetPosition: .zero, targetOrientation: .zero, yawIntent: 0,
                                    throttle: 0, isArmed: true, mode: .manual, controlMode: .stabilized)
    func advance(_ s: AircraftMechanizationState, speed: Float, seconds: Float) -> AircraftMechanizationState {
        var s = s
        for _ in 0..<Int(seconds * 60) {
            s = a.model.advance(s, control: control,
                condition: AircraftMechanizationFlightCondition(dynamicPressurePa: 0.5*1.225*speed*speed,
                    airspeedMps: speed, yawRateRadPerSec: 0, heightAboveGroundM: 100),
                actuatorAuthority: 1, isDestroyed: false, dt: dt)
        }
        return s
    }
    let failSpeed = c.gearLimitSpeedMps * sqrt(AircraftMechanizationModel.ultimateLoadFactor)
    control.landingGearDownCommand = true
    let cruising = advance(AircraftMechanizationState(), speed: failSpeed * 0.99, seconds: 5)
    let overspeed = advance(AircraftMechanizationState(), speed: failSpeed * 1.01, seconds: 1)
    let failedLegs = (0..<a.model.hinges.count).filter { overspeed.gearLegHealth[$0] <= 0.5 }
    let foreAft = a.model.hinges.indices.filter { a.model.hinges[$0].airloadAlignment > 0.9 }
    check(!cruising.hasFailure, "\(a.name): a leg failed below the ultimate load")
    check(cruising.gearLoadRatio > 1.4, "\(a.name): load at the edge reads \(cruising.gearLoadRatio)")
    check(failedLegs == Array(foreAft), "\(a.name): legs \(failedLegs) failed, the fore-and-aft folding ones are \(Array(foreAft))")
    check(!overspeed.gearDownAndLocked, "\(a.name): reports down and locked with a failed leg")

    // Selecting the undercarriage at that speed: the doors meet the air first.
    control.landingGearDownCommand = false
    var retracted = AircraftMechanizationState()
    retracted.gearExtension = 0
    retracted.gearUnsupportedMask = 0b111
    control.landingGearDownCommand = true
    let cycled = advance(retracted, speed: failSpeed * 1.01, seconds: c.doorTravelSeconds + 0.5)
    check(cycled.gearDoorsLost, "\(a.name): doors survived opening above the ultimate load")
    print(pad(a.name, 26) + "VLE \(num(c.gearLimitSpeedMps, "%.1f")) m/s; fails at \(num(failSpeed, "%.1f")) m/s: legs \(failedLegs) of \(a.model.hinges.count) "
          + "(fore-and-aft folding: \(Array(foreAft))); doors lost when cycled there: \(cycled.gearDoorsLost)")

    // Touching down with the legs still travelling.
    let flight = Flight(a, altitude: 0, speed: 0, grounded: true)
    for _ in 0..<30 { flight.step(armed: false) }
    flight.state.mechanization.gearExtension = 0.5
    flight.state.mechanization.gearDoorOpening = 1
    flight.state.mechanization.gearUnsupportedMask = 0b111
    flight.state.position.y = 2
    for _ in 0..<(60 * 6) { flight.step(gearDown: true, armed: false) }
    check(flight.state.mechanization.gearCrushedOnGround, "\(a.name): unlocked legs survived a touchdown")

    // The nose leg has been blown back, the mains are locked: the aircraft cannot be held level
    // by an undercarriage it no longer has, and settles nose-down on what is left.
    if let nose = foreAft.first {
        let tripod = Flight(a, altitude: 0, speed: 0, grounded: true)
        tripod.state.mechanization.gearLegHealth[nose] = 0
        tripod.state.mechanization.gearUnsupportedMask = 1 << UInt8(nose)
        for _ in 0..<(60 * 12) { tripod.step(gearDown: true, armed: false) }
        let pitch = tripod.state.orientation.y * 180 / .pi
        check(tripod.state.position.y.isFinite && pitch.isFinite, "\(a.name): state went non-finite with a failed nose leg")
        check(pitch < -2, "\(a.name): nose leg gone, mains locked — the nose did not come down (pitch \(num(pitch, "%.1f"))°)")
        print(pad("", 26) + "nose leg gone, mains locked, at rest: pitch \(num(pitch, "%+.1f"))°")
    }

    // Wheels up: the undercarriage is safe in its bays and the aircraft rests on its fuselage.
    let belly = Flight(a, altitude: 0, speed: 0, grounded: true)
    belly.state.mechanization.gearExtension = 0
    belly.state.mechanization.gearUnsupportedMask = 0b111
    belly.state.position.y = 2
    for _ in 0..<(60 * 6) { belly.step(gearDown: false, armed: false) }
    check(!belly.state.mechanization.hasFailure, "\(a.name): a wheels-up landing damaged the stowed undercarriage")
    check(belly.state.position.y < -0.3, "\(a.name): wheels up, the aircraft rests at \(belly.state.position.y) m — not on its fuselage")
}

// MARK: - 6. Cost

print("\n6. Cost of carrying it")
print(String(repeating: "-", count: 104))
for a in geared {
    let speed = min(a.c.gearLimitSpeedMps * 0.9, a.wing.cruiseSpeedMps)
    let flight = Flight(a, altitude: 800, speed: speed)
    AircraftMechanizationModel.contactRebuildCount = 0
    let ticks = 60 * 120
    let started = Date()
    for tick in 0..<ticks {
        // Up after 5 s, down again after 60 s: one full cycle in two minutes of flight.
        flight.state.position.y = max(flight.state.position.y, 300)
        flight.step(throttle: 0.6, gearDown: tick < 300 || tick > 3600, holdSpeed: speed)
    }
    let perStep = Float(Date().timeIntervalSince(started)) / Float(ticks) * 1e6
    let rebuilds = AircraftMechanizationModel.contactRebuildCount

    // The same flight with the undercarriage left alone.
    let reference = Flight(a, altitude: 800, speed: speed)
    let referenceStarted = Date()
    for _ in 0..<ticks {
        reference.state.position.y = max(reference.state.position.y, 300)
        reference.step(throttle: 0.6, holdSpeed: speed)
    }
    let referencePerStep = Float(Date().timeIntervalSince(referenceStarted)) / Float(ticks) * 1e6
    print(pad(a.name, 26) + "\(ticks) ticks with one gear cycle: \(rebuilds) contact rebuilds; "
          + "\(num(perStep, "%.1f")) µs/tick against \(num(referencePerStep, "%.1f")) µs/tick with the lever untouched")
    // Unlock on the way up, and the caller's copy; lock on the way down needs none (the
    // neutral profile is returned as it is). Anything near the tick count is a per-step rebuild.
    check(rebuilds <= 4, "\(a.name): \(rebuilds) contact rebuilds for one gear cycle")
}

// MARK: - 7. The autopilot's hand on the levers

print("\n7. Autopilot: levers left in AUTO")
print(String(repeating: "-", count: 104))
do {
    var takeoff = DroneControlInput(targetPosition: .zero, targetOrientation: .zero, yawIntent: 0,
                                    throttle: 1, isArmed: true, mode: .takeoff, controlMode: .stabilized)
    for a in airframes {
        let c = a.c
        let hasFlaps = a.model.configuration.hasFlaps, hasGear = a.model.configuration.retractableGear
        func run(_ s: AircraftMechanizationState, _ control: DroneControlInput, speed: Float, height: Float,
                 seconds: Float) -> AircraftMechanizationState {
            var s = s
            for _ in 0..<Int(seconds * 60) {
                s = a.model.advance(s, control: control, condition: condition(speed: speed, height: height),
                                    actuatorAuthority: 1, isDestroyed: false, dt: dt)
            }
            return s
        }
        let climbSpeed = c.stallSpeedCleanMps * 1.25
        // Takeoff roll and the first metres of the climb: takeoff flap, legs still down.
        takeoff.mode = .takeoff
        let rolling = run(AircraftMechanizationState(), takeoff, speed: c.stallSpeedCleanMps * 0.8, height: 0, seconds: 30)
        let lowClimb = run(rolling, takeoff, speed: climbSpeed, height: 10, seconds: 5)
        // Past the screen height: legs up. On the route: flaps up, and nothing comes back down.
        let climbing = run(lowClimb, takeoff, speed: climbSpeed, height: 20, seconds: 30)
        var route = takeoff
        route.mode = .autoPath
        let cruising = run(climbing, route, speed: a.wing.cruiseSpeedMps, height: 300, seconds: 40)
        let lowPass = run(cruising, route, speed: a.wing.cruiseSpeedMps, height: 5, seconds: 20)
        // Landing selected at cruise speed, then slowed to the approach.
        var landing = takeoff
        landing.mode = .landing
        let fast = run(lowPass, landing, speed: max(a.wing.cruiseSpeedMps, c.gearLimitSpeedMps * 1.05), height: 200, seconds: 5)
        let approach = run(fast, landing, speed: c.stallSpeedCleanMps * 1.3, height: 100, seconds: 40)
        // Manual flight with the levers still in AUTO: they stay where the autopilot left them.
        var manual = takeoff
        manual.mode = .manual
        let handFlown = run(cruising, manual, speed: c.stallSpeedCleanMps * 1.3, height: 3, seconds: 30)
        // The operator's lever against the autopilot's wish.
        landing.landingGearDownCommand = false
        landing.flapCommand = 0
        let overruled = run(lowPass, landing, speed: c.stallSpeedCleanMps * 1.3, height: 100, seconds: 40)

        if hasFlaps {
            let half = AircraftMechanizationCharacteristics.takeoffFlapSetting
            check(abs(rolling.flapDeployment - half) < 0.01, "\(a.name): autopilot takeoff flap is \(rolling.flapDeployment), not the takeoff setting")
            check(cruising.flapDeployment == 0, "\(a.name): autopilot left the flaps down on the route")
            check(approach.flapDeployment > 0.99, "\(a.name): autopilot did not lower full flap for the landing")
            check(handFlown.flapSelection == cruising.flapSelection, "\(a.name): flaps moved in manual flight with the lever in AUTO")
            check(overruled.flapDeployment == 0, "\(a.name): autopilot lowered flaps the operator had selected up")
            check(!approach.hasFailure && approach.flapLoadRatio < 1, "\(a.name): autopilot loaded its own flaps past the limit")
        }
        if hasGear {
            check(lowClimb.gearSelectedDown, "\(a.name): autopilot raised the undercarriage below the screen height")
            check(!climbing.gearSelectedDown && climbing.gearExtension == 0, "\(a.name): autopilot did not raise the undercarriage in the climb")
            check(!lowPass.gearSelectedDown, "\(a.name): the undercarriage came down by itself on the route at 5 m")
            check(!fast.gearSelectedDown, "\(a.name): autopilot selected the undercarriage above its limit speed")
            check(approach.gearDownAndLocked, "\(a.name): autopilot did not lower the undercarriage for the landing")
            check(!handFlown.gearSelectedDown, "\(a.name): the undercarriage moved in manual flight at 3 m with the lever in AUTO")
            check(!overruled.gearSelectedDown && overruled.gearExtension == 0, "\(a.name): autopilot lowered an undercarriage the operator had selected up")
            check(!approach.hasFailure, "\(a.name): autopilot broke its own undercarriage")
        }
    }
    print("   takeoff flap on the roll, legs up past \(Int(AircraftMechanizationModel.autopilotGearRetractionHeightM)) m, clean on the route, nothing lowered at 5 m on the route,")
    print("   legs and flaps down for the landing once inside their limit speeds, nothing moved in manual flight,")
    print("   a lever the operator selected left alone — checked on \(airframes.count) airframes")
}

print("\n   Landing mode from 60 m at 1.3·VS, levers in AUTO, against the same landing with the flaps held up:")
print("   " + pad("airframe", 26) + pad("flaps", 7) + pad("down in", 10) + pad("touchdown m/s", 15) + pad("× VS0", 8) + pad("sink m/s", 10) + pad("min speed × VS0", 17) + "gear")
for a in flapped {
    struct Landing { var time: Float; var speed: Float; var sink: Float; var minimumMargin: Float; var gearLocked: Bool; var flaps: Float }
    func land(flaps: Float?) -> Landing? {
        let flight = Flight(a, altitude: 60, speed: a.wing.minSustainableSpeedMps * 1.3)
        flight.pitchCommand = 6 * .pi / 180
        var minimumMargin = Float.greatestFiniteMagnitude
        for tick in 0..<(60 * 240) {
            flight.stepLanding(flaps: flaps)
            let stall = a.c.stallSpeed(deployment: flight.state.mechanization.flapDeployment)
            if tick > 120 { minimumMargin = min(minimumMargin, flight.state.forwardAirspeed / stall) }
            if let touchdown = flight.state.groundApproach {
                return Landing(time: Float(tick + 1) * dt, speed: simd_length(touchdown.velocity), sink: -touchdown.velocity.y,
                               minimumMargin: minimumMargin, gearLocked: flight.state.mechanization.gearDownAndLocked,
                               flaps: flight.state.mechanization.flapDeployment)
            }
        }
        return nil
    }
    let automatic = land(flaps: nil), clean = land(flaps: 0)
    for (label, result) in [("AUTO", automatic), ("up", clean)] {
        guard let result else { print("   " + pad(a.name, 26) + pad(label, 7) + "not down after 240 s"); continue }
        print("   " + pad(a.name, 26) + pad(label, 7) + pad(num(result.time, "%.0f s"), 10) + pad(num(result.speed, "%.1f"), 15)
              + pad(num(result.speed / a.c.stallSpeed(deployment: result.flaps), "%.2f"), 8) + pad(num(result.sink, "%.2f"), 10)
              + pad(num(result.minimumMargin, "%.2f"), 17) + (a.model.configuration.retractableGear ? (result.gearLocked ? "locked" : "NOT LOCKED") : "fixed"))
    }
    check(automatic != nil, "\(a.name): the landing with autopilot flaps never reaches the ground")
    if let automatic {
        check(automatic.flaps > 0.99, "\(a.name): touched down with the flaps at \(automatic.flaps)")
        check(automatic.gearLocked, "\(a.name): touched down without a locked undercarriage")
        // What the undercarriage is designed to take, CS-23.473(d): 4.4·(W/S)^¼ ft/s, wing
        // loading in lb/ft², not less than 7 nor more than 10 ft/s.
        let wingLoading = a.c.designMassKg * 2.20462 / (a.c.wingAreaM2 * 10.7639)
        let designSink = min(10, max(7, 4.4 * pow(wingLoading, 0.25))) * 0.3048
        check(automatic.sink < designSink,
              "\(a.name): autopilot touchdown at \(num(automatic.sink, "%.2f")) m/s, the undercarriage is designed to \(num(designSink, "%.2f")) m/s"
              + (clean.map { " (the stock landing with flaps up: \(num($0.sink, "%.2f")) m/s)" } ?? ""))
        check(automatic.minimumMargin > 1.1, "\(a.name): the approach got within \(num(automatic.minimumMargin, "%.2f"))·VS0 of the stall")
        if let clean { check(automatic.speed < clean.speed, "\(a.name): flaps do not slow the touchdown") }
    }
}

print("")
if failures.isEmpty {
    print("OK — \(airframes.count) airframes, \(flapped.count) with flaps, \(geared.count) with retractable undercarriage")
} else {
    print("\(failures.count) FAILED")
    for failure in failures { print("  - \(failure)") }
    exit(1)
}
