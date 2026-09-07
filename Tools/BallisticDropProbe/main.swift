import Foundation
import simd

// Headless check of released-payload ballistics.
//
// Everything that used to leave an aircraft fell on a hand-written `s = ½gt²` curve with its
// horizontal position frozen at the release point. This probe measures what the real integrator
// does instead: how far downrange a drop actually lands for a given release speed, how much of
// that is the carrier's velocity versus the wind, and how much difference air drag makes at the
// altitudes these missions are flown at.
//
// The first block is the one that matters for trusting the rest: with drag switched off the
// integrator must reproduce textbook vacuum ballistics exactly, or nothing below it means anything.
//
// Usage: Tools/BallisticDropProbe/run.sh

let runtime = BallisticProjectileRuntime()
let still = BallisticEnvironment.standardStill

/// The whole life of one drop.
struct DropOutcome {
    let impact: BallisticImpact
    let firstContact: SIMD3<Float>
    let bounceCount: Int
}

/// Runs one drop to impact and reports it. Uses the real tick loop, not the predictor, so what is
/// measured here is what a mission would experience.
func dropOutcome(
    descriptor: BallisticDescriptor,
    releaseAltitude: Float,
    carrierVelocity: SIMD3<Float>,
    wind: SIMD3<Float> = .zero,
    surface: BallisticSurfaceProbe = FlatGroundBallisticSurfaceProbe()
) -> DropOutcome? {
    let local = BallisticProjectileRuntime()
    let environment = BallisticEnvironment(atmosphere: .standard, windVector: wind)
    local.launch(
        kind: .fireCapsule(.medium),
        descriptor: descriptor,
        position: SIMD3<Float>(0.0, releaseAltitude, 0.0),
        carrierVelocity: carrierVelocity,
        surfaceProbe: surface
    )

    let dt: Float = 1.0 / 60.0
    var firstContact: SIMD3<Float>?
    var iterations = 0
    while !local.isEmpty, iterations < 20_000 {
        let result = local.update(deltaTime: dt, environment: environment, surfaceProbe: surface)
        if firstContact == nil, let bounce = result.bounces.first {
            firstContact = bounce.position
        }
        if let impact = result.impacts.first {
            return DropOutcome(
                impact: impact,
                firstContact: firstContact ?? impact.position,
                bounceCount: impact.bounceCount
            )
        }
        if !result.abandoned.isEmpty { return nil }
        iterations += 1
    }
    return nil
}

func drop(
    descriptor: BallisticDescriptor,
    releaseAltitude: Float,
    carrierVelocity: SIMD3<Float>,
    wind: SIMD3<Float> = .zero,
    surface: BallisticSurfaceProbe = FlatGroundBallisticSurfaceProbe()
) -> BallisticImpact? {
    dropOutcome(
        descriptor: descriptor,
        releaseAltitude: releaseAltitude,
        carrierVelocity: carrierVelocity,
        wind: wind,
        surface: surface
    )?.impact
}

func vacuumDescriptor(massKg: Float) -> BallisticDescriptor {
    BallisticDescriptor(massKg: massKg, dragCoefficient: 0.0, referenceAreaSqM: 0.01)
}

print("=== Ballistic drop probe ===")
print("")

// MARK: - Integrator validation

print("--- integrator vs vacuum ballistics (drag disabled) ---")
print("  h(m)   t_sim    t_exact    v_sim    v_exact    range_sim  range_exact")
var integratorWorstError: Float = 0.0
for height in [20.0, 50.0, 100.0, 300.0] as [Float] {
    for forwardSpeed in [0.0, 15.0] as [Float] {
        guard let impact = drop(
            descriptor: vacuumDescriptor(massKg: 2.25),
            releaseAltitude: height,
            carrierVelocity: SIMD3<Float>(forwardSpeed, 0.0, 0.0)
        ) else {
            print(String(format: "  %5.0f   NO IMPACT", height))
            continue
        }
        let exactTime = sqrt(2.0 * height / AtmosphereModel.gravityMps2)
        let exactSpeed = sqrt(
            2.0 * AtmosphereModel.gravityMps2 * height + forwardSpeed * forwardSpeed
        )
        let exactRange = forwardSpeed * exactTime
        let simRange = simd_length(SIMD2<Float>(impact.position.x, impact.position.z))
        print(String(
            format: "  %5.0f   %6.3f   %6.3f    %6.2f   %6.2f     %8.2f   %8.2f",
            height, impact.flightTimeSeconds, exactTime,
            impact.speedMps, exactSpeed, simRange, exactRange
        ))
        integratorWorstError = max(integratorWorstError, abs(simRange - exactRange))
        integratorWorstError = max(integratorWorstError, abs(impact.speedMps - exactSpeed))
    }
}
print(String(format: "  worst deviation from the closed form: %.4f", integratorWorstError))
print(integratorWorstError < 0.05
      ? "  PASS — integrator reproduces vacuum ballistics"
      : "  FAIL — integrator does not match the closed form")
