import Foundation
import SceneKit
import simd

struct CityGenerationBudget {
    static let maxBuildings = 8
    static let maxRoadSegments = 4
    static let maxDecorations = 0
    static let maxTotalCityNodes = 128
}

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
        clear()

        if terrain.preset == .city {
            #if DEBUG
            let memoryMode = EnvironmentVisualOptions.enableLegacyCityGeneration
                ? "legacy-capped"
                : "legacy-disabled"
            print("[City] generated map=city buildings=0 roads=0 decorations=0 totalNodes=0 materials=0 memoryMode=\(memoryMode)")
            #endif
            return ([], [:])
        }

        // generateGridDemo() only ever produced .marker/.pole/.crate descriptors, and those kinds
        // render as an invisible empty SCNNode by default (EnvironmentObjectFactory.makeNode,
        // gated on EnvironmentDebugOptions.showPlaceholderObjects, off in normal play) while still
        // being registered as real `collidable: true` obstacles and counted on the radar/minimap.
        // So this map previously had ~300 obstacles you could fly into but never see — not a
        // rendering bug, the objects were genuinely there. The grid demo map is meant to be bare,
        // so skip generating them at all rather than just hiding them.
        if terrain.preset == .gridDemo {
            return ([], [:])
        }

        var generator = SeededRandomGenerator(seed: terrain.seed)
        let density = terrain.density.clamped(to: 0.0...1.0)
        let extent = terrain.worldHalfExtent
        let areaScaleUpperBound: Float = terrain.preset == .cargoYard ? 4.2 : 2.2
        let areaScale = terrain.areaScaleFactor.clamped(to: 0.25...areaScaleUpperBound)

        var collidableDescriptors: [EnvironmentObjectDescriptor] = []

        switch terrain.preset {
        case .gridDemo:
            // The early return above is the only supported grid-demo path.
            collidableDescriptors = []
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
                densityBoost: terrain.missionDensityBoost ? 1.15 : 1.0,
                sectorCenter: terrain.missionSearchSectorCenter,
                sectorRadius: terrain.missionSearchSectorRadius,
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
            // The early return above is the only supported city path.
            collidableDescriptors = []
        }

        // generateForest mixes truly-collidable objects with a non-collidable decorative scatter
        // (cheap visual-only filler — see TerrainConfiguration.missionSearchSectorCenter). Only the
        // collidable subset competes for the fixed object-count cap below; decorative descriptors
        // bypass it entirely, same as the boundary belt.
        let decorativeDescriptors = collidableDescriptors.filter { !$0.isCollidable }
        collidableDescriptors = collidableDescriptors.filter { $0.isCollidable }

        let preCapCount = collidableDescriptors.count
        let preCapTreeCount = collidableDescriptors.filter { $0.kind == .tree }.count
        collidableDescriptors = cappedCollidableDescriptors(collidableDescriptors, for: terrain)
        // Temporary diagnostic for the mission forest-density investigation — remove once
        // resolved. Logs what actually got generated/capped, since the formulas compute a much
        // higher count on paper than testing has shown on screen.
        print("[Density] preset=\(terrain.preset) mapScale=\(terrain.mapScale) density=\(terrain.density) boost=\(terrain.missionDensityBoost) preCap=\(preCapCount) preCapTrees=\(preCapTreeCount) cap=\(maxCollidableObjectCount(for: terrain)) postCap=\(collidableDescriptors.count) postCapTrees=\(collidableDescriptors.filter { $0.kind == .tree }.count) decorative=\(decorativeDescriptors.count)")

        let beltDescriptors = generateBoundaryBelt(
            terrain: terrain,
            generator: &generator
        )
        let allDescriptors = collidableDescriptors + decorativeDescriptors + beltDescriptors

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

    func clear() {
        containerNode.childNodes.forEach { $0.removeFromParentNode() }
        treeVisualsNode.childNodes.forEach { $0.removeFromParentNode() }
        storedTreeDescriptors.removeAll(keepingCapacity: false)
        containerNode.addChildNode(treeVisualsNode)
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
            baseLimit = 1_100
        case .city:
            baseLimit = 620
        }

        // Mission terrain gets a small cap bump as a safety margin above generateForest's own
        // densityBoost — most of the "search sector reads as real forest cover" effect now comes
        // from concentrating generation spatially around the sector (sector-bias split, ~4-5x
        // effective density there for free) rather than from brute-forcing the whole budget up,
        // which is what the old ×1.8 was compensating for before that split existed.
        let boost = terrain.missionDensityBoost ? 1.2 : 1.0
        return max(180, Int((baseLimit * multiplier * boost).rounded()))
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
        densityBoost: Float = 1.0,
        sectorCenter: SIMD2<Float>? = nil,
        sectorRadius: Float? = nil,
        generator: inout SeededRandomGenerator
    ) -> [EnvironmentObjectDescriptor] {
        var descriptors: [EnvironmentObjectDescriptor] = []
        var occupied: [(SIMD2<Float>, Float)] = []
        let coverageScale = max(1.0, extent / 96.0)
        let featureScale = min(1.85, max(1.05, areaScale * 0.62 + min(coverageScale, 2.5) * 0.24))

        // Only as much clearance as the dock itself needs — the old +16.0 padding left a bare
        // ring around takeoff wide enough to read as "nothing nearby" once the sector-bias split
        // thinned the rest of the baseline. A dedicated ring just outside this (below) puts trees
        // back in view immediately, without re-opening that whole radius to random placement.
        let dockClearingRadius = safeSpawn + 6.0
        var clearings: [(center: SIMD2<Float>, radius: Float)] = [
            (SIMD2<Float>(repeating: 0.0), dockClearingRadius)
        ]

        // Fewer, smaller, and (when a sector exists) kept away from it — these are purely for
        // "the forest isn't a uniform wall" variety, and stacking them with the sector concept
        // worked against the "dense forest, no empty space" goal: a stray clearing could land
        // right in the area the player is meant to search.
        let extraClearings = max(1, Int((0.5 + featureScale * 0.5).rounded(.down)))
        for _ in 0..<extraClearings {
            var candidate = randomPosition(extent: extent * 0.68, safeSpawn: safeSpawn + 24.0, generator: &generator)
            if let sectorCenter, let sectorRadius, simd_distance(candidate, sectorCenter) < sectorRadius * 1.3 {
                let awayAngle = atan2(candidate.y - sectorCenter.y, candidate.x - sectorCenter.x)
                candidate = sectorCenter + SIMD2<Float>(cos(awayAngle), sin(awayAngle)) * (sectorRadius * 1.6)
            }
            clearings.append((candidate, Float.random(in: 8.0...14.0, using: &generator)))
        }

        // Guarantee the dock's immediate surroundings read as forest, regardless of how the
        // random sector/baseline split happens to land — non-collidable (zero FPS/pathfinding
        // cost, see [[project_missions_increment1_bugfixes]]), so this is purely cosmetic.
        let dockRingInner = dockClearingRadius
        let dockRingOuter = dockClearingRadius + 55.0
        var dockRingAttempts = 0
        var dockRingPlaced = 0
        let dockRingTarget = 28
        while dockRingAttempts < dockRingTarget * 20, dockRingPlaced < dockRingTarget {
            dockRingAttempts += 1
            let angle = Float.random(in: 0.0...(.pi * 2.0), using: &generator)
            let radius = Float.random(in: dockRingInner...dockRingOuter, using: &generator)
            let position = SIMD2<Float>(cos(angle) * radius, sin(angle) * radius)
            if isInsideClearing(position, clearings: clearings.dropFirst().map { $0 }) {
                continue
            }
            if appendPlacedObject(
                kind: .tree,
                terrain: .forest,
                position: position,
                safeSpawn: dockRingInner,
                overlapPadding: 1.0,
                occupied: &occupied,
                descriptors: &descriptors,
                generator: &generator,
                collidable: false
            ) {
                dockRingPlaced += 1
            }
        }

        // When a mission search sector is set, the collidable/decorative budget concentrates
        // around it (plus a halo so it doesn't end abruptly) instead of spreading uniformly over
        // the whole map — the object budget is finite regardless of map size, so spreading it
        // over a huge map reads as dense only at the fixed-count horizon belt and sparse where
        // the mission actually happens. A thin baseline still covers the rest of the map so the
        // dock-to-sector corridor isn't bare.
        let hasSector = sectorCenter != nil && sectorRadius != nil
        let sectorBiasCenter = sectorCenter ?? .zero
        // Dense placement now spans the *entire* search sector, not a shrunken inner core — a
        // 0.58×radius core only covered ~34% of the sector's *area* (area scales with r²), so
        // two-thirds of the area the player is actually meant to search was barely forested at
        // all. Matching cluster-interior density (~10-13 trees/1000m²) uniformly across the full
        // sector would still need far more fill/decorative budget than is safe for render cost,
        // so coverage now wins over peak density — see the decorative multiplier below, bumped to
        // compensate for the ~3x larger area without returning to the count that previously cost
        // frame time.
        let denseCoreRadius = sectorRadius
        // ×1.15 halo on the (now smaller) core, not the full sector — avoids a razor-sharp edge
        // at the dense-core boundary without diluting density back out to the old, larger area.
        let sectorBiasExtent = denseCoreRadius.map { $0 * 1.15 } ?? (extent * 0.84)

        // A hard `distance <= sectorBiasExtent` cutoff alone reads as a planted forest island —
        // a perfect circle of trees against bare ground. Taper acceptance probability down across
        // the outer 30% of the radius instead of cutting it off at 100%→0% in one step. Uses a
        // position hash (not the shared RNG) so it can be called from `placementValidator`
        // closures, which only see a position, with no generator access.
        func coreEdgeAccepts(_ position: SIMD2<Float>) -> Bool {
            let normalizedDistance = simd_distance(position, sectorBiasCenter) / sectorBiasExtent
            guard normalizedDistance > 0.7 else { return true }
            guard normalizedDistance <= 1.0 else { return false }
            let falloff = 1.0 - (normalizedDistance - 0.7) / 0.3
            let hash = sin(position.x * 12.9898 + position.y * 78.233) * 43758.5453
            let pseudoRandom = hash - hash.rounded(.down)
            return pseudoRandom <= falloff
        }

        func splitCount(_ total: Int, sectorShare: Float) -> (sector: Int, baseline: Int) {
            guard hasSector else { return (0, total) }
            let sectorPart = Int((Float(total) * sectorShare).rounded())
            return (sectorPart, total - sectorPart)
        }

        // densityBoost (mission-only, see TerrainConfiguration.missionDensityBoost) scales both
        // how many clusters get placed and how many trees fill each one — the normal 28/24 caps
        // are tuned for the freeform-flight object budget, not for "search sector should read as
        // real forest cover".
        let clusterCount = min(Int(28 * densityBoost), max(10, Int((10.0 + density * 7.0) * featureScale * densityBoost)))
        // Collision checking (CollisionAnalysisService.analyze/firstSweptCollision) is an
        // unconditional O(n) scan over *every* collidable obstacle every tick — there's no
        // distance culling and obstacle nodes carry no SCNPhysicsBody, so SceneKit can't broad-
        // phase it either. A collidable tree the player will never fly near (outside the search
        // sector, in a manual-flight scenario with no autopilot routing around it — see
        // [[project_missions_vision_and_nfz_removal]]) is pure tax on that scan. So almost all of
        // the collidable budget now goes to the sector, and whatever's left outside is generated
        // non-collidable (still renders, just doesn't enter the obstacle list).
        let clusterSplit = splitCount(clusterCount, sectorShare: 0.95)

        func placeClusterBatch(count: Int, batchCenter: SIMD2<Float>, batchExtent: Float, collidable: Bool, applyCoreEdgeTaper: Bool, generator: inout SeededRandomGenerator) {
            for _ in 0..<count {
                let center = randomPosition(extent: batchExtent, safeSpawn: safeSpawn + 14.0, center: batchCenter, generator: &generator)
                // randomPosition samples a square; without this the dense core reads as a literal
                // square blob on the tactical map instead of a round patch of forest.
                if simd_distance(center, batchCenter) > batchExtent {
                    continue
                }
                if applyCoreEdgeTaper, !coreEdgeAccepts(center) {
                    continue
                }
                if isInsideClearing(center, clearings: clearings) {
                    continue
                }

                let radius = Float.random(in: 14.0...30.0, using: &generator)
                let count = max(10, Int(Float.random(in: 12.0...24.0, using: &generator) * max(0.70, density) * 1.05 * densityBoost))
                appendCluster(
                    count: count,
                    center: center,
                    radius: radius,
                    terrain: .forest,
                    safeSpawn: safeSpawn,
                    overlapPadding: 1.0,
                    occupied: &occupied,
                    descriptors: &descriptors,
                    generator: &generator,
                    collidable: collidable
                ) { rng in
                    let pick = Float.random(in: 0.0...1.0, using: &rng)
                    if pick < 0.95 { return .tree }
                    if pick < 0.985 { return .pole }
                    return .crate
                } placementValidator: { position in
                    !self.isInsideClearing(position, clearings: clearings)
                }
            }
        }
        placeClusterBatch(count: clusterSplit.sector, batchCenter: sectorBiasCenter, batchExtent: sectorBiasExtent, collidable: true, applyCoreEdgeTaper: true, generator: &generator)
        placeClusterBatch(count: clusterSplit.baseline, batchCenter: .zero, batchExtent: extent * 0.84, collidable: false, applyCoreEdgeTaper: false, generator: &generator)

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

        let fillPickKind: (inout SeededRandomGenerator) -> EnvironmentObjectKind = { rng in
            let pick = Float.random(in: 0.0...1.0, using: &rng)
            if pick < 0.95 { return .tree }
            if pick < 0.975 { return .pole }
            if pick < 0.995 { return .crate }
            return .rock
        }
        let fillCount = min(Int(420 * densityBoost), max(120, Int(190.0 * max(0.55, density) * featureScale * densityBoost)))
        let fillSplit = splitCount(fillCount, sectorShare: 0.95)
        appendScatter(
            count: fillSplit.sector,
            extent: sectorBiasExtent,
            safeSpawn: safeSpawn,
            overlapPadding: 1.02,
            terrain: .forest,
            occupied: &occupied,
            descriptors: &descriptors,
            generator: &generator,
            center: sectorBiasCenter,
            placementValidator: { position in
                guard coreEdgeAccepts(position) else { return false }
                return !self.isInsideClearing(position, clearings: clearings)
            },
            pickKind: fillPickKind
        )
        appendScatter(
            count: fillSplit.baseline,
            extent: extent * 0.88,
            safeSpawn: safeSpawn,
            overlapPadding: 1.02,
            terrain: .forest,
            occupied: &occupied,
            descriptors: &descriptors,
            generator: &generator,
            collidable: false,
            placementValidator: { position in
                guard simd_distance(position, .zero) <= extent * 0.88 else { return false }
                return !self.isInsideClearing(position, clearings: clearings)
            },
            pickKind: fillPickKind
        )

        // Decorative (non-collidable) trees are "free" against the collision/pathfinding budget,
        // so near the sector we lean on them hard for visual density — this is the layer the user
        // asked to redirect toward the search area instead of spreading thin over the whole map.
        let decorativePickKind: (inout SeededRandomGenerator) -> EnvironmentObjectKind = { rng in
            let pick = Float.random(in: 0.0...1.0, using: &rng)
            if pick < 0.992 { return .tree }
            return .crate
        }
        // Decorative trees are free against the collision cap, but not against render/FPS cost —
        // pushing the raw *count* too high (was 1,100) cost real frame time regardless of area.
        // User reported a (minor) FPS regression right after this multiplier went to 4.0 to cover
        // the full sector — pulled back to 3.6 since render cost, not collision-scan, is the most
        // likely driver of *this* drop (the collidable layer's own counts didn't change in that
        // round — see densityBoost above, reduced separately for the collision-scan side).
        let decorativeBaseCount = min(520, max(160, Int(220.0 * featureScale)))
        let decorativeRaw = hasSector ? min(2_200, Int(Float(decorativeBaseCount) * 3.6)) : decorativeBaseCount
        // Graphics quality scales the decorative (non-collidable, visual-only) layer — the bulk of
        // forest render cost. Collidable trees are untouched so collision/gameplay is identical
        // across presets. `.high` = ×1.0 (full density), lower tiers thin it for weaker hardware.
        let decorativeForestCount = max(0, Int(Float(decorativeRaw) * AppGraphicsSettings.quality.decorativeTreeMultiplier))
        let decorativeSplit = splitCount(decorativeForestCount, sectorShare: 0.92)
        appendScatter(
            count: decorativeSplit.sector,
            extent: sectorBiasExtent,
            safeSpawn: safeSpawn,
            overlapPadding: 0.98,
            terrain: .forest,
            occupied: &occupied,
            descriptors: &descriptors,
            generator: &generator,
            collidable: false,
            center: sectorBiasCenter,
            placementValidator: { position in
                guard coreEdgeAccepts(position) else { return false }
                return !self.isInsideClearing(position, clearings: clearings)
            },
            pickKind: decorativePickKind
        )
        appendScatter(
            count: decorativeSplit.baseline,
            extent: extent * 0.94,
            safeSpawn: safeSpawn,
            overlapPadding: 0.98,
            terrain: .forest,
            occupied: &occupied,
            descriptors: &descriptors,
            generator: &generator,
            collidable: false,
            placementValidator: { position in
                guard simd_distance(position, .zero) <= extent * 0.94 else { return false }
                return !self.isInsideClearing(position, clearings: clearings)
            },
            pickKind: decorativePickKind
        )

        // Gap fill for the dense core: clusters/fill/decorative above are independent random
        // sampling, which statistically leaves small zero-coverage patches even at a healthy
        // average density (visible as "bald spots" on the tactical map) — no individual layer
        // guarantees a maximum gap size. A jittered grid does: one non-collidable tree attempt
        // per ~16m cell, so no point in the core is more than half a cell-diagonal from a
        // guaranteed placement. Cells that land in an already-dense area just get rejected by the
        // normal overlap check, so this only adds trees where the random layers left empty.
        // Rows are brick-staggered (offset by half a cell on alternating rows) and jitter is
        // almost the full cell width — a plain unstaggered grid with modest jitter still reads as
        // visible planted rows from above, which is exactly what a *natural* forest shouldn't
        // look like.
        if hasSector {
            let cellSize: Float = 16.0
            let cellsPerSide = max(1, Int((sectorBiasExtent * 2.0 / cellSize).rounded(.up)) + 1)
            let gridOrigin = sectorBiasCenter - SIMD2<Float>(repeating: Float(cellsPerSide) * cellSize * 0.5)
            for row in 0..<cellsPerSide {
                let rowStagger: Float = row.isMultiple(of: 2) ? 0.0 : cellSize * 0.5
                for col in 0..<cellsPerSide {
                    let cellCenter = gridOrigin + SIMD2<Float>(
                        (Float(col) + 0.5) * cellSize + rowStagger,
                        (Float(row) + 0.5) * cellSize
                    )
                    guard simd_distance(cellCenter, sectorBiasCenter) <= sectorBiasExtent else {
                        continue
                    }
                    let position = cellCenter + SIMD2<Float>(
                        Float.random(in: -cellSize * 0.47...cellSize * 0.47, using: &generator),
                        Float.random(in: -cellSize * 0.47...cellSize * 0.47, using: &generator)
                    )
                    guard coreEdgeAccepts(position) else {
                        continue
                    }
                    guard !isInsideClearing(position, clearings: clearings) else {
                        continue
                    }
                    _ = appendPlacedObject(
                        kind: .tree,
                        terrain: .forest,
                        position: position,
                        safeSpawn: safeSpawn,
                        overlapPadding: 0.5,
                        occupied: &occupied,
                        descriptors: &descriptors,
                        generator: &generator,
                        collidable: false
                    )
                }
            }
        }

        #if DEBUG
        if hasSector {
            let treeDescriptors = descriptors.filter { $0.kind == .tree }
            let inSectorCount = treeDescriptors.filter { simd_distance(SIMD2<Float>($0.position.x, $0.position.z), sectorBiasCenter) <= sectorBiasExtent }.count
            let sectorAreaM2 = Float.pi * sectorBiasExtent * sectorBiasExtent
            let outsideAreaM2 = max(1.0, (extent * 2.0) * (extent * 2.0) - sectorAreaM2)
            let inSectorDensity = Float(inSectorCount) / max(1.0, sectorAreaM2) * 1000.0
            let outsideDensity = Float(treeDescriptors.count - inSectorCount) / outsideAreaM2 * 1000.0
            print("[Density] sector-check trees=\(treeDescriptors.count) inSector=\(inSectorCount) outside=\(treeDescriptors.count - inSectorCount) inSectorPer1000m2=\(String(format: "%.2f", inSectorDensity)) outsidePer1000m2=\(String(format: "%.2f", outsideDensity))")
        }
        #endif

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
        let targetCount = cargoContainerTargetCount(
            density: density,
            areaScale: areaScale
        )
        let hubCount = cargoTerminalHubCount(areaScale: areaScale)
        let spawnExclusionRadius = safeSpawn + 30.0
        let assets = CargoContainerAssetKind.allCases

        for hubIndex in 0..<hubCount {
            let remainingHubs = hubCount - hubIndex
            let remainingContainers = targetCount - descriptors.count
            let containersInHub = Int(
                ceil(Double(remainingContainers) / Double(max(1, remainingHubs)))
            )
            let hubAngle = (Float(hubIndex) / Float(max(1, hubCount))) * (.pi * 2.0)
                + Float.random(in: -0.45...0.45, using: &generator)
            let minimumRadius = spawnExclusionRadius + 26.0
            let hubRadius = Float.random(in: minimumRadius...(extent * 0.85), using: &generator)
            let hubCenter = SIMD2<Float>(
                cos(hubAngle) * hubRadius,
                sin(hubAngle) * hubRadius
            )
            let hubYaw: Float = Float.random(in: 0.0...1.0, using: &generator) < 0.5
                ? 0.0
                : (Float.pi * 0.5)
            let rightAxis = SIMD2<Float>(cos(hubYaw), sin(hubYaw))
            let forwardAxis = SIMD2<Float>(-sin(hubYaw), cos(hubYaw))
            let columns = max(4, Int(ceil(sqrt(Double(containersInHub)))))
            let rows = max(3, Int(ceil(Double(containersInHub) / Double(columns))))

            for slot in 0..<containersInHub where descriptors.count < targetCount {
                let row = slot / columns
                let column = slot % columns
                let aisleOffset = column >= columns / 2 ? 9.0 as Float : 0.0
                let localX = (Float(column) - Float(columns - 1) * 0.5) * 17.0
                    + aisleOffset
                let localZ = (Float(row) - Float(rows - 1) * 0.5) * 14.5
                let jitter = SIMD2<Float>(
                    Float.random(in: -0.9...0.9, using: &generator),
                    Float.random(in: -0.55...0.55, using: &generator)
                )
                let center = hubCenter + rightAxis * (localX + jitter.x)
                    + forwardAxis * (localZ + jitter.y)

                let asset = assets[(slot + hubIndex) % assets.count]
                let size = asset.nominalSize
                let footprintRadius = max(size.x, size.z) * 0.54

                guard abs(center.x) + footprintRadius < extent * 0.92,
                      abs(center.y) + footprintRadius < extent * 0.92,
                      simd_length(center) > spawnExclusionRadius + footprintRadius,
                      !overlaps(
                        position: center,
                        radius: footprintRadius,
                        occupied: occupied,
                        padding: 1.02
                      ) else {
                    continue
                }

                let facesAisle = asset.hasFlyableInterior && column >= columns / 2
                let yaw: Float = facesAisle ? hubYaw + Float.pi : hubYaw
                descriptors.append(
                    makeCargoContainerDescriptor(
                        asset: asset,
                        position: SIMD3<Float>(center.x, 0.0, center.y),
                        yawRadians: yaw
                    )
                )
                occupied.append((center, footprintRadius))
            }
        }

        let scatterCount = max(30, Int(Float(targetCount) * 0.50))
        appendCargoScatter(
            count: scatterCount,
            extent: extent,
            spawnExclusionRadius: spawnExclusionRadius,
            occupied: &occupied,
            descriptors: &descriptors,
            generator: &generator
        )

        #if DEBUG
        let inventory = Dictionary(grouping: descriptors, by: \.cargoAsset)
            .mapValues(\.count)
        let inventoryDescription = CargoContainerAssetKind.allCases
            .map { "\($0.rawValue)=\(inventory[$0] ?? 0)" }
            .joined(separator: " ")
        print(
            "[Cargo] generated target=\(targetCount) placed=\(descriptors.count) " +
            "hubs=\(hubCount) scattered=\(scatterCount) \(inventoryDescription)"
        )
        #endif

        return descriptors
    }

    private func appendCargoScatter(
        count: Int,
        extent: Float,
        spawnExclusionRadius: Float,
        occupied: inout [(SIMD2<Float>, Float)],
        descriptors: inout [EnvironmentObjectDescriptor],
        generator: inout SeededRandomGenerator
    ) {
        let assets = CargoContainerAssetKind.allCases
        var placed = 0
        var attempts = 0

        while placed < count, attempts < count * 25 {
            attempts += 1
            let center = SIMD2<Float>(
                Float.random(in: -extent...extent, using: &generator),
                Float.random(in: -extent...extent, using: &generator)
            )
            let assetIndex = Int(Float.random(in: 0.0..<Float(assets.count), using: &generator))
            let asset = assets[assetIndex]
            let size = asset.nominalSize
            let footprintRadius = max(size.x, size.z) * 0.54

            guard abs(center.x) + footprintRadius < extent * 0.94,
                  abs(center.y) + footprintRadius < extent * 0.94,
                  simd_length(center) > spawnExclusionRadius + footprintRadius,
                  !overlaps(
                    position: center,
                    radius: footprintRadius,
                    occupied: occupied,
                    padding: 1.3
                  ) else {
                continue
            }

            let yaw: Float = Float.random(in: 0.0...1.0, using: &generator) < 0.5
                ? 0.0
                : (Float.pi * 0.5)
            descriptors.append(
                makeCargoContainerDescriptor(
                    asset: asset,
                    position: SIMD3<Float>(center.x, 0.0, center.y),
                    yawRadians: yaw
                )
            )
            occupied.append((center, footprintRadius))
            placed += 1
        }
    }

    private func cargoContainerTargetCount(
        density: Float,
        areaScale: Float
    ) -> Int {
        let baseCount: Float
        switch areaScale {
        case ...0.90:
            baseCount = 96
        case ...1.10:
            baseCount = 180
        case ...1.50:
            baseCount = 360
        case ...1.90:
            baseCount = 520
        case ...2.50:
            baseCount = 680
        case ...3.50:
            baseCount = 840
        default:
            baseCount = 1_000
        }

        let densityMultiplier = 0.80 + density.clamped(to: 0.0...1.0) * 0.35
        return max(60, Int((baseCount * densityMultiplier).rounded()))
    }

    private func cargoTerminalHubCount(areaScale: Float) -> Int {
        switch areaScale {
        case ...0.90:
            return 4
        case ...1.10:
            return 6
        case ...1.50:
            return 8
        case ...1.90:
            return 12
        case ...2.50:
            return 16
        case ...3.50:
            return 24
        default:
            return 32
        }
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
            ringCount = 0
        case .city:
            ringCount = 0
        case .gridDemo:
            // Bare debug map by design (see populate()'s early return for .gridDemo) — no belt.
            ringCount = 0
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

                case .city, .cargoYard, .gridDemo:
                    continue

                case .field:
                    let size = SIMD3<Float>(
                        Float.random(in: 1.8...4.6, using: &generator),
                        Float.random(in: 8.0...18.0, using: &generator),
                        Float.random(in: 1.8...4.6, using: &generator)
                    )
                    descriptors.append(makeDescriptor(
                        kind: .tree,
                        biome: .field,
                        position: SIMD3<Float>(x, 0.0, z),
                        size: size,
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
        center: SIMD2<Float> = .zero,
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

            let position = center + SIMD2<Float>(
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
        center: SIMD2<Float> = .zero,
        generator: inout SeededRandomGenerator
    ) -> SIMD2<Float> {
        for _ in 0..<48 {
            let candidate = center + SIMD2<Float>(
                Float.random(in: -extent...extent, using: &generator),
                Float.random(in: -extent...extent, using: &generator)
            )
            if simd_length(candidate) >= safeSpawn {
                return candidate
            }
        }

        let angle = Float.random(in: 0.0...(.pi * 2.0), using: &generator)
        return center + SIMD2<Float>(cos(angle), sin(angle)) * safeSpawn
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
            isCollidable: collidable,
            collisionParts: kind == .tree ? treeCollisionParts(size: size) : []
        )
    }

    // Mesh-fitted tree collision, mirroring the container approach (`cargoCollisionParts`): instead
    // of one fat ~canopy-radius cylinder floating at treetop height (which both left the trunk
    // pass-through at low altitude AND made you "collide" with empty air around the canopy), shape
    // the collision to the actual pine form — a slim trunk box for the full lower height plus a
    // tighter canopy box on the upper portion. Two parts only (not a multi-box cone taper): each
    // part is one more entry in the per-tick O(n) collision scan, and only *collidable* trees
    // (sector interior) ever become obstacles — decorative trees carry these too but are never
    // turned into CollisionObstacles (see DroneSceneController: `where descriptor.isCollidable`).
    //
    // Sources keep the "tree" substring on purpose: the autopilot's nav-grid inflation
    // (`AutoPathPlannerService.obstacleInflation`) and the planner's box-aware rasterization key
    // off that substring, so routing still treats these as trees with the same safety margin —
    // just following the accurate trunk+canopy footprint instead of the old cylinder. `false`
    // supportsLanding so drones never try to perch on a tree collision box.
    private func treeCollisionParts(size: SIMD3<Float>) -> [EnvironmentCollisionPart] {
        let canopyBaseY = size.y * 0.40
        let trunkTopY = size.y * 0.46            // slight overlap into the canopy, no vertical gap
        let trunkWidth = max(0.7, size.x * 0.22) // real trunk footprint, not the canopy span
        let trunkDepth = max(0.7, size.z * 0.22)
        let canopyHeight = size.y - canopyBaseY
        let canopyWidth = size.x * 0.86          // actual footprint, vs the old 1.18× inflated cylinder
        let canopyDepth = size.z * 0.86

        return [
            EnvironmentCollisionPart(
                localCenter: SIMD3<Float>(0.0, trunkTopY * 0.5, 0.0),
                size: SIMD3<Float>(trunkWidth, trunkTopY, trunkDepth),
                source: "tree.trunk",
                supportsLanding: false
            ),
            EnvironmentCollisionPart(
                localCenter: SIMD3<Float>(0.0, canopyBaseY + canopyHeight * 0.5, 0.0),
                size: SIMD3<Float>(canopyWidth, canopyHeight, canopyDepth),
                source: "tree.canopy",
                supportsLanding: false
            )
        ]
    }

    private func makeCargoContainerDescriptor(
        asset: CargoContainerAssetKind,
        position: SIMD3<Float>,
        yawRadians: Float
    ) -> EnvironmentObjectDescriptor {
        let size = asset.nominalSize
        return EnvironmentObjectDescriptor(
            id: UUID(),
            kind: .cargoContainer,
            biome: .cargoYard,
            position: position,
            yawRadians: yawRadians,
            size: size,
            boundingRadius: max(size.x, size.z) * 0.55,
            isCollidable: true,
            cargoAsset: asset,
            collisionParts: cargoCollisionParts(for: asset, size: size)
        )
    }

    // `Containers.usdz` looked like 6 named groups ("Object_2"..."Object_7"), but two of them
    // ("Object_2", "Object_3") each turned out to be TWO physically disjoint crates merged into
    // one mesh resource by the export pipeline — a per-vertex-index connectivity check missed
    // this because hard-edge seams duplicate vertices, hiding the fact that they're not actually
    // joined. A spatial-proximity connectivity pass (union vertices within 0.5 source units,
    // not just shared indices) found the real split: 8 physical crates, not 6. Treating each
    // "Object_N" group as one box meant the box silently bridged the gap between two disjoint
    // crates — solid-looking collision floating in the empty air between them. Every piece below
    // was independently fit (min-area yaw search, 0-180°, 0.5° steps) and verified at zero vertex
    // overflow against the real mesh.
    private static let containersClusterBoxes: [(centerFraction: SIMD3<Float>, sizeFraction: SIMD3<Float>, yawRadians: Float)] = [
        (SIMD3(-0.1163, 0.3816, 0.2152), SIMD3(0.1603, 0.7539, 0.5682), -0.0175),
        (SIMD3(-0.0957, 0.8353, -0.3138), SIMD3(0.4933, 0.3294, 0.1740), -2.8885),
        (SIMD3(-0.0335, 0.5017, -0.3779), SIMD3(0.4930, 0.3294, 0.1740), 0.0),
        (SIMD3(-0.0968, 0.1704, -0.0160), SIMD3(0.4930, 0.3294, 0.1740), 0.0),
        (SIMD3(-0.0968, 0.1704, -0.4130), SIMD3(0.1583, 0.3294, 0.5417), -1.5708),
        (SIMD3(-0.2535, 0.1704, -0.1944), SIMD3(0.1583, 0.3294, 0.5417), -1.5708),
        (SIMD3(-0.0968, 0.5017, -0.1975), SIMD3(0.1583, 0.3294, 0.5417), -1.5708),
        (SIMD3(0.2784, 0.1384, 0.2152), SIMD3(0.4942, 0.2767, 0.2178), -2.1817)
    ]

    // `Container_18_MB.usdz`'s isolated open module ("_2_2") is itself a composite: a body
    // shell ("Wall_2") plus 4 separately-hinged door panels swung open at 4 different angles
    // (one at each corner). Verified the same way as the cluster boxes above (real SceneKit
    // transform chain, then zero-overflow check against the source vertices). The body only
    // spans this fraction of the container's nominal length — the rest is the doors projecting
    // past both ends — so the floor/walls below are shortened to match instead of using the
    // generic full-length formula.
    private static let container18MBBodyLengthFraction: Float = 0.7755
    private static let container18MBDoors: [(centerFraction: SIMD3<Float>, sizeFraction: SIMD3<Float>, yawRadians: Float)] = [
        (SIMD3(0.4451, 0.5043, 0.3818), SIMD3(0.0138, 0.9125, 0.4832), -1.1694),
        (SIMD3(-0.4441, 0.5043, -0.3921), SIMD3(0.1178, 0.9125, 0.0563), -2.7925),
        (SIMD3(-0.4341, 0.5043, 0.3242), SIMD3(0.1178, 0.9125, 0.0566), -0.6894),
        (SIMD3(0.4381, 0.5043, -0.3339), SIMD3(0.0139, 0.9125, 0.4831), -2.2078)
    ]

    private func cargoCollisionParts(
        for asset: CargoContainerAssetKind,
        size: SIMD3<Float>
    ) -> [EnvironmentCollisionPart] {
        if asset == .containersCluster {
            return Self.containersClusterBoxes.enumerated().map { index, box in
                EnvironmentCollisionPart(
                    localCenter: box.centerFraction * size,
                    size: box.sizeFraction * size,
                    yawRadians: box.yawRadians,
                    source: "container.cluster.box\(index)",
                    supportsLanding: true
                )
            }
        }

        if asset == .container18MB {
            let thickness = min(0.14, max(0.09, min(size.y, size.z) * 0.05))
            let bodyLength = size.x * Self.container18MBBodyLengthFraction
            var parts = [
                EnvironmentCollisionPart(
                    localCenter: SIMD3<Float>(0.0, thickness * 0.5, 0.0),
                    size: SIMD3<Float>(bodyLength, thickness, size.z),
                    source: "container.floor",
                    supportsLanding: true
                ),
                EnvironmentCollisionPart(
                    localCenter: SIMD3<Float>(0.0, size.y - thickness * 0.5, 0.0),
                    size: SIMD3<Float>(bodyLength, thickness, size.z),
                    source: "container.roof",
                    supportsLanding: true
                ),
                EnvironmentCollisionPart(
                    localCenter: SIMD3<Float>(0.0, size.y * 0.5, -size.z * 0.5 + thickness * 0.5),
                    size: SIMD3<Float>(bodyLength, size.y, thickness),
                    source: "container.wall.left"
                ),
                EnvironmentCollisionPart(
                    localCenter: SIMD3<Float>(0.0, size.y * 0.5, size.z * 0.5 - thickness * 0.5),
                    size: SIMD3<Float>(bodyLength, size.y, thickness),
                    source: "container.wall.right"
                )
            ]
            for (index, door) in Self.container18MBDoors.enumerated() {
                parts.append(
                    EnvironmentCollisionPart(
                        localCenter: door.centerFraction * size,
                        size: door.sizeFraction * size,
                        yawRadians: door.yawRadians,
                        source: "container.door\(index)"
                    )
                )
            }
            return parts
        }

        guard asset.hasFlyableInterior else {
            return [
                EnvironmentCollisionPart(
                    localCenter: SIMD3<Float>(0.0, size.y * 0.5, 0.0),
                    size: size,
                    source: "container.closed.\(asset.rawValue)",
                    supportsLanding: true
                )
            ]
        }

        let thickness = min(0.14, max(0.09, min(size.y, size.z) * 0.05))

        var parts = [
            EnvironmentCollisionPart(
                localCenter: SIMD3<Float>(0.0, thickness * 0.5, 0.0),
                size: SIMD3<Float>(size.x, thickness, size.z),
                source: "container.floor",
                supportsLanding: true
            ),
            EnvironmentCollisionPart(
                localCenter: SIMD3<Float>(0.0, size.y - thickness * 0.5, 0.0),
                size: SIMD3<Float>(size.x, thickness, size.z),
                source: "container.roof",
                supportsLanding: true
            ),
            EnvironmentCollisionPart(
                localCenter: SIMD3<Float>(0.0, size.y * 0.5, -size.z * 0.5 + thickness * 0.5),
                size: SIMD3<Float>(size.x, size.y, thickness),
                source: "container.wall.left"
            ),
            EnvironmentCollisionPart(
                localCenter: SIMD3<Float>(0.0, size.y * 0.5, size.z * 0.5 - thickness * 0.5),
                size: SIMD3<Float>(size.x, size.y, thickness),
                source: "container.wall.right"
            )
        ]

        if !asset.hasOpenRearEnd {
            parts.append(
                EnvironmentCollisionPart(
                    localCenter: SIMD3<Float>(-size.x * 0.5 + thickness * 0.5, size.y * 0.5, 0.0),
                    size: SIMD3<Float>(thickness, size.y, size.z),
                    source: "container.wall.rear"
                )
            )
        }
        return parts
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
        case .cargoContainer:
            return CargoContainerAssetKind.shippingContainerOpen.nominalSize
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
