import AppKit
import QuartzCore
import SceneKit
import simd

/// Scene adapter for the interception mission: builds the two world actors' models, keeps them in
/// step with the simulation, and renders the world-space effects the session has published.
///
/// Adapter only. Actors, effects and their lifetimes are owned by `InterceptMissionSession`; this
/// class never decides that something happened, only that something should now be visible.
final class InterceptMissionScene {
    private let root = SCNNode()
    private var visuals: [String: DroneVisualModel] = [:]
    private var cameras: [String: SCNNode] = [:]
    private var effectNodes: [UUID: EffectInstance] = [:]
    private var detachedVisuals: Set<String> = []
    private var debris: [Debris] = []

    /// A part that came off an airframe. It keeps flying on its own from where it separated,
    /// because a lost subtree is world debris — not a child that follows its former parent.
    private struct Debris {
        let node: SCNNode
        let origin: SIMD3<Float>
        let velocity: SIMD3<Float>
        let bornAt: TimeInterval
    }

    /// One world effect in the scene: its node and the emitters whose birth rate is ramped down
    /// as it ages.
    ///
    /// Deliberately no `SCNLight`. Adding and removing omni lights per contact changes the scene's
    /// light count under the renderer, and SceneKit switches to its indexed lighting path for the
    /// affected draws — a restart mid-effect then hit
    /// `missing Buffer binding at index 5 for u_lightIndicesBuffer[0]` and aborted the process.
    /// The glow is carried by additive emitters instead, which cost nothing in the light budget.
    private struct EffectInstance {
        let node: SCNNode
        let emitters: [(system: SCNParticleSystem, baseBirthRate: CGFloat)]
    }

    // MARK: Tuning

    private static let debrisLifetime: Float = 8
    private static let gravity: Float = 9.81
    private static let cameraFieldOfView: CGFloat = 70
    /// The observer watches from a distance, so it looks through a longer lens than a pilot does.
    private static let observerFieldOfView: CGFloat = 46
    /// How far the observation ball hangs below the airframe, on top of half its own height.
    private static let observerGimbalDrop: Float = 0.45
    private static let cameraNear = 0.02
    private static let cameraFar = 4000.0
    /// How quickly the observer's gimbal swings onto the target, in radians per second. Snapping
    /// straight to `look(at:)` every frame reads as a jump cut whenever the target moves fast.
    private static let observerTrackingRate: Float = 1.8
    /// Fraction of an effect's life during which it emits at full rate. After that emission
    /// ramps down so the plume thins out instead of being cut off.
    private static let emissionHoldFraction: Float = 0.55

    /// `showsCallsigns` is off on the hardest difficulty: a floating label over every aircraft is
    /// a targeting aid, and the point of the hard setting is that the operator finds and tracks
    /// the target by looking at it.
    private let showsCallsigns: Bool

    init(scene: SCNScene, showsCallsigns: Bool) {
        self.showsCallsigns = showsCallsigns
        root.name = "intercept-mission-world"
        scene.rootNode.addChildNode(root)
    }

    // MARK: - Construction

    /// Builds one actor's model, camera and call-sign marker, and returns the simulation runtime
    /// that will drive it. The visual is built first because the component graph — and therefore
    /// the contact spheres and the mass properties — is measured from the actual geometry.
    func makeActor(
        id: String,
        role: InterceptVehicleRole,
        profile: DroneModelProfile,
        position: SIMD3<Float>,
        payload: AttachedPayloadComponent?,
        seed: UInt64,
        initialCourse: SIMD3<Float> = SIMD3<Float>(0, 0, -1)
    ) -> InterceptVehicleRuntime {
        let visual = DroneModelBuilder.build(profile: profile)
        root.addChildNode(visual.rootNode)
        visual.rootNode.simdPosition = position
        if payload != nil { attachPayloadModule(to: visual) }

        let mass = VehicleMassModel.resolve(
            for: profile,
            uavProfile: profile.resolvedUAVProfile,
            payloadMass: payload == nil ? 0 : PayloadType.sensorModule.defaultMass
        )
        let built = VehicleComponentGraphBuilder.build(
            profile: profile,
            vehicleMassModel: mass,
            geometry: DroneVisualGeometrySample.capture(from: visual)
        )
        visuals[id] = visual
        cameras[id] = makeCamera(id: id, role: role, on: visual)
        if showsCallsigns {
            visual.rootNode.addChildNode(makeCallsignMarker(id: id, role: role, visual: visual))
        }

        return InterceptVehicleRuntime(
            id: id,
            role: role,
            profile: profile,
            massModel: mass,
            position: position,
            graph: built.graph,
            contacts: built.contactProfile,
            rotors: built.rotorModel,
            payload: payload,
            seed: seed,
            initialCourse: initialCourse
        )
    }

