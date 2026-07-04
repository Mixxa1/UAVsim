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
    /// Distance from the tree disc's edge to the parked truck (see
    /// `DroneSceneController.spawnFireTruckDecoration`) — computed here, not a fixed constant,
    /// so the truck's actual placement always matches what `zoneRadius` was derived against.
    var truckStandoffMeters: Float

    /// Deterministically derives the fire zone + tree pool from the scenario seed and the
    /// playable world bounds. Mirrors `MissionScenarioPlacement.generate`'s algorithm (keep the
    /// zone away from the world edge and the dock, disc-sample positions inside it).
    ///
    /// `tetherLengthMeters` is the rigged hose's physical length — every tree MUST be reachable
    /// from the truck within this distance (hard requirement, not a soft bias), since the hose
    /// tether hard-clamps the drone's flight radius around the truck at runtime.
    ///
    /// Difficulty controls how much of that reach gets used, not just how big the zone is: easy
    /// keeps the fire cluster close to the truck (comfortable margin, generous spread), hard
    /// pushes it out to near the tether's absolute limit (a tight, high-stakes cluster with
    /// almost no slack) — a deliberate escalation, not an accident of capping. `fireZoneRadiusMeters`
    /// is still an upper bound on cluster spread, but at hard difficulty with a long hose it's
    /// essentially never the binding constraint — the tether geometry is.
    static func generate(
        parameters: MissionScenarioParameters,
        worldHalfExtent: Float,
        dockPosition: SIMD2<Float>,
        tetherLengthMeters: Float
    ) -> FireZonePlacement {
        // Salted so a fire-response mission doesn't reuse the exact same sector as a
        // search-and-rescue mission would for the same seed.
        var rng = MissionSeededGenerator(seed: parameters.seed &+ 0x4649_5245_5A4F_4E45)

        // `bandDistance` is how far the fire cluster's center sits from the truck — a
        // difficulty-scaled fraction of the tether's safe interior (reserving a small
        // `nozzleSlack` so the runtime clamp never has to bind exactly at the drone's current
        // position). `clusterRadius` is how far individual trees scatter from that center; it
        // absorbs whatever's left of the tether budget after `bandDistance`, so it shrinks
        // automatically as bandDistance approaches the limit (hard difficulty: a tight cluster
        // right at the edge of reach) and grows when there's slack to spare (easy difficulty).
        let nozzleSlack: Float = 3.0
        let safeLimit = max(4.0, tetherLengthMeters - nozzleSlack)
        let bandFractionRange: ClosedRange<Float>
        switch parameters.difficulty {
        case .easy:
            bandFractionRange = 0.20...0.35
        case .medium:
            bandFractionRange = 0.50...0.65
        case .hard:
            bandFractionRange = 0.90...0.97
        }
        let bandDistance = safeLimit * Float.random(in: bandFractionRange, using: &rng)
        let clusterRadiusFloor: Float = 1.0
        let radius = min(parameters.difficulty.fireZoneRadiusMeters, max(clusterRadiusFloor, safeLimit - bandDistance))
        // Gap from the cluster's near edge (facing the truck) out to the truck itself — derived
        // so `standoff + radius == bandDistance` exactly, keeping `spawnFireTruckDecoration`'s
        // placement consistent with what this reachability math assumed.
        let standoff = max(0.0, bandDistance - radius)

        let reachExtent = bandDistance + radius
        let safeExtent = max(reachExtent + 20.0, worldHalfExtent * 0.7)
        let centerSpan = max(0.0, safeExtent - reachExtent)

        func randomOffset(_ span: Float) -> Float {
            span <= 0.0 ? 0.0 : Float.random(in: -span...span, using: &rng)
        }

        // Place the zone center far enough from the dock that the truck — which parks
        // `bandDistance` back toward the dock from the cluster — fits comfortably between them,
        // so the operator has to actually transit to the fire.
        var zoneCenter = dockPosition
        for _ in 0..<8 {
            let candidate = SIMD2<Float>(randomOffset(centerSpan), randomOffset(centerSpan))
            if simd_distance(candidate, dockPosition) >= bandDistance + 10.0 {
                zoneCenter = candidate
                break
            }
            zoneCenter = candidate
        }

        // The fire truck parks between the dock and the cluster, `bandDistance` back from the
        // cluster's center — purely a flavor bias now (crew staged toward the accessible flank),
        // not load-bearing for the reachability guarantee above, which already holds for any
        // angle up to the full 180°.
        let toDock = dockPosition - zoneCenter
        let truckFacingAngle: Float = simd_length(toDock) > 0.001 ? atan2(toDock.y, toDock.x) : 0.0
        let angleSpread: Float = 100.0 * .pi / 180.0

        func randomPointInZone() -> SIMD2<Float> {
            // Uniform-ish disc sample (sqrt for area weighting), angle biased toward the truck.
            let angle = truckFacingAngle + Float.random(in: -angleSpread...angleSpread, using: &rng)
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
            initiallyBurningIndices: initiallyBurningIndices,
            truckStandoffMeters: standoff
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
/// isn't keyed per-payload — the hose is the only payload that suppresses via continuous aim/dwell
/// (the fire-capsule launcher, `.fireResponse`'s other compatible payload, instead suppresses via
/// an instant area-of-effect burst on impact — see `FireCapsuleSize`/`FireResponseRuntime.extinguishTreesInRadius`).
///
/// `nozzleThrowMeters` is the nozzle's own spray-throw distance from the drone's current position
/// under pump pressure — a short, fixed distance independent of hose length. It is NOT the same
/// thing as the hose's physical length (`PayloadConfiguration.fireHoseLengthMeters`), which
/// instead constrains how far the drone can get from the fire truck (see the hose-tether
/// constraint in `DroneSimulationViewModel`).
struct FireHoseTuning: Equatable {
    var nozzleThrowMeters: Float
    var aimConeHalfAngleDegrees: Float
    var suppressionDwellSeconds: Double

    static let `default` = FireHoseTuning(
        nozzleThrowMeters: 16.0,
        aimConeHalfAngleDegrees: 6.0,
        suppressionDwellSeconds: 2.2
    )
}

// MARK: - Hose diameter class

/// Real firefighting-drone hoses come in two practical weight classes: a lightweight,
/// small-diameter foldable line for medium-lift platforms, and a full-bore standard attack line
/// for heavy/superheavy platforms. Water-filled mass scales linearly with length; `hardwareOverheadKg`
/// accounts for the reel/valve/nozzle-turret hardware itself, independent of length.
enum FireHoseDiameterClass: String, CaseIterable, Codable, Hashable, Identifiable {
    case narrow
    case standard

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .narrow: return "payload.hose.diameter.narrow"
        case .standard: return "payload.hose.diameter.standard"
        }
    }

    /// Water-filled mass per meter of hose.
    var massPerMeterKg: Float {
        switch self {
        case .narrow: return 0.45
        case .standard: return 1.80
        }
    }

    /// Fixed reel/valve/nozzle-turret hardware mass, independent of length.
    var hardwareOverheadKg: Float {
        switch self {
        case .narrow: return 2.0
        case .standard: return 5.0
        }
    }

    /// Practical rigging range — matches real-world medium-lift (narrow) vs. heavy/superheavy
    /// (standard) operating altitude bands.
    var lengthRangeMeters: ClosedRange<Float> {
        switch self {
        case .narrow: return 10.0...50.0
        case .standard: return 30.0...150.0
        }
    }

    var lengthStepMeters: Float {
        switch self {
        case .narrow: return 5.0
        case .standard: return 10.0
        }
    }

    func massForLength(_ meters: Float) -> Float {
        max(0.0, meters) * massPerMeterKg + hardwareOverheadKg
    }
}

