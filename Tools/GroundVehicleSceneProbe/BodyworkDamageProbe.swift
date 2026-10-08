import AppKit
import Foundation
import Metal
import SceneKit
import simd
import DroneUAVDemo

enum BodyworkDamageProbe {
    @MainActor static func runSurface() {
        let profile = LIPODroneModelRepository().defaultProfile
        let controller = DroneSceneController(initialProfile: profile)
        controller.regenerateEnvironment(TerrainConfiguration(preset: .gridDemo, mapScale: .x4,
            density: 0, seed: 51, safeSpawnRadius: 20))
        let world = InterceptMissionScene(scene: controller.scene, showsCallsigns: false)
        let actor = world.makeGroundActor(id: "surface-car", model: .cabover, position: SIMD3<Float>(0, 0, -65),
            adapterProfile: profile, seed: 25)
        actor.receiveDetonation(ChargeDetonation(position: actor.state.position), directHit: true, now: 0)
        precondition(actor.groundVehicle!.damage.functionalState == .nominal && actor.groundVehicle!.effects.isEmpty,
            "Interception charges must not produce damage or fire on a road actor")
        let ground: (SIMD3<Float>, Float) -> Float = { _, _ in 0 }
        world.updateGroundWorld(actor, now: 0, deltaTime: 0.05, ground: ground, wind: .zero)
        let liveCar = controller.scene.rootNode.childNode(withName: "surface-car", recursively: true)!
        let shadows = liveCar.childNode(withName: "vehicle.contact-shadows", recursively: true)!
        precondition(shadows.childNodes.count == 7 && shadows.childNodes.allSatisfy { !$0.isHidden },
            "Supported chassis and all six wheels must have soft contact shadows")
        for i in 0..<120 {
            _ = actor.stepGroundVehicle(deltaTime: 0.05, destination: SIMD2<Float>(35, -125), threat: nil,
                evasive: false, origin: .zero, areaRadius: 200, grip: 1, obstacles: [], ground: ground)
            world.updateGroundWorld(actor, now: Double(i + 1) * 0.05, deltaTime: 0.05, ground: ground, wind: .zero)
        }
        let tracks = world.wheelTracks
        precondition(tracks.count > 6 && tracks.count <= 768, "A driving car must leave a bounded tyre trail")
        precondition(tracks.allSatisfy { $0.corners.allSatisfy { abs($0.y - 0.025) < 0.0001 } },
            "Every tyre mark must follow the actual ground surface")
        let movingCount = tracks.count
        actor.groundVehicle!.state.position.y = 4
        actor.state.position.y = 4
        world.updateGroundWorld(actor, now: 7, deltaTime: 0.05, ground: ground, wind: .zero)
        precondition(shadows.childNodes.allSatisfy(\.isHidden) && world.wheelTracks.count == movingCount,
            "An unsupported car must not paint tracks or keep ground contact shadows")
        actor.groundVehicle!.state.position.y = 0
        actor.state.position.y = 0
        world.updateGroundWorld(actor, now: 8, deltaTime: 0.05, ground: ground, wind: .zero)
        let recorder = MissionReplayRecorder(); recorder.startSession()
        let snapshot = MissionReplayWorldSnapshot(nodes: world.captureReplayVisuals(actors: [actor], recorder: recorder),
            effects: [], wheelTracks: tracks)
        let encoded = try! JSONEncoder().encode(snapshot)
        precondition(try! JSONDecoder().decode(MissionReplayWorldSnapshot.self, from: encoded).wheelTracks == tracks,
            "Track samples must survive recording storage without geometry archives")
        let scene = SCNScene(), player = SCNNode(); scene.rootNode.addChildNode(player)
        let replay = MissionReplayWorldVisuals()
        replay.load(assets: recorder.currentSession!.visualAssets!, scene: scene, playerRoot: player)
        replay.update(snapshot)
        let replayTracks = scene.rootNode.childNode(withName: "vehicle.tyre-tracks", recursively: true)!
        precondition(replayTracks.geometry != nil && !replay.assetFailures, "Playback must reconstruct tracks and contact shadows")
        replay.update(MissionReplayWorldSnapshot(nodes: [], effects: []))
        precondition(replayTracks.geometry == nil, "Backward seeking must remove future tyre marks")
        let camera = controller.pointOfView(for: .free)
        let p = actor.groundVehicle!.state.position
        camera.simdPosition = p + SIMD3<Float>(13, 12, -19); camera.look(at: SCNVector3(p + SIMD3<Float>(0, 1.5, 2)))
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = controller.scene; renderer.pointOfView = camera
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 1000, height: 700), antialiasingMode: .multisampling4X)
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try! bitmap.representation(using: .png, properties: [:])!.write(to:
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("vehicle-tracks-shadows.png"))
        print("PASS: unarmed road actor, contact shadows, terrain-fitted tracks, no airborne marks and reversible replay")
    }

    @MainActor static func run() {
        let plate = SCNBox(width: 2, height: 0.08, length: 2, chamferRadius: 0)
        plate.firstMaterial?.diffuse.contents = NSColor.systemGreen
        let mild = GroundVehicleDamageSite(point: SIMD3<Float>(0, 0.04, 0), severity: 0.35,
            heat: 0, tearsPanels: false, normal: SIMD3<Float>(0, 1, 0))
        var budget = 4_000
        let dent = VehicleBodyworkDeformation.deform(plate, toBody: matrix_identity_float4x4,
            sites: [mild], glass: false, triangleBudget: &budget)!
        precondition(dent.name == "bodywork.deformed.cut-0", "A mild dent must not perforate sheet metal")
        var severe = mild; severe.severity = 0.95; severe.tearsPanels = true
        budget = 4_000
        let tear = VehicleBodyworkDeformation.deform(plate, toBody: matrix_identity_float4x4,
            sites: [severe], glass: false, triangleBudget: &budget)!
        precondition(tear.name != "bodywork.deformed.cut-0" && tear.elements.last!.primitiveCount > 0,
            "A severe strike must remove triangles and expose a ragged metallic rim")
        func intersects(_ geometry: SCNGeometry, x: Float, z: Float) -> Bool {
            let source = geometry.sources(for: .vertex).first!
            let vertices: [SIMD3<Float>] = (0..<source.vectorCount).map { i in
                source.data.withUnsafeBytes { data in
                    let offset = source.dataOffset + i * source.dataStride
                    return SIMD3<Float>(data.loadUnaligned(fromByteOffset: offset, as: Float.self),
                        data.loadUnaligned(fromByteOffset: offset + 4, as: Float.self),
                        data.loadUnaligned(fromByteOffset: offset + 8, as: Float.self))
                }
            }
            for element in geometry.elements {
                let hit = element.data.withUnsafeBytes { data -> Bool in
                    for i in 0..<element.primitiveCount {
                        let ids = (0..<3).map { Int(data.loadUnaligned(fromByteOffset: (i * 3 + $0) * 4, as: UInt32.self)) }
                        let a = vertices[ids[0]], b = vertices[ids[1]], c = vertices[ids[2]]
                        let ac = SIMD2<Float>(a.x - c.x, a.z - c.z), bc = SIMD2<Float>(b.x - c.x, b.z - c.z)
                        let p = SIMD2<Float>(x - c.x, z - c.z), den = ac.x * bc.y - ac.y * bc.x
                        if abs(den) < 0.000001 { continue }
                        let u = (p.x * bc.y - p.y * bc.x) / den, v = (ac.x * p.y - ac.y * p.x) / den
                        if u >= -0.001 && v >= -0.001 && u + v <= 1.001 { return true }
                    }
                    return false
                }
                if hit { return true }
            }
            return false
        }
        NSLog("Tear fixture %@ vertices=%ld bounds=%@", tear.name!, tear.sources(for: .vertex).first!.vectorCount,
            String(describing: tear.boundingBox))
        precondition(!intersects(tear, x: 0, z: 0),
            "The rupture must be a real opening through both sides of the sheet")
        precondition(intersects(tear, x: 0.9, z: 0.9),
            "Unstruck sheet metal must remain solid")
        let recorder = MissionReplayRecorder(); recorder.startSession()
        let source = SCNNode(geometry: plate)
        let before = MissionReplayVisualCapture.snapshot(id: "plate", node: source, recorder: recorder)
        source.geometry = tear
        let after = MissionReplayVisualCapture.snapshot(id: "plate", node: source, recorder: recorder)
        precondition(before.assetID != after.assetID, "A changed mesh must create a distinct replay geometry version")
        let replayScene = SCNScene(), player = SCNNode(); replayScene.rootNode.addChildNode(player)
        let replay = MissionReplayWorldVisuals()
        replay.load(assets: recorder.currentSession!.visualAssets!, scene: replayScene, playerRoot: player)
        replay.update(MissionReplayWorldSnapshot(nodes: [after], effects: []))
        let restoredTear = replay.node(for: "plate")!.geometry!
        precondition(restoredTear.sources(for: .vertex).first!.vectorCount == tear.sources(for: .vertex).first!.vectorCount
            && !intersects(restoredTear, x: 0, z: 0), "Replay must retain the perforated mesh")
        replay.update(MissionReplayWorldSnapshot(nodes: [before], effects: []))
        precondition(replay.node(for: "plate")!.geometry!.sources(for: .vertex).first!.vectorCount
            == plate.sources(for: .vertex).first!.vectorCount, "Backward seeking must repair the mesh")

        let profile = LIPODroneModelRepository().defaultProfile
        let controller = DroneSceneController(initialProfile: profile)
        controller.regenerateEnvironment(TerrainConfiguration(preset: .gridDemo, mapScale: .x4,
            density: 0, seed: 51, safeSpawnRadius: 20))
        let output = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for model in GroundVehicleModel.allCases {
            let visual = GroundVehicleVisual(model: model)
            let origin = SIMD3<Float>(0, 0, -65)
            visual.rootNode.simdPosition = origin
            controller.scene.rootNode.addChildNode(visual.rootNode)
            var roof: SCNNode?
            visual.rootNode.enumerateChildNodes { node, _ in
                if node.name?.hasPrefix("CabRoof_") == true, node.geometry != nil { roof = node }
            }
            let roofNode = roof!, bounds = roofNode.boundingBox
            let centre = SIMD3<Float>(Float((bounds.min.x + bounds.max.x) * 0.5),
                Float(bounds.max.y), Float((bounds.min.z + bounds.max.z) * 0.5))
            let point = roofNode.simdConvertPosition(centre, to: nil)
            let runtime = GroundVehicleRuntime(position: origin, model: model, seed: 11, vehicleID: "tear-test")
            let camera = controller.pointOfView(for: .free)
            camera.simdPosition = origin + SIMD3<Float>(7, 9, -11)
            camera.look(at: SCNVector3(point))
            let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
            renderer.scene = controller.scene; renderer.pointOfView = camera
            func frame(_ name: String) {
                let image = renderer.snapshot(atTime: 0, with: CGSize(width: 1000, height: 700), antialiasingMode: .multisampling4X)
                let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("bodywork-\(model.rawValue)-\(name).png"))
            }
            frame("before")
            let originalGeometry = roofNode.geometry!
            runtime.receive(ImpactReport(componentID: "body", obstacleID: UUID(), obstacleSource: "road-accident-fixture",
                material: .metalVehicle, acousticSurface: .metal, vehicleMaterial: .steel, impactEnergyJ: 2_000_000, normalClosingSpeed: 20,
                tangentialSpeed: 0, tier: .criticalImpact, damage: [], connectionDamage: [], contactPoint: point,
                contactNormal: SIMD3<Float>(0, 1, 0), appliedImpulse: 0, detachedPartMotions: []))
            let start = CACurrentMediaTime()
            _ = visual.update(runtime)
            print("BODYWORK: \(model), update \((CACurrentMediaTime() - start) * 1000)ms, roof \(roofNode.geometry!.name ?? "missing")")
            precondition(roofNode.geometry !== originalGeometry && roofNode.geometry!.name?.hasPrefix("bodywork.deformed") == true,
                "Both real USDZ models must receive local mesh damage")
            precondition(roofNode.parent?.isHidden == false, "The damaged roof must remain on the vehicle")
            let pristine = GroundVehicleVisual(model: model)
            var hasUnexpectedDamage = false
            pristine.rootNode.enumerateChildNodes { node, _ in
                hasUnexpectedDamage = hasUnexpectedDamage || node.geometry?.name?.hasPrefix("bodywork.deformed") == true
            }
            precondition(!hasUnexpectedDamage, "Damage must not mutate cached models or another vehicle")
            frame("after")
            visual.rootNode.removeFromParentNode()
        }

        controller.regenerateEnvironment(TerrainConfiguration(preset: .forest, mapScale: .x4,
            density: 0.03, seed: 51, safeSpawnRadius: 20))
        let trees = controller.scene.rootNode.childNode(withName: "environment.trees", recursively: true)!
        let original = trees.childNodes.first!, healthy = original.clone(), base = original.simdWorldPosition
        let explosion = InterceptWorldEffect(id: UUID(), runID: UUID(), impactID: UUID(), vehicleID: "test",
            kind: .explosion, position: base + SIMD3<Float>(0, 1.2, 0), startedAt: 0, lifetime: 3)
        controller.applyChargeEnvironmentImpact(explosion)
        let damageRoot = controller.scene.rootNode.childNode(withName: "environment.charge-damage", recursively: false)!
        precondition(original.parent == nil && !damageRoot.childNodes.isEmpty, "Nearby tree/ground must acquire physical visual damage")
        let count = damageRoot.childNodes.count
        controller.applyChargeEnvironmentImpact(explosion)
        precondition(damageRoot.childNodes.count == count, "A charge event must damage the environment exactly once")
        for _ in 0..<60 { controller.updateChargeEnvironmentDamage(deltaTime: 0.05) }
        let worldRecorder = MissionReplayRecorder(); worldRecorder.startSession()
        let snapshots = controller.captureReplayVisuals(recorder: worldRecorder, displayName: "probe")
        let treeSnapshot = snapshots.first { $0.role == "environment" && simd_distance($0.pose.position, base) < 0.25 }!
        precondition(simd_act(simd_quatf(vector: treeSnapshot.pose.rotation), SIMD3<Float>(0, 1, 0)).y < 0.3,
            "A strongly struck tree must fall, not just change colour")
        precondition(snapshots.contains { $0.id.hasPrefix("terrain-damage:") }, "Scorched/displaced soil must be recorded")
        precondition(controller.nearbyEnvironmentObstacles(near: base, radius: 20).contains { $0.source == "damaged_tree" },
            "Fallen trees must remain collision obstacles at their new pose")
        let scene = SCNScene(), replacementTrees = SCNNode(), replayPlayer = SCNNode()
        replacementTrees.name = "environment.trees"; replacementTrees.addChildNode(healthy)
        scene.rootNode.addChildNode(replacementTrees); scene.rootNode.addChildNode(replayPlayer)
        let environmentReplay = MissionReplayWorldVisuals()
        environmentReplay.load(assets: worldRecorder.currentSession!.visualAssets!, scene: scene, playerRoot: replayPlayer)
        environmentReplay.update(MissionReplayWorldSnapshot(nodes: [treeSnapshot], effects: []))
        precondition(healthy.isHidden && !environmentReplay.assetFailures, "Replay must replace the pristine environment tree")
        environmentReplay.update(MissionReplayWorldSnapshot(nodes: [], effects: []))
        precondition(!healthy.isHidden, "Backward seek must restore the undamaged environment")
        print("PASS: mesh rupture/dents, both USDZ models, independent materials, replay topology, trees/soil/collisions and reversible environment")
    }
}