    func camera(for vehicleID: String) -> SCNNode? { cameras[vehicleID] }

    private func attachPayloadModule(to visual: DroneVisualModel) {
        let module = SCNNode(geometry: SCNBox(width: 0.18, height: 0.12, length: 0.24, chamferRadius: 0.02))
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedWhite: 0.22, alpha: 1)
        material.metalness.contents = 0.6
        material.roughness.contents = 0.45
        module.geometry?.firstMaterial = material
        module.name = "attached-payload-module"
        visual.payloadMountNode.addChildNode(module)
    }

    private func makeCamera(id: String, role: InterceptVehicleRole, on visual: DroneVisualModel) -> SCNNode {
        let camera = SCNNode()
        camera.name = "\(id)-camera"
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = role == .observer ? Self.observerFieldOfView : Self.cameraFieldOfView
        camera.camera?.zNear = Self.cameraNear
        camera.camera?.zFar = Self.cameraFar
        if role == .observer {
            // An observation ball hangs under the belly and looks out from below the airframe.
            // On the nose anchor — where a racing camera lives — the aircraft's own booms and
            // propellers filled half the picture, which is what made the observer feed look
            // broken rather than distant.
            let boom = SCNNode()
            boom.name = "\(id)-gimbal"
            boom.simdPosition = SIMD3<Float>(
                0,
                -(visual.visualBoundsSize.y * 0.5 + Self.observerGimbalDrop),
                0
            )
            boom.addChildNode(camera)
            visual.rootNode.addChildNode(boom)
        } else {
            visual.cameraAnchorNode.addChildNode(camera)
        }
        return camera
    }

    /// The floating call sign. Same identifiers the HUD and the mission log use, so what the
    /// operator reads on screen is what the log will say afterwards.
    private func makeCallsignMarker(id: String, role: InterceptVehicleRole, visual: DroneVisualModel) -> SCNNode {
        let label = SCNText(string: id, extrusionDepth: 0)
        label.font = .monospacedSystemFont(ofSize: 0.7, weight: .bold)
        label.firstMaterial?.diffuse.contents = role == .target ? NSColor.systemOrange : NSColor.systemCyan
        label.firstMaterial?.lightingModel = .constant
        let marker = SCNNode(geometry: label)
        marker.name = "\(id)-callsign"
        marker.position = SCNVector3(0, max(0.6, visual.visualBoundsSize.y + 0.4), 0)
        marker.constraints = [SCNBillboardConstraint()]
        return marker
    }

    // MARK: - Per-frame update

    func update(_ session: InterceptMissionSession, deltaTime: Float) {
        let now = session.worldTime
        for actor in session.actors {
            guard let visual = visuals[actor.id] else { continue }
            visual.rootNode.simdPosition = actor.state.position
            visual.rootNode.simdOrientation = actor.state.attitudeQuat
            spinPropellers(of: visual, throttle: actor.state.motorThrottle, deltaTime: deltaTime)
            shedDetachedParts(of: actor, visual: visual, now: now)
            if actor.role == .observer {
                trackTarget(from: actor.id, to: session.target.state.position, deltaTime: deltaTime)
            }
        }
        updateDebris(now: now)
        updateEffects(session.effects.effects, now: now)
    }

    private func spinPropellers(of visual: DroneVisualModel, throttle: Float, deltaTime: Float) {
        for (index, propeller) in visual.propellerNodes.enumerated() {
            let direction = index < visual.propellerSpinDirections.count ? visual.propellerSpinDirections[index] : 1
            propeller.eulerAngles.y += CGFloat(deltaTime * throttle * direction * 100)
        }
    }

    /// Clones every node belonging to a component that has come off and hands the clone to the
    /// debris list. The original is hidden rather than removed so the component graph and the
    /// visual model stay in the same shape.
    private func shedDetachedParts(of actor: InterceptVehicleRuntime, visual: DroneVisualModel, now: TimeInterval) {
        for component in actor.graph.components where !component.isAttached {
            guard let legacy = component.legacyComponent,
                  detachedVisuals.insert("\(actor.id)/\(legacy.rawValue)").inserted else { continue }
            for node in visual.componentNodes[legacy] ?? [] {
                let copy = node.clone()
                copy.simdTransform = node.simdWorldTransform
                root.addChildNode(copy)
                node.isHidden = true
                debris.append(Debris(node: copy, origin: copy.simdPosition, velocity: actor.state.velocity, bornAt: now))
            }
        }
    }

    /// Slews the observer's camera onto the target instead of snapping to it. The observer is a
    /// real aircraft watching the area, and its picture should look like one.
    private func trackTarget(from vehicleID: String, to targetPosition: SIMD3<Float>, deltaTime: Float) {
        guard let camera = cameras[vehicleID] else { return }
        let offset = targetPosition - camera.simdWorldPosition
        guard simd_length_squared(offset) > 1e-6 else { return }
        let desired = Self.lookRotation(forward: simd_normalize(offset))
        let step = min(1, Self.observerTrackingRate * deltaTime)
        let world = simd_slerp(camera.simdWorldOrientation, desired, step)
        // The camera hangs off the airframe's anchor, so the world-space aim has to come back
        // into the parent's frame before it is applied.
        let parentOrientation = camera.parent?.simdWorldOrientation ?? simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
        camera.simdOrientation = parentOrientation.inverse * world
    }

    /// A camera orientation whose −Z looks along `forward`, built from an explicit basis rather
    /// than a shortest-arc rotation: the shortest arc is undefined when the target ends up
    /// directly behind the camera, which is exactly where a target that has just been rammed
    /// tends to be.
    private static func lookRotation(forward: SIMD3<Float>) -> simd_quatf {
        let zAxis = -forward
        // Straight up or straight down leaves no horizon to level against; roll around the
        // world's forward axis instead of dividing by a zero-length cross product.
        let up = abs(simd_dot(forward, SIMD3<Float>(0, 1, 0))) > 0.999
            ? SIMD3<Float>(0, 0, -1)
            : SIMD3<Float>(0, 1, 0)
        let xAxis = simd_normalize(simd_cross(up, zAxis))
        let yAxis = simd_cross(zAxis, xAxis)
        return simd_quatf(simd_float3x3(columns: (xAxis, yAxis, zAxis)))
    }

    private func updateDebris(now: TimeInterval) {
        for item in debris {
            let age = Float(now - item.bornAt)
            item.node.simdPosition = item.origin
                + item.velocity * age
                + SIMD3<Float>(0, -0.5 * Self.gravity * age * age, 0)
            item.node.opacity = CGFloat(max(0, min(1, Self.debrisLifetime - age)))
            if age >= Self.debrisLifetime { item.node.removeFromParentNode() }
        }
        debris.removeAll { Float(now - $0.bornAt) >= Self.debrisLifetime }
    }

    /// Mirrors the session's effect list into the scene. Anything the session has retired is torn
    /// down here in the same pass, so nothing survives its own lifetime.
    ///
    /// Emission is ramped down over the tail of each effect rather than the node being cut: a
    /// plume that stops dead reads as a bug, and tearing the emitters off a live node is what
    /// stalls the render thread.
    private func updateEffects(_ effects: [InterceptWorldEffect], now: TimeInterval) {
        let live = Set(effects.map(\.id))
        for id in effectNodes.keys where !live.contains(id) {
            effectNodes.removeValue(forKey: id)?.node.removeFromParentNode()
        }
        for effect in effects {
            let instance: EffectInstance
            if let existing = effectNodes[effect.id] {
                instance = existing
            } else {
                instance = makeEffect(effect)
                instance.node.simdPosition = effect.position
                root.addChildNode(instance.node)
                effectNodes[effect.id] = instance
            }
            let fraction = max(0, min(1, Float(now - effect.startedAt) / Float(effect.lifetime)))
            let emission = fraction < Self.emissionHoldFraction
                ? 1
                : max(0, 1 - (fraction - Self.emissionHoldFraction) / (1 - Self.emissionHoldFraction))
            for emitter in instance.emitters {
                emitter.system.birthRate = emitter.baseBirthRate * CGFloat(emission)
            }
        }
    }

    // MARK: - Teardown

    /// A restart leaves nothing behind: no actor models, no cameras, no debris and no emitters.
    func clear() {
        // One transaction, so the renderer never sees a half-dismantled world: emitters stop, the
        // actors' cameras go, and the whole subtree detaches between two frames rather than
        // during one. A restart used to tear this down piecemeal while a frame was in flight.
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        for instance in effectNodes.values {
            for emitter in instance.emitters { emitter.system.birthRate = 0 }
        }
        root.childNodes.forEach { $0.removeFromParentNode() }
        root.removeFromParentNode()
        SCNTransaction.commit()

        effectNodes.removeAll()
        visuals.removeAll()
        cameras.removeAll()
        debris.removeAll()
        detachedVisuals.removeAll()
    }

    // MARK: - Effect construction

    private func makeEffect(_ effect: InterceptWorldEffect) -> EffectInstance {
        let container = SCNNode()
        container.name = "effect-\(effect.id)"
        var emitters: [(system: SCNParticleSystem, baseBirthRate: CGFloat)] = []

        func attach(_ system: SCNParticleSystem, direction: SCNVector3? = nil) {
            let node = SCNNode()
            if let direction { node.simdOrientation = Self.lookRotation(forward: SIMD3<Float>(direction)) }
            node.addParticleSystem(system)
            container.addChildNode(node)
            emitters.append((system, system.birthRate))
        }

        // The contact normal points from the struck body back towards the striker, which is the
        // direction sparks and debris actually leave a strike in.
        let outward = simd_length_squared(effect.normal) > 1e-6
            ? simd_normalize(effect.normal)
            : SIMD3<Float>(0, 1, 0)

        switch effect.kind {
        case .contact:
            attach(Self.makeSparkBurst(scale: 1))
            attach(Self.makeDustPuff())
            attach(Self.makeFlash(radius: 0.5))
        case .smoke:
            attach(Self.makeSmokePlume())
        case .fire:
            attach(Self.makeFlame())
            attach(Self.makeEmberSpray())
        case .secondary:
            // The one moment in the mission that is allowed to be loud: a hot core, debris thrown
            // along the contact normal, and a light bright enough to be seen from the observer.
            attach(Self.makeSparkBurst(scale: 2.4))
            attach(Self.makeDebrisBurst(), direction: SCNVector3(outward))
            attach(Self.makeFireball())
            attach(Self.makeFlash(radius: 1.4))
        }

        return EffectInstance(node: container, emitters: emitters)
    }

    // MARK: - Particle systems

    /// White-hot metal thrown off a strike. Short-lived, additive, and gravity-bound so it arcs
    /// instead of drifting.
    private static func makeSparkBurst(scale: CGFloat) -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.particleImage = softSprite
        system.particleColor = NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.55, alpha: 1)
        system.particleColorVariation = SCNVector4(0.05, 0.35, 0.30, 0)
        system.particleSize = 0.05 * scale
        system.particleSizeVariation = 0.03 * scale
        system.birthRate = 900 * scale
        system.emissionDuration = 0.06
        system.loops = false
        system.particleLifeSpan = 0.5
        system.particleLifeSpanVariation = 0.35
        system.emitterShape = SCNSphere(radius: 0.05)
        system.spreadingAngle = 180
        system.particleVelocity = 9 * scale
        system.particleVelocityVariation = 5 * scale
        system.acceleration = SCNVector3(0, -9.8, 0)
        system.isAffectedByGravity = false
        system.blendMode = .additive
        system.isLightingEnabled = false
        system.propertyControllers = [.size: sizeOverLife(from: 0.06 * scale, to: 0.01 * scale)]
        return system
    }

    /// The pale, quickly-spreading puff of pulverised paint and composite that surrounds a strike.
    private static func makeDustPuff() -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.particleImage = softSprite
        system.particleColor = NSColor(calibratedWhite: 0.78, alpha: 0.5)
        system.particleSize = 0.22
        system.particleSizeVariation = 0.12
        system.birthRate = 220
        system.emissionDuration = 0.1
        system.loops = false
        system.particleLifeSpan = 0.9
        system.particleLifeSpanVariation = 0.4
        system.emitterShape = SCNSphere(radius: 0.1)
        system.spreadingAngle = 180
        system.particleVelocity = 2.2
        system.particleVelocityVariation = 1.2
        system.acceleration = SCNVector3(0, 0.4, 0)
        system.isAffectedByGravity = false
        system.blendMode = .alpha
        system.isLightingEnabled = false
        system.propertyControllers = [
            .size: sizeOverLife(from: 0.10, to: 0.85),
            .opacity: opacityOverLife(from: 0.55, to: 0)
        ]
        system.particleAngularVelocity = 40
        system.particleAngularVelocityVariation = 30
        return system
    }

    /// A rising column that keeps drifting and thinning for as long as the effect lives. Visible
    /// from the observer's camera, which is the whole point of putting it in world space.
    private static func makeSmokePlume() -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.particleImage = softSprite
        system.particleColor = NSColor(calibratedWhite: 0.18, alpha: 0.42)
        system.particleColorVariation = SCNVector4(0, 0, 0.10, 0.10)
        system.particleSize = 0.55
        system.particleSizeVariation = 0.3
        system.birthRate = 42
        system.particleLifeSpan = 5.5
        system.particleLifeSpanVariation = 2.0
        system.emitterShape = SCNSphere(radius: 0.22)
        system.spreadingAngle = 22
        system.emittingDirection = SCNVector3(0, 1, 0)
        system.birthDirection = .constant
        system.particleVelocity = 2.6
        system.particleVelocityVariation = 1.1
        system.acceleration = SCNVector3(0.6, 1.1, 0.2)
        system.isAffectedByGravity = false
        system.blendMode = .alpha
        system.isLightingEnabled = false
        system.propertyControllers = [
            .size: sizeOverLife(from: 0.30, to: 2.60),
            .opacity: opacityOverLife(from: 0.50, to: 0)
        ]
        system.particleAngularVelocity = 18
        system.particleAngularVelocityVariation = 14
        system.loops = true
        return system
    }

    private static func makeFlame() -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.particleImage = softSprite
        system.particleColor = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.20, alpha: 0.9)
        system.particleColorVariation = SCNVector4(0.03, 0.28, 0.20, 0.10)
        system.particleSize = 0.32
        system.particleSizeVariation = 0.16
        system.birthRate = 160
        system.particleLifeSpan = 0.7
        system.particleLifeSpanVariation = 0.3
        system.emitterShape = SCNSphere(radius: 0.16)
        system.spreadingAngle = 26
        system.emittingDirection = SCNVector3(0, 1, 0)
        system.birthDirection = .constant
        system.particleVelocity = 3.4
        system.particleVelocityVariation = 1.4
        system.acceleration = SCNVector3(0, 2.6, 0)
        system.isAffectedByGravity = false
        system.blendMode = .additive
        system.isLightingEnabled = false
        system.propertyControllers = [
            .size: sizeOverLife(from: 0.42, to: 0.08),
            .opacity: opacityOverLife(from: 0.95, to: 0)
        ]
        system.loops = true
        return system
    }

    private static func makeEmberSpray() -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.particleImage = softSprite
        system.particleColor = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.30, alpha: 1)
        system.particleSize = 0.035
        system.particleSizeVariation = 0.02
        system.birthRate = 55
        system.particleLifeSpan = 1.8
        system.particleLifeSpanVariation = 0.9
        system.emitterShape = SCNSphere(radius: 0.2)
        system.spreadingAngle = 55
        system.emittingDirection = SCNVector3(0, 1, 0)
        system.birthDirection = .constant
        system.particleVelocity = 3.2
        system.particleVelocityVariation = 1.8
        system.acceleration = SCNVector3(0.8, 1.4, 0.3)
        system.isAffectedByGravity = false
        system.blendMode = .additive
        system.isLightingEnabled = false
        system.loops = true
        return system
    }

    /// The bright expanding core of a secondary effect. One short burst of large, fast-growing
    /// additive particles — no sprite sheet needed for something that lives under a second.
    private static func makeFireball() -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.particleImage = softSprite
        system.particleColor = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.34, alpha: 0.95)
        system.particleColorVariation = SCNVector4(0.02, 0.25, 0.25, 0.05)
        system.particleSize = 0.6
        system.particleSizeVariation = 0.35
        system.birthRate = 700
        system.emissionDuration = 0.12
        system.loops = false
        system.particleLifeSpan = 0.75
        system.particleLifeSpanVariation = 0.3
        system.emitterShape = SCNSphere(radius: 0.3)
        system.spreadingAngle = 180
        system.particleVelocity = 7
        system.particleVelocityVariation = 3.5
        system.acceleration = SCNVector3(0, 3.2, 0)
        system.isAffectedByGravity = false
        system.blendMode = .additive
        system.isLightingEnabled = false
        system.propertyControllers = [
            .size: sizeOverLife(from: 0.25, to: 2.40),
            .opacity: opacityOverLife(from: 1.0, to: 0)
        ]
        return system
    }

    /// Fragments thrown along the contact normal, dark and gravity-affected so they read as
    /// pieces of airframe rather than as more of the flash. Unlit like every other emitter here:
    /// a lit particle system is the other half of the light-indices crash described above.
    private static func makeDebrisBurst() -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.particleColor = NSColor(calibratedWhite: 0.32, alpha: 1)
        system.particleColorVariation = SCNVector4(0, 0, 0.18, 0)
        system.particleSize = 0.08
        system.particleSizeVariation = 0.05
        system.birthRate = 260
        system.emissionDuration = 0.08
        system.loops = false
        system.particleLifeSpan = 2.4
        system.particleLifeSpanVariation = 1.0
        system.emitterShape = SCNSphere(radius: 0.15)
        system.spreadingAngle = 62
        system.emittingDirection = SCNVector3(0, 0, -1)
        system.birthDirection = .constant
        system.particleVelocity = 14
        system.particleVelocityVariation = 7
        system.acceleration = SCNVector3(0, -9.8, 0)
        system.isAffectedByGravity = false
        system.blendMode = .alpha
        system.isLightingEnabled = false
        system.particleAngularVelocity = 220
        system.particleAngularVelocityVariation = 160
        return system
    }

    /// Size and opacity over a particle's own lifetime. `SCNParticleSystem` has no scalar
    /// "grow as you go" knob, so the curve is expressed as a property controller — which is also
    /// what lets smoke fade out instead of vanishing at full opacity.
    private static func sizeOverLife(from: CGFloat, to: CGFloat) -> SCNParticlePropertyController {
        SCNParticlePropertyController(animation: lifeAnimation(from: from, to: to))
    }

    private static func opacityOverLife(from: CGFloat, to: CGFloat) -> SCNParticlePropertyController {
        SCNParticlePropertyController(animation: lifeAnimation(from: from, to: to))
    }

    private static func lifeAnimation(from: CGFloat, to: CGFloat) -> CABasicAnimation {
        let animation = CABasicAnimation()
        animation.fromValue = from
        animation.toValue = to
        return animation
    }

    /// The bloom that stands in for a dynamic light: a single large additive puff that blows up
    /// and dies in a fifth of a second. Reads as a flash from any camera without touching the
    /// scene's light set.
    private static func makeFlash(radius: CGFloat) -> SCNParticleSystem {
        let system = SCNParticleSystem()
        system.particleImage = softSprite
        system.particleColor = NSColor(calibratedRed: 1.0, green: 0.93, blue: 0.78, alpha: 1)
        system.particleSize = radius
        system.birthRate = 60
        system.emissionDuration = 0.04
        system.loops = false
        system.particleLifeSpan = 0.22
        system.particleLifeSpanVariation = 0.06
        system.emitterShape = SCNSphere(radius: radius * 0.2)
        system.spreadingAngle = 180
        system.particleVelocity = 1.5
        system.particleVelocityVariation = 1
        system.isAffectedByGravity = false
        system.blendMode = .additive
        system.isLightingEnabled = false
        system.propertyControllers = [
            .size: sizeOverLife(from: radius * 0.6, to: radius * 3.2),
            .opacity: opacityOverLife(from: 1.0, to: 0)
        ]
        return system
    }

    /// A soft round sprite, built once. Without it every particle is a hard-edged square, which
    /// is what made the old effects read as boxes of grey rather than as smoke.
    private static let softSprite: NSImage = {
        let size = 64
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        if let context = NSGraphicsContext.current?.cgContext {
            let colors = [
                NSColor(calibratedWhite: 1, alpha: 1).cgColor,
                NSColor(calibratedWhite: 1, alpha: 0.55).cgColor,
                NSColor(calibratedWhite: 1, alpha: 0).cgColor
            ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 0.45, 1]
            ) {
                let centre = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
                context.drawRadialGradient(
                    gradient,
                    startCenter: centre,
                    startRadius: 0,
                    endCenter: centre,
                    endRadius: CGFloat(size) / 2,
                    options: []
                )
            }
        }
        image.unlockFocus()
        return image
    }()
}
