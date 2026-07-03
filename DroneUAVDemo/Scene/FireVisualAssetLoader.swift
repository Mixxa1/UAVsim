import SceneKit
import ImageIO

/// Real fire/smoke/foam VFX for the fire-response scenario, replacing increment 1's placeholder
/// burn-state marker sphere.
///
/// The flame texture ships as two plain image files (`Fire_sheet_baseColor.png`/
/// `Fire_sheet_emissive.jpg`, extracted once from the original `flames.usdz` Sketchfab asset and
/// bundled directly) rather than loading `flames.usdz` itself via `SCNScene(url:)`. That path was
/// tried first and produced no visible flame at all — most likely because the USDZ's material is
/// authored as a `UsdPreviewSurface` shader graph (separate `UsdUVTexture`/`UsdPrimvarReader`
/// nodes wired together, not a flat "diffuse = image" material), which SceneKit's USD/USDZ
/// importer may not fully flatten into a usable `SCNMaterial.diffuse.contents`. Loading the two
/// textures directly and building our own material sidesteps that shader-graph parsing question
/// entirely. The 2048×2048 base-color texture LOOKS like a 13×8 flipbook grid at a glance, but
/// is not a uniformly-populated one — confirmed by direct alpha-channel analysis (mean alpha per
/// assumed cell, plus mean alpha in a thin strip at each row boundary to detect cross-row bleed),
/// not eyeballed. Most rows have some cells that are near-blank padding, and since the emissive
/// JPG has no alpha channel of its own to gate against a blank diffuse cell, cycling through one
/// of those produced a solid white block/streak over the flame — this is exactly what showed up
/// in a user-recorded test clip. Row 6 (0-indexed, of 8 total) is the one row confirmed clean on
/// both axes: zero measured bleed at its own top boundary, and every one of its 13 columns carries
/// real, comparably-sized flame content (mean alpha 11.9-31.1 out of 255, vs. near-zero for
/// genuinely blank cells found elsewhere in the sheet) — verified by cropping and viewing that row
/// in isolation. The flipbook now cycles only through that row's 13 columns, not the full grid.
/// Animated via a hand-driven `contentsTransform` (not `SCNParticleSystem.imageSequence*`, whose
/// behavior against this specific texture was unproven and harder to verify blind).
private enum FireFlipbookLayout {
    static let totalColumns = 13
    static let totalRows = 8
    static let sourceRow = 6
    static let frameRate: Double = 14.0
    static var totalFrames: Int { totalColumns }
}

final class FireVisualAssetLoader {
    static let shared = FireVisualAssetLoader()

    private enum AssetConstants {
        static let baseColorResourceName = "Fire_sheet_baseColor"
        static let baseColorResourceExtension = "png"
        static let emissiveResourceName = "Fire_sheet_emissive"
        static let emissiveResourceExtension = "jpg"
    }

    private var cachedBaseColorImage: CGImage?
    private var cachedEmissiveImage: CGImage?
    private var didAttemptLoad = false
    private var didWarnFailure = false

    private init() {}

    /// Animated flame billboard for a burning tree — a plain `SCNPlane` (not the source USDZ's own
    /// ground-facing quad) with an `SCNBillboardConstraint` so it always faces the camera. Falls
    /// back to an empty node if the textures failed to load.
    func makeFlameNode(heightMeters: Float) -> SCNNode {
        let wrapper = SCNNode()
        wrapper.name = "mission.fire_tree.flame"
        wrapper.constraints = [SCNBillboardConstraint()]

        guard let baseColor = loadBaseColorImage(), let emissive = loadEmissiveImage() else {
            warnOnce()
            return wrapper
        }

        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = baseColor
        material.emission.contents = emissive
        material.blendMode = .add
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        material.isDoubleSided = true

        let width = CGFloat(heightMeters) * 0.85
        let height = CGFloat(heightMeters)
        let plane = SCNPlane(width: width, height: height)
        plane.firstMaterial = material

        let planeNode = SCNNode(geometry: plane)
        planeNode.name = "mission.fire_tree.flame.plane"
        planeNode.castsShadow = false
        wrapper.addChildNode(planeNode)

        runFlipbookAnimation(on: planeNode, material: material)

        return wrapper
    }

    /// Soft rising smoke above a burning tree — a procedural particle system (no image), mirroring
    /// the rain/snow convention already proven in `DroneSceneController.makeRainSystem`/`makeSnowSystem`.
    func makeSmokeNode() -> SCNNode {
        let node = SCNNode()
        node.name = "mission.fire_tree.smoke"
        node.addParticleSystem(makeSmokeParticleSystem())
        return node
    }

    /// One-shot suppression burst — a white/foam-colored sphere that scales up and fades out,
    /// then removes itself. Caller attaches it at the moment a tree transitions to `.charred`.
    func makeFoamBurstNode() -> SCNNode {
        let sphere = SCNSphere(radius: 0.6)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.white
        material.emission.contents = NSColor.white.withAlphaComponent(0.5)
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        sphere.firstMaterial = material

        let node = SCNNode(geometry: sphere)
        node.name = "mission.fire_tree.foam_burst"
        node.castsShadow = false
        node.opacity = 0.9

        let grow = SCNAction.scale(to: 2.6, duration: 0.5)
        grow.timingMode = .easeOut
        let fade = SCNAction.sequence([SCNAction.wait(duration: 0.15), SCNAction.fadeOut(duration: 0.35)])
        node.runAction(.sequence([.group([grow, fade]), .removeFromParentNode()]))
        return node
    }

