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

    /// Animated flame "cross-billboard" wrapped around a burning tree — 3 identical `SCNPlane`s
    /// sharing one material, fixed at 60° apart around the trunk's vertical axis (0°/60°/120°,
    /// each double-sided so that span covers the full 360° same as a full turn would). Deliberately
    /// NOT a single `SCNBillboardConstraint`-driven plane (the previous approach): a billboard
    /// always re-orients to face the camera, which cancels out any fixed angular offset between
    /// multiple planes — they'd all converge to the same camera-facing orientation regardless of
    /// how they were initially rotated, so a billboarded plane can never look "wrapped around" a
    /// volume no matter how many copies you add. Fixed, unbillboarded angles are what actually
    /// give the classic impostor-tree look of fire surrounding the trunk from any viewing angle,
    /// same technique real-time engines use for cross-billboard foliage.
    ///
    /// `baseYawDegrees` MUST differ per tree (caller passes the tree's own random yaw) — a first
    /// version hardcoded the same 3 world-space angles for every tree, so every burning tree's
    /// planes lined up at the exact same 3 absolute directions; from any single camera angle, many
    /// same-angle planes across many different trees projected into the same screen-space
    /// orientation and merged into a few giant flat "walls" instead of 13 separate, localized fire
    /// clumps. Falls back to an empty node if the textures failed to load.
    func makeFlameNode(heightMeters: Float, baseYawDegrees: Float = 0.0) -> SCNNode {
        let wrapper = SCNNode()
        wrapper.name = "mission.fire_tree.flame"

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

        // Matches the source sprite cell's own aspect ratio (~157.5:256 px ≈ 0.615:1, measured
        // directly off the grid, not guessed) instead of the earlier 0.5:1, which over-stretched
        // the flame image vertically into a tall, rigid-looking "pillar." Also shrunk overall
        // (was spanning near-ground to well above the crown) so the flame reads as concentrated
        // around the crown instead of a uniform column — narrower helps it stay hugging a single
        // tree instead of visually bridging into neighbors in a dense cluster too.
        let width = CGFloat(heightMeters) * 0.42
        let height = CGFloat(heightMeters) * 0.68
        let plane = SCNPlane(width: width, height: height)
        plane.firstMaterial = material

        let yawAnglesDegrees: [Float] = [0.0, 60.0, 120.0]
        for yawDegrees in yawAnglesDegrees {
            let planeNode = SCNNode(geometry: plane)
            planeNode.name = "mission.fire_tree.flame.plane"
            planeNode.castsShadow = false
            planeNode.eulerAngles.y = CGFloat((yawDegrees + baseYawDegrees) * .pi / 180.0)
            wrapper.addChildNode(planeNode)
        }

        configureFlipbookSampler(material: material)

        return wrapper
    }

    /// Starts/stops the flame's flipbook animation on an already-built flame node (from
    /// `makeFlameNode`) — deliberately NOT auto-started at creation time. Every tree in the fire
    /// zone's full pool (up to 13 at hard difficulty, most of them unburned/hidden at any moment)
    /// gets its own flame node up front; a `SCNAction.repeatForever` keeps evaluating every
    /// rendered frame and re-writing the material's `contentsTransform` even while the node is
    /// `.isHidden` (hidden only skips drawing, not action evaluation) — a constant, mission-long
    /// tax across the whole tree pool regardless of how many are actually burning. Caller (see
    /// `DroneSceneController.updateFireResponseVisuals`) starts this only on the burning-state
    /// transition, not every tick — `runAction`/`removeAction(forKey:)` are idempotent no-ops if
    /// already in the requested state, so redundant calls are harmless but unnecessary.
    func setFlameAnimating(_ flameNode: SCNNode, isAnimating: Bool) {
        guard let planeNode = flameNode.childNodes.first,
              let material = planeNode.geometry?.firstMaterial else {
            return
        }
        if isAnimating {
            guard planeNode.action(forKey: "fireFlipbook") == nil else { return }
            runFlipbookAnimation(on: planeNode, material: material)
        } else {
            planeNode.removeAction(forKey: "fireFlipbook")
        }
    }

    /// Soft rising smoke above a burning tree — a procedural particle system (no image), mirroring
    /// the rain/snow convention already proven in `DroneSceneController.makeRainSystem`/`makeSnowSystem`.
    /// Deliberately created WITHOUT a particle system attached (see `setSmokeActive`) — same
    /// hidden-but-still-simulating cost as the flame flipbook above applies to particle systems too.
    func makeSmokeNode() -> SCNNode {
        let node = SCNNode()
        node.name = "mission.fire_tree.smoke"
        return node
    }

    /// Attaches/removes the smoke particle system based on burning state — called on the
    /// burning-state transition, not every tick (see `setFlameAnimating`'s doc comment for why).
    func setSmokeActive(_ smokeNode: SCNNode, isActive: Bool) {
        if isActive {
            guard smokeNode.particleSystems?.isEmpty ?? true else { return }
            smokeNode.addParticleSystem(makeSmokeParticleSystem())
        } else {
            smokeNode.removeAllParticleSystems()
        }
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

    /// One-shot capsule-burst visual — a grey/white powder-cloud puff that scales up to roughly
    /// the capsule's actual blast radius and fades out, then removes itself. Distinct from
    /// `makeFoamBurstNode()` (pure white, fixed small size, for the hose's per-tree charring
    /// moment) since this needs to communicate the capsule's actual area of effect, which varies
    /// by rigged capsule size.
    func makeCapsuleBurstNode(blastRadiusMeters: Float) -> SCNNode {
        let baseRadius: Float = 0.3
        let sphere = SCNSphere(radius: CGFloat(baseRadius))
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor(calibratedWhite: 0.86, alpha: 1.0)
        material.emission.contents = NSColor(calibratedWhite: 0.86, alpha: 0.35)
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        sphere.firstMaterial = material

        let node = SCNNode(geometry: sphere)
        node.name = "mission.fire_capsule.burst"
        node.castsShadow = false
        node.opacity = 0.85

        let targetScale = CGFloat(max(1.0, blastRadiusMeters / baseRadius))
        let grow = SCNAction.scale(to: targetScale, duration: 0.4)
        grow.timingMode = .easeOut
        let fade = SCNAction.sequence([SCNAction.wait(duration: 0.2), SCNAction.fadeOut(duration: 0.4)])
        node.runAction(.sequence([.group([grow, fade]), .removeFromParentNode()]))
        return node
    }

    /// Persistent, growing foam-coating visual — one per fire tree, scaled externally by the
    /// caller as suppression progress advances (0 = invisible, 1 = fully grown). This is the
    /// visible "how close is THIS tree to being out" read the player asked for in place of a HUD
    /// progress bar: a real accumulating blob at the fire itself instead of a number on screen.
    /// Stays at whatever size it reached rather than resetting or disappearing once a tree is
    /// fully suppressed — reads as foam residue left behind, not a UI element that vanishes.
    func makeFoamAccumulationNode() -> SCNNode {
        let sphere = SCNSphere(radius: 1.0)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.white
        material.emission.contents = NSColor.white.withAlphaComponent(0.12)
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        material.transparency = 0.9
        sphere.firstMaterial = material

        let node = SCNNode(geometry: sphere)
        node.name = "mission.fire_tree.foam_accumulation"
        node.castsShadow = false
        node.isHidden = true
        node.scale = SCNVector3(0.001, 0.001, 0.001)
        return node
    }

    // MARK: - Flame flipbook

    /// One-time sampler setup, safe to do at creation regardless of burn state (unlike actually
    /// running the animation — see `setFlameAnimating`).
    private func configureFlipbookSampler(material: SCNMaterial) {
        // Prevent the sampler from bleeding neighboring frames at tile edges once
        // `contentsTransform` scales the UV rect down to a single grid cell.
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.emission.wrapS = .clamp
        material.emission.wrapT = .clamp
    }

    private func runFlipbookAnimation(on node: SCNNode, material: SCNMaterial) {
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
        node.runAction(.repeatForever(animate), forKey: "fireFlipbook")
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
