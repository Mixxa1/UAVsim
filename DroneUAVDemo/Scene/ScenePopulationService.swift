import Foundation
import SceneKit
import simd

final class ScenePopulationService {
    private let containerNode = SCNNode()
    private let treeVisualsNode = SCNNode()
    private var storedTreeDescriptors: [EnvironmentObjectDescriptor] = []
    private var lastVisualQuality: EnvironmentVisualQuality = .detailed

    init(rootNode: SCNNode) {
        containerNode.name = "environmentContainer"
        treeVisualsNode.name = "environment.trees"
        rootNode.addChildNode(containerNode)
        containerNode.addChildNode(treeVisualsNode)
    }

    @discardableResult
    func populate(
        with terrain: TerrainConfiguration,
        visualQuality: EnvironmentVisualQuality = .detailed
    ) -> ([EnvironmentObjectDescriptor], [UUID: SCNNode]) {
        containerNode.childNodes.forEach { $0.removeFromParentNode() }

        var generator = SeededRandomGenerator(seed: terrain.seed)
        let density = terrain.density.clamped(to: 0.0...1.0)
        let extent = terrain.worldHalfExtent
        let areaScale = terrain.areaScaleFactor.clamped(to: 0.25...2.2)

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
        case .cargoYard:
            collidableDescriptors = generateCargoYard(
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

        collidableDescriptors = cappedCollidableDescriptors(collidableDescriptors, for: terrain)

        let beltDescriptors = generateBoundaryBelt(
            terrain: terrain,
            generator: &generator
        )
        let allDescriptors = collidableDescriptors + beltDescriptors

        // Re-establish treeVisualsNode after clearing containerNode children
        containerNode.addChildNode(treeVisualsNode)
        lastVisualQuality = visualQuality
        storedTreeDescriptors = allDescriptors.filter { $0.kind == .tree }

        var nodesByID: [UUID: SCNNode] = [:]
        nodesByID.reserveCapacity(allDescriptors.count)
        for descriptor in allDescriptors {
            let node = EnvironmentObjectFactory.makeNode(for: descriptor, quality: visualQuality)
            nodesByID[descriptor.id] = node
            if descriptor.kind == .tree {
                treeVisualsNode.addChildNode(node)
            } else {
                containerNode.addChildNode(node)
            }
        }

        return (allDescriptors, nodesByID)
    }

    func refreshTreeVisuals(snowWeatherActive: Bool) {
        EnvironmentObjectFactory.snowWeatherActive = snowWeatherActive
        treeVisualsNode.childNodes.forEach { $0.removeFromParentNode() }
        EnvironmentObjectFactory.resetDiagnostics()
        for descriptor in storedTreeDescriptors {
            let node = EnvironmentObjectFactory.makeNode(for: descriptor, quality: lastVisualQuality)
            treeVisualsNode.addChildNode(node)
        }
        EnvironmentObjectFactory.printDiagnostics()
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

    private func cappedCollidableDescriptors(
        _ descriptors: [EnvironmentObjectDescriptor],
        for terrain: TerrainConfiguration
    ) -> [EnvironmentObjectDescriptor] {
        let limit = maxCollidableObjectCount(for: terrain)
        guard descriptors.count > limit else {
            return descriptors
        }

        let stride = Double(descriptors.count) / Double(limit)
        return (0..<limit).map { index in
            descriptors[min(descriptors.count - 1, Int((Double(index) * stride).rounded(.down)))]
        }
    }

    private func maxCollidableObjectCount(for terrain: TerrainConfiguration) -> Int {
        let densityFactor = Double(terrain.density.clamped(to: 0.0...1.0))
        let scaleFactor = min(Double(terrain.areaScaleFactor), 2.2)
        let multiplier = 0.72 + densityFactor * 0.24 + scaleFactor * 0.06

        let baseLimit: Double
        switch terrain.preset {
        case .gridDemo:
            baseLimit = 340
        case .field:
            baseLimit = 420
        case .forest:
            baseLimit = 720
        case .cargoYard:
            baseLimit = 560
        case .city:
            baseLimit = 620
        }

        return max(180, Int((baseLimit * multiplier).rounded()))
    }

    private func generateField(
        density: Float,
        areaScale: Float,
        safeSpawn: Float,
        extent: Float,
        generator: inout SeededRandomGenerator
    ) -> [EnvironmentObjectDescriptor] {
        var descriptors: [EnvironmentObjectDescriptor] = []
        var occupied: [(SIMD2<Float>, Float)] = []
        let coverageScale = max(1.0, extent / 96.0)
        let featureScale = min(3.2, max(0.9, areaScale * 0.54 + coverageScale * 0.40))

        let hedgerowCount = max(2, Int((1.4 + density * 1.8) * featureScale))
        let lineReach = extent * 0.74

        for _ in 0..<hedgerowCount {
            let angle = Float.random(in: 0.0...(.pi * 2.0), using: &generator)
            let direction = SIMD2<Float>(cos(angle), sin(angle))
            let normal = SIMD2<Float>(-direction.y, direction.x)
            let centerOffset = Float.random(in: -(extent * 0.52)...(extent * 0.52), using: &generator)
            let center = normal * centerOffset
            let rowHalfLength = lineReach * Float.random(in: 0.52...0.82, using: &generator)
            let start = center - direction * rowHalfLength
            let end = center + direction * rowHalfLength
            let spacing = Float.random(in: 18.0...28.0, using: &generator)
            let steps = max(4, Int((rowHalfLength * 2.0 / spacing).rounded(.up)))

            for index in 0...steps {
                let t = Float(index) / Float(max(1, steps))
                let base = start + (end - start) * t
                let jitter = normal * Float.random(in: -5.5...5.5, using: &generator)
                let position = base + jitter
                let chance = Float.random(in: 0.0...1.0, using: &generator)
                let kind: EnvironmentObjectKind = chance < 0.72 ? .tree : .pole
                _ = appendPlacedObject(
                    kind: kind,
                    terrain: .field,
                    position: position,
                    safeSpawn: safeSpawn,
                    overlapPadding: 1.08,
                    occupied: &occupied,
                    descriptors: &descriptors,
                    generator: &generator
                )
            }
        }

        let groveCount = max(2, Int((1.0 + density * 1.6) * featureScale))
        for _ in 0..<groveCount {
            let center = randomPosition(
                extent: extent * 0.78,
                safeSpawn: safeSpawn + 18.0,
                generator: &generator
            )
            let radius = Float.random(in: 8.0...16.0, using: &generator)
            let count = max(4, Int(Float.random(in: 4.0...8.0, using: &generator) * max(0.45, density) * 1.15))
            appendCluster(
                count: count,
                center: center,
                radius: radius,
                terrain: .field,
                safeSpawn: safeSpawn,
                overlapPadding: 1.03,
                occupied: &occupied,
                descriptors: &descriptors,
                generator: &generator
            ) { rng in
                let pick = Float.random(in: 0.0...1.0, using: &rng)
                if pick < 0.74 { return .tree }
                if pick < 0.90 { return .crate }
                return .pole
            }
        }

        let rockClusterCount = max(1, Int((0.6 + density * 1.2) * max(0.85, featureScale * 0.34)))
        for _ in 0..<rockClusterCount {
            let center = randomPosition(
                extent: extent * 0.76,
                safeSpawn: safeSpawn + 14.0,
                generator: &generator
            )
            let radius = Float.random(in: 6.0...12.0, using: &generator)
            let count = Int.random(in: 2...4, using: &generator)
            appendCluster(
                count: count,
                center: center,
                radius: radius,
                terrain: .field,
                safeSpawn: safeSpawn,
                overlapPadding: 1.05,
                occupied: &occupied,
                descriptors: &descriptors,
                generator: &generator
            ) { _ in
                .rock
            }
        }

        let farmsteadCount = max(3, Int((2.0 + density * 3.2) * max(1.0, featureScale * 0.62)))
        for _ in 0..<farmsteadCount {
            let center = randomPosition(
                extent: extent * 0.70,
                safeSpawn: safeSpawn + 20.0,
                generator: &generator
            )
            let poleCount = Int.random(in: 1...2, using: &generator)
            for _ in 0..<poleCount {
                let offset = SIMD2<Float>(
                    Float.random(in: -5.0...5.0, using: &generator),
                    Float.random(in: -5.0...5.0, using: &generator)
                )
                _ = appendPlacedObject(
                    kind: .pole,
                    terrain: .field,
                    position: center + offset,
                    safeSpawn: safeSpawn,
                    overlapPadding: 1.12,
                    occupied: &occupied,
                    descriptors: &descriptors,
                    generator: &generator
                )
            }

            let crateCount = Int.random(in: 2...4, using: &generator)
            appendCluster(
                count: crateCount,
                center: center,
                radius: 4.8,
                terrain: .field,
                safeSpawn: safeSpawn,
                overlapPadding: 1.06,
                occupied: &occupied,
                descriptors: &descriptors,
                generator: &generator
            ) { _ in
                .crate
            }
        }

        let scatterCount = max(14, Int(30.0 * max(0.24, density) * featureScale))
        appendScatter(
            count: scatterCount,
            extent: extent * 0.84,
            safeSpawn: safeSpawn,
            overlapPadding: 1.18,
            terrain: .field,
            occupied: &occupied,
            descriptors: &descriptors,
            generator: &generator
        ) { rng in
            let pick = Float.random(in: 0.0...1.0, using: &rng)
            if pick < 0.46 { return .tree }
            if pick < 0.74 { return .crate }
            if pick < 0.92 { return .pole }
            return .rock
        }

        return descriptors
    }

    private func generateForest(
        density: Float,
        areaScale: Float,
        safeSpawn: Float,
        extent: Float,
        generator: inout SeededRandomGenerator
    ) -> [EnvironmentObjectDescriptor] {
        var descriptors: [EnvironmentObjectDescriptor] = []
        var occupied: [(SIMD2<Float>, Float)] = []
        let coverageScale = max(1.0, extent / 96.0)
        let featureScale = min(1.85, max(1.05, areaScale * 0.62 + min(coverageScale, 2.5) * 0.24))

        var clearings: [(center: SIMD2<Float>, radius: Float)] = [
            (SIMD2<Float>(repeating: 0.0), safeSpawn + 16.0)
        ]

        let extraClearings = max(2, Int((1.0 + featureScale * 0.8).rounded(.down)))
        for _ in 0..<extraClearings {
            clearings.append((
                randomPosition(extent: extent * 0.68, safeSpawn: safeSpawn + 24.0, generator: &generator),
                Float.random(in: 10.0...22.0, using: &generator)
            ))
        }

        let clusterCount = min(28, max(10, Int((10.0 + density * 7.0) * featureScale)))
        for _ in 0..<clusterCount {
            let center = randomPosition(extent: extent * 0.84, safeSpawn: safeSpawn + 14.0, generator: &generator)
            if isInsideClearing(center, clearings: clearings) {
                continue
            }

            let radius = Float.random(in: 14.0...30.0, using: &generator)
            let count = max(10, Int(Float.random(in: 12.0...24.0, using: &generator) * max(0.70, density) * 1.05))
            appendCluster(
                count: count,
                center: center,
                radius: radius,
                terrain: .forest,
                safeSpawn: safeSpawn,
                overlapPadding: 1.0,
                occupied: &occupied,
                descriptors: &descriptors,
                generator: &generator
            ) { rng in
                let pick = Float.random(in: 0.0...1.0, using: &rng)
                if pick < 0.95 { return .tree }
                if pick < 0.985 { return .pole }
                return .crate
            } placementValidator: { position in
                !self.isInsideClearing(position, clearings: clearings)
            }
        }

        for clearing in clearings.dropFirst() {
            let outcropCount = Int.random(in: 1...3, using: &generator)
            appendCluster(
                count: outcropCount,
                center: clearing.center + SIMD2<Float>(
                    Float.random(in: -6.0...6.0, using: &generator),
                    Float.random(in: -6.0...6.0, using: &generator)
                ),
                radius: max(5.0, clearing.radius * 0.55),
                terrain: .forest,
                safeSpawn: safeSpawn,
                overlapPadding: 1.02,
                occupied: &occupied,
                descriptors: &descriptors,
                generator: &generator
            ) { rng in
                Float.random(in: 0.0...1.0, using: &rng) < 0.28 ? .rock : .crate
            } placementValidator: { position in
                !self.isInsideClearing(position, clearings: clearings.filter { $0.center != clearing.center })
            }

            if Float.random(in: 0.0...1.0, using: &generator) < 0.72 {
                _ = appendPlacedObject(
                    kind: .pole,
                    terrain: .forest,
                    position: clearing.center + SIMD2<Float>(
                        Float.random(in: -(clearing.radius * 0.6)...(clearing.radius * 0.6), using: &generator),
                        Float.random(in: -(clearing.radius * 0.6)...(clearing.radius * 0.6), using: &generator)
                    ),
                    safeSpawn: safeSpawn,
                    overlapPadding: 1.06,
                    occupied: &occupied,
                    descriptors: &descriptors,
                    generator: &generator
                )
            }
        }

        let fillCount = min(420, max(120, Int(190.0 * max(0.55, density) * featureScale)))
        appendScatter(
            count: fillCount,
            extent: extent * 0.88,
            safeSpawn: safeSpawn,
            overlapPadding: 1.02,
            terrain: .forest,
            occupied: &occupied,
            descriptors: &descriptors,
            generator: &generator,
            placementValidator: { position in
                !self.isInsideClearing(position, clearings: clearings)
            }
        ) { rng in
            let pick = Float.random(in: 0.0...1.0, using: &rng)
            if pick < 0.95 { return .tree }
            if pick < 0.975 { return .pole }
            if pick < 0.995 { return .crate }
            return .rock
        }

        let decorativeForestCount = min(520, max(160, Int(220.0 * featureScale)))
        appendScatter(
            count: decorativeForestCount,
            extent: extent * 0.94,
            safeSpawn: safeSpawn,
            overlapPadding: 0.98,
            terrain: .forest,
            occupied: &occupied,
            descriptors: &descriptors,
            generator: &generator,
            collidable: false,
            placementValidator: { position in
                !self.isInsideClearing(position, clearings: clearings)
            }
        ) { rng in
            let pick = Float.random(in: 0.0...1.0, using: &rng)
            if pick < 0.992 { return .tree }
            return .crate
        }

        return descriptors
    }

    private func generateCargoYard(
        density: Float,
        areaScale: Float,
        safeSpawn: Float,
        extent: Float,
        generator: inout SeededRandomGenerator
    ) -> [EnvironmentObjectDescriptor] {
        var descriptors: [EnvironmentObjectDescriptor] = []
        var occupied: [(SIMD2<Float>, Float)] = []

        let coverageScale = min(max(1.0, extent / 96.0), 2.8)
        let yardScale = max(1.0, areaScale * 0.64 + coverageScale * 0.32)
        let padPitchX: Float = 19.0 + min(yardScale, 5.0) * 2.9
        let padPitchZ: Float = 16.0 + min(yardScale, 5.0) * 2.4
        let spawnExclusionRadius = safeSpawn + max(padPitchX, padPitchZ) * 1.75
        let columnCount = min(18, max(4, Int((extent * 2.0) / padPitchX)))
        let rowCount = min(18, max(4, Int((extent * 2.0) / padPitchZ)))
        let layoutWidth = extent * 1.72
        let layoutDepth = extent * 1.72
        let effectivePadPitchX = columnCount > 1 ? layoutWidth / Float(columnCount - 1) : padPitchX
        let effectivePadPitchZ = rowCount > 1 ? layoutDepth / Float(rowCount - 1) : padPitchZ
        let centerOffsetX = Float(columnCount - 1) * effectivePadPitchX * 0.5
        let centerOffsetZ = Float(rowCount - 1) * effectivePadPitchZ * 0.5

        for ix in 0..<columnCount {
            for iz in 0..<rowCount {
                let center = SIMD2<Float>(
                    Float(ix) * effectivePadPitchX - centerOffsetX,
                    Float(iz) * effectivePadPitchZ - centerOffsetZ
                )

                let mainAisleX = ix % 4 == 0
                let mainAisleZ = iz % 3 == 0
                if mainAisleX || mainAisleZ {
                    if simd_length(center) < spawnExclusionRadius {
                        continue
                    }
                    if Float.random(in: 0.0...1.0, using: &generator) < 0.18 {
                        _ = appendPlacedObject(
                            kind: Float.random(in: 0.0...1.0, using: &generator) < 0.72 ? .pole : .marker,
                            terrain: .cargoYard,
                            position: center + SIMD2<Float>(
                                Float.random(in: -3.2...3.2, using: &generator),
                                Float.random(in: -3.2...3.2, using: &generator)
                            ),
                            safeSpawn: spawnExclusionRadius,
                            overlapPadding: 1.08,
                            occupied: &occupied,
                            descriptors: &descriptors,
                            generator: &generator
                        )
                    }
                    continue
                }

                let layoutRoll = Float.random(in: 0.0...1.0, using: &generator)
                let footprintRadius: Float
                if layoutRoll < 0.26 {
                    footprintRadius = 5.6
                } else if layoutRoll < 0.64 {
                    footprintRadius = 4.8
                } else {
                    footprintRadius = 4.2
                }

                if simd_length(center) < spawnExclusionRadius + footprintRadius {
                    continue
                }
                guard !overlaps(position: center, radius: footprintRadius, occupied: occupied, padding: 1.10) else {
                    continue
                }
                occupied.append((center, footprintRadius))

                let yaw: Float = Float.random(in: 0.0...1.0, using: &generator) < 0.5 ? 0.0 : (.pi / 2.0)
                if layoutRoll < 0.26 {
                    appendCargoGate(
                        center: center,
                        yawRadians: yaw,
                        descriptors: &descriptors,
                        generator: &generator
                    )
                } else if layoutRoll < 0.64 {
                    appendCargoStackCluster(
                        center: center,
                        yawRadians: yaw,
                        descriptors: &descriptors,
                        generator: &generator
                    )
                } else {
                    appendCargoLongStack(
                        center: center,
                        yawRadians: yaw,
                        descriptors: &descriptors,
                        generator: &generator
                    )
                }
            }
        }

        let serviceObjectCount = max(8, Int((6.0 + density * 10.0) * max(1.0, yardScale * 0.62)))
        appendScatter(
            count: serviceObjectCount,
            extent: extent * 0.88,
            safeSpawn: spawnExclusionRadius,
            overlapPadding: 1.10,
            terrain: .cargoYard,
            occupied: &occupied,
            descriptors: &descriptors,
            generator: &generator
        ) { rng in
            let pick = Float.random(in: 0.0...1.0, using: &rng)
            if pick < 0.58 { return .pole }
            if pick < 0.84 { return .marker }
            return .crate
        }

        return descriptors
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

        let coverageScale = min(max(1.0, extent / 96.0), 2.8)
        let urbanScale = max(1.0, areaScale * 0.72 + coverageScale * 0.28)
        let blockPitch: Float = 38.0 + min(urbanScale, 5.0) * 3.6
        let roadWidth: Float = 10.0 + min(urbanScale, 4.2) * 1.4
        let blockSpan = max(22.0, blockPitch - roadWidth)
        let halfBlock = blockSpan * 0.5
        let blockCount = min(14, max(2, Int((extent * 2.0) / blockPitch)))
        let layoutWidth = extent * 1.72
        let effectiveBlockPitch = blockCount > 1 ? layoutWidth / Float(blockCount - 1) : blockPitch
        let centerOffset = Float(blockCount - 1) * effectiveBlockPitch * 0.5

        for ix in 0..<blockCount {
            for iz in 0..<blockCount {
                let center = SIMD2<Float>(
                    Float(ix) * effectiveBlockPitch - centerOffset,
                    Float(iz) * effectiveBlockPitch - centerOffset
                )

                if simd_length(center) < safeSpawn + blockPitch * 0.78 {
                    continue
                }

                let distanceRatio = (simd_length(center) / max(extent, 1.0)).clamped(to: 0.0...1.0)
                let centrality = (1.0 - distanceRatio).clamped(to: 0.18...1.0)
                let avenueX = ix % 3 == 0
                let avenueZ = iz % 3 == 0
                let occupancyChance = min(0.97, 0.58 + density * 0.26 + centrality * 0.18)
                let blockRoll = Float.random(in: 0.0...1.0, using: &generator)

                if blockRoll > occupancyChance {
                    if Float.random(in: 0.0...1.0, using: &generator) < 0.62 {
                        appendCluster(
                            count: Int.random(in: 4...9, using: &generator),
                            center: center,
                            radius: blockSpan * 0.24,
                            terrain: .city,
                            safeSpawn: safeSpawn,
                            overlapPadding: 0.98,
                            occupied: &occupied,
                            descriptors: &descriptors,
                            generator: &generator
                        ) { rng in
                            Float.random(in: 0.0...1.0, using: &rng) < 0.82 ? .tree : .pole
                        }
                    }
                    continue
                }

                let sideSetback = max(1.4, roadWidth * 0.16)
                let avenueBoost: Float = (avenueX || avenueZ) ? 1.16 : 1.0
                let lotDepthBase = max(9.0, halfBlock - sideSetback - 0.8)

                appendCityFrontage(
                    center: center,
                    isHorizontal: true,
                    sign: 1.0,
                    frontageLength: blockSpan - 5.0,
                    lotDepthBase: lotDepthBase,
                    safeSpawn: safeSpawn,
                    density: density,
                    centrality: centrality,
                    avenueBoost: avenueBoost,
                    occupied: &occupied,
                    descriptors: &descriptors,
                    generator: &generator
                )
                appendCityFrontage(
                    center: center,
                    isHorizontal: true,
                    sign: -1.0,
                    frontageLength: blockSpan - 5.0,
                    lotDepthBase: lotDepthBase,
                    safeSpawn: safeSpawn,
                    density: density,
                    centrality: centrality,
                    avenueBoost: avenueBoost,
                    occupied: &occupied,
                    descriptors: &descriptors,
                    generator: &generator
                )
                appendCityFrontage(
                    center: center,
                    isHorizontal: false,
                    sign: 1.0,
                    frontageLength: blockSpan - 6.0,
                    lotDepthBase: lotDepthBase,
                    safeSpawn: safeSpawn,
                    density: density,
                    centrality: centrality,
                    avenueBoost: avenueBoost,
                    occupied: &occupied,
                    descriptors: &descriptors,
                    generator: &generator
                )
                appendCityFrontage(
                    center: center,
                    isHorizontal: false,
                    sign: -1.0,
                    frontageLength: blockSpan - 6.0,
                    lotDepthBase: lotDepthBase,
                    safeSpawn: safeSpawn,
                    density: density,
                    centrality: centrality,
                    avenueBoost: avenueBoost,
                    occupied: &occupied,
                    descriptors: &descriptors,
                    generator: &generator
                )

                let towerChance = min(0.34, 0.08 + centrality * 0.18 + ((avenueX && avenueZ) ? 0.10 : 0.0))
                if blockSpan > 24.0,
                   Float.random(in: 0.0...1.0, using: &generator) < towerChance {
                    let centerWidth = Float.random(in: 8.0...12.0, using: &generator)
                    let centerDepth = Float.random(in: 8.0...12.0, using: &generator)
                    let centerHeight = Float.random(in: 22.0...54.0, using: &generator)
                    appendCityBuilding(
                        at: center + SIMD2<Float>(
                            Float.random(in: -2.2...2.2, using: &generator),
                            Float.random(in: -2.2...2.2, using: &generator)
                        ),
                        yawRadians: Float.random(in: 0.0...1.0, using: &generator) < 0.5 ? 0.0 : (.pi / 2.0),
                        size: SIMD3<Float>(centerWidth, centerHeight, centerDepth),
                        safeSpawn: safeSpawn,
                        occupied: &occupied,
                        descriptors: &descriptors
                    )
                }

                let cornerPoleChance = min(0.9, 0.46 + density * 0.28)
                if Float.random(in: 0.0...1.0, using: &generator) < cornerPoleChance {
                    let poleOffsets: [SIMD2<Float>] = [
                        SIMD2<Float>( halfBlock + roadWidth * 0.22,  halfBlock + roadWidth * 0.22),
                        SIMD2<Float>(-halfBlock - roadWidth * 0.22,  halfBlock + roadWidth * 0.22),
                        SIMD2<Float>( halfBlock + roadWidth * 0.22, -halfBlock - roadWidth * 0.22),
                        SIMD2<Float>(-halfBlock - roadWidth * 0.22, -halfBlock - roadWidth * 0.22)
                    ]
                    for offset in poleOffsets where Float.random(in: 0.0...1.0, using: &generator) < 0.58 {
                        _ = appendPlacedObject(
                            kind: .pole,
                            terrain: .city,
                            position: center + offset,
                            safeSpawn: safeSpawn,
                            overlapPadding: 1.10,
                            occupied: &occupied,
                            descriptors: &descriptors,
                            generator: &generator
                        )
                    }
                }
            }
        }

        return descriptors
    }

    private func appendCityFrontage(
        center: SIMD2<Float>,
        isHorizontal: Bool,
        sign: Float,
        frontageLength: Float,
        lotDepthBase: Float,
        safeSpawn: Float,
        density: Float,
        centrality: Float,
        avenueBoost: Float,
        occupied: inout [(SIMD2<Float>, Float)],
        descriptors: inout [EnvironmentObjectDescriptor],
        generator: inout SeededRandomGenerator
    ) {
        let baseYaw: Float = isHorizontal ? 0.0 : (.pi / 2.0)
        let minLotWidth: Float = isHorizontal ? 9.5 : 8.5
        let maxLotWidth: Float = isHorizontal ? 16.0 : 13.0
        let innerSetback = Float.random(in: 0.8...1.8, using: &generator)
        let usableHalfSpan = max(8.0, frontageLength * 0.5 - 1.8)
        let serviceGapChance = max(0.05, 0.16 - density * 0.05)

        var cursor = -usableHalfSpan
        while cursor < usableHalfSpan - minLotWidth {
            let remaining = usableHalfSpan - cursor
            let lotWidth = min(remaining, Float.random(in: minLotWidth...maxLotWidth, using: &generator))
            let alongCenter = cursor + lotWidth * 0.5
            let leavesServiceGap = remaining > minLotWidth * 1.4
                && Float.random(in: 0.0...1.0, using: &generator) < serviceGapChance

            if !leavesServiceGap {
                var buildingWidth = max(7.2, lotWidth - Float.random(in: 0.8...2.2, using: &generator))
                var buildingDepth = max(8.0, lotDepthBase * Float.random(in: 0.64...0.92, using: &generator))
                var buildingHeight = min(
                    110.0,
                    max(
                        12.0,
                        mix(14.0, 56.0, centrality)
                            * avenueBoost
                            * Float.random(in: 0.74...1.18, using: &generator)
                    )
                )

                if Float.random(in: 0.0...1.0, using: &generator) < max(0.06, 0.14 * centrality) {
                    buildingHeight *= Float.random(in: 1.18...1.52, using: &generator)
                    buildingWidth *= Float.random(in: 0.72...0.92, using: &generator)
                    buildingDepth *= Float.random(in: 0.72...0.92, using: &generator)
                }

                let planarPosition: SIMD2<Float>
                if isHorizontal {
                    planarPosition = SIMD2<Float>(
                        center.x + alongCenter,
                        center.y + sign * (lotDepthBase - buildingDepth * 0.5 - innerSetback)
                    )
                } else {
                    planarPosition = SIMD2<Float>(
                        center.x + sign * (lotDepthBase - buildingDepth * 0.5 - innerSetback),
                        center.y + alongCenter
                    )
                }

                appendCityBuilding(
                    at: planarPosition,
                    yawRadians: baseYaw,
                    size: SIMD3<Float>(buildingWidth, buildingHeight, buildingDepth),
                    safeSpawn: safeSpawn,
                    occupied: &occupied,
                    descriptors: &descriptors
                )
            }

            cursor += lotWidth + Float.random(in: 1.2...2.8, using: &generator)
        }
    }

    private func appendCityBuilding(
        at position: SIMD2<Float>,
        yawRadians: Float,
        size: SIMD3<Float>,
        safeSpawn: Float,
        occupied: inout [(SIMD2<Float>, Float)],
        descriptors: inout [EnvironmentObjectDescriptor]
    ) {
        let radius = max(size.x, size.z) * 0.58
        guard simd_length(position) >= safeSpawn + radius * 0.75 else {
            return
        }
        guard !overlaps(position: position, radius: radius, occupied: occupied, padding: 1.22) else {
            return
        }

        descriptors.append(makeDescriptor(
            kind: .building,
            biome: .city,
            position: SIMD3<Float>(position.x, 0.0, position.y),
            yawRadians: yawRadians,
            size: size,
            collidable: true
        ))
        occupied.append((position, radius))
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
        terrain: TerrainConfiguration,
        generator: inout SeededRandomGenerator
    ) -> [EnvironmentObjectDescriptor] {
        var descriptors: [EnvironmentObjectDescriptor] = []
        let innerRadius = terrain.worldHalfExtent + 24.0
        let outerRadius = terrain.scenicHalfExtent
        let ringCount: Int

        switch terrain.preset {
        case .forest:
            ringCount = 4
        case .field:
            ringCount = 3
        case .cargoYard:
            ringCount = 3
        case .city:
            ringCount = 3
        case .gridDemo:
            ringCount = 2
        }

        for ringIndex in 0..<ringCount {
            let ringProgress = Float(ringIndex + 1) / Float(ringCount)
            let baseRadius = mix(innerRadius, outerRadius, ringProgress)
            let segmentCount = Int(72.0 + ringProgress * 26.0)

            for index in 0..<segmentCount {
                let theta = (Float(index) / Float(segmentCount)) * (.pi * 2.0)
                let radialJitter = Float.random(in: -12.0...16.0, using: &generator)
                let radius = baseRadius + radialJitter
                let x = cos(theta) * radius
                let z = sin(theta) * radius

                switch terrain.preset {
                case .forest:
                    let size = SIMD3<Float>(
                        Float.random(in: 2.6...6.4, using: &generator),
                        Float.random(in: 12.0...28.0, using: &generator),
                        Float.random(in: 2.6...6.4, using: &generator)
                    )
                    descriptors.append(makeDescriptor(
                        kind: .tree,
                        biome: .forest,
                        position: SIMD3<Float>(x, 0.0, z),
                        size: size,
                        collidable: false
                    ))

                case .city:
                    let width = Float.random(in: 10.0...24.0, using: &generator)
                    let depth = Float.random(in: 10.0...20.0, using: &generator)
                    let height = Float.random(in: 34.0...110.0, using: &generator)
                    descriptors.append(makeDescriptor(
                        kind: .building,
                        biome: .city,
                        position: SIMD3<Float>(x, 0.0, z),
                        size: SIMD3<Float>(width, height, depth),
                        collidable: false
                    ))

                case .cargoYard:
                    descriptors.append(makeDescriptor(
                        kind: .distantBelt,
                        biome: .cargoYard,
                        position: SIMD3<Float>(x, 0.0, z),
                        size: SIMD3<Float>(
                            Float.random(in: 20.0...44.0, using: &generator),
                            Float.random(in: 8.0...18.0, using: &generator),
                            Float.random(in: 10.0...24.0, using: &generator)
                        ),
                        collidable: false
                    ))

                case .field:
                    let kind: EnvironmentObjectKind = Float.random(in: 0.0...1.0, using: &generator) < 0.72 ? .distantBelt : .tree
                    let size = kind == .distantBelt
                        ? SIMD3<Float>(
                            Float.random(in: 18.0...40.0, using: &generator),
                            Float.random(in: 4.5...12.0, using: &generator),
                            Float.random(in: 6.0...16.0, using: &generator)
                        )
                        : SIMD3<Float>(
                            Float.random(in: 1.8...4.6, using: &generator),
                            Float.random(in: 8.0...18.0, using: &generator),
                            Float.random(in: 1.8...4.6, using: &generator)
                        )
                    descriptors.append(makeDescriptor(
                        kind: kind,
                        biome: .field,
                        position: SIMD3<Float>(x, 0.0, z),
                        size: size,
                        collidable: false
                    ))

                case .gridDemo:
                    descriptors.append(makeDescriptor(
                        kind: .distantBelt,
                        biome: .gridDemo,
                        position: SIMD3<Float>(x, 0.0, z),
                        size: SIMD3<Float>(
                            Float.random(in: 12.0...22.0, using: &generator),
                            Float.random(in: 18.0...36.0, using: &generator),
                            Float.random(in: 8.0...16.0, using: &generator)
                        ),
                        collidable: false
                    ))
                }
            }
        }

        return descriptors
    }

    private func appendScatter(
        count: Int,
        extent: Float,
        safeSpawn: Float,
        overlapPadding: Float,
        terrain: TerrainPreset,
        occupied: inout [(SIMD2<Float>, Float)],
        descriptors: inout [EnvironmentObjectDescriptor],
        generator: inout SeededRandomGenerator,
        collidable: Bool = true,
        placementValidator: ((SIMD2<Float>) -> Bool)? = nil,
        pickKind: (inout SeededRandomGenerator) -> EnvironmentObjectKind
    ) {
        let targetCount = descriptors.count + count
        var attempts = 0
        while attempts < count * 22 {
            attempts += 1
            if descriptors.count >= targetCount {
                break
            }

            let position = SIMD2<Float>(
                Float.random(in: -extent...extent, using: &generator),
                Float.random(in: -extent...extent, using: &generator)
            )

            guard placementValidator?(position) ?? true else {
                continue
            }

            let kind = pickKind(&generator)
            _ = appendPlacedObject(
                kind: kind,
                terrain: terrain,
                position: position,
                safeSpawn: safeSpawn,
                overlapPadding: overlapPadding,
                occupied: &occupied,
                descriptors: &descriptors,
                generator: &generator,
                collidable: collidable,
                placementValidator: placementValidator
            )
        }
    }

    private func appendCluster(
        count: Int,
        center: SIMD2<Float>,
        radius: Float,
        terrain: TerrainPreset,
        safeSpawn: Float,
        overlapPadding: Float,
        occupied: inout [(SIMD2<Float>, Float)],
        descriptors: inout [EnvironmentObjectDescriptor],
        generator: inout SeededRandomGenerator,
        collidable: Bool = true,
        pickKind: (inout SeededRandomGenerator) -> EnvironmentObjectKind,
        placementValidator: ((SIMD2<Float>) -> Bool)? = nil
    ) {
        var attempts = 0
        var placed = 0
        while attempts < count * 24, placed < count {
            attempts += 1
            let angle = Float.random(in: 0.0...(.pi * 2.0), using: &generator)
            let distance = sqrt(Float.random(in: 0.0...1.0, using: &generator)) * radius
            let position = center + SIMD2<Float>(cos(angle) * distance, sin(angle) * distance)

            guard placementValidator?(position) ?? true else {
                continue
            }

            let kind = pickKind(&generator)
            if appendPlacedObject(
                kind: kind,
                terrain: terrain,
                position: position,
                safeSpawn: safeSpawn,
                overlapPadding: overlapPadding,
                occupied: &occupied,
                descriptors: &descriptors,
                generator: &generator,
                collidable: collidable,
                placementValidator: placementValidator
            ) {
                placed += 1
            }
        }
    }

    private func appendPlacedObject(
        kind: EnvironmentObjectKind,
        terrain: TerrainPreset,
        position: SIMD2<Float>,
        safeSpawn: Float,
        overlapPadding: Float,
        occupied: inout [(SIMD2<Float>, Float)],
        descriptors: inout [EnvironmentObjectDescriptor],
        generator: inout SeededRandomGenerator,
        collidable: Bool = true,
        placementValidator: ((SIMD2<Float>) -> Bool)? = nil
    ) -> Bool {
        guard placementValidator?(position) ?? true else {
            return false
        }

        let size = sizeForKind(kind, terrain: terrain, generator: &generator)
        let radius = max(size.x, size.z) * 0.56
        if simd_length(position) < safeSpawn + radius * 0.75 {
            return false
        }
        if overlaps(position: position, radius: radius, occupied: occupied, padding: overlapPadding) {
            return false
        }

        descriptors.append(makeDescriptor(
            kind: kind,
            biome: terrain,
            position: SIMD3<Float>(position.x, 0.0, position.y),
            size: size,
            collidable: collidable
        ))
        occupied.append((position, radius))
        return true
    }

    private func randomPosition(
        extent: Float,
        safeSpawn: Float,
        generator: inout SeededRandomGenerator
    ) -> SIMD2<Float> {
        for _ in 0..<48 {
            let candidate = SIMD2<Float>(
                Float.random(in: -extent...extent, using: &generator),
                Float.random(in: -extent...extent, using: &generator)
            )
            if simd_length(candidate) >= safeSpawn {
                return candidate
            }
        }

        let angle = Float.random(in: 0.0...(.pi * 2.0), using: &generator)
        return SIMD2<Float>(cos(angle), sin(angle)) * safeSpawn
    }

    private func isInsideClearing(
        _ position: SIMD2<Float>,
        clearings: [(center: SIMD2<Float>, radius: Float)]
    ) -> Bool {
        for clearing in clearings {
            if simd_distance(position, clearing.center) < clearing.radius {
                return true
            }
        }
        return false
    }

    private func makeDescriptor(
        kind: EnvironmentObjectKind,
        biome: TerrainPreset,
        position: SIMD3<Float>,
        yawRadians: Float = 0.0,
        size: SIMD3<Float>,
        collidable: Bool
    ) -> EnvironmentObjectDescriptor {
        EnvironmentObjectDescriptor(
            id: UUID(),
            kind: kind,
            biome: biome,
            position: position,
            yawRadians: yawRadians,
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
            switch terrain {
            case .forest:
                return SIMD3<Float>(
                    Float.random(in: 3.8...8.8, using: &generator),
                    Float.random(in: 14.0...30.0, using: &generator),
                    Float.random(in: 3.8...8.8, using: &generator)
                )
            case .field:
                return SIMD3<Float>(
                    Float.random(in: 3.2...7.4, using: &generator),
                    Float.random(in: 12.0...24.0, using: &generator),
                    Float.random(in: 3.2...7.4, using: &generator)
                )
            case .cargoYard:
                return SIMD3<Float>(
                    Float.random(in: 2.2...4.8, using: &generator),
                    Float.random(in: 8.0...16.0, using: &generator),
                    Float.random(in: 2.2...4.8, using: &generator)
                )
            case .city:
                return SIMD3<Float>(
                    Float.random(in: 2.6...5.6, using: &generator),
                    Float.random(in: 10.0...18.0, using: &generator),
                    Float.random(in: 2.6...5.6, using: &generator)
                )
            case .gridDemo:
                return SIMD3<Float>(
                    Float.random(in: 2.6...5.6, using: &generator),
                    Float.random(in: 9.0...18.0, using: &generator),
                    Float.random(in: 2.6...5.6, using: &generator)
                )
            }
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
            switch terrain {
            case .cargoYard:
                return SIMD3<Float>(
                    Float.random(in: 1.6...4.8, using: &generator),
                    Float.random(in: 1.2...3.2, using: &generator),
                    Float.random(in: 1.6...4.2, using: &generator)
                )
            case .gridDemo, .field, .forest, .city:
                return SIMD3<Float>(
                    Float.random(in: 1.0...3.0, using: &generator),
                    Float.random(in: 1.0...3.5, using: &generator),
                    Float.random(in: 1.0...3.0, using: &generator)
                )
            }
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

private extension ScenePopulationService {
    func appendCargoGate(
        center: SIMD2<Float>,
        yawRadians: Float,
        descriptors: inout [EnvironmentObjectDescriptor],
        generator: inout SeededRandomGenerator
    ) {
        let rightAxis = SIMD2<Float>(cos(yawRadians), sin(yawRadians))
        let supportHeight = Float.random(in: 2.8...4.4, using: &generator)
        let supportWidth = Float.random(in: 1.5...2.2, using: &generator)
        let supportDepth = Float.random(in: 1.3...1.9, using: &generator)
        let openingHalf = Float.random(in: 2.1...3.0, using: &generator)
        let bridgeHeight = Float.random(in: 1.0...1.4, using: &generator)
        let bridgeLength = openingHalf * 2.0 + supportWidth * 1.3
        let bridgeBaseY = supportHeight + Float.random(in: 0.18...0.42, using: &generator)

        let leftSupport = center - rightAxis * openingHalf
        let rightSupport = center + rightAxis * openingHalf
        descriptors.append(makeDescriptor(
            kind: .crate,
            biome: .cargoYard,
            position: SIMD3<Float>(leftSupport.x, 0.0, leftSupport.y),
            yawRadians: yawRadians,
            size: SIMD3<Float>(supportWidth, supportHeight, supportDepth),
            collidable: true
        ))
        descriptors.append(makeDescriptor(
            kind: .crate,
            biome: .cargoYard,
            position: SIMD3<Float>(rightSupport.x, 0.0, rightSupport.y),
            yawRadians: yawRadians,
            size: SIMD3<Float>(supportWidth, supportHeight, supportDepth),
            collidable: true
        ))
        descriptors.append(makeDescriptor(
            kind: .crate,
            biome: .cargoYard,
            position: SIMD3<Float>(center.x, bridgeBaseY, center.y),
            yawRadians: yawRadians,
            size: SIMD3<Float>(bridgeLength, bridgeHeight, supportDepth * 0.92),
            collidable: true
        ))
    }

    func appendCargoStackCluster(
        center: SIMD2<Float>,
        yawRadians: Float,
        descriptors: inout [EnvironmentObjectDescriptor],
        generator: inout SeededRandomGenerator
    ) {
        let rightAxis = SIMD2<Float>(cos(yawRadians), sin(yawRadians))
        let forwardAxis = SIMD2<Float>(-sin(yawRadians), cos(yawRadians))
        let baseWidth = Float.random(in: 2.4...4.0, using: &generator)
        let baseDepth = Float.random(in: 1.8...3.4, using: &generator)
        let baseHeight = Float.random(in: 1.4...2.4, using: &generator)
        let spacing = Float.random(in: 2.4...4.0, using: &generator)

        for sign in [-1.0 as Float, 1.0] {
            let position = center + rightAxis * (sign * spacing * 0.45)
            descriptors.append(makeDescriptor(
                kind: .crate,
                biome: .cargoYard,
                position: SIMD3<Float>(position.x, 0.0, position.y),
                yawRadians: yawRadians,
                size: SIMD3<Float>(baseWidth, baseHeight, baseDepth),
                collidable: true
            ))
        }

        if Float.random(in: 0.0...1.0, using: &generator) < 0.74 {
            let topSize = SIMD3<Float>(
                baseWidth * Float.random(in: 0.78...0.96, using: &generator),
                baseHeight * Float.random(in: 0.76...0.92, using: &generator),
                baseDepth * Float.random(in: 0.78...0.96, using: &generator)
            )
            let topPosition = center + forwardAxis * Float.random(in: -0.4...0.4, using: &generator)
            descriptors.append(makeDescriptor(
                kind: .crate,
                biome: .cargoYard,
                position: SIMD3<Float>(topPosition.x, baseHeight, topPosition.y),
                yawRadians: yawRadians,
                size: topSize,
                collidable: true
            ))
        }
    }

    func appendCargoLongStack(
        center: SIMD2<Float>,
        yawRadians: Float,
        descriptors: inout [EnvironmentObjectDescriptor],
        generator: inout SeededRandomGenerator
    ) {
        let rightAxis = SIMD2<Float>(cos(yawRadians), sin(yawRadians))
        let segmentWidth = Float.random(in: 4.8...7.6, using: &generator)
        let segmentDepth = Float.random(in: 1.5...2.3, using: &generator)
        let segmentHeight = Float.random(in: 1.3...2.0, using: &generator)
        let segmentCount = Int.random(in: 1...2, using: &generator)
        let step = segmentWidth * 0.74

        for index in 0..<segmentCount {
            let offset = (Float(index) - Float(segmentCount - 1) * 0.5) * step
            let position = center + rightAxis * offset
            descriptors.append(makeDescriptor(
                kind: .crate,
                biome: .cargoYard,
                position: SIMD3<Float>(position.x, 0.0, position.y),
                yawRadians: yawRadians,
                size: SIMD3<Float>(segmentWidth, segmentHeight, segmentDepth),
                collidable: true
            ))
        }

        if Float.random(in: 0.0...1.0, using: &generator) < 0.48 {
            descriptors.append(makeDescriptor(
                kind: .crate,
                biome: .cargoYard,
                position: SIMD3<Float>(center.x, segmentHeight, center.y),
                yawRadians: yawRadians,
                size: SIMD3<Float>(
                    segmentWidth * Float.random(in: 0.58...0.80, using: &generator),
                    segmentHeight * Float.random(in: 0.84...1.00, using: &generator),
                    segmentDepth * Float.random(in: 0.88...1.12, using: &generator)
                ),
                collidable: true
            ))
        }
    }
}

private func mix(_ a: Float, _ b: Float, _ t: Float) -> Float {
    a + (b - a) * t.clamped(to: 0.0...1.0)
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
