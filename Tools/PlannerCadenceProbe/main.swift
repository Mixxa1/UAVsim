import Foundation
import simd

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

let terrain = TerrainConfiguration(
    preset: .city, mapScale: .x64, density: 0.5, seed: 42, safeSpawnRadius: 30
)
let planner = AutoPathPlannerService()
let start = SIMD3<Float>(-600, 80, -400)
let goal = SIMD3<Float>(600, 80, 400)
func plan(_ position: SIMD3<Float>, signature: Int = 1, force: Bool = false) {
    planner.planIfNeeded(
        start: position, goal: goal, terrain: terrain, obstacles: [],
        obstacleSignature: signature, droneRadius: 1, modeTag: "return_home",
        forceRecompute: force, reason: "rth_navigate"
    )
}
plan(start)
let route = planner.snapshot(currentPosition: start).waypoints
check(route.count > 100, "Fixture must contain a long smoothed route")

func referenceDistance(_ position: SIMD3<Float>) -> Float {
    let p = SIMD2<Float>(position.x, position.z)
    return zip(route, route.dropFirst()).map { a3, b3 in
        let a = SIMD2<Float>(a3.x, a3.z)
        let b = SIMD2<Float>(b3.x, b3.z)
        let ab = b - a
        let t = max(0, min(1, simd_dot(p - a, ab) / max(0.000001, simd_length_squared(ab))))
        return simd_distance(p, a + t * ab)
    }.min() ?? .greatestFiniteMagnitude
}

let before = AutoPathPlannerService.accounting
let started = CFAbsoluteTimeGetCurrent()
let tickCount = 1200
for tick in 0..<tickCount {
    let position = start + (goal - start) * (Float(tick) / Float(tickCount))
    check(planner.replanReasonIfNeeded(
        currentPosition: position, collisionRisk: 0, deviationTolerance: 4
    ) == nil, "Normal progress must stay on the cached route")
    plan(position)
}
let after = AutoPathPlannerService.accounting
let segmentChecks = after.deviationSegmentChecks - before.deviationSegmentChecks
check(after.searchCount == before.searchCount, "Cached flight must not start A*")
check(after.gridBuildCount == before.gridBuildCount, "Cached flight must not rebuild the grid")
check(segmentChecks < tickCount * 8, "Corridor checks must not scan the entire route each tick")
print(String(format: "RTH: %d ticks, %d route points, %d segment checks, 0 searches, %.2f ms total",
             tickCount, route.count, segmentChecks, (CFAbsoluteTimeGetCurrent() - started) * 1000))

// Jump forwards/backwards across the route and across both sides of the corridor. A cached
// witness must never exempt a live departure, or reject another valid leg after a jump.
for tick in 0..<2000 {
    let fraction = Float((tick * 761) % 2000) / 2000
    var position = start + (goal - start) * fraction
    position.x += Float((tick * 13) % 41 - 20)
    for tolerance: Float in [2, 4, 8, 12] {
        let offPath = planner.replanReasonIfNeeded(
            currentPosition: position, collisionRisk: 0, deviationTolerance: tolerance
        ) == "off_path"
        check(offPath == (referenceDistance(position) > tolerance), "Deviation differs from full scan")
    }
}
check(planner.replanReasonIfNeeded(
    currentPosition: start, collisionRisk: 0.8, deviationTolerance: 4
) == "high_collision_risk", "Collision risk must bypass the fast path immediately")

let searches = AutoPathPlannerService.accounting.searchCount
plan(start, force: true)
check(AutoPathPlannerService.accounting.searchCount == searches + 1, "Forced replan must run")
let grids = AutoPathPlannerService.accounting.gridBuildCount
plan(start, signature: 2)
check(AutoPathPlannerService.accounting.gridBuildCount == grids + 1, "Environment change must rebuild")
check(AutoPathPlannerService.accounting.searchCount == searches + 2, "Environment change must replan")
planner.invalidate()
check(planner.replanReasonIfNeeded(
    currentPosition: start, collisionRisk: 0, deviationTolerance: 4
) == "no_waypoints", "Invalidation must discard the route")
plan(start, signature: 2)
check(AutoPathPlannerService.accounting.searchCount == searches + 3, "Invalidation must replan")
print("PASS: 8000 deviation comparisons, collision risk, force, environment revision, invalidation")
