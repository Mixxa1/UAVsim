import AppKit
import SceneKit

/// Builds and maintains the visible half of the agricultural spraying mission: the soil patch,
/// the wheat crop, the refill station, the field boundary, and the wet-coverage decal that shows
/// the operator which rows have already been treated.
///
/// Kept as its own object rather than more methods on `DroneSceneController` because it owns
/// state (nodes, the coverage texture buffer) and because the controller is already very large;
/// the controller holds one instance and forwards three calls to it.
final class AgriFieldSceneLayer {
    /// Side of one batched crop tile. Every clump inside a tile is merged into a single geometry,
    /// so this is the trade between draw calls (bigger tiles = fewer) and culling granularity
    /// (smaller tiles = less off-screen crop drawn).
    private static let cropChunkMeters: Float = 16.0
    /// Hard ceiling on clumps for the whole field. A dense field is the point, but the ceiling is
    /// what keeps a future larger field from turning into a quarter of a million billboards
    /// without anyone deciding to.
    private static let maxCropClumps = 140_000
    private static let groundY: Float = 0.0
    private static let soilPatchLift: Float = 0.04
    private static let coverageDecalLift: Float = 0.10

    private let rootNode = SCNNode()
    private var coverageNode: SCNNode?
    private var coverageMaterial: SCNMaterial?
    private var coveragePixels: [UInt8] = []
    /// What the decal is *showing*, as opposed to what the runtime has dosed. Soil does not turn
    /// dark the instant it is hit — and a cell that goes from dry to fully wet in one repaint
    /// reads as a hard-edged stain snapping into existence behind the aircraft.
    private var displayedWetness: [Float] = []
    private var coverageSide = 0
    private var isAttached = false

    // MARK: Build

    /// Spawns the whole field. Returns the world position of the refill station (its collar
    /// height included), which the mission runtime uses as the refill anchor.
    @discardableResult
    func build(
        placement: AgriFieldPlacement,
        difficulty: MissionDifficulty,
        into parent: SCNNode
    ) -> SIMD3<Float> {
        clear()
        rootNode.name = "agri.field"
        if !isAttached || rootNode.parent == nil {
            parent.addChildNode(rootNode)
            isAttached = true
        }

        buildSoilPatch(placement: placement)
        buildCrop(placement: placement, difficulty: difficulty)
        buildBoundary(placement: placement)
        buildCoverageDecal(placement: placement)
        let station = buildRefillStation(placement: placement)
        return station
    }

    func clear() {
        rootNode.childNodes.forEach { $0.removeFromParentNode() }
        coverageNode = nil
        coverageMaterial = nil
        coveragePixels = []
        displayedWetness = []
        coverageSide = 0
    }

    func detach() {
        clear()
        rootNode.removeFromParentNode()
        isAttached = false
    }

    // MARK: Soil

    private func buildSoilPatch(placement: AgriFieldPlacement) {
        let side = CGFloat(placement.fieldHalfExtent * 2.0)
        let plane = SCNPlane(width: side, height: side)
        plane.firstMaterial = FieldSoilMaterialLoader.makeSoilMaterial(
            patchSizeMeters: placement.fieldHalfExtent * 2.0
        )
        let node = makeGroundQuadNode(
            geometry: plane,
            name: "agri.field.soil",
            placement: placement,
            lift: Self.soilPatchLift
        )
        rootNode.addChildNode(node)
    }

