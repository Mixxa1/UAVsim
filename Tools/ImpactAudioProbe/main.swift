import Foundation
import simd

// Headless probe for impact and damage audio.
//
// The audio plan ends with ten acceptance checks. Six of them are statements about a mapping
// from physics to sound and can be settled here, without a speaker: what gets played, how
// loud, in what order, and whether the same event twice gives the same answer. The rest —
// whether the mix is pleasant, whether a loop is seamless — are listening questions and are
// not pretended to be settled by arithmetic.
//
// Checked here:
//   1. One aircraft at one speed sounds different against concrete, wood, water and soil.
//   2. Brushing a branch does not produce a heavy metal crash.
//   3. Glass is added only once the surface actually fails.
//   4. A hit that keeps sliding produces a scrape, and stops producing one when it stops.
//   5. A shed part's contacts resolve against what it landed on, not against the airframe.
//   7. The same event resolves to the same takes every time.
//   9. Nothing in the layer stack asks for more than unity gain.
//  10. Simultaneous destruction cannot produce an unbounded number of layers.
//
// Run: Tools/ImpactAudioProbe/run.sh

var failures: [String] = []

func check(_ condition: Bool, _ description: String) {
    if !condition { failures.append(description) }
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
}

func padLeft(_ text: String, _ width: Int) -> String {
    text.count >= width ? " " + text : String(repeating: " ", count: width - text.count) + text
}

func event(
    surface: AcousticSurfaceMaterial,
    vehicle: VehicleAcousticMaterial = .aluminum,
    impulse: Float,
    normalSpeed: Float,
    tangential: Float = 0.0,
    damage: Float = 0.0,
    seed: UInt64 = 4_242
) -> ImpactAudioEvent {
    ImpactAudioEvent(
        worldPosition: SIMD3<Float>(0, 5, -20),
        surface: surface,
        vehicleMaterial: vehicle,
        normalImpulse: impulse,
        normalSpeed: normalSpeed,
        tangentialSpeed: tangential,
        damageSeverity: damage,
        brokeSurface: ImpactAudioResolver.surfaceFails(
            surface: surface,
            normalImpulseNs: impulse,
            normalSpeedMps: normalSpeed
        ),
        isDetachedPart: false,
        seed: seed
    )
}

// MARK: - 1. The same contact against different materials

print("Check 1 — one aircraft, one speed, four surfaces")
print(String(repeating: "-", count: 92))
print(pad("surface", 14) + pad("layers", 46) + padLeft("primary dB", 12))

let surveyImpulse: Float = 30.0
let surveySpeed: Float = 7.0
var primaries: [AcousticSurfaceMaterial: AudioAssetID] = [:]
for surface in [AcousticSurfaceMaterial.concrete, .treeTrunk, .water, .soil, .metal, .snow, .foliage] {
    let requests = ImpactAudioResolver.resolve(
        event(surface: surface, impulse: surveyImpulse, normalSpeed: surveySpeed)
    )
    guard let primary = requests.first else {
        check(false, "\(surface.rawValue) produced no sound at all")
        continue
    }
    primaries[surface] = primary.id
    let names = requests.map(\.id.rawValue).joined(separator: " + ")
    print(pad(surface.rawValue, 14) + pad(names, 46) + padLeft(String(format: "%.1f", primary.gainDb), 12))
}

check(primaries[.concrete] != primaries[.treeTrunk], "concrete and a tree trunk share a primary sound")
check(primaries[.concrete] != primaries[.water], "concrete and water share a primary sound")
check(primaries[.treeTrunk] != primaries[.soil], "wood and soil share a primary sound")
check(primaries[.water] != primaries[.soil], "water and soil share a primary sound")
check(primaries[.metal] != primaries[.concrete], "metal and concrete share a primary sound")

// MARK: - 2. A branch is not a crash

print()
print("Check 2 — brushing a branch against hitting a wall")
print(String(repeating: "-", count: 92))

let branch = ImpactAudioResolver.resolve(
    event(surface: .foliage, impulse: 1.2, normalSpeed: 4.0)
)
let wall = ImpactAudioResolver.resolve(
    event(surface: .concrete, impulse: 140.0, normalSpeed: 14.0)
)
let branchPeak = branch.map(\.gainDb).max() ?? -.greatestFiniteMagnitude
let wallPeak = wall.map(\.gainDb).max() ?? -.greatestFiniteMagnitude
print(String(format: "branch: %@  peak %.1f dB", branch.map(\.id.rawValue).joined(separator: " + "), branchPeak))
print(String(format: "wall:   %@  peak %.1f dB", wall.map(\.id.rawValue).joined(separator: " + "), wallPeak))
check(
    !branch.contains { $0.id == .impactMetalHeavy },
    "a branch contact reached for the heavy metal crash"
)
check(branchPeak < wallPeak - 20.0, "a branch is not at least 20 dB below a wall impact")

