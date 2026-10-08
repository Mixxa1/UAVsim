import SceneKit
import ImageIO

/// CC0 Houdini-rendered sequences. The GPU blends adjacent frames in premultiplied colour,
/// while simulation age selects the frame: live playback, pause and seeking agree.
/// Padded cells and level-zero sampling prevent other frames leaking into a small flame.
enum HoudiniFlipbook: String, CaseIterable {
    case flame = "HoudiniFlame", burst = "HoudiniBurst", smoke = "HoudiniSmoke"

    private var layout: SIMD4<Float> {
        switch self {
        case .flame: return SIMD4(16, 4, 128, 256)
        case .burst: return SIMD4(5, 5, 256, 256)
        case .smoke: return SIMD4(8, 8, 128, 128)
        }
    }
    private var frames: Int { Int(layout.x * layout.y) }
    private var fps: Double { self == .burst ? 24 : 30 }
    private static let images: [HoudiniFlipbook: CGImage] = {
        var result: [HoudiniFlipbook: CGImage] = [:]
        for asset in allCases {
            let url = Bundle.main.url(forResource: asset.rawValue, withExtension: "png", subdirectory: "VFX")
                ?? Bundle.main.url(forResource: asset.rawValue, withExtension: "png")
            if let url, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0,
                   [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                result[asset] = image
            }
        }
        return result
    }()

    func makeMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.name = rawValue
        material.lightingModel = .constant
        material.blendMode = .alpha
        material.transparencyMode = .aOne
        material.writesToDepthBuffer = false
        material.readsFromDepthBuffer = true
        material.isDoubleSided = true
        guard let image = Self.images[self] else {
            // A broken asset installation must not crash a flight. The native asset probe also
            // checks that every bundled sequence renders and animates.
            NSLog("Missing bundled VFX texture: %@", rawValue)
            material.diffuse.contents = NSColor.clear
            return material
        }
        let property = SCNMaterialProperty(contents: image)
        property.wrapS = .clamp; property.wrapT = .clamp
        property.minificationFilter = .linear; property.magnificationFilter = .linear
        property.mipFilter = .none
        material.setValue(property, forKey: "vfxAtlas")
        material.setValue(NSValue(scnVector4: SCNVector4(layout.x, layout.y, layout.z, layout.w)), forKey: "vfxLayout")
        material.setValue(NSValue(scnVector4: SCNVector4(1, 1, 1, 1)), forKey: "vfxTint")
        material.setValue(NSNumber(value: Float(0)), forKey: "vfxFrame")
        material.shaderModifiers = [.geometry: Self.geometryShader, .surface: Self.surfaceShader]
        return material
    }

    func setAge(_ age: TimeInterval, material: SCNMaterial) {
        let age = age.isFinite ? max(0, age) : 0
        let frame = self == .burst ? min(Double(frames - 1), age * fps)
            : (age * fps).truncatingRemainder(dividingBy: Double(frames))
        // Match the Metal argument's 32-bit storage. An NSNumber backed by Double made the
        // native renderer keep sampling frame zero even though value(forKey:) changed.
        material.setValue(NSNumber(value: Float(frame)), forKey: "vfxFrame")
    }

    static func setTint(_ colour: SIMD3<Float>, material: SCNMaterial) {
        material.setValue(NSValue(scnVector4: SCNVector4(colour.x, colour.y, colour.z, 1)), forKey: "vfxTint")
    }

    private static let geometryShader = """
    #pragma varyings
    float2 vfxUV;
    #pragma body
    out.vfxUV = _geometry.texcoords[0];
    """

    private static let surfaceShader = """
    #pragma arguments
    texture2d<float> vfxAtlas;
    float4 vfxLayout;
    float4 vfxTint;
    float vfxFrame;
    #pragma transparent
    #pragma body
    constexpr sampler atlasSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float count = vfxLayout.x * vfxLayout.y;
    float first = floor(vfxFrame);
    float second = fmod(first + 1.0, count);
    float2 tile = vfxLayout.zw + 4.0;
    float2 atlasSize = tile * vfxLayout.xy;
    float2 local = clamp(in.vfxUV, 0.0, 1.0);
    float2 cellA = float2(fmod(first, vfxLayout.x), floor(first / vfxLayout.x));
    float2 cellB = float2(fmod(second, vfxLayout.x), floor(second / vfxLayout.x));
    float2 pixel = 2.5 + local * (vfxLayout.zw - 1.0);
    float4 a = vfxAtlas.sample(atlasSampler, (cellA * tile + pixel) / atlasSize, level(0.0));
    float4 b = vfxAtlas.sample(atlasSampler, (cellB * tile + pixel) / atlasSize, level(0.0));
    float blend = fract(vfxFrame);
    float alpha = mix(a.a, b.a, blend);
    float3 colour = mix(a.rgb * a.a, b.rgb * b.a, blend) / max(alpha, 0.00001);
    _surface.diffuse = float4(colour * vfxTint.rgb, alpha * vfxTint.a);
    _surface.emission = float4(0.0);
    """
}

final class FireVisualAssetLoader {
    static let shared = FireVisualAssetLoader()

    private init() {}

    /// Each flame faces the viewing azimuth, with several independently aged flames placed
    /// around the actual burning component by the world renderer. No crossed sprite walls.
    func makeFlameNode(heightMeters: Float, baseYawDegrees: Float = 0) -> SCNNode {
        let wrapper = SCNNode()
        wrapper.name = "mission.fire_tree.flame"
        let plane = SCNPlane(width: CGFloat(heightMeters) * 0.5, height: CGFloat(heightMeters))
        plane.firstMaterial = HoudiniFlipbook.flame.makeMaterial()
        let node = SCNNode(geometry: plane)
        node.name = "mission.fire_tree.flame.plane"
        node.castsShadow = false
        let billboard = SCNBillboardConstraint(); billboard.freeAxes = .Y
        node.constraints = [billboard]
        wrapper.addChildNode(node)
        setFlameAge(wrapper, age: Double(baseYawDegrees) / 100)
        return wrapper
    }

    func setFlameAnimating(_ flameNode: SCNNode, isAnimating: Bool) {
        guard let plane = flameNode.childNodes.first,
              let material = plane.geometry?.firstMaterial else { return }
        if isAnimating {
            guard plane.action(forKey: "fireFlipbook") == nil else { return }
            let duration = 64.0 / 30.0
            let animation = SCNAction.customAction(duration: duration) { _, age in
                HoudiniFlipbook.flame.setAge(Double(age), material: material)
            }
            plane.runAction(.repeatForever(animation), forKey: "fireFlipbook")
        } else {
            plane.removeAction(forKey: "fireFlipbook")
        }
    }

    func setFlameAge(_ flameNode: SCNNode, age: TimeInterval) {
        guard let material = flameNode.childNodes.first?.geometry?.firstMaterial else { return }
        HoudiniFlipbook.flame.setAge(age, material: material)
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
