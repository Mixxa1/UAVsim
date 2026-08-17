import Foundation
import simd

// Route-shape regression for the A* planner on a city block grid.
//
// Every probe so far tests how the aircraft *flies* a route. This one tests the route itself: a
// flight over imported Manhattan produced a first route node 790 m away on a mission whose whole
// four-waypoint path is 678 m, and the aircraft tracked it faithfully — guidance was right, the
// plan was wrong. Three causes give that one symptom and each is fixed elsewhere, so this file
// asserts the properties that separate them, on geometry that is generated here and therefore
// needs no scene, no view model and no flight:
//
//   * a route exists at all when a straight corridor exists;
//   * its length is not absurd against the straight line (detour ratio);
//   * every segment actually clears the buildings it was planned around — a short route that
//     cuts a corner is worse than a long one that does not.
//
// The remaining cause — the planner being handed the wrong goal entirely — lives in the view
// model and cannot be reached from here; `src=` in the flight log covers that one.

private var failures: [String] = []

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        failures.append(message)
        print("FAIL: \(message)")
    }
}

// MARK: City fixture
//
// Regular blocks with streets between them: the layout the planner is expected to thread. Block
// and street sizes are the measured Lower Manhattan order of magnitude (≈60 x 90 m blocks,
// ≈22 m streets), so cell-size and clearance interactions are representative rather than toy.

private let blockSizeX: Float = 60.0
private let blockSizeZ: Float = 90.0
private let streetWidth: Float = 22.0
private let buildingHeight: Float = 80.0

private func cityObstacles(blocksPerSide: Int) -> [CollisionObstacle] {
    var obstacles: [CollisionObstacle] = []
    let pitchX = blockSizeX + streetWidth
    let pitchZ = blockSizeZ + streetWidth
    let span = Float(blocksPerSide - 1) * 0.5
    for ix in 0..<blocksPerSide {
        for iz in 0..<blocksPerSide {
            let cx = (Float(ix) - span) * pitchX
            let cz = (Float(iz) - span) * pitchZ
            obstacles.append(
                CollisionObstacle(
                    id: UUID(),
                    center: SIMD3<Float>(cx, buildingHeight * 0.5, cz),
                    radius: simd_length(SIMD2<Float>(blockSizeX, blockSizeZ)) * 0.5,
                    source: "probe.building",
                    baseY: 0.0,
                    topY: buildingHeight,
                    planarHalfExtents: SIMD2<Float>(blockSizeX * 0.5, blockSizeZ * 0.5),
                    yawRadians: 0.0
                )
            )
        }
    }
    return obstacles
}

/// Distance from a planar point to the nearest building surface. Negative inside a footprint.
private func clearance(_ point: SIMD2<Float>, _ obstacles: [CollisionObstacle]) -> Float {
    obstacles.reduce(Float.greatestFiniteMagnitude) {
        min($0, $1.planarSignedDistance(to: point))
    }
}

/// Worst clearance along a segment, sampled densely. The planner's own segment test is analytic;
/// sampling here keeps the probe honest about what the geometry actually is.
private func segmentClearance(
    _ start: SIMD2<Float>,
    _ end: SIMD2<Float>,
    _ obstacles: [CollisionObstacle]
) -> (clearance: Float, point: SIMD2<Float>) {
    let length = simd_distance(start, end)
    let samples = max(2, Int(length / 0.5))
    var worst = Float.greatestFiniteMagnitude
    var worstPoint = start
    for step in 0...samples {
        let t = Float(step) / Float(samples)
        let point = start + (end - start) * t
        let value = clearance(point, obstacles)
        if value < worst {
            worst = value
            worstPoint = point
        }
    }
    return (worst, worstPoint)
}

/// The width of the passage a point sits in: its two nearest footprints, nearest first.
///
/// A route that clears a wall by little can mean the planner cut a corner, or it can mean the
/// passage is simply that narrow and the route is centred in it. These two numbers tell them apart.
private func passageWidth(
    _ point: SIMD2<Float>,
    _ obstacles: [CollisionObstacle]
) -> (nearest: Float, second: Float) {
    var nearest = Float.greatestFiniteMagnitude
    var second = Float.greatestFiniteMagnitude
    for obstacle in obstacles {
        let distance = obstacle.planarSignedDistance(to: point)
        if distance < nearest {
            second = nearest
            nearest = distance
        } else if distance < second {
            second = distance
        }
    }
    return (nearest, second)
}