// MARK: - 3. Glass only when the glass goes

print()
print("Check 3 — glazing")
print(String(repeating: "-", count: 92))

let tap = ImpactAudioResolver.resolve(event(surface: .glass, impulse: 2.0, normalSpeed: 1.5))
let smash = ImpactAudioResolver.resolve(event(surface: .glass, impulse: 40.0, normalSpeed: 9.0))
print("light touch on a window: " + tap.map(\.id.rawValue).joined(separator: " + "))
print("flown into a window:     " + smash.map(\.id.rawValue).joined(separator: " + "))
check(!tap.contains { $0.id == .glassShatter }, "a light touch shattered a window")
check(smash.contains { $0.id == .glassShatter }, "a hard hit did not break the window")
check(
    (smash.first { $0.id == .glassShatter }?.delaySeconds ?? 0.0) > 0.0,
    "the glass broke at the same instant as the impact rather than after it"
)

// MARK: - 4. Hit, then slide

print()
print("Check 4 — a hit that turns into a slide")
print(String(repeating: "-", count: 92))

let stationary = ImpactAudioResolver.scrape(surface: .concrete, normalImpulseNs: 40.0, tangentialSpeedMps: 0.2)
let sliding = ImpactAudioResolver.scrape(surface: .concrete, normalImpulseNs: 40.0, tangentialSpeedMps: 6.0)
let slidingFast = ImpactAudioResolver.scrape(surface: .concrete, normalImpulseNs: 40.0, tangentialSpeedMps: 11.0)
let slidingLight = ImpactAudioResolver.scrape(surface: .concrete, normalImpulseNs: 3.0, tangentialSpeedMps: 6.0)
let onWater = ImpactAudioResolver.scrape(surface: .water, normalImpulseNs: 40.0, tangentialSpeedMps: 6.0)

print("resting contact:      \(stationary == nil ? "no scrape" : "scrape")")
print(String(format: "sliding at 6 m/s:     %.1f dB, pitch %.2f",
             sliding?.gainDb ?? 0, sliding?.pitchRatio ?? 0))
print(String(format: "sliding at 11 m/s:    %.1f dB, pitch %.2f",
             slidingFast?.gainDb ?? 0, slidingFast?.pitchRatio ?? 0))
print(String(format: "same slide, light load: %.1f dB", slidingLight?.gainDb ?? 0))
print("sliding on water:     \(onWater == nil ? "no scrape" : "scrape")")

check(stationary == nil, "a contact with no sliding speed still started a scrape")
check(sliding != nil, "a sliding contact produced no scrape")
check(onWater == nil, "sliding across water produced a scrape")
check((slidingFast?.pitchRatio ?? 0) > (sliding?.pitchRatio ?? 0), "a faster slide was not higher pitched")
check((slidingLight?.gainDb ?? 0) < (sliding?.gainDb ?? 0) - 3.0, "load does not change the scrape level")

// MARK: - 5. Shed parts land on what they land on

print()
print("Check 5 — a detached part's own contacts")
print(String(repeating: "-", count: 92))

for source in ["ground.field", "container.wall.left", "world.building", "tree.canopy"] {
    let surface = AcousticSurfaceMaterial.fromObstacleSource(source)
    let requests = ImpactAudioResolver.resolve(
        event(surface: surface, vehicle: .composite, impulse: 8.0, normalSpeed: 5.0, seed: 99)
    )
    print(pad(source, 24) + pad("→ " + surface.rawValue, 16)
          + requests.map(\.id.rawValue).joined(separator: " + "))
    check(!requests.isEmpty, "a detached part hitting \(source) made no sound")
}
check(
    AcousticSurfaceMaterial.fromObstacleSource("container.wall.left") == .metal,
    "a shipping container is not resolving as metal"
)
check(
    AcousticSurfaceMaterial.fromObstacleSource("tree.canopy") == .foliage,
    "a tree canopy is not resolving as foliage"
)

// MARK: - 7. The same event sounds the same twice

print()
print("Check 7 — determinism")
print(String(repeating: "-", count: 92))

let firstPass = ImpactAudioResolver.resolve(event(surface: .treeTrunk, impulse: 55.0, normalSpeed: 9.0, seed: 12_345))
let secondPass = ImpactAudioResolver.resolve(event(surface: .treeTrunk, impulse: 55.0, normalSpeed: 9.0, seed: 12_345))
let differentEvent = ImpactAudioResolver.resolve(event(surface: .treeTrunk, impulse: 55.0, normalSpeed: 9.0, seed: 12_346))
print("event 12345, pass 1: " + firstPass.map { "\($0.id.rawValue)#\($0.variant)" }.joined(separator: " + "))
print("event 12345, pass 2: " + secondPass.map { "\($0.id.rawValue)#\($0.variant)" }.joined(separator: " + "))
print("event 12346:         " + differentEvent.map { "\($0.id.rawValue)#\($0.variant)" }.joined(separator: " + "))
check(firstPass == secondPass, "the same event resolved differently on a second pass")