print("")

// MARK: - What the payloads are

print("--- payload ballistic descriptors ---")
print("  object                mass    Cd     area      Cd·A/m    v_term")
for size in FireCapsuleSize.allCases {
    let d = size.ballisticDescriptor
    print(String(
        format: "  capsule %-12s  %5.2f  %4.2f  %7.4f  %8.5f  %6.1f",
        (size.rawValue as NSString).utf8String!, d.massKg, d.dragCoefficient,
        d.referenceAreaSqM, d.dragAreaPerMass,
        d.terminalVelocity(airDensity: AtmosphereModel.seaLevelDensity)
    ))
}
for type in [PayloadType.cargoBox, .rescuePack, .sensorModule] {
    let d = type.ballisticDescriptor(massKg: type.defaultMass)
    print(String(
        format: "  %-20s  %5.2f  %4.2f  %7.4f  %8.5f  %6.1f",
        (type.rawValue as NSString).utf8String!, d.massKg, d.dragCoefficient,
        d.referenceAreaSqM, d.dragAreaPerMass,
        d.terminalVelocity(airDensity: AtmosphereModel.seaLevelDensity)
    ))
}
print("")

// MARK: - How much drag actually matters

print("--- drag vs vacuum, medium capsule, released from a hover ---")
print("  h(m)   t_drag  t_vacuum   v_drag  v_vacuum   speed error if drag ignored")
for height in [30.0, 60.0, 100.0, 300.0] as [Float] {
    guard let real = drop(
        descriptor: FireCapsuleSize.medium.ballisticDescriptor,
        releaseAltitude: height,
        carrierVelocity: .zero
    ), let vacuum = drop(
        descriptor: vacuumDescriptor(massKg: FireCapsuleSize.medium.massKg),
        releaseAltitude: height,
        carrierVelocity: .zero
    ) else { continue }
    let error = (vacuum.speedMps - real.speedMps) / max(0.01, real.speedMps) * 100.0
    print(String(
        format: "  %5.0f  %6.2f   %6.2f    %6.2f   %6.2f     %+6.1f%%",
        height, real.flightTimeSeconds, vacuum.flightTimeSeconds,
        real.speedMps, vacuum.speedMps, error
    ))
}
print("")

// MARK: - The error the old drop path had

print("--- downrange miss the frozen-XZ drop path produced ---")
print("  (distance from the point directly under the aircraft at release)")
print("  h(m)  speed  wind    miss(m)   t(s)   v_impact")
for height in [30.0, 60.0, 100.0] as [Float] {
    for speed in [0.0, 5.0, 10.0, 15.0, 20.0] as [Float] {
        for windSpeed in [0.0, 10.0] as [Float] {
            guard let impact = drop(
                descriptor: FireCapsuleSize.medium.ballisticDescriptor,
                releaseAltitude: height,
                carrierVelocity: SIMD3<Float>(speed, 0.0, 0.0),
                wind: SIMD3<Float>(0.0, 0.0, windSpeed)
            ) else { continue }
            let miss = simd_length(SIMD2<Float>(impact.position.x, impact.position.z))
            print(String(
                format: "  %4.0f  %5.1f  %4.1f   %7.2f  %5.2f   %6.2f",
                height, speed, windSpeed, miss, impact.flightTimeSeconds, impact.speedMps
            ))
        }
    }
}
print("")

// MARK: - Wind alone

print("--- wind-only drift, medium capsule released from a hover ---")
print("  h(m)  wind   drift(m)")
for height in [30.0, 60.0, 100.0] as [Float] {
    for windSpeed in [5.0, 10.0, 15.0] as [Float] {
        guard let impact = drop(
            descriptor: FireCapsuleSize.medium.ballisticDescriptor,
            releaseAltitude: height,
            carrierVelocity: .zero,
            wind: SIMD3<Float>(windSpeed, 0.0, 0.0)
        ) else { continue }
        print(String(
            format: "  %4.0f  %4.1f   %8.2f",
            height, windSpeed, simd_length(SIMD2<Float>(impact.position.x, impact.position.z))
        ))
    }
}
print("")

// MARK: - Structures and water

