import Foundation
import simd

// Headless turn-coordination probe.
//
// Answers one question the operator raised and no flight log can settle: during an *automatic*
// banked turn, does the automatic rudder actually participate, or is the turn flown on ailerons
// alone?
//
// The rudder's coordination term is `desiredFixedWingRudderFraction`'s
// `coordination = coordinationBankRad * 0.5` — an open-loop feedforward proportional to bank
// angle, with one fleet-wide constant and no dependence on airspeed, fin size or airframe mass.
// Whether that happens to be the right gain is an empirical question, so measure it:
//
//   beta   steady sideslip in the turn. A coordinated turn holds it near zero. Positive or
//          negative simply says which way the nose hangs off the velocity vector.
//   rud    the rudder deflection actually being carried.
//   rate   achieved turn rate against the ideal coordinated rate g*tan(phi)/V. Below 100% means
//          the aircraft is skidding and not turning as fast as its bank should deliver.
//
// Note the shape of the expected error before reading the numbers: a coordinated turn needs a yaw
// rate of g*tan(phi)/V, so the rudder requirement grows with *tan* of the bank angle, while the
// feedforward is linear in the angle itself. The two agree at small bank and diverge steadily
// above it — at 45 deg, tan(phi) exceeds phi by 28%. Airspeed and fin authority do not appear in
// the feedforward at all.
//
// Run: Tools/TurnCoordinationProbe/run.sh

let repository = LIPODroneModelRepository()
let engine = SimpleDronePhysicsEngine()
let dt: Float = 1.0 / 90.0

