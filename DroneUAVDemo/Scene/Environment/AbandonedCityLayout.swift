import Foundation
import SceneKit
import simd

struct AbandonedCityOptions {
    static let minBuildings = 10
    static let targetBuildings = 14
    static let maxBuildings = 16
    static let spawnClearRadius: Float = 45.0
    static let minBuildingSpacing: Float = 8.0
    static let enableDebugCollisionBoxes = false

    static func targetBuildingCount(for mapScale: MapScale) -> Int {
        switch mapScale {
        case .x4, .x8:
            return 8
        case .x16:
            return 12
        case .x32:
            return targetBuildings
        // The extended ranges get the same block of buildings as the largest ordinary
        // map, not a proportionally bigger city. The abandoned-city layout places a
        // handful of authored buildings around the spawn to fly between; scaled up to
        // an 800-kilometre range that stops being a city and becomes scattered debris,
        // and the aircraft these ranges exist for is not flying between buildings.
        case .x64, .x128, .x256, .x512, .x1024, .x2048, .x4096, .x8192:
            return maxBuildings
        }
    }

    static func minimumBuildingCount(for mapScale: MapScale) -> Int {
        switch mapScale {
        case .x4, .x8:
            return 6
        case .x16, .x32, .x64, .x128, .x256, .x512, .x1024, .x2048, .x4096, .x8192:
            return minBuildings
        }
    }

    static func spawnClearRadius(for mapScale: MapScale) -> Float {
        switch mapScale {
        case .x4:
            return 30.0
        case .x8:
            return 35.0
        case .x16, .x32:
            return spawnClearRadius
        case .x64:
            return 50.0
        case .x128, .x256:
            return 60.0
        // A supersonic aircraft needs more than sixty metres of clear ground around
        // its start point. This is only the radius the city layout keeps free; the
        // departure-corridor check still has the final word on whether a given
        // aircraft can actually get out.
        case .x512, .x1024, .x2048, .x4096, .x8192:
            return 400.0
        }
    }
}

struct AbandonedCityFootprint {
    let minX: Float
    let maxX: Float
    let minZ: Float
    let maxZ: Float

    func intersects(_ other: AbandonedCityFootprint) -> Bool {
        minX < other.maxX && maxX > other.minX &&
            minZ < other.maxZ && maxZ > other.minZ
    }
}

struct AbandonedCityPlacement {
    let id: UUID
    let kind: AbandonedCityBuildingKind
    let position: SIMD3<Float>
    let yaw: Float
    let targetHeightMeters: Float
    let normalizedSize: SIMD3<Float>
    let footprint: AbandonedCityFootprint
}

struct AbandonedCityLayoutResult {
    let targetCount: Int
    let placements: [AbandonedCityPlacement]
    let skippedSpawnOverlap: Int
    let skippedFootprintOverlap: Int
    let skippedOutOfBounds: Int
}

enum AbandonedCityLayout {
    static func makeLayout(
        terrain: TerrainConfiguration,
        loader: AbandonedCityBuildingLoader
    ) -> AbandonedCityLayoutResult {
        let targetCount = AbandonedCityOptions.targetBuildingCount(for: terrain.mapScale)
        let spawnRadius = AbandonedCityOptions.spawnClearRadius(for: terrain.mapScale)
        let layoutScale = scaleFactor(for: terrain.mapScale)
        let edgeMargin = max(20.0, terrain.worldHalfExtent * 0.05)
        let usableHalfExtent = min(
            max(spawnRadius + 70.0, terrain.worldHalfExtent - edgeMargin),
            220.0 * layoutScale
        )

        let kinds = requestedKinds(count: targetCount)
        let points = candidatePoints.map { $0 * layoutScale }
        let yaws: [Float] = [0.0, 30.0, 90.0, 180.0, 270.0].map {
            $0 * .pi / 180.0
        }
        var generator = AbandonedCitySeededGenerator(seed: terrain.seed &+ 0xABAD_C17E)
        var occupied: [AbandonedCityFootprint] = []
        var placements: [AbandonedCityPlacement] = []
        var skippedSpawnOverlap = 0
        var skippedFootprintOverlap = 0
        var skippedOutOfBounds = 0
        var kindIndex = 0

        for (candidateIndex, point) in points.enumerated() {
            guard placements.count < targetCount, kindIndex < kinds.count else {
                break
            }

            let kind = kinds[kindIndex]
            let asset = AbandonedCityAssetCatalog.buildingAsset(for: kind)
            let baseHeight = (asset.targetHeightRange.lowerBound + asset.targetHeightRange.upperBound) * 0.5
            let variation = Float.random(in: 0.92...1.08, using: &generator)
            let targetHeight = min(
                asset.targetHeightRange.upperBound,
                max(asset.targetHeightRange.lowerBound, baseHeight * variation)
            )
            guard let size = loader.normalizedSize(
                kind: kind,
                targetHeightMeters: targetHeight
            ) else {
                kindIndex += 1
                continue
            }

            let yaw = yaws[candidateIndex % yaws.count]
            let yawCosine = abs(cos(yaw))
            let yawSine = abs(sin(yaw))
            let rotatedWidth = yawCosine * size.x + yawSine * size.z
            let rotatedDepth = yawSine * size.x + yawCosine * size.z
            let padding = AbandonedCityOptions.minBuildingSpacing * 0.5
            let footprint = AbandonedCityFootprint(
                minX: point.x - rotatedWidth * 0.5 - padding,
                maxX: point.x + rotatedWidth * 0.5 + padding,
                minZ: point.y - rotatedDepth * 0.5 - padding,
                maxZ: point.y + rotatedDepth * 0.5 + padding
            )
            let spawnExclusion = AbandonedCityFootprint(
                minX: -spawnRadius,
                maxX: spawnRadius,
                minZ: -spawnRadius,
                maxZ: spawnRadius
            )

            if footprint.intersects(spawnExclusion) {
                skippedSpawnOverlap += 1
                continue
            }
            if occupied.contains(where: { $0.intersects(footprint) }) {
                skippedFootprintOverlap += 1
                continue
            }
            if footprint.minX < -usableHalfExtent ||
                footprint.maxX > usableHalfExtent ||
                footprint.minZ < -usableHalfExtent ||
                footprint.maxZ > usableHalfExtent {
                skippedOutOfBounds += 1
                continue
            }

            placements.append(AbandonedCityPlacement(
                id: UUID(),
                kind: kind,
                position: SIMD3<Float>(point.x, 0.0, point.y),
                yaw: yaw,
                targetHeightMeters: targetHeight,
                normalizedSize: size,
                footprint: footprint
            ))
            occupied.append(footprint)
            kindIndex += 1
        }

        return AbandonedCityLayoutResult(
            targetCount: targetCount,
            placements: placements,
            skippedSpawnOverlap: skippedSpawnOverlap,
            skippedFootprintOverlap: skippedFootprintOverlap,
            skippedOutOfBounds: skippedOutOfBounds
        )
    }

