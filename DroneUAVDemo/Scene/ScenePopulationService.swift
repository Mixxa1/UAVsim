import Foundation
import SceneKit
import simd

final class ScenePopulationService {
    private let containerNode = SCNNode()

    init(rootNode: SCNNode) {
        containerNode.name = "environmentContainer"
        rootNode.addChildNode(containerNode)
    }

    @discardableResult
    func populate(with terrain: TerrainConfiguration) -> ([EnvironmentObjectDescriptor], [UUID: SCNNode]) {
        containerNode.childNodes.forEach { $0.removeFromParentNode() }

        var generator = SeededRandomGenerator(seed: terrain.seed)
        let density = terrain.density.clamped(to: 0.0...1.0)
        let extent = terrain.worldHalfExtent
        let areaScale = terrain.areaScaleFactor.clamped(to: 0.1...16.0)

        var collidableDescriptors: [EnvironmentObjectDescriptor] = []

        switch terrain.preset {
        case .gridDemo:
            collidableDescriptors = generateGridDemo(
                density: density,
                safeSpawn: terrain.safeSpawnRadius,
                extent: extent,
                generator: &generator
            )
        case .field:
            collidableDescriptors = generateField(
                density: density,
                areaScale: areaScale,
                safeSpawn: terrain.safeSpawnRadius,
                extent: extent,
                generator: &generator
            )
        case .forest:
            collidableDescriptors = generateForest(
                density: density,
                areaScale: areaScale,
                safeSpawn: terrain.safeSpawnRadius,
                extent: extent,
                generator: &generator
            )
        case .city:
            collidableDescriptors = generateCity(
                density: density,
                areaScale: areaScale,
                safeSpawn: terrain.safeSpawnRadius,
                extent: extent,
                generator: &generator
            )
        }

        let beltDescriptors = generateBoundaryBelt(
            extent: extent,
            terrain: terrain.preset,
            generator: &generator
        )
        let allDescriptors = collidableDescriptors + beltDescriptors

        var nodesByID: [UUID: SCNNode] = [:]
        for descriptor in allDescriptors {
            let node = EnvironmentObjectFactory.makeNode(for: descriptor)
            nodesByID[descriptor.id] = node
            containerNode.addChildNode(node)
        }

        return (allDescriptors, nodesByID)
    }

    private func generateGridDemo(
        density: Float,
        safeSpawn: Float,
        extent: Float,
        generator: inout SeededRandomGenerator
    ) -> [EnvironmentObjectDescriptor] {
        var descriptors: [EnvironmentObjectDescriptor] = []

        let spacing: Float = 10.0
        let halfCells = max(2, Int((extent / spacing).rounded(.down)))

        for ix in -halfCells...halfCells {
            for iz in -halfCells...halfCells {
                if abs(ix) <= 1, abs(iz) <= 1 { continue }
                if Float.random(in: 0...1, using: &generator) > density + 0.18 { continue }

                let x = Float(ix) * spacing
                let z = Float(iz) * spacing
                let startDistance = simd_length(SIMD2<Float>(x, z))
                if startDistance < safeSpawn { continue }

                let kind: EnvironmentObjectKind = (abs(ix + iz) % 3 == 0) ? .marker : ((abs(ix) % 2 == 0) ? .pole : .crate)
                let size = sizeForKind(kind, terrain: .gridDemo, generator: &generator)
                descriptors.append(makeDescriptor(kind: kind, biome: .gridDemo, position: SIMD3<Float>(x, 0, z), size: size, collidable: true))
            }
        }

        return descriptors
    }

    private func generateField(
        density: Float,
        areaScale: Float,
        safeSpawn: Float,
        extent: Float,
        generator: inout SeededRandomGenerator
    ) -> [EnvironmentObjectDescriptor] {
        let count = max(24, Int(120 * density * areaScale))
        return scatterObjects(
            count: count,
            extent: extent,
            safeSpawn: safeSpawn,
            overlapPadding: 1.2,
            terrain: .field,
            generator: &generator
        ) { rng in
            let pick = Float.random(in: 0...1, using: &rng)
            if pick < 0.55 { return .tree }
            if pick < 0.78 { return .rock }
            if pick < 0.92 { return .crate }
            return .pole
        }
    }

    private func generateForest(
        density: Float,
        areaScale: Float,
        safeSpawn: Float,
        extent: Float,
        generator: inout SeededRandomGenerator
    ) -> [EnvironmentObjectDescriptor] {
        let count = max(120, Int(560 * density * areaScale))
        return scatterObjects(
            count: count,
            extent: extent,
            safeSpawn: safeSpawn,
            overlapPadding: 1.0,
            terrain: .forest,
            generator: &generator
        ) { rng in
            let pick = Float.random(in: 0...1, using: &rng)
            if pick < 0.78 { return .tree }
            if pick < 0.92 { return .rock }
            if pick < 0.97 { return .pole }
            return .crate
        }
    }

