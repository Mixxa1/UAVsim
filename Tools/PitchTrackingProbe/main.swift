import Foundation
import simd

// Headless pitch-tracking probe.
//
// The operator's logs show commanded and achieved pitch in antiphase during a sustained banked
// turn — `pitchCmd=11.7` against `pitchActual=-3.7` — and the altitude loop above it limit-cycling
// at ±9 m/s. Before redesigning that loop, this asks whether its *plant* is the problem: given a
// commanded pitch attitude, does the airframe actually reach it, and how fast?
//
// The pitch-rate damping term in `stepFixedWingAerodynamic` was raised 0.4 → 0.9 earlier in this
// session to cure a launch-phase resonance. A damping term slows the response it stabilises, so it
// is a plausible suspect for an outer loop that has started fighting its own plant. Run this, then
// change the constant, then run it again: the columns below are what changes.
//
//   settled  the pitch actually held, against the 8.0° commanded. Droop is expected — the loop is
//            a P+trim against the airframe's own stiffness — but a large droop means the outer
//            loop must ask for far more than it wants, which is what saturates it.
//   rise     seconds to first reach 90% of the settled value. Lag is what turns an outer loop's
//            correction into an oscillation.
//   overshoot peak past settled, in degrees.
//
// Both level and in a 28° banked turn, because the operator's oscillation only appears in the turn.
//
// Run: Tools/PitchTrackingProbe/run.sh

let repository = LIPODroneModelRepository()
let engine = SimpleDronePhysicsEngine()
let dt: Float = 1.0 / 90.0
let commandedPitchDeg: Float = 8.0

struct Result {
    let settled: Float
    let riseSeconds: Float
    let overshoot: Float
}

func trackPitch(profile: DroneModelProfile, wing: FixedWingParameters, bankDeg: Float) -> Result? {
    let massModel = VehicleMassModel.baseline(for: profile, uavProfile: nil)
    let fuelState: FuelSystemState? = profile.resolvedUAVProfile?.powerplant?.fuel.map {
        .full(capacityKg: $0.usableFuelMassKg, reserveFraction: $0.reserveFraction)
    }
    let backend = FuelPropulsionBackend(
        powerplant: profile.resolvedUAVProfile?.powerplant,
        cruiseSpeedMps: wing.cruiseSpeedMps
    )

    var state = DroneState(
        position: SIMD3<Float>(0, 800, 0),
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

    func step(pitchDeg: Float, ticks: Int, sample: ((Float, Float) -> Void)? = nil) {
        for i in 0..<ticks {
            let control = DroneControlInput(
                targetPosition: SIMD3<Float>(state.position.x, 800, state.position.z),
                targetOrientation: SIMD3<Float>(
                    bankDeg * .pi / 180.0,
                    pitchDeg * .pi / 180.0,
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
            sample?(Float(i) * dt, state.orientation.y * 180.0 / .pi)
        }
    }

    // Establish the bank and let the airframe settle at zero pitch first, so the step that follows
    // measures the pitch loop and not the roll-in transient.
    step(pitchDeg: 0.0, ticks: Int(18.0 / Double(dt)))
    guard state.physicalState == .airborne, state.position.y.isFinite else { return nil }

    var samples: [(Float, Float)] = []
    step(pitchDeg: commandedPitchDeg, ticks: Int(14.0 / Double(dt))) { t, pitch in
        samples.append((t, pitch))
    }
    guard !samples.isEmpty else { return nil }

    // Settled = mean over the last three seconds.
    let tail = samples.filter { $0.0 >= 11.0 }
    let settled = tail.isEmpty ? 0 : tail.map(\.1).reduce(0, +) / Float(tail.count)
    let threshold = settled * 0.9
    let rise = samples.first(where: { $0.1 >= threshold })?.0 ?? -1.0
    let peak = samples.map(\.1).max() ?? settled
    return Result(settled: settled, riseSeconds: rise, overshoot: max(0.0, peak - settled))
}

print("Pitch tracking: commanded \(Int(commandedPitchDeg))° step, level and in a 28° banked turn")
print("")
print(String(
    format: "%-24@ %9@ %8@ %10@ %9@ %8@ %10@",
    "profile" as NSString,
    "lvl set" as NSString, "lvl rise" as NSString, "lvl over" as NSString,
    "trn set" as NSString, "trn rise" as NSString, "trn over" as NSString
))
print(String(repeating: "-", count: 84))

let wanted = ["mq-9b-skyguardian", "mq-9a-reaper", "Hermes 900", "FT5 Łoś"]

for profile in repository.allProfiles where profile.airframeClass == .fixedWing {
    guard wanted.contains(profile.id) || wanted.contains(profile.displayName),
          let wing = profile.fixedWingParameters else { continue }
    guard let level = trackPitch(profile: profile, wing: wing, bankDeg: 0.0),
          let turn = trackPitch(profile: profile, wing: wing, bankDeg: 28.0) else {
        print(String(format: "%-24@  (did not sustain flight)", profile.displayName as NSString))
        continue
    }
    print(String(
        format: "%-24@ %8.1f° %7.2fs %9.1f° %8.1f° %7.2fs %9.1f°",
        profile.displayName as NSString,
        level.settled, level.riseSeconds, level.overshoot,
        turn.settled, turn.riseSeconds, turn.overshoot
    ))
}

print("")
print("Commanded \(Int(commandedPitchDeg))°. A settled value far below it means the outer altitude")
print("loop has to overdrive to get any climb, and a long rise means its correction arrives late —")
print("together those are how an altitude hold turns into a limit cycle.")