    // MARK: - Flame flipbook

    private func runFlipbookAnimation(on node: SCNNode, material: SCNMaterial) {
        // Prevent the sampler from bleeding neighboring frames at tile edges once
        // `contentsTransform` scales the UV rect down to a single grid cell.
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.emission.wrapS = .clamp
        material.emission.wrapT = .clamp

        let totalFrames = FireFlipbookLayout.totalFrames
        let cycleDuration = Double(totalFrames) / FireFlipbookLayout.frameRate
        let animate = SCNAction.customAction(duration: cycleDuration) { _, elapsedTime in
            let progress = (Double(elapsedTime) / cycleDuration).truncatingRemainder(dividingBy: 1.0)
            let column = min(totalFrames - 1, max(0, Int(progress * Double(totalFrames))))
            let sx = 1.0 / CGFloat(FireFlipbookLayout.totalColumns)
            let sy = 1.0 / CGFloat(FireFlipbookLayout.totalRows)

            var transform = SCNMatrix4Identity
            transform.m11 = sx
            transform.m22 = sy
            transform.m41 = CGFloat(column) * sx
            // Sprite-sheet row 0 is the texture's top; flip so row 0 maps to the top of UV space.
            transform.m42 = 1.0 - sy - CGFloat(FireFlipbookLayout.sourceRow) * sy

            material.diffuse.contentsTransform = transform
            material.emission.contentsTransform = transform
        }
        node.runAction(.repeatForever(animate))
    }

    private func loadBaseColorImage() -> CGImage? {
        loadTextures()
        return cachedBaseColorImage
    }

    private func loadEmissiveImage() -> CGImage? {
        loadTextures()
        return cachedEmissiveImage
    }

    private func loadTextures() {
        guard !didAttemptLoad else { return }
        didAttemptLoad = true

        cachedBaseColorImage = loadCGImage(
            resourceName: AssetConstants.baseColorResourceName,
            withExtension: AssetConstants.baseColorResourceExtension
        )
        cachedEmissiveImage = loadCGImage(
            resourceName: AssetConstants.emissiveResourceName,
            withExtension: AssetConstants.emissiveResourceExtension
        )
    }

    // Loads via ImageIO/CGImageSource directly (not NSImage) — a more reliable path for feeding
    // an image into an SCNMaterialProperty; NSImage occasionally fails to hand SceneKit's Metal
    // renderer a usable backing representation depending on the image's internal representation.
    private func loadCGImage(resourceName: String, withExtension ext: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: ext) else {
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func warnOnce() {
        guard !didWarnFailure else { return }
        didWarnFailure = true
        print("[Scenario] Fire_sheet textures unavailable; burning trees will show no flame VFX")
    }

    // MARK: - Foam spray

    /// The visible foam stream itself — travels from the nozzle to wherever it currently lands.
    /// Caller retunes `particleVelocity`/`particleLifeSpan` every tick so particles arrive at the
    /// actual raycast distance instead of a fixed guessed range (aim direction and target distance
    /// both change continuously while flying).
    func makeFoamStreamParticleSystem() -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.particleColor = NSColor(calibratedRed: 0.92, green: 0.96, blue: 1.0, alpha: 0.92)
        system.particleSize = 0.16
        system.particleSizeVariation = 0.06
        system.birthRate = 300
        system.emitterShape = SCNSphere(radius: 0.04)
        system.birthDirection = .constant
        system.emittingDirection = SCNVector3(0, 0, -1)
        system.spreadingAngle = 4
        system.isAffectedByGravity = false
        system.blendMode = .alpha
        system.loops = true
        system.particleLifeSpan = 0.35
        system.particleVelocity = 45
        system.particleVelocityVariation = 4
        return system
    }

    /// Continuous splash where the stream currently lands — reads as impact, not just a beam
    /// stopping in mid-air.
    func makeFoamImpactParticleSystem() -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.particleColor = NSColor.white
        system.particleSize = 0.3
        system.particleSizeVariation = 0.15
        system.birthRate = 70
        system.emitterShape = SCNSphere(radius: 0.2)
        system.particleLifeSpan = 0.45
        system.particleLifeSpanVariation = 0.15
        system.particleVelocity = 0.9
        system.particleVelocityVariation = 0.4
        system.spreadingAngle = 180
        system.isAffectedByGravity = true
        system.acceleration = SCNVector3(0, -2.2, 0)
        system.blendMode = .alpha
        system.loops = true
        return system
    }

    // MARK: - Smoke

    private func makeSmokeParticleSystem() -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.particleColor = NSColor(calibratedWhite: 0.55, alpha: 0.32)
        system.particleSize = 1.1
        system.particleSizeVariation = 0.6
        system.birthRate = 4
        system.particleLifeSpan = 6.0
        system.particleLifeSpanVariation = 2.0
        system.emitterShape = SCNSphere(radius: 0.5)
        system.spreadingAngle = 25
        system.particleVelocity = 1.3
        system.particleVelocityVariation = 0.5
        system.acceleration = SCNVector3(0, 0.55, 0)
        system.isAffectedByGravity = false
        system.blendMode = .alpha
        system.particleAngularVelocity = 20
        system.particleAngularVelocityVariation = 12
        system.loops = true
        return system
    }
}
