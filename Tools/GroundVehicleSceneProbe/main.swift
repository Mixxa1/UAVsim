import Foundation
import AppKit
import Metal
import SceneKit
import simd
import DroneUAVDemo

/// Links the actual app objects: these checks use its scene queries and actor/visual adapters,
/// rather than replacing the world with the always-supported flat closure in the physics probe.
@main
struct GroundVehicleSceneProbe {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--detonation") {
            _ = DetonationPresentationProbe.run(render: true)
            return
        }
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(value(), message)
        }
        let profile = LIPODroneModelRepository().defaultProfile
        let controller = DroneSceneController(initialProfile: profile)
        let start = SIMD2<Float>(0, -45)
        check(controller.supportSurfaceHeight(at: start, clearanceRadius: 0.3, maximumHeight: 0.7) == nil,
              "The original object-only query misses bare procedural terrain")
        check(controller.groundVehicleSurfaceHeight(at: start, clearanceRadius: 0.3, maximumHeight: 0.7) != nil,
              "Road vehicles must find the actual procedural ground")
        let plane = controller.scene.rootNode.childNode(withName: "groundPlane", recursively: true)!.geometry as! SCNPlane
        check(controller.groundVehicleSurfaceHeight(at: SIMD2<Float>(Float(plane.width) * 0.5 + 10, 0), clearanceRadius: 0.3,
            maximumHeight: 0.7) == nil, "The procedural ground must not extend beyond its geometry")
        check(controller.groundVehicleSurfaceHeight(at: start, clearanceRadius: 0.3,
            maximumHeight: -2) == nil, "The support query cannot lift a vehicle through a surface above it")

        for preset in TerrainPreset.allCases {
            controller.regenerateEnvironment(TerrainConfiguration(preset: preset, mapScale: .x4,
                density: 0.05, seed: 51, safeSpawnRadius: 100))
            check(controller.groundVehicleSurfaceHeight(at: start, clearanceRadius: 0.3,
                maximumHeight: 0.7)?.isFinite == true, "Bare ground must be usable on \(preset)")
        }
        controller.regenerateEnvironment(TerrainConfiguration(preset: .gridDemo, mapScale: .x4,
            density: 0, seed: 51, safeSpawnRadius: 100))
        let ground: (SIMD3<Float>, Float) -> Float = { point, radius in
            controller.groundVehicleSurfaceHeight(at: SIMD2<Float>(point.x, point.z), clearanceRadius: radius,
                maximumHeight: point.y + 0.7) ?? .nan
        }

        for model in GroundVehicleModel.allCases {
            for escort in [false, true] {
                let adapter = InterceptMissionScene(scene: controller.scene, showsCallsigns: false)
                let id = "test-\(model.rawValue)-\(escort)"
                let spawn = SIMD3<Float>(start.x, ground(SIMD3<Float>(start.x, 0, start.y), 0.3), start.y)
                let actor = adapter.makeGroundActor(id: id, model: model, position: spawn,
                    adapterProfile: profile, seed: 505)
                var mission = GroundVehicleMissionRuntime(escort: escort, difficulty: .easy,
                    timeLimit: 120, route: [SIMD2<Float>(0, -100)])
                for _ in 0..<60 {
                    _ = actor.stepGroundVehicle(deltaTime: 1.0 / 60.0, destination: start,
                        threat: nil, evasive: !escort, origin: .zero, areaRadius: 160, grip: 1,
                        obstacles: [], ground: ground)
                    mission.tick(deltaTime: 1.0 / 60.0, playerAirborne: false, playerLost: false,
                        carPosition: SIMD2<Float>(actor.state.position.x, actor.state.position.z),
                        carCondition: actor.snapshot.functionalState, distance: 40, inCamera: true, lineOfSight: true)
                }
                check(simd_distance(actor.state.position, spawn) < 0.05 && mission.elapsed == 0,
                      "Pre-flight setup holds the car and mission clock")
                var peakSpeed: Float = 0
                for step in 0..<900 {
                    let moving = step == 0 || mission.elapsed > 0
                    let destination = moving && mission.result == nil ? mission.destination
                        : SIMD2<Float>(actor.state.position.x, actor.state.position.z)
                    _ = actor.stepGroundVehicle(deltaTime: 1.0 / 60.0, destination: destination,
                        threat: escort ? nil : SIMD3<Float>(0, 20, 0), evasive: !escort,
                        origin: .zero, areaRadius: 160, grip: 1,
                        obstacles: controller.nearbyEnvironmentObstacles(from: actor.state.position,
                            to: actor.state.position, margin: 125), ground: ground)
                    peakSpeed = max(peakSpeed, simd_length(actor.state.velocity))
                    adapter.updateGroundWorld(actor, now: Double(step) / 60, deltaTime: 1.0 / 60.0,
                        ground: ground, wind: .zero)
                    mission.tick(deltaTime: 1.0 / 60.0, playerAirborne: true, playerLost: false,
                        carPosition: SIMD2<Float>(actor.state.position.x, actor.state.position.z),
                        carCondition: actor.snapshot.functionalState, distance: 40, inCamera: true, lineOfSight: true)
                }
                let travelled = simd_distance(actor.state.position, spawn)
                check(travelled > 25 && peakSpeed > 3,
                      "\(model) must drive after takeoff in \(escort ? "escort" : "pursuit"): \(travelled)m, \(peakSpeed)m/s")
                check(actor.snapshot.functionalState == .nominal, "Bare terrain cannot damage a car")
                let visual = controller.scene.rootNode.childNode(withName: id, recursively: true)!
                check(simd_distance(visual.simdWorldPosition, actor.state.position) < 0.001,
                      "The displayed car must follow its simulated position")
                if escort { check(mission.result == .arrived, "Escort must reach its route destination") }
                print("PASS: \(model.rawValue), \(escort ? "escort" : "pursuit"): \(travelled)m, peak \(peakSpeed)m/s")
                adapter.clear()
            }
        }

        // An imported road can be above or below zero. Its missing areas must stay missing,
        // even though the procedural ground node still exists behind the imported mesh.
        let floor: Float = -12
        let corners = [SIMD3<Float>(-100, floor, -100), SIMD3<Float>(100, floor, 100),
            SIMD3<Float>(100, floor, -100), SIMD3<Float>(-100, floor, -100),
            SIMD3<Float>(-100, floor, 100), SIMD3<Float>(100, floor, 100)]
        controller.setMeshCollision(MeshCollisionIndex(triangleCorners: corners))
        check(abs(ground(SIMD3<Float>(0, floor, 0), 0.3) - floor) < 0.001,
              "Imported road height must keep the world's vertical datum")
        check(!ground(SIMD3<Float>(150, floor, 0), 0.3).isFinite,
              "Missing imported terrain cannot become a phantom road")
        let importedCar = GroundVehicleRuntime(position: SIMD3<Float>(0, floor, 0), seed: 42)
        for _ in 0..<1200 {
            _ = importedCar.step(deltaTime: 1.0 / 60.0, destination: SIMD2<Float>(0, -140), threat: nil,
                evasive: false, origin: .zero, areaRadius: 180, grip: 1,
                obstacles: controller.nearbyEnvironmentObstacles(from: importedCar.state.position,
                    to: importedCar.state.position, margin: 125), ground: ground)
        }
        check(importedCar.state.position.z < -25 && importedCar.state.position.z > -100,
              "A car must drive on imported terrain and stop before its missing edge")
        check(abs(importedCar.state.position.y - floor) < 0.001,
              "Driving must not snap imported terrain to sea level")

        // The scene's mesh obstacle query must keep a facade separate from its road surface.
        let wall = [SIMD3<Float>(-9, floor, -35), SIMD3<Float>(9, floor + 8, -35),
            SIMD3<Float>(9, floor, -35), SIMD3<Float>(-9, floor, -35),
            SIMD3<Float>(-9, floor + 8, -35), SIMD3<Float>(9, floor + 8, -35)]
        controller.setMeshCollision(MeshCollisionIndex(triangleCorners: corners + wall))
        let detouringCar = GroundVehicleRuntime(position: SIMD3<Float>(0, floor, 0), seed: 42)
        var crossedWall = false
        for _ in 0..<3600 {
            _ = detouringCar.step(deltaTime: 1.0 / 60.0, destination: SIMD2<Float>(0, -70), threat: nil,
                evasive: false, origin: .zero, areaRadius: 180, grip: 1,
                obstacles: controller.nearbyEnvironmentObstacles(from: detouringCar.state.position,
                    to: detouringCar.state.position, margin: 125), ground: ground)
            let p = detouringCar.state.position
            crossedWall = crossedWall || (abs(p.z + 35) < 0.5 && abs(p.x) < 9)
        }
        check(!crossedWall, "A ground vehicle cannot drive through an imported facade")
        check(simd_distance(SIMD2<Float>(detouringCar.state.position.x, detouringCar.state.position.z),
            SIMD2<Float>(0, -70)) < 12, "The car must detour around the facade and reach its destination")
        check(detouringCar.damage.functionalState == .nominal, "Detouring must not damage the vehicle")

        // Interception uses a separate world step from pursuit/escort. Its car must use the
        // imported road's height even when the aircraft query falls back to zero.
        controller.setMeshCollision(MeshCollisionIndex(triangleCorners: corners))
        let adapter = InterceptMissionScene(scene: controller.scene, showsCallsigns: false)
        let carSpawn = SIMD3<Float>(20, floor, -10)
        let target = adapter.makeGroundActor(id: InterceptCallsign.target,
            model: GroundVehicleModel.allCases[0], position: carSpawn, adapterProfile: profile, seed: 42)
        let observer = adapter.makeActor(id: InterceptCallsign.observer, role: .observer, profile: profile,
            position: SIMD3<Float>(70, 40, 70), payload: nil, moduleShape: .ballast, seed: 42)
        var configuration = InterceptMissionConfiguration()
        configuration.targetKind = .groundVehicle
        configuration.moduleShape = .ballast
        let session = InterceptMissionSession(configuration: configuration, target: target,
            observer: observer, origin: SIMD3<Float>(0, floor, 0))
        var player = DroneState.initial
        player.position = SIMD3<Float>(-50, 35, 0)
        player.physicalState = .airborne
        var graph = observer.graph
        for _ in 0..<600 {
            let previous = player
            _ = session.simulate(deltaTime: 1.0 / 60.0, playerPrevious: previous,
                player: &player, playerGraph: &graph, playerContacts: .empty, playerClass: .multirotor,
                weather: .normal, wind: .zero, ground: { _, _ in 0 },
                obstacles: { a, b, margin in controller.nearbyEnvironmentObstacles(from: a, to: b, margin: margin) },
                groundVehicleSurface: ground)
        }
        check(simd_distance(target.state.position, carSpawn) > 15, "Interception's car target must also drive")
        check(abs(target.state.position.y - floor) < 0.001,
              "Interception's car must use its own road query, not the aircraft ground fallback")
        adapter.clear()
        controller.setMeshCollision(nil)
        check(ground(SIMD3<Float>(0, 0, 0), 0.3).isFinite, "Returning to a standard map restores ground")
        print("PASS: \(checks) production-scene ground/movement checks")

        // Damage uses the same production scene adapter and actual USDZ geometry as missions.
        let flat: (SIMD3<Float>, Float) -> Float = { _, _ in 0 }
        for model in GroundVehicleModel.allCases {
            let scene = SCNScene()
            scene.background.contents = NSColor(calibratedRed: 0.29, green: 0.34, blue: 0.39, alpha: 1)
            let floor = SCNNode(geometry: SCNPlane(width: 100, height: 100))
            floor.eulerAngles.x = -.pi / 2
            floor.geometry?.firstMaterial?.diffuse.contents = NSColor(white: 0.38, alpha: 1)
            scene.rootNode.addChildNode(floor)
            let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.fieldOfView = 44
            camera.simdPosition = SIMD3<Float>(13, 9, -17)
            camera.look(at: SCNVector3(0, 3, 0)); scene.rootNode.addChildNode(camera)
            let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
            ambient.light?.intensity = 700; scene.rootNode.addChildNode(ambient)
            let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional
            sun.light?.intensity = 900; sun.eulerAngles = SCNVector3(-0.8, -0.6, 0)
            sun.light?.castsShadow = true; sun.light?.shadowColor = NSColor(white: 0, alpha: 0.45)
            scene.rootNode.addChildNode(sun)
            let world = InterceptMissionScene(scene: scene, showsCallsigns: false)
            let car = world.makeGroundActor(id: "damaged-car", model: model, position: .zero,
                adapterProfile: profile, seed: 44)
            let recorder = MissionReplayRecorder(); recorder.startSession()
            let before = MissionReplayWorldSnapshot(nodes: world.captureReplayVisuals(actors: [car], recorder: recorder), effects: [])
            let carNode = scene.rootNode.childNode(withName: "damaged-car", recursively: true)!
            let cab = carNode.childNode(withName: "panel-CabLower_01", recursively: true)!
            let cabHeight = cab.simdWorldPosition.y
            let renderer = CommandLine.arguments.contains("--render") ? MTLCreateSystemDefaultDevice().map { SCNRenderer(device: $0, options: nil) } : nil
            renderer?.scene = scene; renderer?.pointOfView = camera
            func render(_ name: String, time: Double) {
                guard let renderer else { return }
                let image = renderer.snapshot(atTime: time, with: CGSize(width: 1100, height: 800), antialiasingMode: .multisampling4X)
                if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    let folder = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                    try! png.write(to: folder.appendingPathComponent("\(model.rawValue)-\(name).png"))
                }
            }
            render("intact", time: 0)
            let detonation = ChargeDetonation(position: GroundVehiclePart.engine.position(in: car.groundVehicle!.profile))
            car.receiveDetonation(detonation, directHit: true, now: 0)
            world.updateGroundWorld(car, now: 0, deltaTime: 0.001, ground: flat, wind: SIMD3<Float>(1, 0, 0))
            let explosion = WorldDamageEffectVisual(kind: .explosion)
            scene.rootNode.addChildNode(explosion.node)
            explosion.node.simdPosition = SIMD3<Float>(-1.45, 1.5, -4.25)
            explosion.update(age: 0.12, lifetime: ChargeDetonation.effectLifetime, normal: SIMD3<Float>(0, 1, 0))
            render("burst", time: 0.12); explosion.node.removeFromParentNode()
            check(world.hasReplayAftermath, "Burning wreckage keeps the recorder running through aftermath")
            var charred: MissionReplayWorldSnapshot?
            for step in 1...2100 {
                _ = car.stepGroundVehicle(deltaTime: 0.05, destination: .zero, threat: nil, evasive: false,
                    origin: .zero, areaRadius: 100, grip: 1, obstacles: [], ground: flat)
                world.updateGroundWorld(car, now: Double(step) * 0.05, deltaTime: 0.05, ground: flat, wind: SIMD3<Float>(1, 0, 0))
                if step == 160 {
                    render("burning", time: 8)
                    check(cab.simdWorldPosition.y < cabHeight - 0.15, "Losing the front wheels lowers the suspended cab")
                    let rearAxle = carNode.childNode(withName: "wheel-mount-wheelRearLeft", recursively: true)!
                    check(abs(rearAxle.simdWorldPosition.y - 0.642) < 0.04,
                          "Surviving wheels retain ground support while the damaged chassis sags")
                    let nodes = world.captureReplayVisuals(actors: [car], recorder: recorder)
                    charred = MissionReplayWorldSnapshot(nodes: nodes, effects: car.groundVehicle!.effects.map {
                        MissionReplayEffectSnapshot(id: $0.id, kind: $0.kind.rawValue, position: $0.position,
                            normal: $0.normal, age: 8 - $0.startedAt, lifetime: $0.lifetime, scale: $0.scale, wind: SIMD3<Float>(1, 0, 0))
                    })
                    let debris = nodes.filter { $0.id.hasPrefix("intercept-debris:") }
                    check(debris.count > 2, "The actual car sheds local panels as well as wheels")
                    check(nodes.contains { $0.id.hasPrefix("vehicle-scorch:") }, "Scorched road is captured as actual replay geometry")
                    let pieces = scene.rootNode.childNode(withName: "intercept-mission-world", recursively: true)!.childNodes
                        .filter { $0.name?.hasPrefix("wheel-mount-") == true || $0.name?.hasPrefix("panel-") == true }
                    for node in pieces {
                        let bounds = node.boundingBox
                        var low: Float = .greatestFiniteMagnitude
                        for x in [bounds.min.x, bounds.max.x] { for y in [bounds.min.y, bounds.max.y] { for z in [bounds.min.z, bounds.max.z] {
                            low = min(low, node.simdConvertPosition(SIMD3<Float>(Float(x), Float(y), Float(z)), to: nil).y)
                        } } }
                        check(low >= -0.002 && low < 0.04, "Settled wheel/panel rests on the ground, not buried in it: \(low)")
                    }
                }
                if step == 1000 { render("smouldering", time: 50) }
            }
            render("aftermath", time: 105)
            check(!world.hasReplayAftermath, "Persistent ash and settled debris do not record forever after fire expires")
            check(world.captureReplayVisuals(actors: [car], recorder: recorder).filter { $0.id.hasPrefix("intercept-debris:") }.count
                == charred!.nodes.filter { $0.id.hasPrefix("intercept-debris:") }.count, "Settled car wreckage stays after the smoke disappears")
            check(scene.rootNode.childNode(withName: "vehicle.scorched-ground", recursively: true) != nil,
                  "Burnt ground remains after smoke clears")
            let replayScene = SCNScene(), replayRoot = SCNNode(), replay = MissionReplayWorldVisuals()
            replayScene.rootNode.addChildNode(replayRoot)
            replay.load(assets: recorder.currentSession!.visualAssets!, scene: replayScene, playerRoot: replayRoot)
            replay.update(charred!)
            check(!replay.assetFailures && replay.snapshots.count > 3, "Replay restores the real wreck, debris and scorched road")
            let effect = charred!.effects.first { $0.kind == "fire" }!
            let flame = replayScene.rootNode.childNode(withName: "replay.effect.\(effect.id)", recursively: true)!
            let poses = flame.childNodes.map(\.simdTransform)
            replay.update(charred!)
            check(zip(flame.childNodes.map(\.simdTransform), poses).allSatisfy { simd_equal($0.0, $0.1) },
                  "Pausing a recorded car fire freezes its flame sprites")
            replay.update(before)
            check(replayScene.rootNode.childNode(withName: "vehicle.scorched-ground", recursively: true) == nil,
                  "Seeking before the hit removes future ash and debris")
            world.clear()
            check(!world.hasReplayAftermath, "Restart clears the damage simulation as well as visible geometry")
            check(scene.rootNode.childNode(withName: "intercept-mission-world", recursively: true) == nil,
                  "Restart removes all vehicle aftermath")
        }
        let noRoad = WorldDamageEffectVisual.makeScorch(centre: .zero, yaw: 0, ground: { _, _ in .nan })
        check(noRoad == nil, "Scorch cannot invent ground across missing imported mesh")
        let slope: (SIMD3<Float>, Float) -> Float = { point, _ in -12 + point.x * 0.15 }
        let mark = WorldDamageEffectVisual.makeScorch(centre: SIMD3<Float>(0, -12, 0), yaw: 0.3, ground: slope)!
        check(mark.geometry!.elements[0].primitiveCount > 0 && mark.simdPosition.y == -12,
              "Burnt-ground geometry follows an imported slope at its actual elevation")
        let pose = MissionReplayPose(position: .zero, rotation: simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0)).vector,
                                     scale: SIMD3<Float>(repeating: 1))
        var startWheel = MissionReplayVisualSnapshot(id: "wheel", assetID: "wheel", role: nil, displayName: nil,
            pose: pose, opacity: 1, isHidden: false, hiddenNodePaths: [], absentNodeNames: [], camera: nil)
        startWheel.nodeStates = ["/spin": MissionReplayNodeState(pose: pose, opacity: 1, wheelRoll: 5)]
        var endWheel = startWheel; endWheel.nodeStates!["/spin"]!.wheelRoll = 9
        let midpoint = MissionReplayWorldSnapshot.interpolated(.init(nodes: [startWheel], effects: []),
            .init(nodes: [endWheel], effects: []), fraction: 0.5)!.nodes[0].nodeStates!["/spin"]!
        check(midpoint.wheelRoll == 7 && abs(simd_dot(midpoint.pose.rotation,
            simd_quatf(angle: 7, axis: SIMD3<Float>(1, 0, 0)).vector)) > 0.999,
            "Fast recorded wheels interpolate their forward revolutions across the quaternion wrap")
        let oldStateJSON = try! JSONEncoder().encode(MissionReplayNodeState(pose: pose, opacity: 1))
        let oldState = try! JSONDecoder().decode(MissionReplayNodeState.self, from: oldStateJSON)
        check(oldState.wheelRoll == nil && oldState.materialTint == nil, "Old node-state records need no wheel/tint fields")
        let oldEffect = MissionReplayEffectSnapshot(id: UUID(), kind: "smoke", position: .zero,
            normal: SIMD3<Float>(0, 1, 0), age: 1, lifetime: 10)
        let restoredOldEffect = try! JSONDecoder().decode(MissionReplayEffectSnapshot.self, from: JSONEncoder().encode(oldEffect))
        check(restoredOldEffect.scale == nil && restoredOldEffect.wind == nil, "Old effect records need no scale/wind fields")

        // Exercise the actual contact -> session -> scene path, without a manually placed blast.
        let hitScene = SCNScene(); hitScene.background.contents = NSColor(calibratedWhite: 0.06, alpha: 1)
        let hitWorld = InterceptMissionScene(scene: hitScene, showsCallsigns: false)
        let hitCar = hitWorld.makeGroundActor(id: InterceptCallsign.target, model: .cabover,
            position: .zero, adapterProfile: profile, seed: 9)
        let hitObserver = hitWorld.makeActor(id: InterceptCallsign.observer, role: .observer, profile: profile,
            position: SIMD3<Float>(70, 40, 70), payload: nil, moduleShape: .ballast, seed: 9)
        var hitConfiguration = InterceptMissionConfiguration()
        hitConfiguration.targetKind = .groundVehicle; hitConfiguration.moduleShape = .charge
        let hitSession = InterceptMissionSession(configuration: hitConfiguration, target: hitCar,
            observer: hitObserver, origin: .zero)
        let hitCamera = SCNNode(); hitCamera.camera = SCNCamera(); hitCamera.camera?.fieldOfView = 44
        hitCamera.simdPosition = SIMD3<Float>(13, 9, -17); hitCamera.look(at: SCNVector3(0, 3, 0))
        hitScene.rootNode.addChildNode(hitCamera)
        let hitLight = SCNNode(); hitLight.light = SCNLight(); hitLight.light?.type = .ambient
        hitLight.light?.intensity = 900; hitScene.rootNode.addChildNode(hitLight)
        let hitRenderer = CommandLine.arguments.contains("--render") ? MTLCreateSystemDefaultDevice().map { SCNRenderer(device: $0, options: nil) } : nil
        hitRenderer?.scene = hitScene; hitRenderer?.pointOfView = hitCamera
        func renderContact(_ name: String) -> Int {
            guard let renderer = hitRenderer else { return 0 }
            let image = renderer.snapshot(atTime: hitSession.worldTime, with: CGSize(width: 1100, height: 800), antialiasingMode: .multisampling4X)
            var hotPixels = 0
            if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                    .appendingPathComponent("contact-\(name).png"))
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                        if let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           colour.redComponent > 0.75, colour.greenComponent > 0.5, colour.blueComponent > 0.2 {
                            hotPixels += 1
                        }
                    }
                }
            }
            return hotPixels
        }
        let hotBefore = renderContact("before")
        var hitPrevious = DroneState.initial; hitPrevious.physicalState = .airborne
        hitPrevious.position = SIMD3<Float>(0, 4.5, -2.7); hitPrevious.velocity = SIMD3<Float>(0, -40, 0)
        var hitPlayer = hitPrevious; hitPlayer.position.y = 2.5
        var hitGraph = hitObserver.graph
        let hitContacts = VehicleContactProfile(spheres: [.init(componentID: "frame", offset: .zero, radius: 0.3)], boundingRadius: 0.3)
        _ = hitSession.simulate(deltaTime: 0.05, playerPrevious: hitPrevious, player: &hitPlayer,
            playerGraph: &hitGraph, playerContacts: hitContacts, playerClass: .multirotor,
            weather: .normal, wind: .zero, ground: flat, obstacles: { _, _, _ in [] }, groundVehicleSurface: flat)
        let blast = hitSession.effects.effects.first { $0.kind == .explosion }!
        check(abs(blast.startedAt - hitSession.worldTime) < 0.001, "Detonation begins in the first contact tick")
        hitWorld.update(hitSession, deltaTime: 0.05, ground: flat)
        print("CONTACT BLAST: \(blast.position), normal \(blast.normal), age \(hitSession.worldTime - blast.startedAt)")
        let hotOnContact = renderContact("first-frame")
        if hitRenderer != nil {
            check(hotOnContact > hotBefore + 60, "The actual roof contact has a visible flash in its first rendered frame")
            let cover = SCNNode(geometry: SCNBox(width: 16, height: 12, length: 1, chamferRadius: 0))
            cover.geometry?.firstMaterial?.lightingModel = .constant
            cover.geometry?.firstMaterial?.diffuse.contents = NSColor(white: 0.02, alpha: 1)
            cover.simdPosition = SIMD3<Float>(0, 4, -7); hitScene.rootNode.addChildNode(cover)
            check(renderContact("occluded-first-frame") < hotBefore + 10,
                "Unrelated scenery still occludes the contact flash")
            cover.removeFromParentNode()
        }
        for step in 1...4 {
            let previous = hitPlayer
            _ = hitSession.simulate(deltaTime: 0.05, playerPrevious: previous, player: &hitPlayer,
                playerGraph: &hitGraph, playerContacts: .empty, playerClass: .multirotor,
                weather: .normal, wind: .zero, ground: flat, obstacles: { _, _, _ in [] }, groundVehicleSurface: flat)
            hitWorld.update(hitSession, deltaTime: 0.05, ground: flat)
            if step == 2 { _ = renderContact("100ms") }
        }
        hitWorld.clear()

        controller.regenerateEnvironment(TerrainConfiguration(preset: .forest, mapScale: .x4,
            density: 0.6, seed: 51, safeSpawnRadius: 12))
        let trees = controller.nearbyEnvironmentObstacles(from: .zero, to: .zero, margin: 120)
            .filter { $0.source == "tree.trunk" }
        check(!trees.isEmpty, "A populated forest exposes actual trunks to the ground driver")
        var forestHits = 0
        for seed: UInt64 in 1...8 {
            let car = GroundVehicleRuntime(position: .zero, seed: seed)
            var travelled: Float = 0
            for _ in 0..<1200 {
                let previous = car.state.position
                forestHits += car.step(deltaTime: 0.05, destination: nil, threat: nil, evasive: false,
                    origin: .zero, areaRadius: 150, grip: 1,
                    obstacles: controller.nearbyEnvironmentObstacles(from: car.state.position, to: car.state.position, margin: 125),
                    ground: ground).count
                travelled += simd_distance(previous, car.state.position)
            }
            check(travelled > 30, "A forest driver must make progress rather than remain parked: \(travelled)m")
            check(car.damage.functionalState == .nominal, "Normal forest routing preserves the car")
            print("FOREST DRIVER: seed \(seed), \(car.state.position), \(car.damage.functionalState), travelled \(travelled)m")
        }
        print("FOREST CONTACTS: \(forestHits)")
        check(forestHits == 0, "Ordinary driving in a populated forest cannot hit known trunks")
        print("PASS: \(checks) production-scene movement/damage/replay checks")
    }
}