    /// A flat quad lying on the field, turned to the crop rows.
    ///
    /// Laying the plane down and turning it must be two nested nodes, not one node with three
    /// Euler angles. Combined on a single node the roll is applied in the plane's own frame after
    /// it has been pitched, which is *not* a heading — that is why the soil patch and the field
    /// boundary, given the same heading, came out as two differently oriented rectangles.
    private func makeGroundQuadNode(
        geometry: SCNGeometry,
        name: String,
        placement: AgriFieldPlacement,
        lift: Float
    ) -> SCNNode {
        let wrapper = SCNNode()
        wrapper.name = name
        wrapper.position = SCNVector3(
            placement.fieldCenter.x,
            Self.groundY + lift,
            placement.fieldCenter.y
        )
        // Negated on purpose. A SceneKit yaw of +θ turns a point the *opposite* way to the
        // field's own 2-D rotation (`AgriFieldPlacement.fieldLocalToWorld`), which is what places
        // the coverage grid. Using +θ here put the soil, the boundary and the wet decal in one
        // frame and the crop and the coverage cells in the mirror image of it — visibly, wheat
        // growing on the grass outside the fence.
        wrapper.eulerAngles = SCNVector3(0.0, -placement.rowHeadingRadians, 0.0)

        let quad = SCNNode(geometry: geometry)
        quad.eulerAngles = SCNVector3(-Float.pi / 2.0, 0.0, 0.0)
        quad.castsShadow = false
        wrapper.addChildNode(quad)
        return wrapper
    }

    // MARK: Crop

    private func buildCrop(placement: AgriFieldPlacement, difficulty: MissionDifficulty) {
        let side = placement.fieldHalfExtent * 2.0
        let chunksPerSide = max(1, Int(ceil(side / Self.cropChunkMeters)))
        let chunkSize = side / Float(chunksPerSide)

        let requestedDensity = difficulty.agriCropDensityPerSquareMeter
        let totalRequested = requestedDensity * side * side
        // Thin the crop uniformly rather than leaving bald patches if the ceiling binds.
        let densityScale = totalRequested > Float(Self.maxCropClumps)
            ? Float(Self.maxCropClumps) / totalRequested
            : 1.0
        let density = requestedDensity * densityScale
        let perChunk = max(1, Int((density * chunkSize * chunkSize).rounded()))

        var rng = MissionSeededGenerator(seed: 0xC0FF_EE01)
        var chunkCount = 0
        for cy in 0..<chunksPerSide {
            for cx in 0..<chunksPerSide {
                let chunkLocalOrigin = SIMD2<Float>(
                    -placement.fieldHalfExtent + Float(cx) * chunkSize,
                    -placement.fieldHalfExtent + Float(cy) * chunkSize
                )
                var clumps: [WheatFieldAssetLoader.ClumpPlacement] = []
                clumps.reserveCapacity(perChunk)
                for _ in 0..<perChunk {
                    let offset = SIMD2<Float>(
                        Float.random(in: 0...chunkSize, using: &rng),
                        Float.random(in: 0...chunkSize, using: &rng)
                    )
                    clumps.append(
                        WheatFieldAssetLoader.ClumpPlacement(
                            position: SIMD3<Float>(offset.x, 0.0, offset.y),
                            yaw: Float.random(in: 0...(2.0 * .pi), using: &rng),
                            heightMeters: Float.random(in: 0.78...1.08, using: &rng)
                        )
                    )
                }
                guard let chunk = WheatFieldAssetLoader.shared.makeFieldChunk(clumps: clumps) else {
                    return
                }
                let world = placement.fieldLocalToWorld(chunkLocalOrigin)
                chunk.position = SCNVector3(world.x, Self.groundY, world.y)
                chunk.eulerAngles = SCNVector3(0.0, -placement.rowHeadingRadians, 0.0)
                rootNode.addChildNode(chunk)
                chunkCount += 1
            }
        }
        print("[Agri] crop built: \(chunkCount) batched tiles, ~\(chunkCount * perChunk) clumps, density=\(density)/m²")
    }

    // MARK: Boundary

