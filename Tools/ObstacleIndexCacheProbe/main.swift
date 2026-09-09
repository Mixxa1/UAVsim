import Foundation
import simd

// Headless equality probe for `CollisionObstacleSpatialIndex.SegmentQueryCache`.
//
// The cache exists because the radio-link path made the broad phase quadratic: the segment query
// walks every cell of the segment's bounding rectangle, and with the aircraft 44 km from the ground
// station that rectangle was 474 x 1375 cells — 653 000 bucket lookups, 72 ms, three times a
// second. The cache keeps the union of everything scanned so far and walks only the strip each new
// query adds.
//
// That is only acceptable if the *set it returns is the same set*. The one caller,
// `analyticEnvironmentRayHit`, feeds these candidates into exact ray/obstacle tests, so a missing
// candidate is a missed obstruction — a line-of-sight or drop-prediction answer that silently
// changes. So this compares the cache against the authoritative query, obstacle-for-obstacle, over
// randomised fields and query sequences, with the cache reused across the whole sequence exactly as
// the scene controller reuses it.
//
// Sequences deliberately include the shapes that break naive caches:
//   grow      the radio case — one end fixed, the other receding. The rectangle only grows.
//   shrink    flying home again, so the requested rectangle is strictly inside what was scanned.
//   lateral   crossing the fixed end, so the rectangle moves rather than grows.
//   degenerate zero-length segments and zero margin.
//
// Run: Tools/ObstacleIndexCacheProbe/run.sh

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

func makeField(count: Int, extent: Float, generator: inout SeededGenerator) -> [CollisionObstacle] {
    (0..<count).map { _ in
        let center = SIMD3<Float>(
            Float.random(in: -extent...extent, using: &generator),
            Float.random(in: 0...40, using: &generator),
            Float.random(in: -extent...extent, using: &generator)
        )
        // Both shapes matter: the index inserts on `planarHalfExtents` when present and on the
        // bounding-sphere `radius` otherwise, and the cache's membership test has to reproduce
        // whichever rule applied.
        let usesPlanarBox = Bool.random(using: &generator)
        return CollisionObstacle(
            id: UUID(),
            center: center,
            radius: Float.random(in: 0.5...45.0, using: &generator),
            source: usesPlanarBox ? "probe.box" : "probe.sphere",
            planarHalfExtents: usesPlanarBox
                ? SIMD2<Float>(
                    Float.random(in: 0.5...60.0, using: &generator),
                    Float.random(in: 0.5...60.0, using: &generator)
                )
                : nil
        )
    }
}

struct Segment {
    let start: SIMD3<Float>
    let end: SIMD3<Float>
    let margin: Float
}

func makeSequence(
    kind: String,
    steps: Int,
    generator: inout SeededGenerator
) -> [Segment] {
    let anchor = SIMD3<Float>(0, 2, 0)
    switch kind {
    case "grow":
        return (0..<steps).map { step in
            let reach = Float(step) * 900.0
            return Segment(
                start: anchor,
                end: SIMD3<Float>(reach * 0.34, 120, -reach),
                margin: Float.random(in: 0...6, using: &generator)
            )
        }
    case "shrink":
        return (0..<steps).map { step in
            let reach = Float(steps - step) * 900.0
            return Segment(
                start: anchor,
                end: SIMD3<Float>(reach * 0.34, 120, -reach),
                margin: Float.random(in: 0...6, using: &generator)
            )
        }
    case "lateral":
        return (0..<steps).map { step in
            let sweep = (Float(step) - Float(steps) / 2.0) * 700.0
            return Segment(
                start: anchor,
                end: SIMD3<Float>(sweep, 120, -4000),
                margin: Float.random(in: 0...6, using: &generator)
            )
        }
    default:
        return (0..<steps).map { _ in
            let point = SIMD3<Float>(
                Float.random(in: -3000...3000, using: &generator),
                Float.random(in: 0...200, using: &generator),
                Float.random(in: -3000...3000, using: &generator)
            )
            // Zero-length and zero-margin are the cases where the rectangle collapses to one cell.
            return Segment(start: point, end: point, margin: 0.0)
        }
    }
}

print("Segment-query cache vs the authoritative query")
print("")
print(String(
    format: "%-12@ %8@ %9@ %10@ %12@ %10@",
    "sequence" as NSString, "field" as NSString, "queries" as NSString,
    "mismatch" as NSString, "authoritative" as NSString, "cached" as NSString
))
print(String(repeating: "-", count: 68))

var failures: [String] = []

for (fieldCount, extent) in [(400, Float(2500)), (4000, Float(9000))] {
    for kind in ["grow", "shrink", "lateral", "degenerate"] {
        var generator = SeededGenerator(seed: 0xC0FFEE &+ UInt64(fieldCount) &+ UInt64(kind.count))
        let obstacles = makeField(count: fieldCount, extent: extent, generator: &generator)
        let index = CollisionObstacleSpatialIndex(obstacles: obstacles)
        // One cache for the whole sequence — the reuse is the thing under test.
        let cache = index.makeSegmentQueryCache()
        let segments = makeSequence(kind: kind, steps: 60, generator: &generator)

        var mismatches = 0
        var authoritativeSeconds = 0.0
        var cachedSeconds = 0.0

        for segment in segments {
            var started = CFAbsoluteTimeGetCurrent()
            let expected = Set(
                index.query(from: segment.start, to: segment.end, margin: segment.margin)
                    .map(\.id)
            )
            authoritativeSeconds += CFAbsoluteTimeGetCurrent() - started

            started = CFAbsoluteTimeGetCurrent()
            let actual = Set(
                cache.query(from: segment.start, to: segment.end, margin: segment.margin)
                    .map(\.id)
            )
            cachedSeconds += CFAbsoluteTimeGetCurrent() - started

            if expected != actual {
                mismatches += 1
                if mismatches == 1 {
                    let missing = expected.subtracting(actual).count
                    let extra = actual.subtracting(expected).count
                    failures.append(String(
                        format: "%@/%d — %d missing, %d extra on a %.0f m segment",
                        kind, fieldCount, missing, extra,
                        simd_length(segment.end - segment.start)
                    ))
                }
            }
        }

        print(String(
            format: "%-12@ %8d %9d %10d %10.1fms %8.1fms",
            kind as NSString, fieldCount, segments.count, mismatches,
            authoritativeSeconds * 1000.0, cachedSeconds * 1000.0
        ))
    }
}

print("")
if failures.isEmpty {
    print("PASS: the cache returned the authoritative set for every query.")
} else {
    print("FAIL:")
    for failure in failures { print("  " + failure) }
}