// MARK: - Fire-extinguishing capsule launcher

/// Real drone-droppable fire-extinguishing capsules/balls: 1.5-3kg each depending on size, burst
/// on impact and disperse powder/gas in a fixed radius around the impact point, instantly clearing
/// anything burning within it. Unlike the hose (continuous aim, dwell-based, effectively unlimited
/// water from the truck), this is a lighter, ammo-limited, bursty mechanic for aircraft too light
/// to carry a hose rig at all — the "size" axis trades more capsules (more attempts) against a
/// bigger blast radius (each attempt covers more area) rather than length like the hose.
enum FireCapsuleSize: String, CaseIterable, Codable, Hashable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .small: return "payload.capsule.size.small"
        case .medium: return "payload.capsule.size.medium"
        case .large: return "payload.capsule.size.large"
        }
    }

    var massKg: Float {
        switch self {
        case .small: return 1.5
        case .medium: return 2.25
        case .large: return 3.0
        }
    }

    var blastRadiusMeters: Float {
        switch self {
        case .small: return 3.0
        case .medium: return 4.0
        case .large: return 5.0
        }
    }
}

enum FireCapsuleTuning {
    /// Fixed launcher-rack hardware mass, independent of how many capsules are loaded.
    static let launcherHardwareOverheadKg: Float = 1.5
    static let countRange: ClosedRange<Int> = 1...4

    static func totalMass(size: FireCapsuleSize, count: Int) -> Float {
        launcherHardwareOverheadKg + size.massKg * Float(max(0, count))
    }

    /// Truck placement reach for capsule missions — feeds `FireZonePlacement.generate`'s
    /// `tetherLengthMeters` exactly like the hose's rigged length does, giving the capsule
    /// launcher its own difficulty-scaled truck standoff instead of the hose's fallback. First-pass
    /// numbers, expected to be tuned after in-game testing like every other constant in this
    /// mission type.
    static func truckOperationalReachMeters(for difficulty: MissionDifficulty) -> Float {
        switch difficulty {
        case .easy: return 100.0
        case .medium: return 180.0
        case .hard: return 280.0
        }
    }

    /// Seconds to refill one capsule while landed in the truck's recharge zone.
    static func rechargeSecondsPerCapsule(for difficulty: MissionDifficulty) -> Double {
        switch difficulty {
        case .easy: return 5.0
        case .medium: return 6.5
        case .hard: return 8.0
        }
    }

    /// Fixed "close enough to the truck" tolerance — deliberately NOT difficulty-scaled; only
    /// reload time and truck placement distance scale with difficulty.
    static let rechargeZoneRadiusMeters: Float = 10.0
}