    /// Four low emissive rails around the treated sector. A spraying mission is flown in straight
    /// passes with turns outside the crop, so the operator needs to see the headland from the air
    /// — a circle would not tell him where a pass ends.
    private func buildBoundary(placement: AgriFieldPlacement) {
        let half = placement.fieldHalfExtent
        let thickness: CGFloat = 0.45
        let height: CGFloat = 0.25
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.systemTeal.withAlphaComponent(0.7)
        material.emission.contents = NSColor.systemTeal.withAlphaComponent(0.45)
        material.lightingModel = .constant
        material.isDoubleSided = true

        let container = SCNNode()
        container.name = "agri.field.boundary"
        container.position = SCNVector3(
            placement.fieldCenter.x,
            Self.groundY + Float(height) * 0.5,
            placement.fieldCenter.y
        )
        container.eulerAngles = SCNVector3(0.0, -placement.rowHeadingRadians, 0.0)

        let edges: [(SIMD2<Float>, Bool)] = [
            (SIMD2<Float>(0, -half), true),
            (SIMD2<Float>(0, half), true),
            (SIMD2<Float>(-half, 0), false),
            (SIMD2<Float>(half, 0), false)
        ]
        for (offset, isAlongX) in edges {
            let box = SCNBox(
                width: isAlongX ? CGFloat(half * 2.0) : thickness,
                height: height,
                length: isAlongX ? thickness : CGFloat(half * 2.0),
                chamferRadius: 0
            )
            box.firstMaterial = material
            let node = SCNNode(geometry: box)
            node.position = SCNVector3(offset.x, 0.0, offset.y)
            node.castsShadow = false
            container.addChildNode(node)
        }
        rootNode.addChildNode(container)
    }

    // MARK: Refill station

    private func buildRefillStation(placement: AgriFieldPlacement) -> SIMD3<Float> {
        let container = SCNNode()
        container.name = "agri.refill_station"
        container.position = SCNVector3(
            placement.stationPosition.x,
            Self.groundY,
            placement.stationPosition.y
        )

        // Three canisters on a pallet reads as a supply point rather than as litter.
        let offsets: [SIMD2<Float>] = [
            SIMD2<Float>(0.0, 0.0),
            SIMD2<Float>(0.85, 0.35),
            SIMD2<Float>(-0.7, 0.55)
        ]
        for (index, offset) in offsets.enumerated() {
            let gallon = WaterStationAssetLoader.shared.makeGallonNode(
                targetHeightMeters: index == 0 ? 1.25 : 1.05,
                yaw: Float(index) * 0.7
            )
            gallon.position = SCNVector3(offset.x, 0.0, offset.y)
            container.addChildNode(gallon)
        }

        // Landing collar: the refill rule is "be close, low and stopped", so the operator needs
        // to see where that is from the air, at spraying altitude, in one glance.
        let collar = SCNTorus(
            ringRadius: CGFloat(AgriSprayTuning.refillRadiusMeters),
            pipeRadius: 0.22
        )
        let collarMaterial = SCNMaterial()
        collarMaterial.diffuse.contents = NSColor.systemBlue.withAlphaComponent(0.65)
        collarMaterial.emission.contents = NSColor.systemBlue.withAlphaComponent(0.45)
        collarMaterial.lightingModel = .constant
        collarMaterial.isDoubleSided = true
        collar.firstMaterial = collarMaterial
        let collarNode = SCNNode(geometry: collar)
        collarNode.position = SCNVector3(0.0, 0.15, 0.0)
        collarNode.castsShadow = false
        container.addChildNode(collarNode)

        let beacon = SCNCylinder(radius: 0.12, height: 6.0)
        let beaconMaterial = SCNMaterial()
        beaconMaterial.diffuse.contents = NSColor.systemBlue.withAlphaComponent(0.28)
        beaconMaterial.emission.contents = NSColor.systemBlue.withAlphaComponent(0.5)
        beaconMaterial.lightingModel = .constant
        beaconMaterial.writesToDepthBuffer = false
        beacon.firstMaterial = beaconMaterial
        let beaconNode = SCNNode(geometry: beacon)
        beaconNode.position = SCNVector3(0.0, 3.0, 0.0)
        beaconNode.castsShadow = false
        container.addChildNode(beaconNode)

        rootNode.addChildNode(container)
        return SIMD3<Float>(placement.stationPosition.x, Self.groundY, placement.stationPosition.y)
    }

    // MARK: Coverage decal