private let terrain = TerrainConfiguration(
    preset: .city,
    mapScale: .x64,
    density: 0.5,
    seed: 20260817,
    safeSpawnRadius: 30.0
)

private struct RouteOutcome {
    var status: NavigationPathStatus
    var points: [SIMD3<Float>]
    var length: Float
    var direct: Float
    var worstClearance: Float
    /// The two nearest footprints at the point that scored `worstClearance`.
    var worstPassage: (nearest: Float, second: Float)
    /// Wall time of the search itself. Route repair runs inside it, and this path has stalled the
    /// render thread before, so the cost is measured rather than assumed.
    var planMs: Double
    /// Turn geometry at the interior nodes.
    var turns: TurnProfile
}

/// How sharply a route actually bends at its own nodes.
///
/// A flight put a 222 m leg — 16 nodes, detour ratio 1.04, i.e. very nearly a straight line —
/// entirely into `.stopAndPivotVTOL`, so the aircraft stopped, yawed and re-accelerated every 14 m
/// and never called the wing at all. Stop-and-pivot is chosen when the turn corridors fail to
/// validate at the wing's turn radius, which should be impossible on a straight leg. Either the
/// route really does bend — in which case the nodes are kinks, and route smoothing put them there —
/// or it does not, and the fault is in the validator. These numbers separate the two.
private struct TurnProfile {
    var maximumDegrees: Float = 0.0
    var meanDegrees: Float = 0.0
    var over5: Int = 0
    var over15: Int = 0
    var over45: Int = 0
    var interiorNodes: Int = 0
}

private func turnProfile(_ points: [SIMD3<Float>]) -> TurnProfile {
    guard points.count >= 3 else { return TurnProfile() }
    var profile = TurnProfile()
    var total: Float = 0.0
    for index in 1..<(points.count - 1) {
        let a = SIMD2<Float>(points[index].x - points[index - 1].x,
                             points[index].z - points[index - 1].z)
        let b = SIMD2<Float>(points[index + 1].x - points[index].x,
                             points[index + 1].z - points[index].z)
        guard simd_length_squared(a) > 1e-8, simd_length_squared(b) > 1e-8 else { continue }
        let ua = simd_normalize(a)
        let ub = simd_normalize(b)
        let cosine = min(1.0, max(-1.0, simd_dot(ua, ub)))
        let degrees = acos(cosine) * 180.0 / .pi
        guard degrees.isFinite else { continue }
        profile.interiorNodes += 1
        total += degrees
        profile.maximumDegrees = max(profile.maximumDegrees, degrees)
        if degrees > 5.0 { profile.over5 += 1 }
        if degrees > 15.0 { profile.over15 += 1 }
        if degrees > 45.0 { profile.over45 += 1 }
    }
    profile.meanDegrees = profile.interiorNodes > 0 ? total / Float(profile.interiorNodes) : 0.0
    return profile
}

private func planRoute(
    from start: SIMD2<Float>,
    to goal: SIMD2<Float>,
    altitude: Float,
    obstacles: [CollisionObstacle],
    droneRadius: Float
) -> RouteOutcome {
    let planner = AutoPathPlannerService()
    let startWorld = SIMD3<Float>(start.x, altitude, start.y)
    let goalWorld = SIMD3<Float>(goal.x, altitude, goal.y)
    planner.planIfNeeded(
        start: startWorld,
        goal: goalWorld,
        terrain: terrain,
        obstacles: obstacles,
        droneRadius: droneRadius,
        minimumObstacleRadiusFactor: 1.0,
        modeTag: "probe_city",
        forceRecompute: true,
        reason: "probe"
    )
    let snapshot = planner.snapshot(currentPosition: startWorld)
    var points = snapshot.waypoints
    if points.first.map({ simd_distance(SIMD2<Float>($0.x, $0.z), start) > 0.01 }) ?? true {
        points.insert(startWorld, at: 0)
    }
    var length: Float = 0.0
    var worst = Float.greatestFiniteMagnitude
    var worstPoint = start
    if points.count >= 2 {
        for pair in zip(points, points.dropFirst()) {
            let a = SIMD2<Float>(pair.0.x, pair.0.z)
            let b = SIMD2<Float>(pair.1.x, pair.1.z)
            length += simd_distance(a, b)
            let sample = segmentClearance(a, b, obstacles)
            if sample.clearance < worst {
                worst = sample.clearance
                worstPoint = sample.point
            }
        }
    }
    let passage = passageWidth(worstPoint, obstacles)
    return RouteOutcome(
        status: snapshot.status,
        points: points,
        length: length,
        direct: simd_distance(start, goal),
        worstClearance: points.count >= 2 ? worst : .nan,
        worstPassage: passage,
        planMs: planner.lastPlanDurationMs,
        turns: turnProfile(points)
    )
}