/// Flies a steady commanded bank and reports the settled turn state.
/// `bankDegrees` is the commanded bank; the achieved bank is reported separately because the
/// attitude loop droops against the airframe's own stiffness.
func flyTurn(
    profile: DroneModelProfile,
    wing: FixedWingParameters,
    bankDegrees: Float
) -> (beta: Float, spread: Float, rudder: Float, achievedBank: Float, turnRate: Float, speed: Float)? {
    let massModel = VehicleMassModel.baseline(for: profile, uavProfile: nil)
    let fuelState: FuelSystemState? = profile.resolvedUAVProfile?.powerplant?.fuel.map {
        .full(capacityKg: $0.usableFuelMassKg, reserveFraction: $0.reserveFraction)
    }
    let backend = FuelPropulsionBackend(
        powerplant: profile.resolvedUAVProfile?.powerplant,
        cruiseSpeedMps: wing.cruiseSpeedMps
    )

    var state = DroneState(
        position: SIMD3<Float>(0, 600, 0),
        velocity: SIMD3<Float>(0, 0, -wing.cruiseSpeedMps),
        orientation: .zero,
        angularVelocity: .zero,
        throttle: 0.7,
        motorThrottle: 0.7,
        rotorAngularSpeed: .zero,
        forwardAirspeed: wing.cruiseSpeedMps,
        physicalState: .airborne,
        mode: .autoPath
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

    var betaSamples: [Float] = []
    var rudderSamples: [Float] = []
    var bankSamples: [Float] = []
    var yawRateSamples: [Float] = []
    var speedSamples: [Float] = []

    // 45 s: a heavy wing takes many seconds to establish bank, and the sideslip that matters is
    // the settled one, not the transient during roll-in.
    let totalTicks = Int(45.0 / Double(dt))
    let settleTicks = Int(30.0 / Double(dt))

    for tick in 0..<totalTicks {
        // The autopilot case: a commanded bank and pitch, no pilot rudder. `yawIntent: 0` is what
        // `resolveYawRouting` delivers whenever the assist owns the course, so this is the real
        // automatic-turn input, not an approximation of it.
        let control = DroneControlInput(
            targetPosition: SIMD3<Float>(state.position.x, 600, state.position.z),
            targetOrientation: SIMD3<Float>(
                bankDegrees * .pi / 180.0,
                0.0,
                state.orientation.z
            ),
            yawIntent: 0.0,
            throttle: 0.7,
            isArmed: true,
            mode: .autoPath,
            controlMode: .stabilized
        )
        let context = DroneSimulationContext(
            profile: profile,
            // Never nil: for the aircraft carrying a `runtimeSceneDimensionsOverride` the fallback
            // is the scene-asset size, which undersizes the wing by an order of magnitude.
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

        guard state.position.y.isFinite, state.physicalState == .airborne else { return nil }

        if tick > settleTicks {
            // Sideslip exactly as the engine defines it, so the number is the one the aero
            // actually reacts to rather than a re-derivation that could disagree by a sign.
            let bodyAirflow = simd_act(state.fixedWingOrientationQuat.conjugate, state.velocity)
            let airspeed = max(simd_length(bodyAirflow), 0.5)
            betaSamples.append(asin(max(-1.0, min(1.0, bodyAirflow.x / airspeed))))
            rudderSamples.append(state.rudderDeflection)
            let euler = state.orientation
            bankSamples.append(euler.x)
            yawRateSamples.append(state.bodyAngularVelocity.z)
            speedSamples.append(airspeed)
        }
    }

    guard !betaSamples.isEmpty else { return nil }
    func mean(_ xs: [Float]) -> Float { xs.reduce(0, +) / Float(xs.count) }
    // Peak-to-peak sideslip over the settled window. Without it a mean cannot tell a steady skid
    // from a limit cycle, and a feedback gain high enough to null the mean is exactly the gain
    // that can start one — so the two failure modes must be distinguishable in the output.
    let betaSpread = (betaSamples.max() ?? 0) - (betaSamples.min() ?? 0)
    return (
        beta: mean(betaSamples),
        spread: betaSpread,
        rudder: mean(rudderSamples),
        achievedBank: mean(bankSamples),
        turnRate: mean(yawRateSamples),
        speed: mean(speedSamples)
    )
}

print("Turn coordination in an automatic banked turn")
print("beta = settled sideslip (deg). A coordinated turn holds it near zero.")
print("rud  = carried rudder deflection. rate = achieved turn rate / ideal g*tan(phi)/V.")
print("")
print(String(
    format: "%-28@ %6@ %6@ %7@ %7@ %6@ %6@",
    "profile" as NSString, "cmd" as NSString, "bank" as NSString,
    "beta" as NSString, "p-p" as NSString, "rud" as NSString, "rate" as NSString
))
print(String(repeating: "-", count: 76))

var slipping: [(String, Float)] = []
var oscillating: [(String, Float)] = []
var measured = 0

for profile in repository.allProfiles where profile.airframeClass == .fixedWing {
    guard let wing = profile.fixedWingParameters else { continue }
    // The bank an automatic route turn actually commands.
    let commanded = wing.maxBankAngleDeg * 0.95
    guard let r = flyTurn(profile: profile, wing: wing, bankDegrees: commanded) else {
        print(String(format: "%-28@  (did not sustain the turn)", profile.displayName as NSString))
        continue
    }
    measured += 1
    let bankRad = r.achievedBank
    let idealRate = abs(bankRad) > 0.001
        ? 9.81 * tan(abs(bankRad)) / max(r.speed, 1.0)
        : 0.0
    let rateRatio = idealRate > 0.0001 ? abs(r.turnRate) / idealRate : 0.0
    let betaDeg = r.beta * 180.0 / .pi
    if abs(betaDeg) > 3.0 {
        slipping.append((profile.displayName, betaDeg))
    }
    let spreadDeg = r.spread * 180.0 / .pi
    if spreadDeg > 2.0 {
        oscillating.append((profile.displayName, spreadDeg))
    }
    print(String(
        format: "%-28@ %5.1f° %5.1f° %6.2f° %6.2f° %6.3f %5.0f%%",
        profile.displayName as NSString,
        commanded, bankRad * 180.0 / .pi, betaDeg, spreadDeg, r.rudder, rateRatio * 100.0
    ))
}

print("")
print("Measured \(measured) fixed-wing profiles.")
if !oscillating.isEmpty {
    print("Sideslip is not settling — peak-to-peak beyond 2 deg means a limit cycle, not a skid:")
    for (name, spread) in oscillating.sorted(by: { $0.1 > $1.1 }) {
        print(String(format: "  %-28@ %6.2f deg p-p", name as NSString, spread))
    }
    print("")
}
if slipping.isEmpty {
    print("PASS: every automatic turn settled inside 3 deg of sideslip.")
} else {
    print("Sideslip beyond 3 deg in an automatic turn — the rudder is not coordinating these:")
    for (name, beta) in slipping.sorted(by: { abs($0.1) > abs($1.1) }) {
        print(String(format: "  %-28@ %6.2f deg", name as NSString, beta))
    }
}