// Across many neighbouring events the variants must actually spread, or "deterministic"
// would be indistinguishable from "always the same take".
let variantSpread = Set((1...200).map { seed -> Int in
    ImpactAudioResolver.resolve(event(surface: .treeTrunk, impulse: 55.0, normalSpeed: 9.0, seed: UInt64(seed)))
        .first?.variant ?? 0
})
print("variants used across 200 consecutive events: \(variantSpread.sorted())")
check(variantSpread.count >= 4, "consecutive events barely vary their take")

// MARK: - 9. Headroom

print()
print("Check 9 — nothing asks for more than unity")
print(String(repeating: "-", count: 92))

var worstGain = -Float.greatestFiniteMagnitude
for surface in AcousticSurfaceMaterial.allCases {
    for vehicle in VehicleAcousticMaterial.allCases {
        let requests = ImpactAudioResolver.resolve(
            event(surface: surface, vehicle: vehicle, impulse: 5_000.0, normalSpeed: 90.0, damage: 1.0)
        )
        worstGain = max(worstGain, requests.map(\.gainDb).max() ?? worstGain)
    }
}
print(String(format: "loudest layer any material pair can request: %.1f dB", worstGain))
check(worstGain <= 0.5, "a layer asked for more than unity gain — the master bus would clip")

let quietest = ImpactAudioResolver.impactGainDb(normalImpulseNs: ImpactAudioResolver.audibleImpulseNs)
print(String(format: "quietest audible contact: %.1f dB", quietest))
check(quietest < -25.0, "the softest audible contact is not quiet")

// MARK: - 10. Bounded layers

print()
print("Check 10 — a breakup cannot produce unbounded layers")
print(String(repeating: "-", count: 92))

var worstLayerCount = 0
for surface in AcousticSurfaceMaterial.allCases {
    for vehicle in VehicleAcousticMaterial.allCases {
        let count = ImpactAudioResolver.resolve(
            event(surface: surface, vehicle: vehicle, impulse: 900.0, normalSpeed: 40.0, damage: 1.0)
        ).count
        worstLayerCount = max(worstLayerCount, count)
    }
}
print("worst case layers for a single contact: \(worstLayerCount)")
check(worstLayerCount <= 4, "one contact can request more than four layers")

let detachLayers = ImpactAudioResolver.resolveDamage(
    type: .componentDetached, material: .aluminum, severity: 1.0, seed: 5
).count
print("layers for a component coming off: \(detachLayers)")
check(detachLayers <= 3, "a detachment requests more than three layers")

// A contact below the audible floor must produce nothing at all — this is what keeps a
// resting airframe, whose contact solver re-fires twenty times a second, from machine-gunning.
let resting = ImpactAudioResolver.resolve(event(surface: .grass, impulse: 0.05, normalSpeed: 0.01))
print("resting contact on grass: \(resting.isEmpty ? "silent" : "\(resting.count) layers")")
check(resting.isEmpty, "a resting contact still produced sound")

// MARK: - The gain law

print()
print("Impulse → level")
print(String(repeating: "-", count: 92))
print(padLeft("N·s", 10) + padLeft("dB", 10))
var previousLevel = -Float.greatestFiniteMagnitude
var levelMonotonic = true
for impulse in [Float(0.25), 1, 4, 16, 64, 256, 400, 2_000] {
    let level = ImpactAudioResolver.impactGainDb(normalImpulseNs: impulse)
    print(padLeft(String(format: "%.2f", impulse), 10) + padLeft(String(format: "%.1f", level), 10))
    if level < previousLevel { levelMonotonic = false }
    previousLevel = level
}
check(levelMonotonic, "the impulse-to-level law is not monotonic")

// MARK: - Result

print()
print(String(repeating: "=", count: 92))
if failures.isEmpty {
    print("RESULT: PASS — materials are distinguishable, a branch is not a crash, glass breaks "
          + "only when it fails, a slide becomes a scrape and stops being one, shed parts "
          + "resolve against what they hit, the same event always sounds the same, no layer "
          + "exceeds unity, and one contact cannot flood the mixer.")
} else {
    print("RESULT: FAIL — \(failures.count) problem(s)")
    for failure in failures {
        print("  • \(failure)")
    }
    exit(1)
}