private let droneRadius: Float = 1.6

/// The stand-off the planner's own rasterisation intends for a building: its 1.4 m source buffer
/// plus the airframe radius. A route may fall short of it only where the passage is genuinely
/// too narrow to hold it.
private let intendedBuildingStandoff: Float = 1.4 + droneRadius

/// Both halves of the clearance contract.
///
/// The airframe radius is the floor everywhere — below it the aircraft is inside the building. But
/// a floor alone passes a route that hugs one wall with the whole street free on the other side,
/// which is exactly the failure that hid here: 1.67 m from a wall whose opposite neighbour was
/// 42 m away. So where the passage is wide, the full stand-off is required as well.
private func checkClearance(_ outcome: RouteOutcome, _ label: String) {
    check(
        outcome.worstClearance >= droneRadius,
        String(format: "%@ passed %.2f m from a building (needs >= %.2f m)",
               label, outcome.worstClearance, droneRadius)
    )
    guard outcome.worstPassage.second > 8.0 else { return }
    check(
        outcome.worstClearance >= intendedBuildingStandoff - 0.25,
        String(format: "%@ hugged a wall at %.2f m with %.2f m free on the other side",
               label, outcome.worstClearance, outcome.worstPassage.second)
    )
}

// MARK: A. Straight street — the route must not invent a detour
//
// Start and goal on the same street with nothing between them. Any meaningful excess length here
// is the planner routing around geometry that is not in the way, which is what "went into the
// blocks instead of the corridor" looks like from the aircraft.

print("--- A. clear straight corridor ---")
do {
    let obstacles = cityObstacles(blocksPerSide: 5)
    let streetZ = (blockSizeZ + streetWidth) * 0.5
    let outcome = planRoute(
        from: SIMD2<Float>(-220.0, streetZ),
        to: SIMD2<Float>(220.0, streetZ),
        altitude: 30.0,
        obstacles: obstacles,
        droneRadius: droneRadius
    )
    let ratio = outcome.direct > 0 ? outcome.length / outcome.direct : .infinity
    print(String(
        format: "A straight: status %@, pts %d, len %.0f m, direct %.0f m, ratio %.2f, clearance %.2f m | turns n=%d max %.1f deg, mean %.1f deg, >5 %d, >15 %d",
        String(describing: outcome.status) as NSString,
        outcome.points.count, outcome.length, outcome.direct, ratio, outcome.worstClearance,
        outcome.turns.interiorNodes, outcome.turns.maximumDegrees, outcome.turns.meanDegrees,
        outcome.turns.over5, outcome.turns.over15
    ))
    check(
        outcome.turns.over15 == 0,
        String(format: "straight corridor (ratio %.2f) bends >15 deg at %d node(s), max %.1f deg",
               ratio, outcome.turns.over15, outcome.turns.maximumDegrees)
    )
    check(outcome.points.count >= 2, "no route produced along an open street")
    check(ratio <= 1.35, String(format: "open street was routed %.2fx longer than the straight line", ratio))
    check(
        outcome.worstClearance >= droneRadius,
        String(format: "route along an open street passed %.2f m from a building (needs >= %.2f m)",
               outcome.worstClearance, droneRadius)
    )
}

// MARK: B. Around a block — a detour is expected, but a bounded one
//
// Goal diagonally across the grid: the route has to turn, and a Manhattan detour is at most the
// L-shaped path, i.e. sqrt(2) times the diagonal plus corner allowances.

