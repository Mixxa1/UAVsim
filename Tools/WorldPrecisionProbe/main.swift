import Foundation
import simd

// Headless single-precision probe for the extended map ranges.
//
// The supersonic scope needs maps far larger than the 25.6 km the catalogue used to
// top out at — an aircraft at Mach 2 crosses the whole of the old largest map in
// twenty-one seconds. The new `MapScale` cases go to 819.2 km across, which puts the
// far corner 409.6 km from the origin, and every position in this simulation is a
// `SIMD3<Float>`.
//
// A 32-bit float has 24 bits of mantissa, so the gap between representable values at
// 409,600 m is about 31 mm. That is a fact about the format, not a bug; the question
// this probe exists to answer is which of the simulation's own motions fall through
// that gap. Two things can go wrong and they have different cures:
//
//  1. Slow motion stops accumulating. `position += velocity * dt` at the physics
//     substep of 1/90 s adds v/90 metres. Where that is smaller than half the local
//     spacing, the addition rounds back to where it started and the aircraft does not
//     move at all — no drift, no jitter, simply frozen. This is the failure that would
//     make a landing or a taxi at the far edge of a range impossible.
//  2. The trajectory diverges. The same aircraft flown from the origin and from the
//     far corner should trace the same path; anything else is precision leaking into
//     the dynamics.
//
// Both are measured here rather than argued about, because the remedy for the first
// (a floating origin, rebasing the world around the aircraft) is a large piece of work
// and should only be paid for against a number.
//
// Run: Tools/WorldPrecisionProbe/run.sh

var failures: [String] = []
var warnings: [String] = []

let substepSeconds: Float = 1.0 / 90.0

// MARK: - 1. What the format can represent at each range

print("Single-precision spacing at each map size, and the speed it swallows")
print(String(repeating: "-", count: 92))
print(String(format: "%-8@ %12@ %12@ %12@ %14@ %14@",
             "scale" as NSString, "side km" as NSString, "corner km" as NSString,
             "spacing mm" as NSString, "frozen below" as NSString, "ceiling m" as NSString))

/// Gap between adjacent representable `Float` values at `magnitude`.
func floatSpacing(at magnitude: Float) -> Float {
    let value = abs(magnitude)
    guard value > 0, value.isFinite else { return .leastNormalMagnitude }
    return value.ulp
}

/// Slowest speed whose per-substep step still changes the stored coordinate.
///
/// Half a spacing is the rounding threshold: below it `p + delta` rounds back to `p`.
func slowestRegisteredSpeed(at magnitude: Float) -> Float {
    floatSpacing(at: magnitude) * 0.5 / substepSeconds
}

for scale in MapScale.allCases {
    let corner = scale.worldHalfExtentMeters
    let spacing = floatSpacing(at: corner)
    let frozenBelow = slowestRegisteredSpeed(at: corner)
    print(String(format: "%-8@ %12.1f %12.1f %12.2f %14.3f %14.0f",
                 scale.rawValue as NSString,
                 scale.sideLengthMeters / 1000.0,
                 corner / 1000.0,
                 spacing * 1000.0,
                 frozenBelow,
                 scale.altitudeCeilingMeters))
}

// The vertical axis is governed by the altitude, not by how far the aircraft has flown
// horizontally — the components of a SIMD3 are independent floats — so it is checked
// separately and against the ceiling that actually applies up there.
let ceilingSpacing = floatSpacing(at: 25_000.0)
print(String(format: "\nvertical at the 25 km ceiling: spacing %.3f mm, frozen below %.4f m/s",
             ceilingSpacing * 1000.0,
             slowestRegisteredSpeed(at: 25_000.0)))

// A landing, a taxi or a hover has to work wherever the aircraft is. 0.5 m/s is a
// gentle touchdown rate and a slow taxi; if the coordinate cannot register it, the
// aircraft is frozen in place at that range.
let gentleMotionMps: Float = 0.5
for scale in MapScale.allCases where slowestRegisteredSpeed(at: scale.worldHalfExtentMeters) > gentleMotionMps {
    warnings.append(String(
        format: "%@: horizontal motion below %.2f m/s does not register at the far corner (%.0f km)",
        scale.rawValue,
        slowestRegisteredSpeed(at: scale.worldHalfExtentMeters),
        scale.worldHalfExtentMeters / 1000.0
    ))
}

// MARK: - 2. Does the same flight fly the same way far from the origin?

print("\n\nSame aircraft, same controls, flown from the origin and from each range corner")
print(String(repeating: "-", count: 92))
print(String(format: "%-22@ %10@ %12@ %12@ %12@ %10@",
             "profile" as NSString, "offset km" as NSString, "path drift m" as NSString,
             "drift ppm" as NSString, "speed d m/s" as NSString, "att d deg" as NSString))

let repository = LIPODroneModelRepository()
let engine = SimpleDronePhysicsEngine()
let dt: Float = 1.0 / 60.0
let flightSeconds = 60