    private func buildCoverageDecal(placement: AgriFieldPlacement) {
        coverageSide = placement.cellsPerSide
        coveragePixels = [UInt8](repeating: 0, count: coverageSide * coverageSide * 4)
        displayedWetness = [Float](repeating: 0.0, count: coverageSide * coverageSide)

        let side = CGFloat(placement.fieldHalfExtent * 2.0)
        let plane = SCNPlane(width: side, height: side)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = false
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        material.blendMode = .alpha
        material.transparencyMode = .aOne
        material.diffuse.contents = makeCoverageImage()
        material.diffuse.magnificationFilter = .linear
        material.diffuse.minificationFilter = .linear
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        plane.firstMaterial = material

        let node = makeGroundQuadNode(
            geometry: plane,
            name: "agri.field.coverage",
            placement: placement,
            lift: Self.coverageDecalLift
        )
        rootNode.addChildNode(node)
        coverageNode = node
        coverageMaterial = material
    }

    /// How fast a cell can visually darken, in fractions of full wetness per second. A pass wets
    /// the ground under the boom in a moment as far as the *dose* is concerned; the soil takes
    /// about a second to show it, which is what makes the patch spread behind the aircraft
    /// instead of appearing under it.
    private static let wetnessRisePerSecond: Float = 0.85
    /// Wet earth, not shadow. The first version tinted towards navy and read as a cloud passing
    /// over the field rather than as a treated strip.
    private static let wetColour = SIMD3<Float>(58.0, 44.0, 31.0)
    private static let wetMaxAlpha: Float = 152.0

    /// Repaints the wet-soil decal from the runtime's dose grid, easing each cell towards its
    /// dose rather than snapping to it. Returns whether any cell is still catching up, so the
    /// caller knows to keep repainting after the dosing itself has stopped changing.
    ///
    /// Cheap enough to call several times a second: the texture is one pixel per coverage cell
    /// (at most 80×80).
    @discardableResult
    func updateCoverage(doseFractions: [Float], deltaTime: TimeInterval) -> Bool {
        guard coverageSide > 0,
              doseFractions.count == coverageSide * coverageSide,
              displayedWetness.count == doseFractions.count,
              let material = coverageMaterial else {
            return false
        }

        let step = Self.wetnessRisePerSecond * Float(max(0.0, deltaTime))
        var stillRising = false
        for index in 0..<doseFractions.count {
            let target = max(0.0, min(1.0, doseFractions[index]))
            var shown = displayedWetness[index]
            if shown < target {
                shown = step > 0.0 ? min(target, shown + step) : target
                if shown < target {
                    stillRising = true
                }
                displayedWetness[index] = shown
            } else if shown > target {
                // Only ever happens on a reset; snap rather than linger on a stale stain.
                shown = target
                displayedWetness[index] = shown
            }

            let base = index * 4
            coveragePixels[base] = UInt8(Self.wetColour.x)
            coveragePixels[base + 1] = UInt8(Self.wetColour.y)
            coveragePixels[base + 2] = UInt8(Self.wetColour.z)
            // Eased on top of the linear ramp: the last of the darkening arrives slowly, which is
            // what stops a finished cell from popping to its final tone.
            let eased = shown * shown * (3.0 - 2.0 * shown)
            coveragePixels[base + 3] = UInt8(min(Self.wetMaxAlpha, Self.wetMaxAlpha * eased))
        }
        material.diffuse.contents = makeCoverageImage()
        return stillRising
    }

    private func makeCoverageImage() -> CGImage? {
        guard coverageSide > 0 else { return nil }
        let bytesPerRow = coverageSide * 4
        guard let provider = CGDataProvider(data: Data(coveragePixels) as CFData) else { return nil }
        return CGImage(
            width: coverageSide,
            height: coverageSide,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            // Straight (non-premultiplied) alpha: the colour written per cell is the wet-soil
            // tint itself, and only the alpha carries the dose. Premultiplying here would make
            // a half-dosed cell both fainter *and* darker, double-counting the same number.
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