    private func generateCity(
        density: Float,
        areaScale: Float,
        safeSpawn: Float,
        extent: Float,
        generator: inout SeededRandomGenerator
    ) -> [EnvironmentObjectDescriptor] {
        var descriptors: [EnvironmentObjectDescriptor] = []
        var occupied: [(SIMD2<Float>, Float)] = []

        let blockSpacing: Float = 18.0
        let blockCount = Int((extent * 2) / blockSpacing)
        let centerOffset = Float(blockCount - 1) * blockSpacing * 0.5

        for ix in 0..<blockCount {
            for iz in 0..<blockCount {
                let x = Float(ix) * blockSpacing - centerOffset
                let z = Float(iz) * blockSpacing - centerOffset

                let axisRoad = (ix % 3 == 0) || (iz % 3 == 0)
                if axisRoad { continue }
                if Float.random(in: 0...1, using: &generator) > density + 0.08 { continue }
                if Float.random(in: 0...1, using: &generator) > min(1.0, 0.62 + areaScale * 0.12) { continue }
                if simd_length(SIMD2<Float>(x, z)) < safeSpawn + 8.0 { continue }

                let width = Float.random(in: 8.0...18.0, using: &generator)
                let depth = Float.random(in: 8.0...18.0, using: &generator)
                let height = Float.random(in: 18.0...64.0, using: &generator)
                let position = SIMD3<Float>(x + Float.random(in: -2.8...2.8, using: &generator), 0.0, z + Float.random(in: -2.8...2.8, using: &generator))

                let radius = max(width, depth) * 0.58
                if overlaps(position: SIMD2<Float>(position.x, position.z), radius: radius, occupied: occupied, padding: 1.25) {
                    continue
                }

                descriptors.append(makeDescriptor(
                    kind: .building,
                    biome: .city,
                    position: position,
                    size: SIMD3<Float>(width, height, depth),
                    collidable: true
                ))
                occupied.append((SIMD2<Float>(position.x, position.z), radius))

                if Float.random(in: 0...1, using: &generator) < 0.55 {
                    let poleOffset = SIMD3<Float>(Float.random(in: -5.0...5.0, using: &generator), 0, Float.random(in: -5.0...5.0, using: &generator))
                    let polePos = position + poleOffset
                    if simd_length(SIMD2<Float>(polePos.x, polePos.z)) > safeSpawn {
                        descriptors.append(makeDescriptor(
                            kind: .pole,
                            biome: .city,
                            position: polePos,
                            size: sizeForKind(.pole, terrain: .city, generator: &generator),
                            collidable: true
                        ))
                    }
                }
            }
        }

        return descriptors
    }

    private func scatterObjects(
        count: Int,
        extent: Float,
        safeSpawn: Float,
        overlapPadding: Float,
        terrain: TerrainPreset,
        generator: inout SeededRandomGenerator,
        pickKind: (inout SeededRandomGenerator) -> EnvironmentObjectKind
    ) -> [EnvironmentObjectDescriptor] {
        var descriptors: [EnvironmentObjectDescriptor] = []
        descriptors.reserveCapacity(count)
        var occupied: [(SIMD2<Float>, Float)] = []
        var attempts = 0

        while descriptors.count < count, attempts < count * 20 {
            attempts += 1

            let x = Float.random(in: -extent...extent, using: &generator)
            let z = Float.random(in: -extent...extent, using: &generator)
            let startDistance = simd_length(SIMD2<Float>(x, z))
            if startDistance < safeSpawn { continue }

            let kind = pickKind(&generator)
            let size = sizeForKind(kind, terrain: terrain, generator: &generator)
            let radius = max(size.x, size.z) * 0.56
            let pos2 = SIMD2<Float>(x, z)

            if overlaps(position: pos2, radius: radius, occupied: occupied, padding: overlapPadding) {
                continue
            }

            descriptors.append(makeDescriptor(
                kind: kind,
                biome: terrain,
                position: SIMD3<Float>(x, 0.0, z),
                size: size,
                collidable: true
            ))
            occupied.append((pos2, radius))
        }

        return descriptors
    }