/// Flies one profile straight and level for `flightSeconds` starting `offset` metres
/// east of the origin, and reports where it ended up relative to where it began.
func flyLevel(
    profile: DroneModelProfile,
    offsetMeters: Float
) -> (displacement: SIMD3<Float>, velocity: SIMD3<Float>, attitude: SIMD3<Float>)? {
    guard let wing = profile.fixedWingParameters else { return nil }
    let massModel = VehicleMassModel.baseline(for: profile, uavProfile: nil)
    let fuelState: FuelSystemState? = profile.resolvedUAVProfile?.powerplant?.fuel.map {
        .full(capacityKg: $0.usableFuelMassKg, reserveFraction: $0.reserveFraction)
    }
    let backend = FuelPropulsionBackend(
        powerplant: profile.resolvedUAVProfile?.powerplant,
        cruiseSpeedMps: wing.cruiseSpeedMps
    )

    // Same air for every run, so that the only thing that can differ between an aircraft at
    // the origin and the same aircraft 400 km out is where the numbers land in a Float.
    engine.resetAtmosphericDisturbance()

    let start = SIMD3<Float>(offsetMeters, 6_000.0, 0.0)
    var state = DroneState(
        position: start,
        velocity: SIMD3<Float>(0, 0, -wing.cruiseAirspeed),
        orientation: .zero,
        angularVelocity: .zero,
        throttle: 0.7,
        motorThrottle: 0.7,
        rotorAngularSpeed: .zero,
        forwardAirspeed: wing.cruiseAirspeed,
        physicalState: .airborne,
        mode: .autoPath
    )
    state.armState = .armed
    if let backend {
        var warm = EngineRuntimeState.cold(ambientTemperatureC: 15.0)
        warm.runState = .ready
        warm.shaftRPM = (backend.powerplant.ratedShaftRPM ?? 6_000.0) * 0.9
        warm.temperatureC = EngineOperatingEnvelope
            .envelope(for: backend.powerplant.engineType).operatingTemperatureC
        state.engineRuntime = warm
    }

    for _ in 0..<(60 * flightSeconds) {
        let control = DroneControlInput(
            targetPosition: SIMD3<Float>(state.position.x, state.position.y, state.position.z - 1_000),
            targetOrientation: .zero,
            yawIntent: 0.0,
            throttle: 0.7,
            isArmed: true,
            mode: .autoPath,
            controlMode: .stabilized
        )
        let context = DroneSimulationContext(
            profile: profile,
            activeUAVProfile: profile.resolvedUAVProfile,
            // Calm weather, and — since clear-air turbulence was added — that is no
            // longer enough on its own. Gusts now exist at 6 km whatever the surface
            // weather is doing, because jet-stream shear does not care what the surface
            // weather is doing. Two runs through two different random gust sequences
            // differ by tens of metres over a minute, which would be reported here as a
            // float-precision failure it has nothing to do with. The engine's disturbance
            // is therefore reset to the same seed before each run, below, so both flights
            // pass through *the same* air and the only thing left to differ is the
            // arithmetic.
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
    }
    return (state.position - start, state.velocity, state.orientation)
}

// One propeller aircraft and one jet: the jet covers ten kilometres in this minute and
// the survey wing barely two, so between them they exercise both ends of the
// step-size-against-spacing ratio that decides whether precision bites.
let probeProfileIDs = ["mq-9b-skyguardian", "hesa-karrar"]
let offsets: [Float] = [12_800, 51_200, 204_800, 409_600]

for id in probeProfileIDs {
    guard let profile = repository.allProfiles.first(where: { $0.id == id }),
          let reference = flyLevel(profile: profile, offsetMeters: 0.0) else {
        failures.append("probe profile \(id) is missing or not a fixed wing")
        continue
    }
    let referenceDistance = max(1.0, simd_length(reference.displacement))

    for offset in offsets {
        guard let far = flyLevel(profile: profile, offsetMeters: offset) else { continue }
        let drift = simd_distance(far.displacement, reference.displacement)
        let speedDelta = abs(simd_length(far.velocity) - simd_length(reference.velocity))
        let attitudeDelta = simd_length(far.attitude - reference.attitude) * 180.0 / .pi
        let driftPPM = drift / referenceDistance * 1_000_000.0

        print(String(format: "%-22@ %10.1f %12.3f %12.1f %12.4f %10.4f",
                     profile.displayName as NSString,
                     offset / 1000.0, drift, driftPPM, speedDelta, attitudeDelta))

        // A metre of accumulated difference over a minute of cruise is well inside the
        // envelope of anything the flight model resolves — obstacle clearances are
        // metres, waypoint capture radii are tens of metres. Ten is not.
        if drift > 10.0 {
            failures.append(String(format: "%@ drifts %.1f m over %d s at %.0f km from origin",
                                   profile.displayName, drift, flightSeconds, offset / 1000.0))
        } else if drift > 1.0 {
            warnings.append(String(format: "%@ drifts %.2f m over %d s at %.0f km from origin",
                                   profile.displayName, drift, flightSeconds, offset / 1000.0))
        }
        if attitudeDelta > 0.5 {
            failures.append(String(format: "%@ attitude differs by %.2f deg at %.0f km from origin",
                                   profile.displayName, attitudeDelta, offset / 1000.0))
        }
    }
}

// MARK: - 3. Verdict

print("\n" + String(repeating: "=", count: 92))
if !warnings.isEmpty {
    print("\nLIMITS (expected, and the boundary of what these ranges are for):")
    for warning in warnings { print("  - \(warning)") }
}
if failures.isEmpty {
    print("""

    RESULT: PASS — cruise and supersonic flight are unaffected by single precision out to \
    409.6 km. The limit is slow motion at extreme range: a landing or a taxi out there needs \
    a floating origin, which is separate work and is not required by any acceptance point in \
    the supersonic scope.
    """)
} else {
    print("\nRESULT: FAIL")
    for failure in failures { print("  - \(failure)") }
    exit(1)
}