print("--- impact surfaces ---")
let rooftop = FlatGroundBallisticSurfaceProbe(
    groundHeight: 0.0,
    boxes: [
        // A 20 m building 40 m downrange, so a fast release lands on the roof and a hover does not.
        FlatGroundBallisticSurfaceProbe.Box(
            minimum: SIMD2<Float>(30.0, -20.0),
            maximum: SIMD2<Float>(60.0, 20.0),
            topHeight: 20.0
        )
    ]
)
for speed in [0.0, 15.0] as [Float] {
    guard let impact = drop(
        descriptor: FireCapsuleSize.medium.ballisticDescriptor,
        releaseAltitude: 60.0,
        carrierVelocity: SIMD3<Float>(speed, 0.0, 0.0),
        surface: rooftop
    ) else { continue }
    let surface = impact.position.y > 1.0 ? "ROOFTOP" : "ground"
    print(String(
        format: "  release at 60 m, %4.1f m/s → x %6.2f, y %5.2f  (%@)",
        speed, impact.position.x, impact.position.y, surface
    ))
}

let river = FlatGroundBallisticSurfaceProbe(groundHeight: -4.0, waterLevel: 0.0)
if let impact = drop(
    descriptor: FireCapsuleSize.medium.ballisticDescriptor,
    releaseAltitude: 40.0,
    carrierVelocity: .zero,
    surface: river
) {
    print(String(
        format: "  release over water          → y %5.2f, isWater %@",
        impact.position.y, impact.isWater ? "true" : "false"
    ))
}
print("")

// MARK: - Predictor agreement

print("--- predictor (aiming reticle) vs the flown trajectory ---")
print("  the reticle runs a coarser step; this is the error a pilot would aim with")
print("  h(m)  speed   flown(m)   predicted(m)   error(m)")
var worstPredictionError: Float = 0.0
for height in [30.0, 60.0, 100.0] as [Float] {
    for speed in [0.0, 10.0, 20.0] as [Float] {
        let surface = FlatGroundBallisticSurfaceProbe()
        guard let impact = drop(
            descriptor: FireCapsuleSize.medium.ballisticDescriptor,
            releaseAltitude: height,
            carrierVelocity: SIMD3<Float>(speed, 0.0, 0.0),
            surface: surface
        ) else { continue }
        let prediction = runtime.predictImpact(
            descriptor: FireCapsuleSize.medium.ballisticDescriptor,
            position: SIMD3<Float>(0.0, height, 0.0),
            carrierVelocity: SIMD3<Float>(speed, 0.0, 0.0),
            environment: still,
            surfaceProbe: surface
        )
        let flown = simd_length(SIMD2<Float>(impact.position.x, impact.position.z))
        let predicted = simd_length(SIMD2<Float>(prediction.position.x, prediction.position.z))
        let error = abs(flown - predicted)
        worstPredictionError = max(worstPredictionError, error)
        print(String(
            format: "  %4.0f  %5.1f   %8.2f   %12.2f   %8.3f",
            height, speed, flown, predicted, error
        ))
    }
}
print(String(format: "  worst reticle error: %.3f m", worstPredictionError))
print(worstPredictionError < 1.0
      ? "  PASS — reticle is accurate to under a metre"
      : "  FAIL — reticle would mislead the pilot")
print("")

// MARK: - Parachute

print("--- recovery parachute (rescue pack) ---")
print("  the canopy is what makes a drop survivable; without it the pack arrives at ~30 m/s")
print("  h(m)  speed   canopy?   v_impact   t(s)   downrange(m)")
for height in [40.0, 80.0, 150.0] as [Float] {
    for withCanopy in [false, true] {
        let mass = PayloadType.rescuePack.defaultMass
        let descriptor = withCanopy
            ? BallisticDescriptor(massKg: mass, shape: .softPack,
                                  parachute: .standardCargo(massKg: mass))
            : BallisticDescriptor(massKg: mass, shape: .softPack)
        guard let impact = drop(
            descriptor: descriptor,
            releaseAltitude: height,
            carrierVelocity: SIMD3<Float>(12.0, 0.0, 0.0)
        ) else { continue }
        print(String(
            format: "  %4.0f  %5.1f   %-7@   %7.2f  %5.2f   %10.2f",
            height, 12.0, withCanopy ? "yes" : "no" as NSString,
            impact.speedMps, impact.flightTimeSeconds,
            simd_length(SIMD2<Float>(impact.position.x, impact.position.z))
        ))
    }
}
let canopyMass = PayloadType.rescuePack.defaultMass
let canopied = drop(
    descriptor: BallisticDescriptor(massKg: canopyMass, shape: .softPack,
                                    parachute: .standardCargo(massKg: canopyMass)),
    releaseAltitude: 80.0,
    carrierVelocity: .zero
)
print(canopied.map { $0.speedMps < 8.0 } == true
      ? "  PASS — canopy brings the pack down under 8 m/s"
      : "  FAIL — canopy is not doing its job")
