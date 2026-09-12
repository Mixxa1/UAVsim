import AppKit
import SceneKit
import simd
import Metal

struct DroneVisualModel {
    let rootNode: SCNNode; let propellerNodes: [SCNNode]; let propellerSpinDirections: [Float]
    let componentNodes: [DamageComponent: [SCNNode]]; let fpvAnchorNode: SCNNode
    let payloadMountNode: SCNNode; let tiltPivotNodes: [SCNNode]
    let visualBoundsCenter: SIMD3<Float>; let visualBoundsSize: SIMD3<Float>
    init(rootNode: SCNNode, propellerNodes: [SCNNode], propellerSpinDirections: [Float],
         componentNodes: [DamageComponent: [SCNNode]], fpvAnchorNode: SCNNode, payloadMountNode: SCNNode,
         tiltPivotNodes: [SCNNode] = [], visualBoundsCenter: SIMD3<Float> = .zero,
         visualBoundsSize: SIMD3<Float> = SIMD3<Float>(repeating: 0.36)) {
        self.rootNode = rootNode; self.propellerNodes = propellerNodes
        self.propellerSpinDirections = propellerSpinDirections; self.componentNodes = componentNodes
        self.fpvAnchorNode = fpvAnchorNode; self.payloadMountNode = payloadMountNode
        self.tiltPivotNodes = tiltPivotNodes; self.visualBoundsCenter = visualBoundsCenter
        self.visualBoundsSize = visualBoundsSize }
}
func bnds(_ node: SCNNode, _ ref: SCNNode) -> (min: SIMD3<Float>, max: SIMD3<Float>)? {
    var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude); var found = false
    func walk(_ c: SCNNode) {
        if c.geometry != nil {
            let b = c.boundingBox
            let a = SIMD3<Float>(Float(b.min.x), Float(b.min.y), Float(b.min.z))
            let d = SIMD3<Float>(Float(b.max.x), Float(b.max.y), Float(b.max.z))
            for k in [SIMD3<Float>(a.x,a.y,a.z), SIMD3<Float>(d.x,d.y,d.z), SIMD3<Float>(a.x,d.y,d.z),
                      SIMD3<Float>(d.x,a.y,a.z), SIMD3<Float>(a.x,a.y,d.z), SIMD3<Float>(d.x,d.y,a.z),
                      SIMD3<Float>(a.x,d.y,a.z), SIMD3<Float>(d.x,a.y,d.z)] {
                let v = ref.simdConvertPosition(k, from: c); low = simd_min(low, v); high = simd_max(high, v) }
            found = true }
        for ch in c.childNodes { walk(ch) } }
    walk(node); return found ? (low, high) : nil }