print("--- B. bounded detour across the grid ---")
for blocks in [3, 5, 7] {
    let obstacles = cityObstacles(blocksPerSide: blocks)
    let pitchX = blockSizeX + streetWidth
    let pitchZ = blockSizeZ + streetWidth
    let reach = Float(blocks) * 0.5
    let outcome = planRoute(
        from: SIMD2<Float>(-reach * pitchX, -reach * pitchZ),
        to: SIMD2<Float>(reach * pitchX, reach * pitchZ),
        altitude: 30.0,
        obstacles: obstacles,
        droneRadius: droneRadius
    )
    let ratio = outcome.direct > 0 ? outcome.length / outcome.direct : .infinity
    print(String(
        format: "B %d blocks: status %@, pts %d, len %.0f m, direct %.0f m, ratio %.2f, clearance %.2f m, plan %.1f ms",
        blocks,
        String(describing: outcome.status) as NSString,
        outcome.points.count, outcome.length, outcome.direct, ratio, outcome.worstClearance,
        outcome.planMs
    ))
    check(outcome.points.count >= 2, "no route produced across a \(blocks)-block grid")
    // An L-shaped Manhattan path is sqrt(2) of the diagonal; 1.9 leaves room for the jog around
    // each block without admitting a route that wanders the city.
    check(ratio <= 1.9, String(format: "%d-block crossing was routed %.2fx the straight line", blocks, ratio))
    checkClearance(outcome, "\(blocks)-block crossing")
}

// MARK: D. Irregular blocks — the geometry an imported city actually has
//
// Groups A and B use identical axis-aligned blocks, and the planner threads them at ratio 1.27.
// A flight over imported OSM produced 18 nodes, 1488 m against a 632 m straight line — ratio 2.35.
// The fixture is the obvious suspect: real footprints vary in size and carry a yaw, so the streets
// between them are neither uniform nor axis-aligned. This group keeps the same block pitch and the
// same clearance requirement but varies extent and rotation deterministically, to see whether the
// detour ratio survives geometry the grid version never had.

/// Deterministic generator, so a failing seed is a reproducible fixture rather than a one-off.
private struct ProbeRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func nextUnitFloat() -> Float {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Float(z >> 40) / Float(1 << 24)
    }
}

private func irregularCityObstacles(blocksPerSide: Int, seed: UInt64) -> [CollisionObstacle] {
    var rng = ProbeRandom(seed: seed)
    var obstacles: [CollisionObstacle] = []
    let pitchX = blockSizeX + streetWidth
    let pitchZ = blockSizeZ + streetWidth
    let span = Float(blocksPerSide - 1) * 0.5
    for ix in 0..<blocksPerSide {
        for iz in 0..<blocksPerSide {
            // Keep the street corridor open: extents never grow past the nominal block, so the
            // gap between neighbours is at least `streetWidth`. Only shape and angle vary.
            let shrinkX = 0.62 + rng.nextUnitFloat() * 0.38
            let shrinkZ = 0.62 + rng.nextUnitFloat() * 0.38
            let yaw = (rng.nextUnitFloat() - 0.5) * Float(0.55)   // ±16 deg
            let halfExtents = SIMD2<Float>(
                blockSizeX * 0.5 * shrinkX,
                blockSizeZ * 0.5 * shrinkZ
            )
            let cx = (Float(ix) - span) * pitchX
            let cz = (Float(iz) - span) * pitchZ
            obstacles.append(
                CollisionObstacle(
                    id: UUID(),
                    center: SIMD3<Float>(cx, buildingHeight * 0.5, cz),
                    radius: simd_length(halfExtents),
                    source: "probe.building.irregular",
                    baseY: 0.0,
                    topY: buildingHeight,
                    planarHalfExtents: halfExtents,
                    yawRadians: yaw
                )
            )
        }
    }
    return obstacles
}