    private func generateBoundaryBelt(
        extent: Float,
        terrain: TerrainPreset,
        generator: inout SeededRandomGenerator
    ) -> [EnvironmentObjectDescriptor] {
        var descriptors: [EnvironmentObjectDescriptor] = []
        let baseRadius = extent + 26.0
        let segmentCount = 96

        for index in 0..<segmentCount {
            let theta = (Float(index) / Float(segmentCount)) * (.pi * 2)
            let radialJitter = Float.random(in: -6.0...8.0, using: &generator)
            let x = cos(theta) * (baseRadius + radialJitter)
            let z = sin(theta) * (baseRadius + radialJitter)

            switch terrain {
            case .forest:
                let size = SIMD3<Float>(
                    Float.random(in: 2.2...5.4, using: &generator),
                    Float.random(in: 10.0...24.0, using: &generator),
                    Float.random(in: 2.2...5.4, using: &generator)
                )
                descriptors.append(makeDescriptor(
                    kind: .tree,
                    biome: .forest,
                    position: SIMD3<Float>(x, 0.0, z),
                    size: size,
                    collidable: false
                ))

            case .city:
                let width = Float.random(in: 9.0...20.0, using: &generator)
                let depth = Float.random(in: 8.0...18.0, using: &generator)
                let height = Float.random(in: 28.0...90.0, using: &generator)
                descriptors.append(makeDescriptor(
                    kind: .building,
                    biome: .city,
                    position: SIMD3<Float>(x, 0.0, z),
                    size: SIMD3<Float>(width, height, depth),
                    collidable: false
                ))

            case .field:
                let kind: EnvironmentObjectKind = Float.random(in: 0...1, using: &generator) < 0.76 ? .distantBelt : .tree
                let size = kind == .distantBelt
                    ? SIMD3<Float>(Float.random(in: 14.0...32.0, using: &generator), Float.random(in: 4.0...11.0, using: &generator), Float.random(in: 5.0...13.0, using: &generator))
                    : SIMD3<Float>(Float.random(in: 1.8...3.8, using: &generator), Float.random(in: 6.0...14.0, using: &generator), Float.random(in: 1.8...3.8, using: &generator))
                descriptors.append(makeDescriptor(
                    kind: kind,
                    biome: .field,
                    position: SIMD3<Float>(x, 0.0, z),
                    size: size,
                    collidable: false
                ))

            case .gridDemo:
                let width = Float.random(in: 10.0...18.0, using: &generator)
                let depth = Float.random(in: 6.0...12.0, using: &generator)
                let height = Float.random(in: 16.0...32.0, using: &generator)
                descriptors.append(makeDescriptor(
                    kind: .distantBelt,
                    biome: .gridDemo,
                    position: SIMD3<Float>(x, 0.0, z),
                    size: SIMD3<Float>(width, height, depth),
                    collidable: false
                ))
            }
        }

        return descriptors
    }

    private func makeDescriptor(kind: EnvironmentObjectKind, biome: TerrainPreset, position: SIMD3<Float>, size: SIMD3<Float>, collidable: Bool) -> EnvironmentObjectDescriptor {
        EnvironmentObjectDescriptor(
            id: UUID(),
            kind: kind,
            biome: biome,
            position: position,
            size: size,
            boundingRadius: max(size.x, max(size.y, size.z)) * 0.55,
            isCollidable: collidable
        )
    }

    private func overlaps(position: SIMD2<Float>, radius: Float, occupied: [(SIMD2<Float>, Float)], padding: Float) -> Bool {
        for entry in occupied {
            let distance = simd_distance(entry.0, position)
            if distance < (entry.1 + radius) * padding {
                return true
            }
        }
        return false
    }

    private func sizeForKind(_ kind: EnvironmentObjectKind, terrain: TerrainPreset, generator: inout SeededRandomGenerator) -> SIMD3<Float> {
        switch kind {
        case .tree:
            return SIMD3<Float>(
                Float.random(in: 1.8...4.8, using: &generator),
                Float.random(in: 7.0...18.0, using: &generator),
                Float.random(in: 1.8...4.8, using: &generator)
            )
        case .building:
            return SIMD3<Float>(
                Float.random(in: 8.0...24.0, using: &generator),
                Float.random(in: 18.0...72.0, using: &generator),
                Float.random(in: 8.0...24.0, using: &generator)
            )
        case .pole:
            return SIMD3<Float>(
                Float.random(in: 0.4...0.9, using: &generator),
                Float.random(in: 8.0...18.0, using: &generator),
                Float.random(in: 0.4...0.9, using: &generator)
            )
        case .crate:
            return SIMD3<Float>(
                Float.random(in: 1.0...3.0, using: &generator),
                Float.random(in: 1.0...3.5, using: &generator),
                Float.random(in: 1.0...3.0, using: &generator)
            )
        case .rock:
            return SIMD3<Float>(
                Float.random(in: 1.2...3.2, using: &generator),
                Float.random(in: 0.8...2.2, using: &generator),
                Float.random(in: 1.2...3.2, using: &generator)
            )
        case .marker:
            return SIMD3<Float>(
                Float.random(in: 0.8...1.6, using: &generator),
                Float.random(in: 1.5...3.2, using: &generator),
                Float.random(in: 0.8...1.6, using: &generator)
            )
        case .distantBelt:
            return SIMD3<Float>(16.0, 32.0, 8.0)
        }
    }
}

private struct SeededRandomGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xCAFE_BABE : seed
    }

    mutating func next() -> UInt64 {
        state = 2862933555777941757 &* state &+ 3037000493
        return state
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
