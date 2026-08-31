import Foundation
import simd

/// Builds a complete, flyable circuit from a seed.
///
/// The generator lays a closed loop rather than a random scatter, because a race track is a
/// *line* before it is a set of objects: every gate is turned to face along the line through it,
/// consecutive gates are kept far enough apart to be taken at speed and close enough to read as
/// one course, and the whole thing closes back onto the first gate so laps mean something.
enum RaceTrackGenerator {
    /// Gates the pilot can meet on a generated track, with the weight each is drawn at. The
    /// tower is deliberately rare: it is flown through vertically, so it asks for a climb and a
    /// dive in the middle of a lap, which is a feature at one per track and a chore at three.
    private static let gateWeights: [(id: String, weight: Int)] = [
        ("gate_square", 5),
        ("gate_hexagon", 4),
        ("gate_pentagon", 3),
        ("gate_square_large", 3),
        ("gate_square_banner", 2),
        ("gate_cube", 2),
        ("gate_arch_base", 2),
        ("gate_arch", 1),
        ("gate_pentagon_cluster", 1),
        ("gate_tower", 1)
    ]

    private static let decorIDs = ["flag_feather", "flag_drop", "flag_sail", "flag_blade"]

    struct Parameters {
        var gateCount: Int
        var radiusMeters: Float
        /// How far the loop's radius is allowed to wander, as a fraction of `radiusMeters`.
        var radiusVariation: Float
        var laps: Int
        var seed: UInt64
        var name: String

        static func forDifficulty(_ difficulty: MissionDifficulty, seed: UInt64) -> Parameters {
            switch difficulty {
            case .easy:
                return Parameters(
                    gateCount: 6, radiusMeters: 65.0, radiusVariation: 0.12,
                    laps: 2, seed: seed, name: NSLocalizedString("race.track.generated.easy", comment: "")
                )
            case .medium:
                return Parameters(
                    gateCount: 9, radiusMeters: 95.0, radiusVariation: 0.22,
                    laps: 3, seed: seed, name: NSLocalizedString("race.track.generated.medium", comment: "")
                )
            case .hard:
                return Parameters(
                    gateCount: 13, radiusMeters: 130.0, radiusVariation: 0.34,
                    laps: 3, seed: seed, name: NSLocalizedString("race.track.generated.hard", comment: "")
                )
            }
        }
    }

    static func generate(parameters: Parameters, worldHalfExtent: Float) -> RaceTrack {
        var rng = MissionSeededGenerator(seed: parameters.seed == 0 ? 0x0ACE_0001 : parameters.seed)
        let gateCount = max(3, parameters.gateCount)
        // Keep the whole loop inside the playable world with room for the run-off outside a turn.
        let radius = min(parameters.radiusMeters, max(30.0, worldHalfExtent * 0.55))

        // 1. A closed ring of waypoints with a wandering radius and a little angular jitter, so
        //    the lap has long straights and tight corners instead of a perfect polygon.
        var waypoints: [SIMD2<Float>] = []
        for index in 0..<gateCount {
            let baseAngle = Float(index) / Float(gateCount) * 2.0 * .pi
            let jitter = Float.random(in: -0.25...0.25, using: &rng) * (2.0 * .pi / Float(gateCount))
            let angle = baseAngle + jitter
            let wander = 1.0 + Float.random(
                in: -parameters.radiusVariation...parameters.radiusVariation,
                using: &rng
            )
            let r = radius * wander
            waypoints.append(SIMD2<Float>(cos(angle) * r, sin(angle) * r))
        }

        // 2. Push apart any pair that ended up too close to fly cleanly between.
        let minimumSpacing: Float = 22.0
        for _ in 0..<4 {
            for index in waypoints.indices {
                let next = (index + 1) % waypoints.count
                let delta = waypoints[next] - waypoints[index]
                let distance = simd_length(delta)
                guard distance > 0.001, distance < minimumSpacing else { continue }
                let push = simd_normalize(delta) * (minimumSpacing - distance) * 0.5
                waypoints[index] -= push
                waypoints[next] += push
            }
        }

        // 3. A gate at each waypoint, square to the racing line through it.
        var elements: [RaceTrackElement] = []
        for index in waypoints.indices {
            let previous = waypoints[(index + waypoints.count - 1) % waypoints.count]
            let next = waypoints[(index + 1) % waypoints.count]
            let tangent = simd_normalize(next - previous + SIMD2<Float>(0.0001, 0.0))
            let yaw = atan2(tangent.x, tangent.y)

            let catalogID = weightedGateID(using: &rng)
            let descriptor = RacingElementCatalog.descriptor(id: catalogID)
            let isVertical = descriptor?.role == .verticalGate
            let position = SIMD3<Float>(waypoints[index].x, 0.0, waypoints[index].y)

            elements.append(
                RaceTrackElement(
                    catalogID: catalogID,
                    position: position,
                    // A tower is entered from above, so the yaw of the racing line means nothing
                    // to it; give it a free heading instead of a misleading one.
                    yawRadians: isVertical ? Float.random(in: 0...(2.0 * .pi), using: &rng) : yaw,
                    scale: Float.random(in: 0.95...1.25, using: &rng),
                    gateOrder: index
                )
            )

            // A pair of flags flanking the gate: the marker a pilot actually picks the gate out
            // by at speed, long before the frame itself resolves.
            let lateral = SIMD2<Float>(tangent.y, -tangent.x)
            let flagOffset = (descriptor?.sizeMeters.x ?? 2.5) * 0.5 + 1.8
            for side in [Float(-1.0), 1.0] {
                let flagPosition = waypoints[index] + lateral * (flagOffset * side)
                elements.append(
                    RaceTrackElement(
                        catalogID: decorIDs[Int.random(in: 0..<decorIDs.count, using: &rng)],
                        position: SIMD3<Float>(flagPosition.x, 0.0, flagPosition.y),
                        yawRadians: Float.random(in: 0...(2.0 * .pi), using: &rng),
                        scale: Float.random(in: 0.9...1.15, using: &rng)
                    )
                )
            }
        }

        // 4. A start pad on the approach to the first gate.
        if let first = waypoints.first, let padDescriptor = RacingElementCatalog.startPad {
            let second = waypoints[1 % waypoints.count]
            let approach = simd_normalize(first - second + SIMD2<Float>(0.0001, 0.0))
            let padPosition = first + approach * 14.0
            elements.append(
                RaceTrackElement(
                    catalogID: padDescriptor.id,
                    position: SIMD3<Float>(padPosition.x, 0.0, padPosition.y),
                    yawRadians: atan2(-approach.x, -approach.y),
                    scale: 1.4
                )
            )
        }

        return RaceTrack(
            name: parameters.name,
            elements: elements,
            laps: parameters.laps,
            isGenerated: true
        )
    }

    private static func weightedGateID(using rng: inout MissionSeededGenerator) -> String {
        let total = gateWeights.reduce(0) { $0 + $1.weight }
        var roll = Int.random(in: 0..<max(1, total), using: &rng)
        for entry in gateWeights {
            roll -= entry.weight
            if roll < 0 {
                return entry.id
            }
        }
        return gateWeights.first?.id ?? "gate_square"
    }
}
