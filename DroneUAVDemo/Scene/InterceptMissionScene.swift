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
    private var groundVisuals: [String: GroundVehicleVisual] = [:]
    private var cameras: [String: SCNNode] = [:]
    private var effectNodes: [UUID: WorldDamageEffectVisual] = [:]
    private var scorchNodes: [String: (node: SCNNode, bornAt: TimeInterval)] = [:]
    private var detachedVisuals: Set<String> = []
    private var debris: [Debris] = []
    /// Wreckage in the air, integrated with real drag, wind and ground contact.
    private let debrisRuntime = BallisticProjectileRuntime()
    /// Nodes for the pieces the runtime is flying, keyed by projectile id.
    private var debrisNodes: [UUID: DebrisNode] = [:]

    private struct DebrisNode {
        let node: SCNNode
        let bornAt: TimeInterval
        let spawnOrientation: simd_quatf
        /// Set once the piece has come to rest, so it fades from where it actually stopped.
        var settledAt: TimeInterval?
        var lifetime: Float = 8
    }
    /// The drop zone on the ground and the load itself, on the delivery side of the mission.
    private var deliveryZoneNode: SCNNode?
    private var deliveryLoadNode: SCNNode?

    /// A part that came off an airframe. It keeps flying on its own from where it separated,
    /// because a lost subtree is world debris — not a child that follows its former parent.
    private struct Debris {
        let node: SCNNode
        let origin: SIMD3<Float>
        let velocity: SIMD3<Float>
        let bornAt: TimeInterval
        /// Axis and rate it tumbles about. A piece that comes off an airframe at speed does not
        /// hold its attitude, and a fragment translating without rotating reads as a dropped prop.
        let spinAxis: SIMD3<Float>
        let spinRate: Float
        let spawnOrientation: simd_quatf
    }

    private var debrisSurfaceProbeStorage: ClosureBallisticSurfaceProbe?
    /// Ground for wreckage. Falls back to sea level only if the scene never handed one over, which
    /// is exactly what the old parabola assumed anyway.
    private var debrisSurfaceProbe: BallisticSurfaceProbe {
        debrisSurfaceProbeStorage ?? Self.flatDebrisGround
    }
    private static let flatDebrisGround = FlatGroundBallisticSurfaceProbe()

    // MARK: Tuning

    private static let debrisLifetime: Float = 8
    /// How hard a piece is thrown clear of the airframe it came off, metres per second.
    private static let debrisBurstSpeed: Float = 5.5
    /// Tumble rate of a shed piece, radians per second.
    private static let debrisSpinRate: Float = 7
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
    /// How far the zone disc floats above the ground sample, so it does not z-fight with terrain.
    private static let zoneGroundClearance: Float = 0.25
    /// A marker the operator can pick out from altitude while being chased.
    private static let zoneMastHeight: Float = 26

    /// `showsCallsigns` is off on the hardest difficulty: a floating label over every aircraft is
    /// a targeting aid, and the point of the hard setting is that the operator finds and tracks
    /// the target by looking at it.
    private let showsCallsigns: Bool

    init(scene: SCNScene, showsCallsigns: Bool) {
        self.showsCallsigns = showsCallsigns
        root.name = "intercept-mission-world"
        root.addChildNode(WorldDamageEffectVisual.makePreparationNode())
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
        moduleShape: AttachedModuleShape,
        seed: UInt64,
        initialCourse: SIMD3<Float> = SIMD3<Float>(0, 0, -1)
    ) -> InterceptVehicleRuntime {
        let visual = DroneModelBuilder.build(profile: profile)
        root.addChildNode(visual.rootNode)
        visual.rootNode.simdPosition = position
        if payload != nil {
            visual.payloadMountNode.addChildNode(Self.makeModuleNode(shape: moduleShape))
        }

        let mass = VehicleMassModel.resolve(
            for: profile,
            uavProfile: profile.resolvedUAVProfile,
            payloadMass: payload == nil ? 0 : moduleShape.massKg
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

    func makeGroundActor(id: String, model: GroundVehicleModel, position: SIMD3<Float>,
                         adapterProfile: DroneModelProfile, seed: UInt64) -> InterceptVehicleRuntime {
        let road = GroundVehicleRuntime(position: position, model: model, seed: seed, vehicleID: id)
        let visual = GroundVehicleVisual(model: model)
        visual.rootNode.name = id
        visual.rootNode.simdPosition = position
        root.addChildNode(visual.rootNode); groundVisuals[id] = visual
        let camera = SCNNode()
        camera.name = "\(id)-camera"; camera.camera = SCNCamera()
        camera.camera?.fieldOfView = Self.cameraFieldOfView
        camera.camera?.zNear = Self.cameraNear; camera.camera?.zFar = Self.cameraFar
        camera.simdPosition = SIMD3<Float>(0, 3.5, -3.85)
        visual.rootNode.addChildNode(camera); cameras[id] = camera
        if showsCallsigns {
            let label = SCNText(string: id, extrusionDepth: 0)
            label.font = .monospacedSystemFont(ofSize: 0.7, weight: .bold)
            label.firstMaterial?.diffuse.contents = NSColor.systemOrange
            label.firstMaterial?.lightingModel = .constant
            let marker = SCNNode(geometry: label)
            marker.position = SCNVector3(0, 4, 0); marker.constraints = [SCNBillboardConstraint()]
            visual.rootNode.addChildNode(marker)
        }
        let mass = VehicleMassModel(baseMass: road.profile.massKg, batteryMass: 0, payloadMass: 0,
            currentTotalMass: road.profile.massKg, effectiveMass: road.profile.massKg,
            payloadLoadRatio: 0, massSourceQuality: .estimated, usesEstimatedValues: true)
        return InterceptVehicleRuntime(id: id, role: .target, profile: adapterProfile, massModel: mass,
            position: position, graph: road.componentGraph(), contacts: road.contactProfile, rotors: .empty,
            payload: nil, seed: seed, groundVehicle: road)
    }

    // MARK: - Delivery zone

    /// Marks the place the load has to reach. A flat disc with a rim, laid on the ground and not
    /// lit, so it reads the same from the operator's camera at 200 m and from the observer's at
    /// 600 m, at any hour of the world's clock.
    func setDeliveryZone(centre: SIMD3<Float>, radius: Float, shape: AttachedModuleShape) {
        deliveryZoneNode?.removeFromParentNode()
        let zone = SCNNode()
        zone.name = "delivery-zone"
        zone.simdPosition = centre + SIMD3<Float>(0, Self.zoneGroundClearance, 0)

        let floor = SCNNode(geometry: SCNCylinder(radius: CGFloat(radius), height: 0.05))
        let fill = SCNMaterial()
        fill.diffuse.contents = NSColor(calibratedRed: 0.30, green: 0.78, blue: 0.55, alpha: 0.16)
        fill.lightingModel = .constant
        fill.isDoubleSided = true
        fill.writesToDepthBuffer = false
        floor.geometry?.firstMaterial = fill
        zone.addChildNode(floor)

        let rim = SCNNode(geometry: SCNTube(
            innerRadius: CGFloat(radius * 0.94),
            outerRadius: CGFloat(radius),
            height: 0.4
        ))
        let edge = SCNMaterial()
        edge.diffuse.contents = NSColor(calibratedRed: 0.35, green: 0.92, blue: 0.62, alpha: 0.75)
        edge.lightingModel = .constant
        edge.isDoubleSided = true
        rim.geometry?.firstMaterial = edge
        zone.addChildNode(rim)

        // A marker tall enough to find from the air. The zone is a patch of ground in a forest and
        // an operator being chased has no time to hunt for a faint ring.
        let mast = SCNNode(geometry: SCNCylinder(radius: 0.5, height: CGFloat(Self.zoneMastHeight)))
        mast.geometry?.firstMaterial = edge
        mast.simdPosition = SIMD3<Float>(0, Self.zoneMastHeight * 0.5, 0)
        zone.addChildNode(mast)

        root.addChildNode(zone)
        deliveryZoneNode = zone

        deliveryLoadNode?.removeFromParentNode()
        let load = Self.makeModuleNode(shape: shape)
        load.name = "delivery-load"
        load.isHidden = true
        root.addChildNode(load)
        deliveryLoadNode = load
    }

    /// Draws the load where the session says it is. Hidden while it is still on the aircraft — the
    /// aircraft is already carrying a visible one.
    func updateDelivery(_ delivery: InterceptDeliveryRuntime?) {
        guard let node = deliveryLoadNode else { return }
        guard let delivery, delivery.state != .carried, delivery.state != .destroyed else {
            node.isHidden = true
            return
        }
        node.isHidden = false
        node.simdPosition = delivery.position
        if delivery.state == .falling, simd_length_squared(delivery.velocity) > 1e-4 {
            // Nose-down along its own flight path, the way a dropped object settles.
            node.simdOrientation = Self.lookRotation(forward: simd_normalize(delivery.velocity))
        }
    }

    /// The module as an object in the world. Built here rather than in the payload catalogue
    /// because this is mission equipment: it exists for the length of one run, and what the
    /// operator chose about it is a shape and a mass, not a sensor.
    static func makeModuleNode(shape: AttachedModuleShape) -> SCNNode {
        let size = shape.sizeMeters
        let node = SCNNode()
        node.name = moduleNodeName

        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedWhite: 0.22, alpha: 1)
        material.metalness.contents = 0.6
        material.roughness.contents = 0.45

        switch shape {
        case .charge:
            node.geometry = SCNBox(
                width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z),
                chamferRadius: 0.02
            )
        case .ballast:
            let body = SCNCylinder(radius: CGFloat(size.x / 2), height: CGFloat(size.z))
            let cylinder = SCNNode(geometry: body)
            // A cylinder stands up its own Y; the module lies along the airframe's length.
            cylinder.eulerAngles.x = .pi / 2
            cylinder.geometry?.firstMaterial = material
            node.addChildNode(cylinder)
        case .supplyCrate, .medicalPack:
            // A strapped crate. Lighter than the ordnance so it reads as cargo at a glance, with
            // a band across it where the strap goes.
            node.geometry = SCNBox(
                width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z),
                chamferRadius: 0.02
            )
            let crate = SCNMaterial()
            crate.diffuse.contents = shape == .medicalPack
                ? NSColor(calibratedWhite: 0.86, alpha: 1)
                : NSColor(calibratedRed: 0.40, green: 0.36, blue: 0.28, alpha: 1)
            crate.roughness.contents = 0.82
            node.geometry?.firstMaterial = crate
            let strap = SCNNode(geometry: SCNBox(
                width: CGFloat(size.x * 1.02), height: CGFloat(size.y * 0.18), length: CGFloat(size.z * 1.02),
                chamferRadius: 0.01
            ))
            let strapMaterial = SCNMaterial()
            strapMaterial.diffuse.contents = shape == .medicalPack
                ? NSColor(calibratedRed: 0.78, green: 0.18, blue: 0.16, alpha: 1)
                : NSColor(calibratedWhite: 0.22, alpha: 1)
            strapMaterial.roughness.contents = 0.9
            strap.geometry?.firstMaterial = strapMaterial
            node.addChildNode(strap)
            return node
        case .sensorPod:
            // A short mast on a base — something that is meant to stand where it is put down.
            node.geometry = SCNBox(
                width: CGFloat(size.x), height: CGFloat(size.y * 0.55), length: CGFloat(size.z),
                chamferRadius: 0.02
            )
            let mast = SCNNode(geometry: SCNCylinder(
                radius: CGFloat(size.x * 0.10),
                height: CGFloat(size.y * 0.9)
            ))
            mast.geometry?.firstMaterial = material
            mast.simdPosition = SIMD3<Float>(0, size.y * 0.62, -size.z * 0.18)
            node.addChildNode(mast)
            let dome = SCNNode(geometry: SCNSphere(radius: CGFloat(size.x * 0.28)))
            let lens = SCNMaterial()
            lens.diffuse.contents = NSColor(calibratedRed: 0.14, green: 0.20, blue: 0.26, alpha: 1)
            lens.metalness.contents = 0.2
            lens.roughness.contents = 0.18
            dome.geometry?.firstMaterial = lens
            dome.simdPosition = SIMD3<Float>(0, -size.y * 0.24, size.z * 0.24)
            node.addChildNode(dome)
        case .net:
            node.geometry = SCNBox(
                width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z),
                chamferRadius: 0.03
            )
            // The folded net itself, visible as a lighter band across the pack.
            let band = SCNNode(geometry: SCNBox(
                width: CGFloat(size.x * 0.92), height: CGFloat(size.y * 0.34), length: CGFloat(size.z * 0.92),
                chamferRadius: 0.02
            ))
            let netMaterial = SCNMaterial()
            netMaterial.diffuse.contents = NSColor(calibratedWhite: 0.62, alpha: 1)
            netMaterial.roughness.contents = 0.9
            band.geometry?.firstMaterial = netMaterial
            band.simdPosition = SIMD3<Float>(0, -size.y * 0.22, 0)
            node.addChildNode(band)
        case .kineticSlug:
            let body = SCNCapsule(capRadius: CGFloat(size.x / 2), height: CGFloat(size.z))
            let capsule = SCNNode(geometry: body)
            capsule.eulerAngles.x = .pi / 2
            capsule.geometry?.firstMaterial = material
            node.addChildNode(capsule)
            // Two tail fins, so the faired body reads as faired rather than as a pill.
            for side in [-1, 1] {
                let fin = SCNNode(geometry: SCNBox(
                    width: 0.012, height: CGFloat(size.x * 0.9), length: CGFloat(size.z * 0.22),
                    chamferRadius: 0.004
                ))
                fin.geometry?.firstMaterial = material
                fin.simdPosition = SIMD3<Float>(Float(side) * size.x * 0.42, 0, size.z * 0.34)
                node.addChildNode(fin)
            }
        }
        node.geometry?.firstMaterial = material
        return node
    }

    static let moduleNodeName = "attached-payload-module"

    private func makeCamera(id: String, role: InterceptVehicleRole, on visual: DroneVisualModel) -> SCNNode {
        let camera = SCNNode()
        camera.name = "\(id)-camera"
        camera.camera = SCNCamera()
        camera.camera?.categoryBitMask = Int.max & ~ThermalRenderCategory.proxyBit
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

    var hasReplayAftermath: Bool {
        debrisNodes.values.contains { $0.settledAt == nil } || !effectNodes.isEmpty
    }

    func captureReplayVisuals(session: InterceptMissionSession, recorder: MissionReplayRecorder) -> [MissionReplayVisualSnapshot] {
        captureReplayVisuals(actors: session.actors, recorder: recorder)
    }

    func captureReplayVisuals(actors: [InterceptVehicleRuntime], recorder: MissionReplayRecorder) -> [MissionReplayVisualSnapshot] {
        var nodes: [MissionReplayVisualSnapshot] = []
        for actor in actors {
            guard let node = groundVisuals[actor.id]?.rootNode ?? visuals[actor.id]?.rootNode else { continue }
            nodes.append(MissionReplayVisualCapture.snapshot(id: actor.id, node: node, recorder: recorder,
                role: actor.role.rawValue, displayName: actor.displayName, camera: cameras[actor.id]))
        }
        for (id, entry) in debrisNodes {
            nodes.append(MissionReplayVisualCapture.snapshot(id: "intercept-debris:\(id)", node: entry.node, recorder: recorder))
        }
        for (id, entry) in scorchNodes {
            nodes.append(MissionReplayVisualCapture.snapshot(id: "vehicle-scorch:\(id)", node: entry.node, recorder: recorder))
        }
        if let load = deliveryLoadNode, !load.isHidden {
            nodes.append(MissionReplayVisualCapture.snapshot(id: "delivery-load", node: load, recorder: recorder))
        }
        return nodes.sorted { $0.id < $1.id }
    }

    func update(
        _ session: InterceptMissionSession,
        deltaTime: Float,
        ground: @escaping (SIMD3<Float>, Float) -> Float,
        wind: SIMD3<Float> = .zero
    ) {
        // A contact publishes damage, shed panels and its flash together. The render thread
        // must not see a charred body in between those mutations or interpolate the burst in.
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        defer { SCNTransaction.commit() }
        let now = session.worldTime
        if debrisSurfaceProbeStorage == nil {
            debrisSurfaceProbeStorage = ClosureBallisticSurfaceProbe(heightAt: ground)
        }
        for actor in session.actors {
            if actor.isGroundVehicle { updateGroundActor(actor, now: now, ground: ground); continue }
            guard let visual = visuals[actor.id] else { continue }
            visual.rootNode.simdPosition = actor.state.position
            visual.rootNode.simdOrientation = actor.state.attitudeQuat
            spinPropellers(of: visual, throttle: actor.state.motorThrottle, deltaTime: deltaTime)
            shedDetachedParts(of: actor, visual: visual, now: now)
            if actor.role == .observer {
                trackTarget(from: actor.id, to: session.target.state.position, deltaTime: deltaTime)
            }
        }
        updateDebris(now: now, deltaTime: deltaTime, wind: wind)
        updateEffects(session.effects.effects + session.actors.flatMap { $0.groundVehicle?.effects ?? [] }, now: now, wind: wind)
        updateDelivery(session.delivery)
    }

    func updateGroundWorld(_ actor: InterceptVehicleRuntime, now: TimeInterval, deltaTime: Float,
                           ground: @escaping (SIMD3<Float>, Float) -> Float, wind: SIMD3<Float>) {
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        defer { SCNTransaction.commit() }
        if debrisSurfaceProbeStorage == nil { debrisSurfaceProbeStorage = ClosureBallisticSurfaceProbe(heightAt: ground) }
        updateGroundActor(actor, now: now, ground: ground)
        updateDebris(now: now, deltaTime: deltaTime, wind: wind)
        updateEffects(actor.groundVehicle?.effects ?? [], now: now, wind: wind)
    }

    private func updateGroundActor(_ actor: InterceptVehicleRuntime, now: TimeInterval,
                                   ground: (SIMD3<Float>, Float) -> Float) {
        guard let road = actor.groundVehicle, let visual = groundVisuals[actor.id] else { return }
        for piece in visual.update(road) {
            root.addChildNode(piece)
            let mass = (piece.value(forKey: "userData") as? NSDictionary)?["debrisMass"] as? Double ?? 25
            let id = debrisRuntime.launch(kind: .debris, descriptor: BallisticDescriptor(massKg: Float(mass), shape: .debris),
                position: piece.simdWorldPosition, carrierVelocity: actor.state.velocity,
                separationImpulse: separationVelocity(for: piece.simdWorldPosition, actor: actor, now: now)
                    ?? SIMD3<Float>(0, 1.2, 0), surfaceProbe: debrisSurfaceProbe)
            debrisNodes[id] = DebrisNode(node: piece, bornAt: now, spawnOrientation: piece.simdOrientation,
                settledAt: nil, lifetime: .infinity)
        }
        var marks = road.damage.sites.enumerated().filter { $0.element.heat > 0.4 }
            .map { ("impact-\($0.offset)", $0.element.point) }
        if let firePoint = road.damage.firePoint,
           !marks.contains(where: { simd_distance($0.1, firePoint) < 1.5 }) {
            marks.append(("fire", firePoint))
        }
        for (name, localPoint) in marks {
            let key = "\(actor.id)/\(name)"
            if scorchNodes[key] == nil {
                let point = road.state.position + simd_act(road.state.attitudeQuat, SIMD3<Float>(localPoint.x, 0, localPoint.z))
                let height = ground(point, 0.1)
                guard height.isFinite else { continue }
                if let mark = WorldDamageEffectVisual.makeScorch(centre: SIMD3<Float>(point.x, height, point.z),
                    yaw: road.state.orientation.z, ground: ground) {
                    root.addChildNode(mark); scorchNodes[key] = (mark, now)
                }
            }
            if let entry = scorchNodes[key] {
                entry.node.opacity = CGFloat(min(0.88, 0.35 + Float(now - entry.bornAt) * 0.04))
            }
        }
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
        let hub = visual.rootNode.simdWorldPosition
        for component in actor.graph.components where !component.isAttached {
            guard let legacy = component.legacyComponent,
                  detachedVisuals.insert("\(actor.id)/\(legacy.rawValue)").inserted else { continue }
            for node in visual.componentNodes[legacy] ?? [] {
                let copy = node.clone()
                copy.simdTransform = node.simdWorldTransform
                root.addChildNode(copy)
                node.isHidden = true
                // Thrown outward from the airframe it came off, not carried along with it. Every
                // piece leaving on the same vector is a formation, not a wreck.
                let offset = copy.simdWorldPosition - hub
                let outward = simd_length_squared(offset) > 1e-6
                    ? simd_normalize(offset)
                    : SIMD3<Float>(0, 1, 0)
                // Deterministic per piece, so a replay of the same run sheds the same wreckage.
                let seed = Float(abs(legacy.rawValue.hashValue % 1000)) / 1000
                let burst = Self.debrisBurstSpeed * (0.55 + seed * 0.9)
                // Flown by the shared ballistic runtime rather than a local parabola: a shed part
                // now feels air resistance and wind, lands on the ground instead of sinking through
                // it, and skips off it once or twice before settling. Its mass is the component's
                // own — a torn-off camera pod and a whole wing do not fall the same way.
                let projectileID = debrisRuntime.launch(
                    kind: .debris,
                    descriptor: BallisticDescriptor(
                        massKg: max(0.05, component.massKg),
                        shape: .debris
                    ),
                    position: copy.simdWorldPosition,
                    carrierVelocity: actor.state.velocity,
                    separationImpulse: separationVelocity(for: copy.simdWorldPosition, actor: actor, now: now)
                        ?? (outward * burst + SIMD3<Float>(0, 1.4 + seed, 0)),
                    surfaceProbe: debrisSurfaceProbe
                )
                debrisNodes[projectileID] = DebrisNode(
                    node: copy,
                    bornAt: now,
                    spawnOrientation: copy.simdOrientation,
                    settledAt: nil
                )
            }
        }
    }

    private func separationVelocity(for point: SIMD3<Float>, actor: InterceptVehicleRuntime,
                                    now: TimeInterval) -> SIMD3<Float>? {
        guard now - actor.lastDetonationTime < 0.5, let origin = actor.lastDetonationPosition else { return nil }
        let delta = point - origin
        let outward = simd_length_squared(delta) > 0.001 ? simd_normalize(delta) : SIMD3<Float>(0, 1, 0)
        let strength = ChargeDetonation(position: origin).exposure(at: point)
        return outward * (2 + 8 * strength) + SIMD3<Float>(0, 2, 0)
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

    private func updateDebris(now: TimeInterval, deltaTime: Float, wind: SIMD3<Float>) {
        guard !debrisNodes.isEmpty else {
            return
        }

        let result = debrisRuntime.update(
            deltaTime: deltaTime,
            environment: BallisticEnvironment(atmosphere: .standard, windVector: wind),
            surfaceProbe: debrisSurfaceProbe
        )

        for projectile in debrisRuntime.projectiles {
            guard let entry = debrisNodes[projectile.id] else { continue }
            entry.node.simdWorldPosition = projectile.position
            entry.node.simdWorldOrientation = projectile.orientation * entry.spawnOrientation
        }

        // A piece that has landed stays where it landed and fades there, rather than being flown
        // on by a formula that no longer describes anything.
        for impact in result.impacts {
            guard var entry = debrisNodes[impact.projectileID] else { continue }
            entry.node.simdWorldPosition = impact.position
            if entry.lifetime.isInfinite {
                // Low-energy final contact lets a panel fall onto its broad face and a tyre
                // onto its side, rather than balancing forever on a random tumbling edge.
                let bounds = entry.node.boundingBox
                let size = SIMD3<Float>(bounds.max) - SIMD3<Float>(bounds.min)
                let thin = size.x <= size.y && size.x <= size.z ? SIMD3<Float>(1, 0, 0)
                    : size.y <= size.z ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1)
                var normal = simd_act(entry.node.simdWorldOrientation, thin)
                if simd_dot(normal, impact.normal) < 0 { normal = -normal }
                entry.node.simdWorldOrientation = simd_quatf(from: normal, to: impact.normal)
                    * entry.node.simdWorldOrientation
                // The ballistic contact is at the origin. Actual wheels and panels have volume:
                // rest the lowest transformed corner on the road instead of burying half a tyre.
                var lowest: Float = .greatestFiniteMagnitude
                for x in [bounds.min.x, bounds.max.x] {
                    for y in [bounds.min.y, bounds.max.y] {
                        for z in [bounds.min.z, bounds.max.z] {
                            lowest = min(lowest, entry.node.simdConvertPosition(SIMD3<Float>(Float(x), Float(y), Float(z)), to: nil).y)
                        }
                    }
                }
                if lowest.isFinite { entry.node.simdWorldPosition.y += impact.position.y - lowest + 0.012 }
            }
            entry.settledAt = now
            debrisNodes[impact.projectileID] = entry
        }
        for lost in result.abandoned {
            debrisNodes.removeValue(forKey: lost.id)?.node.removeFromParentNode()
        }

        for (id, entry) in debrisNodes {
            let age = Float(now - entry.bornAt)
            entry.node.opacity = CGFloat(max(0, min(1, entry.lifetime - age)))
            if age >= entry.lifetime {
                entry.node.removeFromParentNode()
                debrisNodes.removeValue(forKey: id)
            }
        }
    }

    /// Mirrors the session's effect list into the scene. Anything the session has retired is torn
    /// down here in the same pass, so nothing survives its own lifetime.
    ///
    /// Emission is ramped down over the tail of each effect rather than the node being cut: a
    /// plume that stops dead reads as a bug, and tearing the emitters off a live node is what
    /// stalls the render thread.
    private func updateEffects(_ effects: [InterceptWorldEffect], now: TimeInterval, wind: SIMD3<Float>) {
        let live = Set(effects.map(\.id))
        for id in effectNodes.keys where !live.contains(id) {
            effectNodes.removeValue(forKey: id)?.node.removeFromParentNode()
        }
        for effect in effects {
            let instance: WorldDamageEffectVisual
            if let existing = effectNodes[effect.id] {
                instance = existing
            } else {
                instance = WorldDamageEffectVisual(kind: effect.kind, scale: effect.scale ?? 1)
                instance.node.name = "effect-\(effect.id)"
                instance.node.simdPosition = effect.position
                root.addChildNode(instance.node)
                effectNodes[effect.id] = instance
            }
            instance.node.simdPosition = effect.position
            instance.update(age: now - effect.startedAt, lifetime: effect.lifetime, normal: effect.normal, wind: wind)
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
        root.childNodes.forEach { $0.removeFromParentNode() }
        root.removeFromParentNode()
        SCNTransaction.commit()

        effectNodes.removeAll()
        scorchNodes.removeAll()
        visuals.removeAll()
        groundVisuals.removeAll()
        cameras.removeAll()
        debris.removeAll()
        debrisNodes.removeAll()
        debrisRuntime.removeAll()
        debrisSurfaceProbeStorage = nil
        detachedVisuals.removeAll()
        deliveryZoneNode = nil
        deliveryLoadNode = nil
    }

}
