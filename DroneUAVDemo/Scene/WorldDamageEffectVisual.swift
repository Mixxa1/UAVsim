import AppKit
import Metal
import SceneKit
import simd

/// The live scene and recorder share these bounded, simulation-aged visuals. No lights,
/// particle emitters or actions are created per hit; seeking restores the same frame of fire.
final class WorldDamageEffectVisual {
    static let preparationNodeName = "damage-effects-preparation"
    let node = SCNNode()
    private let kind: InterceptEffectKind
    private let scale: Float
    private var sprites: [SCNNode] = []
    private var flames: [SCNNode] = []

    /// Asset preparation alone does not compile Metal's first draw pipelines. The view also
    /// renders an isolated warm-up scene before flight; this hidden subtree only owns assets.
    static func makePreparationNode() -> SCNNode {
        let root = SCNNode()
        root.name = preparationNodeName
        for kind in [InterceptEffectKind.explosion, .smoke, .fire] {
            let effect = WorldDamageEffectVisual(kind: kind)
            effect.update(age: 0.1, lifetime: 10, normal: SIMD3<Float>(0, 1, 0))
            root.addChildNode(effect.node)
        }
        // Ruptured sheet metal and ground-contact surfaces introduce draw variants too.
        // Compile them before flight, alongside the flame/burst passes.
        let metal = SCNMaterial(); metal.lightingModel = .physicallyBased
        metal.diffuse.contents = NSColor(calibratedWhite: 0.55, alpha: 1)
        metal.multiply.contents = NSColor(calibratedWhite: 0.6, alpha: 1)
        metal.metalness.contents = 0.65; metal.roughness.contents = 0.7; metal.isDoubleSided = true
        let sheet = SCNGeometry(sources: [SCNGeometrySource(vertices: [SCNVector3(-1, 0, 0), SCNVector3(1, 0, 0), SCNVector3(0, 2, 0)]),
            SCNGeometrySource(normals: Array(repeating: SCNVector3(0, 0, 1), count: 3)),
            SCNGeometrySource(textureCoordinates: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0.5, y: 1)])],
            elements: [SCNGeometryElement(indices: [UInt32(0), 1, 2], primitiveType: .triangles)])
        sheet.firstMaterial = metal; root.addChildNode(SCNNode(geometry: sheet))
        let road = GroundVehicleRuntime(position: .zero, seed: 1)
        let shadows = GroundVehicleContactShadows(); shadows.update(road, ground: { _, _ in 0 })
        root.addChildNode(shadows.node)
        let tracks = GroundVehicleTrackVisuals()
        tracks.update([MissionReplayWheelTrack(id: UUID(), corners: [SIMD3<Float>(-1, 0, -1), SIMD3<Float>(1, 0, -1),
            SIMD3<Float>(-1, 0, 1), SIMD3<Float>(1, 0, 1)], length: 2, opacity: 0.34)])
        root.addChildNode(tracks.node)
        root.isHidden = true
        return root
    }

    /// SCNSceneRenderer.prepare uploads resources but skips pipelines for hidden geometry.
    /// A tiny real draw compiles the same alpha/additive shaders and MSAA variants. This uses
    /// independent nodes so the live world never shows a preparation effect or receives actions.
    static func prepareRenderPipelines(device: any MTLDevice, antialiasing: SCNAntialiasingMode) {
        autoreleasepool {
            let scene = SCNScene()
            let preparation = makePreparationNode()
            preparation.isHidden = false
            scene.rootNode.addChildNode(preparation)
            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.usesOrthographicProjection = true
            camera.camera?.orthographicScale = 8
            camera.simdPosition = SIMD3<Float>(0, 3, 20)
            scene.rootNode.addChildNode(camera)
            let light = SCNNode(); light.light = SCNLight(); light.light?.type = .directional
            light.light?.castsShadow = true; light.eulerAngles = SCNVector3(-0.7, -0.4, 0)
            scene.rootNode.addChildNode(light)
            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = scene
            renderer.pointOfView = camera
            _ = renderer.prepare(preparation, shouldAbortBlock: nil)
            _ = renderer.snapshot(atTime: 0, with: CGSize(width: 64, height: 64), antialiasingMode: antialiasing)
        }
    }

    init(kind: InterceptEffectKind, scale: Float = 1) {
        self.kind = kind
        self.scale = max(0.2, min(4, scale))
        if kind == .fire {
            for index in 0..<6 {
                let flame = FireVisualAssetLoader.shared.makeFlameNode(heightMeters: self.scale * (1.7 + Float(index % 3) * 0.18),
                    baseYawDegrees: Float(index) * 37)
                flame.simdPosition = SIMD3<Float>(sin(Float(index) * 2.4) * self.scale * 0.27,
                    self.scale * 0.72, cos(Float(index) * 2.4) * self.scale * 0.27)
                node.addChildNode(flame); flames.append(flame)
            }
        }
        let count = kind == .smoke ? 12 : kind == .explosion ? 24 : kind == .fire ? 12 : 18
        for index in 0..<count {
            let sprite = SCNPlane(width: 2, height: 2)
            let cloud = kind == .smoke || (kind == .explosion && index >= 4 && index < 12)
            let burst = kind == .explosion && index > 0 && index < 4
            let material: SCNMaterial
            if cloud || burst {
                material = (cloud ? HoudiniFlipbook.smoke : .burst).makeMaterial()
            } else {
                material = SCNMaterial()
                material.lightingModel = .constant
                material.diffuse.contents = Self.glowSprite
                material.multiply.contents = NSColor(calibratedRed: 1, green: 0.43, blue: 0.08, alpha: 1)
                material.blendMode = .add
                material.writesToDepthBuffer = false
                material.readsFromDepthBuffer = true
                material.isDoubleSided = true
            }
            sprite.firstMaterial = material
            let child = SCNNode(geometry: sprite)
            child.name = "damage.\(kind.rawValue).\(index)"
            child.castsShadow = false
            child.constraints = [SCNBillboardConstraint()]
            node.addChildNode(child); sprites.append(child)
        }
    }

    func update(age: TimeInterval, lifetime: TimeInterval, normal: SIMD3<Float>, wind: SIMD3<Float> = .zero) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        defer { SCNTransaction.commit() }
        let t = Float(max(0, age)), life = Float(max(0.01, lifetime))
        let tail = min(1, max(0, (life - t) / min(8, life * 0.25)))
        let finiteWind = wind.x.isFinite && wind.y.isFinite && wind.z.isFinite ? wind : .zero
        let outward = simd_length_squared(normal) > 0.001 ? simd_normalize(normal) : SIMD3<Float>(0, 1, 0)
        let frame = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: outward)
        // A large vehicle fire subsides into embers well before its last smoke disappears.
        let flameStrength = life <= 10 ? max(0, min(1, (life * 0.65 - t) / (life * 0.4)))
            : scale > 1.5 ? max(0, min(1, (45 - t) / 15)) : tail
        for (index, flame) in flames.enumerated() {
            FireVisualAssetLoader.shared.setFlameAge(flame, age: age * (0.85 + Double(index) * 0.057) + Double(index) * 0.37)
            let pulse = 0.92 + 0.08 * sin(t * 6.3 + Float(index) * 2.1)
            flame.simdScale = SIMD3<Float>(pulse, 0.45 + flameStrength * 0.55, pulse)
            let height = scale * (0.72 + Float(index % 3) * 0.06) * (0.45 + flameStrength * 0.55)
            flame.simdPosition = SIMD3<Float>(sin(Float(index) * 2.4) * scale * 0.25,
                height, cos(Float(index) * 2.4) * scale * 0.25)
                + finiteWind * 0.035 * flameStrength
            flame.opacity = CGFloat(flameStrength * tail)
            flame.isHidden = flameStrength <= 0
        }
        for (index, sprite) in sprites.enumerated() {
            let seed = Float(index + 1)
            let radial = SIMD3<Float>(sin(seed * 2.39996), 0, cos(seed * 2.39996))
            var position = SIMD3<Float>.zero
            var size: Float = 0.05, opacity: Float = 0
            switch kind {
            case .smoke:
                let cycle: Float = 6.5
                let delay = Float(index) * cycle / Float(sprites.count)
                let puffAge = max(0, t - delay).truncatingRemainder(dividingBy: cycle)
                let phase = puffAge / cycle
                position = radial * (0.12 + phase * 0.55) * scale
                    + SIMD3<Float>(0, puffAge * (1.5 + scale * 0.2), 0)
                    + finiteWind * puffAge * 0.35
                size = (0.22 + phase * 1.65) * scale
                let fadeIn = min(1, phase * 8)
                let smoulder = scale > 1.5 ? 1 - min(1, max(0, t - 35) / 35) * 0.65 : 1
                opacity = t >= delay ? fadeIn * (1 - phase) * tail * smoulder * 0.40 : 0
                let grey = CGFloat(0.12 + phase * 0.10 + min(1, t / 80) * 0.13)
                if let material = sprite.geometry?.firstMaterial {
                    HoudiniFlipbook.smoke.setAge(Double(puffAge) * 0.4 + Double(index) * 0.17, material: material)
                    HoudiniFlipbook.setTint(SIMD3(repeating: Float(grey) * 2), material: material)
                }
            case .fire:
                let phase = (t * 0.75 + seed * 0.17).truncatingRemainder(dividingBy: 1)
                // Sparse incandescent flecks, not hovering red/orange marker balls.
                position = radial * phase * scale * 0.3 + SIMD3<Float>(0, phase * scale * 1.5, 0)
                    + finiteWind * phase * 0.06
                size = scale * 0.009
                opacity = (1 - phase) * tail * flameStrength * 0.65
            case .explosion:
                let expansion = 1 - exp(-t * 8)
                if index == 0 {
                    // Collision spheres meet just inside the visible bodywork. A flash at that
                    // point was hidden by the roof until the panel flew off. Place only the hot
                    // core outside along the contact normal; depth testing still hides it behind
                    // unrelated walls, and smoke/debris retain the actual impact origin.
                    position = outward * 0.85 * scale
                    size = (0.9 + expansion * 1.1) * scale
                    opacity = exp(-t * 20)
                    sprite.geometry?.firstMaterial?.multiply.contents = NSColor(calibratedRed: 1, green: 0.94, blue: 0.70, alpha: 1)
                } else if index < 4 {
                    // A real simulated fireball grows and rolls into soot. Its first frame is
                    // already bright; contact does not wait for a fade-in or a detached panel.
                    let delay = Float(index - 1) * 0.045
                    let burstAge = max(0, t - delay)
                    let variation = 1 - Float(index - 1) * 0.22
                    position = outward * (0.8 + expansion * 0.25) * scale
                        + frame.act(radial * Float(index - 1) * 0.35) * scale
                        + SIMD3<Float>(0, burstAge * scale * 0.7, 0)
                    size = (0.65 + (1 - exp(-burstAge * 10)) * 1.15) * variation * scale
                    opacity = t >= delay ? max(0, min(1, (1.3 - burstAge) * 3)) * 0.95 : 0
                    if let material = sprite.geometry?.firstMaterial {
                        HoudiniFlipbook.burst.setAge(Double(burstAge), material: material)
                    }
                } else if index < 12 {
                    let variation = 0.8 + abs(sin(seed * 1.71)) * 0.4
                    let curl = SIMD3<Float>(sin(seed + t * 1.2), 0, cos(seed * 1.3 + t * 0.9))
                    position = outward * 0.65 * scale
                        + frame.act(radial * (0.2 + expansion * 0.9 + t * 0.35) * variation) * scale
                        + curl * t * 0.22 * scale + SIMD3<Float>(0, t * (1.25 + variation * 0.25) * scale, 0)
                        + finiteWind * t * 0.35
                    size = (0.5 + expansion * 0.55 + t * 0.35) * variation * scale
                    opacity = min(1, t * 4) * tail * 0.50
                    if let material = sprite.geometry?.firstMaterial {
                        HoudiniFlipbook.smoke.setAge(Double(t) * 0.35 + Double(index) * 0.29, material: material)
                        HoudiniFlipbook.setTint(SIMD3(repeating: 0.13 + min(1, t / 4) * 0.14), material: material)
                    }
                } else {
                    let direction = frame.act(radial + SIMD3<Float>(0, 0.35 + abs(sin(seed)) * 0.65, 0))
                    position = outward * 0.45 * scale + direction * t * (4 + abs(sin(seed)) * 5) * scale
                        - SIMD3<Float>(0, 4.9 * t * t, 0)
                    size = (0.025 + Float(index % 3) * 0.015) * scale
                    opacity = max(0, 1 - t / 1.1)
                }
            case .contact, .secondary:
                let burst: Float = kind == .secondary ? 1.8 : 1
                position = frame.act(radial + SIMD3<Float>(0, 0.5, 0)) * t * 5 * burst
                    - SIMD3<Float>(0, 4.9 * t * t, 0)
                opacity = max(0, 1 - t / 0.8)
                size = 0.025 * burst
                if index == 0 { position = .zero; size = 0.35 + t; opacity = exp(-t * 15) }
            }
            sprite.simdPosition = position
            let aspect: Float = kind == .explosion && index > 0 && index < 12
                ? 0.85 + abs(sin(seed * 3.7)) * 0.3 : 1
            sprite.simdScale = SIMD3<Float>(max(0.001, size * aspect), max(0.001, size), max(0.001, size))
            sprite.opacity = CGFloat(max(0, min(1, opacity)))
            sprite.isHidden = opacity < 0.002
        }
    }

    /// A textured, irregular soot/ash mark follows the sampled road. Missing road triangles
    /// are omitted; a decal must not bridge a hole or float over imported terrain.
    static func makeScorch(centre: SIMD3<Float>, yaw: Float, ground: (SIMD3<Float>, Float) -> Float) -> SCNNode? {
        let steps = 8
        var vertices: [SCNVector3] = [], uv: [CGPoint] = [], valid: [Bool] = []
        let rotation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        for z in 0...steps {
            for x in 0...steps {
                let u = Float(x) / Float(steps), v = Float(z) / Float(steps)
                let offset = rotation.act(SIMD3<Float>((u - 0.5) * 8, 0, (v - 0.5) * 6))
                let point = centre + offset
                let y = ground(point + SIMD3<Float>(0, 2, 0), 0.1)
                valid.append(y.isFinite && abs(y - centre.y) < 2)
                vertices.append(SCNVector3(offset.x, y.isFinite ? y - centre.y + 0.018 : 0, offset.z))
                uv.append(CGPoint(x: CGFloat(u), y: CGFloat(v)))
            }
        }
        var indices: [UInt32] = []
        for z in 0..<steps {
            for x in 0..<steps {
                let a = z * (steps + 1) + x, b = a + 1, c = a + steps + 1, d = c + 1
                for triangle in [[a, c, b], [b, c, d]] where triangle.allSatisfy({ valid[$0] }) {
                    indices += triangle.map(UInt32.init)
                }
            }
        }
        guard !indices.isEmpty else { return nil }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(textureCoordinates: uv)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        let material = SCNMaterial()
        material.lightingModel = .constant; material.diffuse.contents = scorchSprite
        material.blendMode = .alpha; material.isDoubleSided = true
        material.writesToDepthBuffer = false; material.readsFromDepthBuffer = true
        geometry.firstMaterial = material
        let node = SCNNode(geometry: geometry)
        node.name = "vehicle.scorched-ground"; node.castsShadow = false
        node.simdPosition = centre
        return node
    }

    private static let glowSprite = texture(size: 64, cloud: false, scorch: false)
    private static let scorchSprite = texture(size: 128, cloud: true, scorch: true)

    private static func texture(size: Int, cloud: Bool, scorch: Bool) -> CGImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied,
            bytesPerRow: size * 4, bitsPerPixel: 32)!
        let data = bitmap.bitmapData!
        for y in 0..<size {
            for x in 0..<size {
                let px = Float(x) / Float(size - 1) * 2 - 1, py = Float(y) / Float(size - 1) * 2 - 1
                let noise = 0.44 + smoothNoise(px * 4, py * 4) * 0.30
                    + smoothNoise(px * 9 + 17, py * 9 - 11) * 0.18
                    + smoothNoise(px * 21 - 9, py * 21 + 31) * 0.08
                let radius = sqrt(px * px + py * py) / (cloud ? 0.63 + noise * 0.42 : 1)
                let edge = max(0, 1 - radius)
                let alpha = cloud ? min(1, edge * 5) * (0.45 + noise * 0.55) : edge * edge
                let colour: Float = scorch ? 0.035 + noise * 0.065 : 1
                let i = y * bitmap.bytesPerRow + x * 4
                data[i] = UInt8(colour * 255)
                data[i + 1] = UInt8((colour * 0.92) * 255)
                data[i + 2] = UInt8((colour * 0.82) * 255)
                data[i + 3] = UInt8(max(0, min(1, alpha)) * 255)
            }
        }
        // Direct pixel backing prevents lazy NSImage drawing or texture interpretation from
        // delaying the first damage frame in SceneKit, and is shared by live and replay scenes.
        return bitmap.cgImage!
    }

    /// Seeded value noise with smooth interpolation avoids visible sine-wave stripes in plumes.
    private static func smoothNoise(_ x: Float, _ y: Float) -> Float {
        let ix = Int(floor(x)), iy = Int(floor(y))
        let fx = x - Float(ix), fy = y - Float(iy)
        let u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy)
        func sample(_ x: Int, _ y: Int) -> Float {
            var value = UInt32(truncatingIfNeeded: x) &* 374_761_393
                &+ UInt32(truncatingIfNeeded: y) &* 668_265_263 &+ 2_147_483_647
            value = (value ^ (value >> 13)) &* 1_274_126_177
            return Float(value & 0x00ff_ffff) / Float(0x00ff_ffff)
        }
        let a = sample(ix, iy), b = sample(ix + 1, iy), c = sample(ix, iy + 1), d = sample(ix + 1, iy + 1)
        return (a + (b - a) * u) * (1 - v) + (c + (d - c) * u) * v
    }
}