print("")

// MARK: - Bouncing

print("--- bounce behaviour on impact ---")
print("  a crate skips; a water capsule bursts where it lands; a soft pack barely moves")
for (label, descriptor) in [
    ("cargo crate", BallisticDescriptor(massKg: 3.0, shape: .crate)),
    ("water capsule", FireCapsuleSize.medium.ballisticDescriptor),
    ("rescue pack (no canopy)", BallisticDescriptor(massKg: 2.2, shape: .softPack)),
    ("debris fragment", BallisticDescriptor(massKg: 0.8, shape: .debris))
] {
    guard let outcome = dropOutcome(
        descriptor: descriptor,
        releaseAltitude: 40.0,
        carrierVelocity: SIMD3<Float>(12.0, 0.0, 0.0)
    ) else { continue }
    let skid = simd_length(
        SIMD2<Float>(outcome.impact.position.x - outcome.firstContact.x,
                     outcome.impact.position.z - outcome.firstContact.z)
    )
    print(String(
        format: "  %-24@ restitution %.2f → %d bounce(s), skidded %6.2f m past first contact, settled at %.1f m/s",
        label as NSString, descriptor.restitution, outcome.bounceCount, skid, outcome.impact.speedMps
    ))
}
print("")

// MARK: - Walls in procedural scenes

print("--- procedural obstacle segment test ---")
print("  the column query alone reports a wall strike on the roof; the prism test finds the wall")
let wall = CollisionObstacle(
    id: UUID(),
    center: SIMD3<Float>(40.0, 10.0, 0.0),
    radius: 22.0,
    source: "probe.building",
    baseY: 0.0,
    topY: 20.0,
    planarHalfExtents: SIMD2<Float>(10.0, 20.0),
    yawRadians: 0.0,
    meshTriangles: nil,
    planarFootprint: nil
)
for (label, from, to) in [
    ("level flight into the façade", SIMD3<Float>(20.0, 10.0, 0.0), SIMD3<Float>(45.0, 9.0, 0.0)),
    ("descending onto the roof", SIMD3<Float>(38.0, 24.0, 0.0), SIMD3<Float>(40.0, 18.0, 0.0)),
    ("passing safely overhead", SIMD3<Float>(20.0, 30.0, 0.0), SIMD3<Float>(60.0, 26.0, 0.0))
] as [(String, SIMD3<Float>, SIMD3<Float>)] {
    if let hit = BallisticObstacleIntersection.intersect(from: from, to: to, obstacle: wall) {
        let face = abs(hit.normal.y) > 0.5 ? "ROOF" : "WALL"
        print(String(
            format: "  %-30@ → hit at (%.1f, %.1f) as %@",
            label as NSString, hit.point.x, hit.point.y, face as NSString
        ))
    } else {
        print(String(format: "  %-30@ → clear air", label as NSString))
    }
}
print("")

// MARK: - Determinism

print("--- determinism (LAN replication and replay depend on this) ---")
let sharedID = UUID()
func runOnce() -> SIMD3<Float>? {
    let local = BallisticProjectileRuntime()
    let surface = FlatGroundBallisticSurfaceProbe()
    local.launch(
        id: sharedID,
        kind: .fireCapsule(.medium),
        descriptor: FireCapsuleSize.medium.ballisticDescriptor,
        position: SIMD3<Float>(0, 70, 0),
        carrierVelocity: SIMD3<Float>(14, -1, 3),
        surfaceProbe: surface
    )
    var iterations = 0
    while !local.isEmpty, iterations < 20_000 {
        let result = local.update(
            deltaTime: 1.0 / 60.0,
            environment: BallisticEnvironment(atmosphere: .standard, windVector: SIMD3<Float>(4, 0, -2)),
            surfaceProbe: surface
        )
        if let impact = result.impacts.first { return impact.position }
        iterations += 1
    }
    return nil
}
let runA = runOnce()
let runB = runOnce()
if let runA, let runB {
    let delta = simd_length(runA - runB)
    print(String(format: "  two runs of the same release differ by %.6f m", delta))
    print(delta < 1e-5
          ? "  PASS — identical initial conditions give identical impacts"
          : "  FAIL — replication and replay would diverge")
} else {
    print("  FAIL — no impact")
}