    private static func requestedKinds(count: Int) -> [AbandonedCityBuildingKind] {
        let shopCount = count >= 14 ? 3 : 2
        let aspectCount: Int
        switch count {
        case ...8:
            aspectCount = 2
        case 9...13:
            aspectCount = 4
        default:
            aspectCount = 5
        }
        let sengchorCount = max(0, count - shopCount - aspectCount)

        var remaining: [AbandonedCityBuildingKind: Int] = [
            .shopOldHouse: shopCount,
            .aspectHouse: aspectCount,
            .sengchorHouse: sengchorCount
        ]
        let pattern: [AbandonedCityBuildingKind] = [
            .sengchorHouse, .aspectHouse, .sengchorHouse, .shopOldHouse
        ]
        var result: [AbandonedCityBuildingKind] = []

        while result.count < count {
            var added = false
            for kind in pattern where (remaining[kind] ?? 0) > 0 {
                result.append(kind)
                remaining[kind, default: 0] -= 1
                added = true
                if result.count == count {
                    break
                }
            }
            if !added {
                break
            }
        }
        return result
    }

    private static func scaleFactor(for mapScale: MapScale) -> Float {
        switch mapScale {
        case .x4:
            return 0.80
        case .x8:
            return 0.90
        case .x16:
            return 1.00
        case .x32:
            return 1.08
        case .x64:
            return 1.16
        case .x128:
            return 1.24
        case .x256:
            return 1.32
        // Held at the x256 value. This factor spreads the authored buildings further
        // apart as the map grows; continuing the ramp onto a range hundreds of
        // kilometres across would scatter fourteen buildings so far apart that none of
        // them is ever visible from another.
        case .x512, .x1024, .x2048, .x4096, .x8192:
            return 1.32
        }
    }

    private static let candidatePoints: [SIMD2<Float>] = [
        SIMD2<Float>(-58, 20), SIMD2<Float>(58, 10), SIMD2<Float>(-20, 95),
        SIMD2<Float>(-98, 10), SIMD2<Float>(98, 22), SIMD2<Float>(20, 92),
        SIMD2<Float>(-72, 60), SIMD2<Float>(70, 60), SIMD2<Float>(60, 108),
        SIMD2<Float>(-112, 52), SIMD2<Float>(112, 55), SIMD2<Float>(-60, 112),
        SIMD2<Float>(-128, -55), SIMD2<Float>(128, -62), SIMD2<Float>(0, -118),
        SIMD2<Float>(-150, 92), SIMD2<Float>(150, 96), SIMD2<Float>(-72, -105),
        SIMD2<Float>(75, -110), SIMD2<Float>(0, 145), SIMD2<Float>(-165, 10),
        SIMD2<Float>(165, 15), SIMD2<Float>(-130, 135), SIMD2<Float>(132, 140)
    ]
}

private struct AbandonedCitySeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xABAD_C17E : seed
    }

    mutating func next() -> UInt64 {
        state = 2862933555777941757 &* state &+ 3037000493
        return state
    }
}