print("--- D. irregular blocks ---")
for seed in [UInt64(1), 7, 20260817] {
    let obstacles = irregularCityObstacles(blocksPerSide: 5, seed: seed)
    let pitchX = blockSizeX + streetWidth
    let pitchZ = blockSizeZ + streetWidth
    let reach: Float = 2.5
    let outcome = planRoute(
        from: SIMD2<Float>(-reach * pitchX, -reach * pitchZ),
        to: SIMD2<Float>(reach * pitchX, reach * pitchZ),
        altitude: 30.0,
        obstacles: obstacles,
        droneRadius: droneRadius
    )
    let ratio = outcome.direct > 0 ? outcome.length / outcome.direct : .infinity
    print(String(
        format: "D seed %8llu: status %@, pts %d, len %.0f m, direct %.0f m, ratio %.2f, clearance %.2f m, plan %.1f ms | turns n=%d max %.1f deg, mean %.1f deg, >5 %d, >15 %d, >45 %d",
        seed,
        String(describing: outcome.status) as NSString,
        outcome.points.count, outcome.length, outcome.direct, ratio, outcome.worstClearance,
        outcome.planMs,
        outcome.turns.interiorNodes, outcome.turns.maximumDegrees, outcome.turns.meanDegrees,
        outcome.turns.over5, outcome.turns.over15, outcome.turns.over45
    ))
    check(outcome.points.count >= 2, "no route produced across an irregular grid (seed \(seed))")
    check(ratio <= 1.9, String(format: "irregular grid (seed %llu) was routed %.2fx the straight line", seed, ratio))
    checkClearance(outcome, "irregular grid (seed \(seed))")
}

// MARK: C. Above the roofs — no detour at all is correct
//
// The obstacle set is altitude-banded, so a route planned above the buildings should be a straight
// line. If it still detours, the band filter is not reaching the planner and every high-altitude
// leg is being planned against a city that is not there.

print("--- C. above the rooftops ---")
do {
    let obstacles = cityObstacles(blocksPerSide: 5)
        .filter { $0.topY >= 120.0 }   // nothing this tall exists in the fixture
    let outcome = planRoute(
        from: SIMD2<Float>(-220.0, -220.0),
        to: SIMD2<Float>(220.0, 220.0),
        altitude: 140.0,
        obstacles: obstacles,
        droneRadius: droneRadius
    )
    let ratio = outcome.direct > 0 ? outcome.length / outcome.direct : .infinity
    print(String(
        format: "C above: status %@, pts %d, len %.0f m, direct %.0f m, ratio %.2f",
        String(describing: outcome.status) as NSString,
        outcome.points.count, outcome.length, outcome.direct, ratio
    ))
    check(outcome.points.count >= 2, "no route produced over an empty world")
    check(ratio <= 1.05, String(format: "empty world was routed %.2fx the straight line", ratio))
}

// MARK: E. Turn geometry on a short leg — the flight case
//
// The flight that provoked this group flew a 222 m leg and got a 16-node route with detour ratio
// 1.04. Reproduce that shape and report what the nodes actually do, on both regular and irregular
// blocks, so "the route bends" and "the validator is wrong" stop being interchangeable guesses.

print("--- E. turn geometry on a short leg ---")
for (label, obstacles) in [
    ("regular  ", cityObstacles(blocksPerSide: 5)),
    ("irregular", irregularCityObstacles(blocksPerSide: 5, seed: 20260817))
] {
    let outcome = planRoute(
        from: SIMD2<Float>(-160.0, -150.0),
        to: SIMD2<Float>(0.0, 5.0),
        altitude: 30.0,
        obstacles: obstacles,
        droneRadius: droneRadius
    )
    let ratio = outcome.direct > 0 ? outcome.length / outcome.direct : .infinity
    let turns = outcome.turns
    print(String(
        format: "E %@: pts %d, len %.0f m, direct %.0f m, ratio %.2f | turns n=%d max %.1f deg, mean %.1f deg, >5 %d, >15 %d, >45 %d",
        label as NSString,
        outcome.points.count, outcome.length, outcome.direct, ratio,
        turns.interiorNodes, turns.maximumDegrees, turns.meanDegrees,
        turns.over5, turns.over15, turns.over45
    ))
    check(outcome.points.count >= 2, "no route produced for the short \(label) leg")
    // A route whose detour ratio is near 1 is a straight line, and a straight line has no corners.
    // If it reports corners anyway, they were introduced after planning, not found by it.
    if ratio <= 1.10 {
        check(
            turns.over15 == 0,
            String(format: "%@ leg is straight (ratio %.2f) yet bends >15 deg at %d node(s), max %.1f deg",
                   label, ratio, turns.over15, turns.maximumDegrees)
        )
    }
}

if failures.isEmpty {
    print("RESULT: PASS - planned city routes are direct, bounded and clear of buildings")
    exit(0)
}

print("RESULT: FAIL - \(failures.count) route-shape contract(s) violated")
exit(1)
