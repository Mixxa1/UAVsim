import Foundation
import simd

// MARK: - Fire zone placement (pre-launch derived, analogous to MissionScenarioPlacement)

/// Deterministic placement of a fire zone: a pool of trees scattered in a circular zone, a subset
/// of which start pre-ignited. Parallel to `MissionScenarioPlacement` but not shared with it —
/// SAR's placement is single-target-shaped (one target + candidate decoys), while a fire zone is
/// inherently a small population of independently-tracked trees.
struct FireZonePlacement: Equatable {
    var zoneCenter: SIMD2<Float>
    var zoneRadius: Float
    var treePositions: [SIMD2<Float>]
    var initiallyBurningIndices: Set<Int>

    /// Deterministically derives the fire zone + tree pool from the scenario seed and the
    /// playable world bounds. Mirrors `MissionScenarioPlacement.generate`'s algorithm (keep the
    /// zone away from the world edge and the dock, disc-sample positions inside it).
    static func generate(
        parameters: MissionScenarioParameters,
        worldHalfExtent: Float,
        dockPosition: SIMD2<Float>
    ) -> FireZonePlacement {
        // Salted so a fire-response mission doesn't reuse the exact same sector as a
        // search-and-rescue mission would for the same seed.
        var rng = MissionSeededGenerator(seed: parameters.seed &+ 0x4649_5245_5A4F_4E45)
        let radius = parameters.difficulty.fireZoneRadiusMeters

        let safeExtent = max(radius + 20.0, worldHalfExtent * 0.7)
        let centerSpan = max(0.0, safeExtent - radius)

        func randomOffset(_ span: Float) -> Float {
            span <= 0.0 ? 0.0 : Float.random(in: -span...span, using: &rng)
        }

        // Place the zone center at least ~1 zone-radius from the dock so the operator has to
        // actually transit to the fire.
        var zoneCenter = dockPosition
        for _ in 0..<8 {
            let candidate = SIMD2<Float>(randomOffset(centerSpan), randomOffset(centerSpan))
            if simd_distance(candidate, dockPosition) >= radius * 0.9 {
                zoneCenter = candidate
                break
            }
            zoneCenter = candidate
        }

        func randomPointInZone() -> SIMD2<Float> {
            // Uniform-ish disc sample (sqrt for area weighting).
            let angle = Float.random(in: 0...(2.0 * .pi), using: &rng)
            let r = radius * sqrt(Float.random(in: 0...1, using: &rng)) * 0.92
            return zoneCenter + SIMD2<Float>(cos(angle) * r, sin(angle) * r)
        }

        let treeCount = max(1, parameters.difficulty.fireTreeCount)
        let treePositions = (0..<treeCount).map { _ in randomPointInZone() }

        let initialCount = min(treeCount, max(1, parameters.difficulty.initialFireCount))
        var shuffledIndices = Array(treePositions.indices)
        shuffledIndices.shuffle(using: &rng)
        let initiallyBurningIndices = Set(shuffledIndices.prefix(initialCount))

        return FireZonePlacement(
            zoneCenter: zoneCenter,
            zoneRadius: radius,
            treePositions: treePositions,
            initiallyBurningIndices: initiallyBurningIndices
        )
    }
}

// MARK: - Per-tree state

/// Burn state of a single tree in the fire zone. `.charred` is terminal — once suppressed, a
/// tree stays permanently charred and can never re-ignite (matches the confirmed product
/// decision that extinguishing leaves visible, lasting damage).
enum FireTreeStatus: Equatable {
    case unburned
    case burning(ignitedAtSeconds: Double, suppressionProgress: Double)
    case charred
}

// MARK: - Runtime objective + outcome

enum FireResponseObjectiveState: Equatable {
    case active
    case allExtinguished
    case failedTimeout
}

enum FireResponseOutcome: Equatable {
    case success(elapsedSeconds: Double)
    case failureTimeout
    case aborted
}

// MARK: - Hose tuning

/// Fixed suppression tuning for the fire hose. Unlike `MissionDetectionTuning.make(for:)`, this
/// isn't keyed per-payload — `.fireResponse` has exactly one compatible payload, so there's no
/// varying input axis to switch on.
struct FireHoseTuning: Equatable {
    var reachMeters: Float
    var aimConeHalfAngleDegrees: Float
    var suppressionDwellSeconds: Double

    static let `default` = FireHoseTuning(
        reachMeters: 16.0,
        aimConeHalfAngleDegrees: 6.0,
        suppressionDwellSeconds: 2.2
    )
}