var failures: [String] = []
var checks = 0
func check(_ ok: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !ok() { failures.append(message); print("FAIL: \(message)") }
}
func aircraftState(position: SIMD3<Float> = .zero, velocity: SIMD3<Float> = .zero) -> DroneState {
    DroneState(position: position, velocity: velocity, orientation: .zero, angularVelocity: .zero,
        throttle: 0, motorThrottle: 0, rotorAngularSpeed: .zero, forwardAirspeed: 0,
        physicalState: .airborne, mode: .manual)
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let library = UAVModelAssetLibrary(directory: root.appendingPathComponent("DroneUAVDemo/Resources/Models/UAVModels"))
let repository = LIPODroneModelRepository()
let impact = ImpactResolutionService()
let ground = VehicleGroundContactSolver()
let dt: Float = 1 / 90
let renderDamage = CommandLine.arguments.contains("--render")
let surface = CollisionObstacle(id: UUID(), center: SIMD3<Float>(0, -0.5, 0), radius: 10000,
    source: "ground.asphalt", baseY: -1, topY: 0, acousticSurface: .asphalt)
var models = 0
let onlyProfiles = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
for profile in repository.allProfiles where onlyProfiles.isEmpty || onlyProfiles.contains(profile.id) {
    guard let uav = profile.resolvedUAVProfile,
          let visual = library.makeVisualModel(profileID: profile.id, payloadMountOffset: uav.payloadMountOffset)
    else { continue }
    visual.rootNode.eulerAngles.y = CGFloat(Float.pi)
    let mp = SCNNode(); mp.addChildNode(visual.rootNode)
    guard let box = bnds(visual.rootNode, mp) else { continue }
    let liftY = max(0.0, -box.min.y)
    let lo = box.min + SIMD3<Float>(0, liftY, 0), hi = box.max + SIMD3<Float>(0, liftY, 0)
    visual.rootNode.removeFromParentNode()
    let fr = SCNNode(); let vr = SCNNode()
    visual.rootNode.simdPosition += SIMD3<Float>(0, liftY, 0)
    vr.addChildNode(visual.rootNode); fr.addChildNode(vr)
    let wrapped = DroneVisualModel(rootNode: fr, propellerNodes: visual.propellerNodes,
        propellerSpinDirections: visual.propellerSpinDirections, componentNodes: visual.componentNodes,
        fpvAnchorNode: visual.fpvAnchorNode, payloadMountNode: visual.payloadMountNode,
        tiltPivotNodes: visual.tiltPivotNodes, visualBoundsCenter: (lo + hi) * 0.5,
        visualBoundsSize: simd_max(hi - lo, SIMD3<Float>(repeating: 0.001)))
    let massModel = VehicleMassModel.baseline(for: profile, uavProfile: uav)
    let built = VehicleComponentGraphBuilder.build(profile: profile, vehicleMassModel: massModel,
        geometry: DroneVisualGeometrySample.capture(from: wrapped))

    models += 1
    let rest = VehicleContactProfile.restOrientation(for: profile.airframeStyle)
    let lift = built.contactProfile.lowestPointOffset(orientation: rest)
    let origin = SIMD3<Float>(0, lift, 0)
    let properties = built.graph.massProperties
    check(FixedWingAeroDamage.build(from: built.graph).isPristine, "\(profile.id): pristine graph changes aerodynamics")
    for wing in built.graph.components {
        guard case .wingSection = wing.kind else { continue }
        check(built.contactProfile.spheres.contains { $0.componentID == wing.id }, "\(profile.id): no contacts for \(wing.id)")
        let wingContacts = built.contactProfile.spheres.filter { $0.componentID == wing.id }
        // Probe both cell interiors and edges over the entire panel, including
        // the large aircraft whose old fixed contact budget left open gaps.
        let coverage = (0...20).allSatisfy { x in (0...10).allSatisfy { z in
            let point = wing.localPosition + SIMD3<Float>(
                (Float(x) / 10 - 1) * wing.boundingHalfExtents.x, 0,
                (Float(z) / 5 - 1) * wing.boundingHalfExtents.z)
            return wingContacts.contains { simd_distance(point, $0.offset) <= $0.radius + 0.00001 }
        } }
        check(coverage, "\(profile.id): holes in contact coverage of \(wing.id)")
        var graph = built.graph
        var state = aircraftState(velocity: SIMD3<Float>(0, -18, 0))
        let contact = VehicleSweptContact(obstacle: surface, componentID: wing.id,
            contactPoint: wing.localPosition - SIMD3<Float>(0, wing.boundingHalfExtents.y + 0.06, 0),
            contactNormal: SIMD3<Float>(0, 1, 0), hitFraction: 1,
            isSupportSurfaceContact: false, sphereOffset: wing.localPosition, sphereRadius: 0.08)
        let report = impact.resolve(contact: contact, previousPosition: .zero, state: &state,
            graph: &graph, massProperties: properties, airframeClass: profile.airframeClass,
            rotorsSpinning: false, deltaTime: dt)
        check(report.componentID == wing.id, "\(profile.id): contact reassigned away from \(wing.id)")
        check(!report.damage.isEmpty || !report.connectionDamage.isEmpty, "\(profile.id): invulnerable \(wing.id)")
    }
    // Last pre-contact frame below the former 20 cm rearm threshold.
    func landing(_ sink: Float, _ forward: Float = 0, spinning: Bool = false) -> (VehicleComponentGraph, DroneState, [ImpactReport]) {
        var graph = built.graph
        var previous = aircraftState(position: SIMD3<Float>(0, 0.055, 0), velocity: SIMD3<Float>(0, -sink, -forward))
        previous.attitudeQuat = rest
        var state = previous
        state.position.y = 0
        state.velocity.y = 0 // same constraint as the actual flight stepper
        if spinning { state.motorThrottle = 0.6; state.throttle = 0.6; state.rotorAngularSpeed = SIMD4<Float>(repeating: 500) }
        state.groundApproach = VehicleGroundApproach(velocity: previous.velocity, rates: .zero, attitude: rest)
        let reports = ground.resolve(previousState: previous, state: &state, graph: &graph,
            profile: built.contactProfile, massProperties: properties, airframeClass: profile.airframeClass,
            obstacle: surface, bodyOriginWorldOffset: origin,
            hasWheels: profile.fixedWingParameters?.hasWheeledUndercarriage ?? false,
            rotorsSpinning: spinning, deltaTime: dt)
        return (graph, state, reports)
    }
    let spinningRest = landing(0, spinning: true)
    let hasBladeClearance = built.contactProfile.spheres.filter { sphere in
        if case .propeller = built.graph.component(id: sphere.componentID)?.kind { return true }
        return false
    }.allSatisfy { simd_act(rest, $0.offset).y + lift - $0.radius > 0.002 }
    if hasBladeClearance {
        check(spinningRest.0.components.allSatisfy { $0.integrity == 1 },
            "\(profile.id): ground spool-up damages blades with real clearance")
    } else {
        // Some belly/hand-launch aircraft really do rest on the prop disc.
        // Starting that motor on the ground must remain a physical strike.
        check(spinningRest.2.contains { report in
            if case .propeller = built.graph.component(id: report.componentID)?.kind { return !report.damage.isEmpty }
            return false
        }, "\(profile.id): a blade resting on the surface ignores motor start")
    }
    let soft = landing(0.25)
    check(soft.0.components.allSatisfy { $0.integrity == 1 }, "\(profile.id): soft landing damages structure")
    let hard = landing(8)
    check(!hard.2.isEmpty, "\(profile.id): hard landing skipped")
    check(hard.0.components.contains { $0.integrity < 0.999 || $0.residualStrength < 0.999 }, "\(profile.id): hard landing has no consequences")
    check(hard.1.velocity.x.isFinite && hard.1.bodyAngularVelocity.x.isFinite, "\(profile.id): nonfinite ground dynamics")
    // Exercise the production stepper before the contact service: the clamp
    // must preserve momentum even when its last pre-impact height is only 1 cm.
    var approaching = aircraftState(position: SIMD3<Float>(0, 0.01, 0), velocity: SIMD3<Float>(0, -6, 0))
    approaching.attitudeQuat = rest
    let controls = DroneControlInput(targetPosition: .zero, targetOrientation: .zero,
        yawIntent: 0, throttle: 0, isArmed: false, mode: .manual, controlMode: .stabilized)
    let context = DroneSimulationContext(profile: profile, activeUAVProfile: uav, weather: .normal,
        damageState: .pristine, batteryState: .full, collisionRisk: 0, windVector: .zero,
        vehicleMassModel: massModel, vehicleMassProperties: properties,
        contactProfile: built.contactProfile, rotorModel: built.rotorModel)
    let integrated = SimpleDronePhysicsEngine().step(state: approaching, control: controls, context: context, deltaTime: dt)
    let freeContext = DroneSimulationContext(profile: profile, activeUAVProfile: uav, weather: .normal,
        damageState: .pristine, batteryState: .full, collisionRisk: 0, windVector: .zero,
        vehicleMassModel: massModel, vehicleMassProperties: properties,
        contactProfile: built.contactProfile, rotorModel: built.rotorModel, groundHeight: -1000)
    let unconstrained = SimpleDronePhysicsEngine().step(state: approaching, control: controls, context: freeContext, deltaTime: dt)
    if let saved = integrated.groundApproach {
        check(simd_distance(saved.velocity, unconstrained.velocity) < 0.04,
            "\(profile.id): contact momentum differs from unconstrained dynamics")
    }
    check(integrated.groundApproach != nil && integrated.groundApproach!.velocity.y < -0.35,
        "\(profile.id): physics step erased landing momentum")
    let body = built.graph.components.first { $0.kind == .fuselage || $0.kind == .frame }!
    var crushed = built.graph
    _ = crushed.applyImpact(primaryComponentID: body.id, energyJ: body.strengthJ * 0.25,
        damageFactor: 1, spreadRadius: 0, contactPointBody: body.localPosition)
    check(crushed.component(id: body.id)!.deformation != .none, "\(profile.id): root body never deforms")
    check(crushed.component(id: body.id)!.isAttached, "\(profile.id): damage automatically detaches body")
    var missing = built.graph
    for wing in missing.components { if case .wingSection = wing.kind { missing.setIntegrity(0, id: wing.id) } }
    if profile.airframeClass != .multirotor {
        check(FixedWingAeroDamage.build(from: missing).liftScale == 0, "\(profile.id): phantom lift after losing every wing")
        let wing = built.graph.components.first { if case .wingSection(_, .outer) = $0.kind { return true }; return false }!
        let travel = built.contactProfile.boundingRadius + abs(wing.localPosition.z) + 1
        let from = SIMD3<Float>(0, 20, travel), to = SIMD3<Float>(0, 20, -travel)
        let obstacle = CollisionObstacle(id: UUID(), center: SIMD3<Float>(wing.localPosition.x, 20, wing.localPosition.z),
            radius: max(0.12, profile.collisionRadius * 0.05), source: "obstacle", baseY: 0, topY: 40)
        let canopy = CollisionObstacle(id: UUID(), center: obstacle.center, radius: 4,
            source: "foliage", baseY: 0, topY: 40)
        let contact = CollisionAnalysisService().firstSweptVehicleCollision(contactSpheres: built.contactProfile.spheres,
            fromPosition: from, toPosition: to, fromOrientation: aircraftState().attitudeQuat, toOrientation: aircraftState().attitudeQuat,
            obstacles: [canopy, obstacle], includesContact: { !ImpactResolutionService.isPenetrable($0) })
        check(contact?.obstacle.id == obstacle.id, "\(profile.id): penetrable volume masks solid wing strike")
        if let contact {
            var graph = built.graph
            var flight = aircraftState(position: to, velocity: SIMD3<Float>(0, 0, -25))
            let report = impact.resolve(contact: contact, previousPosition: from, state: &flight,
                graph: &graph, massProperties: properties, airframeClass: profile.airframeClass,
                rotorsSpinning: true, deltaTime: dt)
            check(!report.damage.isEmpty && !graph.failedConnectionRootIDs.isEmpty,
                "\(profile.id): 25 m/s wing strike does not break structure (\(report.componentID), E=\(report.impactEnergyJ), closing=\(report.normalClosingSpeed), damage=\(report.damage.count), joints=\(report.connectionDamage.count))")
        }
    }
    // Stations: a wing is a chain of stations along its real planform, not two halves.
    if profile.airframeClass != .multirotor {
        let left = built.graph.memberChains["wing.left"] ?? []
        check(left.count == 12, "\(profile.id): wing has \(left.count) stations instead of 12")
        let spans = left.compactMap { built.graph.component(id: $0)?.localPosition.x }
        check(zip(spans, spans.dropFirst()).allSatisfy { $0 > $1 }, "\(profile.id): left wing stations not ordered root→tip")
        if profile.airframeStyle == .flyingWing {
            check(!built.graph.components.contains { $0.kind == .verticalTail || $0.kind == .horizontalTail },
                  "\(profile.id): flying wing given a tail it does not have")
        }
    }
    // A pristine airframe pulling 2.5 g (limit load) is still elastic everywhere — at any
    // speed it can actually make that load factor.
    if profile.airframeClass != .multirotor, let wing = profile.fixedWingParameters {
        var graph = built.graph
        let speed = max(wing.cruiseSpeedMps, profile.maxHorizontalSpeedMps * 0.8)
        var before = aircraftState(position: SIMD3<Float>(0, 300, 0), velocity: SIMD3<Float>(0, 0, -speed))
        before.forwardAirspeed = speed
        var after = before
        after.velocity.y += 1.5 * 9.81 * dt
        let result = UAVStructuralLoadSolver().evaluate(graph: &graph, previousState: before, state: after,
            airframeClass: profile.airframeClass, rotorModel: built.rotorModel, deltaTime: dt)
        let yielded = graph.structuralConnections.filter { $0.plasticRotationSpent > 0 || $0.fracture != .intact }
        check(yielded.isEmpty, "\(profile.id): limit-load pull yields \(yielded.map(\.childComponentID).prefix(4))")
        _ = result
    }
    // A landing and its roll-out to a stop. Whatever breaks, breaks in the blow that broke it:
    // nothing may come off the aircraft later than the last contact that could have done it.
    if profile.airframeClass != .multirotor {
        let stall = profile.fixedWingParameters?.minSustainableSpeedMps ?? 12
        for (sink, rollDeg) in [(Float(1.0), Float(0)), (Float(2.0), Float(6))] {
            var graph = built.graph
            var contacts = built.contactProfile
            // Three centimetres above the runway at the lowest point, so the sink it touches down
            // at is the sink the case is named for. From 0.6 m the aircraft fell for a third of a
            // second first and every "1 m/s" landing arrived at 2.2–3.2 m/s.
            let rolled = simd_quatf(angle: rollDeg * .pi / 180, axis: SIMD3<Float>(0, 0, 1)) * rest
            let startHeight = 0.03 + max(0, built.contactProfile.lowestPointOffset(orientation: rolled) - lift)
            var s = aircraftState(position: SIMD3<Float>(0, startHeight, 0), velocity: SIMD3<Float>(0, -sink, -stall * 1.1))
            s.attitudeQuat = rolled
            s.orientation = SIMD3<Float>(rollDeg * .pi / 180, 0, 0)
            s.forwardAirspeed = stall * 1.1
            let idle = DroneControlInput(targetPosition: .zero, targetOrientation: .zero,
                yawIntent: 0, throttle: 0, isArmed: false, mode: .manual, controlMode: .stabilized)
            var lastBlow: Float = -1
            var late: [String] = []
            var fractures = 0
            var broken: [String] = []
            var time: Float = 0
            var preload: [String: VehicleJointLoad] = [:]
            for _ in 0..<(90 * 10) {
                let previous = s
                let stepContext = DroneSimulationContext(profile: profile, activeUAVProfile: uav, weather: .normal,
                    damageState: .pristine, batteryState: .full, collisionRisk: 0, windVector: .zero,
                    vehicleMassModel: massModel, vehicleMassProperties: graph.massProperties,
                    contactProfile: contacts, rotorModel: built.rotorModel)
                s = SimpleDronePhysicsEngine().step(state: s, control: idle, context: stepContext, deltaTime: dt)
                let loadState = s
                let reports = ground.resolve(previousState: previous, state: &s, graph: &graph,
                    profile: contacts, massProperties: graph.massProperties, airframeClass: profile.airframeClass,
                    obstacle: surface, bodyOriginWorldOffset: origin,
                    hasWheels: profile.fixedWingParameters?.hasWheeledUndercarriage ?? false,
                    rotorsSpinning: false, deltaTime: dt, jointPreload: preload)
                if reports.contains(where: { $0.normalClosingSpeed > 0.35 }) { lastBlow = time }
                let result = UAVStructuralLoadSolver().evaluate(graph: &graph, previousState: previous, state: loadState,
                    airframeClass: profile.airframeClass, rotorModel: built.rotorModel, deltaTime: dt,
                    sustainedForces: reports.flatMap(\.sustainedForces))
                preload = result.jointLoads
                for root in graph.failedConnectionRootIDs {
                    guard let piece = graph.detachSubtree(rootComponentID: root) else { continue }
                    // A stopped propeller whose disc reaches below the belly scrapes the runway on
                    // any flat landing: that is the model's geometry, not a structural failure, and
                    // it is counted apart.
                    if !root.hasPrefix("propeller.") { fractures += 1 }
                    broken.append("\(root)@\(String(format: "%.2f", time))s")
                    contacts = contacts.removing(componentIDs: piece.componentIDs)
                    if lastBlow < 0 || time - lastBlow > 0.25 {
                        late.append("\(root)@\(String(format: "%.2f", time))s last blow \(String(format: "%.2f", lastBlow))s")
                    }
                }
                time += dt
            }
            check(late.isEmpty, "\(profile.id): parts fall off after the landing, not in it: \(late.prefix(3))")
            if sink <= 1.0 && rollDeg == 0 {
                check(fractures == 0, "\(profile.id): a 1 m/s level landing breaks \(fractures) joints: \(broken.prefix(4))")
            }
        }
    }
    // Exercise the actual authored visual, rather than only its damage numbers.
    let binding = VehicleComponentVisualBinding(root: vr, bodyFrame: fr,
        legacyNodes: wrapped.componentNodes, propellers: wrapped.propellerNodes, graph: built.graph)
    var visualGraph = built.graph
    _ = visualGraph.detachSubtree(rootComponentID: "flightController")
    binding.apply(visualGraph)
    let hullNodes = binding.nodes(for: [body.id])
    check(!hullNodes.isEmpty && hullNodes.allSatisfy { !$0.isHidden },
        "\(profile.id): detaching flight computer hides fuselage")
    for wing in built.graph.components {
        guard case .wingSection = wing.kind else { continue }
        var split = built.graph
        guard let part = split.detachSubtree(rootComponentID: wing.id) else { continue }
        binding.apply(split)
        check(!binding.nodes(for: [wing.id]).isEmpty, "\(profile.id): wing section has no physical visual")
        check(binding.nodes(for: part.componentIDs).allSatisfy { $0.isHidden },
            "\(profile.id): detached subtree still follows aircraft")
        check(binding.nodes(for: [body.id]).allSatisfy { !$0.isHidden },
            "\(profile.id): wing separation removes retained fuselage")
    }
    binding.apply(built.graph)
    if profile.airframeClass == .multirotor {
        var falling = aircraftState(position: SIMD3<Float>(0, 100, 0))
        falling.angularVelocity = SIMD3<Float>(1, 0, 0)
        let off = DroneControlInput(targetPosition: falling.position, targetOrientation: .zero,
            yawIntent: 0, throttle: 0, isArmed: false, mode: .hover, controlMode: .hoverAssist)
        let freeFall = SimpleDronePhysicsEngine().step(state: falling, control: off, context: context, deltaTime: dt)
        check(freeFall.motorThrottle == 0 && freeFall.velocity.y < -0.08,
            "\(profile.id): disarmed controller manufactures thrust during a tumble")
        let deadControllerContext = DroneSimulationContext(profile: profile, activeUAVProfile: uav, weather: .normal,
            damageState: .pristine, batteryState: .full, collisionRisk: 0, windVector: .zero,
            vehicleMassModel: massModel, vehicleMassProperties: properties,
            contactProfile: built.contactProfile, rotorModel: built.rotorModel, controlSystemFactor: 0)
        var liveCommand = off; liveCommand.isArmed = true; liveCommand.throttle = 1
        let lostControl = SimpleDronePhysicsEngine().step(state: falling, control: liveCommand,
            context: deadControllerContext, deltaTime: dt)
        check(lostControl.motorThrottle == 0 && lostControl.velocity.y < -0.08,
            "\(profile.id): missing controller still follows powered user commands")
    }
    if renderDamage, ["ft5-los", "sensefly-ebee-tac", "quantum-systems-trinity-pro", "zipline-platform-1"].contains(profile.id) {
        let scene = SCNScene()
        scene.rootNode.addChildNode(fr)
        fr.simdPosition = SIMD3<Float>(0, 6, 0)
        var split = built.graph
        let wingID = split.memberChains["wing.left"]!.first!
        let part = split.detachSubtree(rootComponentID: wingID)!
        let fragment = SCNNode()
        fragment.simdPosition = fr.simdPosition + part.localBoundsCenter
        scene.rootNode.addChildNode(fragment)
        let sources = binding.nodes(for: part.componentIDs)
        for source in sources {
            fragment.addChildNode(VehicleDetachedPartPhysics.snapshot(source, bodyFrame: fr,
                vehicleTransform: fr.simdWorldTransform, partTransform: fragment.simdWorldTransform))
        }
        binding.apply(split)
        let h = part.localBoundsHalfExtents
        fragment.physicsBody = VehicleDetachedPartPhysics.makeBody(part: part,
            shapeGeometry: SCNBox(width: CGFloat(h.x * 2), height: CGFloat(h.y * 2), length: CGFloat(h.z * 2), chamferRadius: 0),
            velocity: SIMD3<Float>(1, 0, 0), angularVelocity: SIMD3<Float>(0.3, 0.5, 0.8))
        let floor = SCNNode(geometry: SCNFloor())
        floor.geometry?.firstMaterial?.diffuse.contents = NSColor(white: 0.35, alpha: 1)
        floor.physicsBody = SCNPhysicsBody(type: .static, shape: SCNPhysicsShape(geometry: SCNBox(width: 1000, height: 0.1, length: 1000, chamferRadius: 0)))
        floor.physicsBody?.categoryBitMask = VehicleDetachedPartPhysics.environmentCategory
        floor.physicsBody?.collisionBitMask = VehicleDetachedPartPhysics.category
        scene.rootNode.addChildNode(floor)
        let camera = SCNNode(); camera.camera = SCNCamera()
        camera.simdPosition = SIMD3<Float>(8, 11, 13)
        camera.look(at: SCNVector3(0, 4, 0)); scene.rootNode.addChildNode(camera)
        let light = SCNNode(); light.light = SCNLight(); light.light?.type = .ambient; light.light?.intensity = 900
        scene.rootNode.addChildNode(light)
        scene.background.contents = NSColor(white: 0.15, alpha: 1)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene; renderer.pointOfView = camera; renderer.isPlaying = true
        let output = URL(fileURLWithPath: "/tmp/uav-damage-visuals")
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let initialY = fragment.simdPosition.y
        for frame in 0...120 {
            let snapshot = renderer.snapshot(atTime: Double(frame) / 60,
                with: NSSize(width: 960, height: 720), antialiasingMode: .none)
            if frame == 36 {
                check(fragment.presentation.simdWorldPosition.y < initialY - 0.6,
                    "\(profile.id): detached wing hangs in air instead of falling")
            }
            if frame == 0 || frame == 120 {
                let bitmap = NSBitmapImageRep(data: snapshot.tiffRepresentation!)!
                try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(profile.id)-\(frame).png"))
            }
        }
        let position = fragment.presentation.simdWorldPosition
        fr.simdPosition.x += 20
        check(simd_distance(fragment.presentation.simdWorldPosition, position) < 0.001,
            "\(profile.id): detached fragment follows parent transform")
        fr.removeFromParentNode()
    }
    if uav.vehicleType == .helicopter {
        let engine = SimpleDronePhysicsEngine()
        var helicopter = aircraftState()
        helicopter.physicalState = .takeoffTransition
        let input = DroneControlInput(targetPosition: SIMD3<Float>(0, 20, 0), targetOrientation: SIMD3<Float>(0.06, 0, 0),
            yawIntent: 0, throttle: 0.9, isArmed: true, mode: .manual, controlMode: .stabilized)
        var graph = built.graph
        for _ in 0..<360 {
            let previous = helicopter
            helicopter = engine.step(state: helicopter, control: input, context: context, deltaTime: dt)
            _ = ground.resolve(previousState: previous, state: &helicopter, graph: &graph,
                profile: built.contactProfile, massProperties: properties, airframeClass: profile.airframeClass,
                obstacle: surface, bodyOriginWorldOffset: origin, rotorsSpinning: true, deltaTime: dt)
        }
        print("HELICOPTER \(profile.id): y=\(helicopter.position.y) v=\(helicopter.velocity) rates=\(helicopter.angularVelocity) health=\(graph.components.map { "\($0.id):\($0.integrity)" })")
        check(helicopter.position.y > 3, "\(profile.id): cannot take off with authored geometry")
        // Tilting while the skids still touch can leave microscopic abrasion.
        check(graph.components.allSatisfy { $0.integrity > 0.999 }, "\(profile.id): damages itself during takeoff")
        check(abs(helicopter.orientation.x - 0.06) < 0.035, "\(profile.id): tandem rotor has no cyclic roll authority")
    }
    print("PASS fleet: \(profile.id)")
}
check(models >= 25, "Too few authored aircraft tested: \(models)")

func member(_ id: String, _ kind: VehicleComponentKind, _ parent: String?, _ mass: Float,
            _ position: SIMD3<Float>, _ half: SIMD3<Float>, _ strength: Float, health: Float = 1) -> VehicleComponent {
    VehicleComponent(id: id, kind: kind, parentID: parent, massKg: mass, localPosition: position,
        boundingHalfExtents: half, strengthJ: strength, integrity: health,
        legacyComponent: nil, functionalDependencies: [], failureModes: [.efficiencyLoss, .totalFailure])
}
let synthetic = VehicleComponentGraph(components: [
    member("core", .fuselage, nil, 1, SIMD3<Float>(0, 0.2, 0), SIMD3<Float>(0.1, 0.1, 0.3), 100),
    member("portPanel", .wingSection(side: .left, segment: .outer), "core", 0.1, SIMD3<Float>(-0.5, 0.2, 0), SIMD3<Float>(0.4, 0.015, 0.2), 30),
    member("starboardPanel", .wingSection(side: .right, segment: .outer), "core", 0.1, SIMD3<Float>(0.5, 0.2, 0), SIMD3<Float>(0.4, 0.015, 0.2), 30),
    member("motor.cruise", .motor(slot: "cruise"), "core", 0.04, SIMD3<Float>(0, 0.2, -0.3), SIMD3<Float>(repeating: 0.025), 20),
    member("propeller.cruise", .propeller(slot: "cruise"), "motor.cruise", 0.008, SIMD3<Float>(0, 0.15, -0.35), SIMD3<Float>(0.15, 0.15, 0.008), 4)
])
var asym = synthetic
asym.setIntegrity(0.55, id: "starboardPanel")
let asymmetricDamage = FixedWingAeroDamage.build(from: asym)
check(asymmetricDamage.liftScale < 0.9 && asymmetricDamage.liftScale > 0.7, "arbitrary IDs do not drive wing aerodynamics")
check(asymmetricDamage.elevatorScale == 1, "tailless graph invents absent elevator damage")
let baseAero = FixedWingAerodynamics.build(family: .conventionalSurvey, massKg: 1.248, wingSpanM: 1.8,
    fuselageLengthM: 0.7, heightM: 0.3, turnAuthority: 1, minSustainableSpeedMps: 10)
let damagedAero = baseAero.applyingDamage(asymmetricDamage)
let levelRoll = damagedAero.rollMoment(alphaRad: 0.12, betaRad: 0, aileronFraction: 0, pHat: 0)
check(levelRoll < 0, "lost right-wing lift rolls in wrong direction")
let earlyStall = damagedAero.liftDrag(alphaRad: baseAero.stallAlphaRad)
check(earlyStall.cl < baseAero.liftDrag(alphaRad: baseAero.stallAlphaRad).cl * 0.85, "damaged panel retains pristine stall boundary")
let spinAlpha = baseAero.stallAlphaRad + 0.13
let spinLeft = damagedAero.rollMoment(alphaRad: spinAlpha, betaRad: 0, aileronFraction: 0, pHat: -0.01)
let spinRight = damagedAero.rollMoment(alphaRad: spinAlpha, betaRad: 0, aileronFraction: 0, pHat: 0.01)
check(spinRight > spinLeft, "post-stall local flow does not allow autorotation")
var lost = synthetic
lost.setIntegrity(0, id: "portPanel"); lost.setIntegrity(0, id: "starboardPanel")
let wingless = baseAero.applyingDamage(FixedWingAeroDamage.build(from: lost))
check(abs(wingless.liftDrag(alphaRad: 0.2).cl) < 0.000001, "wingless aircraft retains lift")
check(wingless.liftDrag(alphaRad: 0).cd > baseAero.liftDrag(alphaRad: 0).cd, "wing loss removes fuselage drag")

// Sliding dissipates actual friction work, including at zero normal approach.
let bellyProfile = VehicleContactProfile(spheres: [VehicleContactSphere(componentID: "core", offset: SIMD3<Float>(0, 0.1, 0), radius: 0.1)], boundingRadius: 0.5)
let gearProfile = VehicleContactProfile(spheres: [
    VehicleContactSphere(componentID: "gear", offset: SIMD3<Float>(0, 0.1, 0), radius: 0.1, isGroundSupport: true),
    VehicleContactSphere(componentID: "core", offset: SIMD3<Float>(0, 0.7, 0), radius: 0.2)
], boundingRadius: 1, referenceGroundOffset: 0)
let collapsed = gearProfile.removing(componentIDs: ["gear"])
let identity = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
check(abs(collapsed.groundClearanceOffset(orientation: identity, restOrientation: identity) + 0.5) < 0.00001,
    "lost landing gear still provides an invisible support plane")
check(abs(collapsed.lowestPointY(position: SIMD3<Float>(0, -0.5, 0), orientation: identity)) < 0.00001,
    "surviving fuselage cannot reach the surface after gear loss")
var slidingGraph = synthetic
var sliding = aircraftState(velocity: SIMD3<Float>(0, 0, -15))
let initialSpeed = simd_length(sliding.velocity)
for _ in 0..<90 {
    let previous = sliding
    sliding.position.y = 0
    _ = ground.resolve(previousState: previous, state: &sliding, graph: &slidingGraph,
        profile: bellyProfile, massProperties: synthetic.massProperties, airframeClass: .fixedWing,
        obstacle: surface, rotorsSpinning: false, deltaTime: dt)
}
check(slidingGraph.integrity(id: "core") < 1, "persistent belly slide causes no abrasion")
check(simd_length(sliding.velocity) < initialSpeed, "friction adds translational energy")

let propProfile = VehicleContactProfile(spheres: [VehicleContactSphere(componentID: "propeller.cruise", offset: SIMD3<Float>(0, 0.02, -0.35), radius: 0.02)], boundingRadius: 0.5)
var propGraph = synthetic
var rotating = aircraftState()
rotating.motorThrottle = 0.6; rotating.rotorAngularSpeed.x = 500
let propReports = ground.resolve(previousState: rotating, state: &rotating, graph: &propGraph,
    profile: propProfile, massProperties: synthetic.massProperties, airframeClass: .fixedWing,
    obstacle: surface, rotorsSpinning: true, deltaTime: dt)
check(propGraph.integrity(id: "propeller.cruise") < 1, "stationary spinning prop ignores the ground")
check(!propReports.isEmpty, "propeller strike has no event")
var staticGraph = synthetic
var stationary = aircraftState()
_ = ground.resolve(previousState: stationary, state: &stationary, graph: &staticGraph,
    profile: propProfile, massProperties: synthetic.massProperties, airframeClass: .fixedWing,
    obstacle: surface, rotorsSpinning: false, deltaTime: dt)
check(staticGraph.integrity(id: "propeller.cruise") == 1, "unpowered stationary prop damages itself")

// A rotating damaged blade fatigues its load path even after the initial hit;
// an equally damaged but stopped blade does not.
var runningGraph = synthetic, stoppedGraph = synthetic
runningGraph.setIntegrity(0.5, id: "propeller.cruise")
stoppedGraph.setIntegrity(0.5, id: "propeller.cruise")
let rotor = VehicleRotor(slot: "cruise", offsetBody: SIMD3<Float>(0, 0, -0.35), spinSign: 1,
    laneIndex: nil, thrustFactor: 0.4, vibration01: 0.55)
let rotorModel = VehicleRotorModel(rotors: [rotor], torqueToThrustRatio: 0.02)
var yawedRotor = rotor
yawedRotor.thrustFactor = 1
yawedRotor.vibration01 = 0
yawedRotor.cruiseThrustDirectionBody = simd_act(
    simd_quatf(angle: 0.2, axis: SIMD3<Float>(0, 1, 0)), SIMD3<Float>(0, 0, -1))
let yawedWrench = VehicleRotorModel(rotors: [yawedRotor], torqueToThrustRatio: 0.02)
    .cruiseWrench(nominalThrust: 10)
check(yawedWrench.force.x < -1.9 && abs(yawedWrench.force.y) < 0.00001,
    "bent cruise mount uses the lift-rotor axis instead of its real shaft direction")
var running = aircraftState(position: SIMD3<Float>(0, 20, 0)); running.motorThrottle = 0.8
var stopped = running; stopped.motorThrottle = 0
for _ in 0..<900 {
    _ = UAVStructuralLoadSolver().evaluate(graph: &runningGraph, previousState: running, state: running,
        airframeClass: .fixedWing, rotorModel: rotorModel, deltaTime: dt)
    _ = UAVStructuralLoadSolver().evaluate(graph: &stoppedGraph, previousState: stopped, state: stopped,
        airframeClass: .fixedWing, rotorModel: rotorModel, deltaTime: dt)
}
check(runningGraph.connection(childComponentID: "propeller.cruise")!.residualStrength < stoppedGraph.connection(childComponentID: "propeller.cruise")!.residualStrength,
    "blade imbalance does not progress after takeoff")

// The physical pulse duration and outcome cannot change with display FPS.
func hit(_ delta: Float) -> VehicleComponentGraph {
    var graph = synthetic
    var state = aircraftState(velocity: SIMD3<Float>(0, -3, 0))
    let contact = VehicleSweptContact(obstacle: surface, componentID: "portPanel", contactPoint: SIMD3<Float>(-0.5, 0.2, 0),
        contactNormal: SIMD3<Float>(0, 1, 0), hitFraction: 1, isSupportSurfaceContact: false,
        sphereOffset: SIMD3<Float>(-0.5, 0.2, 0), sphereRadius: 0.02)
    _ = impact.resolve(contact: contact, previousPosition: .zero, state: &state, graph: &graph,
        massProperties: synthetic.massProperties, airframeClass: .fixedWing, rotorsSpinning: false, deltaTime: delta)
    return graph
}
check(hit(1 / 30) == hit(1 / 120), "impact damage depends on display frame rate")
// Full sweep -> impulse -> component damage, with no obstacle-name rule.
// A wing strike that removes substantial speed must not bypass its material
// and connection response after the narrow phase selected that wing.
let sweepService = CollisionAnalysisService()
let wingSpheres = synthetic.components.compactMap { component -> VehicleContactSphere? in
    guard case .wingSection = component.kind else { return nil }
    return VehicleContactSphere(componentID: component.id, offset: component.localPosition, radius: 0.06)
}
for speed: Float in [6, 15, 35] {
    let block = CollisionObstacle(id: UUID(), center: SIMD3<Float>(-0.5, 10.2, -0.8), radius: 0.2,
        source: "", baseY: 10, topY: 10.4, planarHalfExtents: SIMD2<Float>(0.15, 0.15))
    let previous = aircraftState(position: SIMD3<Float>(0, 10, 0), velocity: SIMD3<Float>(0, 0, -speed))
    var current = previous
    current.position.z = -1.2
    var graph = synthetic
    if let contact = sweepService.firstSweptVehicleCollision(contactSpheres: wingSpheres,
        fromPosition: previous.position, toPosition: current.position,
        fromOrientation: previous.attitudeQuat, toOrientation: current.attitudeQuat, obstacles: [block]) {
        let report = impact.resolve(contact: contact, previousPosition: previous.position,
            state: &current, graph: &graph, massProperties: synthetic.massProperties,
            airframeClass: .fixedWing, rotorsSpinning: false, deltaTime: dt)
        check(report.componentID == "portPanel", "sweep assigned unnamed-obstacle hit to wrong component")
        check(!report.damage.isEmpty && graph.integrity(id: "portPanel") < 1,
            "wing contact loses speed but ignores structural damage at \(speed) m/s")
        if speed >= 15 { check(!graph.failedConnectionRootIDs.isEmpty, "severe wing strike never fractures a load path") }
    } else { check(false, "swept wing contact missed at \(speed) m/s") }
}
// A collision between two airframes cannot dissipate the same energy twice.
let pairSphere = VehicleContactSphere(componentID: "core", offset: .zero, radius: 0.1)
let pairContact = VehiclePairContact(fraction: 1, point: SIMD3<Float>(0, 0.2, 0), normal: SIMD3<Float>(1, 0, 0), firstSphere: pairSphere, secondSphere: pairSphere)
var first = aircraftState(velocity: SIMD3<Float>(-10, 0, 0))
var second = aircraftState(velocity: SIMD3<Float>(10, 0, 0))
var firstGraph = synthetic, secondGraph = synthetic
let kineticBudget = 0.5 * synthetic.massProperties.totalMassKg * (simd_length_squared(first.velocity) + simd_length_squared(second.velocity))
let pairReports = VehiclePairContactService.resolve(contact: pairContact, firstPrevious: first, secondPrevious: second,
    first: &first, firstGraph: &firstGraph, firstClass: .fixedWing,
    second: &second, secondGraph: &secondGraph, secondClass: .fixedWing, deltaTime: dt)
check(pairReports.first.impactEnergyJ + pairReports.second.impactEnergyJ <= kineticBudget + 0.001,
    "two-body damage exceeds the incoming kinetic energy")
print("DamageModelProbe: \(checks) checks, \(models) authored aircraft, \(failures.count) failures")
if !failures.isEmpty { exit(1) }
