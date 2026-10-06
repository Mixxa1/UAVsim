import AppKit
import Foundation
import Metal
import SceneKit
import simd
import DroneUAVDemo

/// Exercises daylight, the mission's real observer camera and the source-loss ladder together.
/// The first invocation runs before the flame atlas or damage shaders have been used.
struct DetonationPresentationProbe {
    @MainActor static func run(render: Bool) -> Int {
        var checks = 0, failures: [String] = []
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            if !value() { failures.append(message); print("FAIL: \(message)") }
        }
        let profile = LIPODroneModelRepository().defaultProfile
        let controller = DroneSceneController(initialProfile: profile)
        controller.regenerateEnvironment(TerrainConfiguration(preset: .gridDemo, mapScale: .x4,
            density: 0, seed: 51, safeSpawnRadius: 100))
        let flat: (SIMD3<Float>, Float) -> Float = { _, _ in 0 }
        let clean = RFVideoPresentationState.clean(mode: .digital, nominalBitrateBPS: 1_000_000)
        let output = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for model in GroundVehicleModel.allCases {
            let world = InterceptMissionScene(scene: controller.scene, showsCallsigns: false)
            let origin = SIMD3<Float>(0, 0, -65)
            let car = world.makeGroundActor(id: InterceptCallsign.target, model: model,
                position: origin, adapterProfile: profile, seed: 9)
            var configuration = InterceptMissionConfiguration()
            configuration.targetKind = .groundVehicle; configuration.moduleShape = .charge
            let observer = world.makeActor(id: InterceptCallsign.observer, role: .observer, profile: profile,
                position: configuration.observerOffset, payload: nil, moduleShape: .ballast, seed: 9)
            let session = InterceptMissionSession(configuration: configuration, target: car,
                observer: observer, origin: .zero)
            for _ in 0..<120 { world.update(session, deltaTime: 1.0 / 60, ground: flat) }
            let observerCamera = world.camera(for: observer.id)!
            let external = controller.pointOfView(for: .free)
            external.simdPosition = origin + SIMD3<Float>(16, 10, -18)
            external.look(at: SCNVector3(origin + SIMD3<Float>(0, 2, 0)))
            let renderer = render ? MTLCreateSystemDefaultDevice().map { SCNRenderer(device: $0, options: nil) } : nil
            renderer?.scene = controller.scene
            if let renderer, let preparation = controller.scene.rootNode
                .childNode(withName: "intercept-mission-world", recursively: false)?
                .childNode(withName: WorldDamageEffectVisual.preparationNodeName, recursively: false) {
                check(preparation.isHidden && renderer.prepare(preparation, shouldAbortBlock: nil),
                    "Damage textures and shaders are prepared before flight, without a visible effect")
            }
            func frame(_ label: String, camera: SCNNode) -> Int {
                guard let renderer else { return 0 }
                renderer.pointOfView = camera
                let size = CGSize(width: 1280, height: 800)
                let renderStartedAt = CACurrentMediaTime()
                let image = renderer.snapshot(atTime: session.worldTime, with: size, antialiasingMode: .multisampling4X)
                let renderMS = (CACurrentMediaTime() - renderStartedAt) * 1000
                let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try! bitmap.representation(using: .png, properties: [:])!.write(to:
                    output.appendingPathComponent("detonation-\(model.rawValue)-\(label).png"))
                var effects: [SCNNode] = []
                controller.scene.rootNode.enumerateChildNodes { node, _ in
                    if node.name?.hasPrefix("effect-") == true { effects.append(node) }
                }
                SCNTransaction.begin(); SCNTransaction.disableActions = true
                effects.forEach { $0.isHidden = true }; SCNTransaction.commit()
                let without = renderer.snapshot(atTime: session.worldTime, with: size, antialiasingMode: .multisampling4X)
                let comparison = NSBitmapImageRep(data: without.tiffRepresentation!)!
                SCNTransaction.begin(); SCNTransaction.disableActions = true
                effects.forEach { $0.isHidden = false }; SCNTransaction.commit()
                var changed = 0
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                        let a = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                        let b = comparison.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                        if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                            + abs(a.blueComponent - b.blueComponent) > 0.18 { changed += 1 }
                    }
                }
                print("PRESENTATION: \(model), \(label), age \(session.worldTime), changed \(changed), render \(renderMS)ms")
                return changed
            }
            _ = frame("before-observer", camera: observerCamera)
            var previous = DroneState.initial; previous.physicalState = .airborne
            previous.position = origin + SIMD3<Float>(0, 4.5, -2.7); previous.velocity = SIMD3<Float>(0, -40, 0)
            var player = previous; player.position.y -= 2
            var graph = observer.graph
            let contacts = VehicleContactProfile(spheres: [.init(componentID: "frame", offset: .zero, radius: 0.3)], boundingRadius: 0.3)
            _ = session.simulate(deltaTime: 0.05, playerPrevious: previous, player: &player,
                playerGraph: &graph, playerContacts: contacts, playerClass: .multirotor,
                weather: .normal, wind: .zero, ground: flat, obstacles: { _, _, _ in [] }, groundVehicleSurface: flat)
            func assess() {
                session.observation.register(InterceptObservationSource(vehicleID: InterceptCallsign.attacker,
                    role: .attacker, position: player.position, orientation: player.attitudeQuat, video: clean,
                    hasLineOfSight: true, cameraFunctional: InterceptRFDamageAdapter.cameraFactor(graph: graph, failures: .init()) > 0.05))
                session.observation.register(InterceptObservationSource(vehicleID: observer.id, role: .observer,
                    position: observerCamera.simdWorldPosition, orientation: observerCamera.simdWorldOrientation,
                    video: clean, hasLineOfSight: true, cameraFunctional: true))
                session.assess(deltaTime: 0.05, player: player, graph: graph, targetVisible: true)
            }
            assess()
            let start = CACurrentMediaTime()
            world.update(session, deltaTime: 0.05, ground: flat)
            print("FIRST UPDATE: \(model) \((CACurrentMediaTime() - start) * 1000)ms")
            check(session.observation.activeVehicleID == observer.id,
                "A destroyed charge carrier hands off to a valid observer in the contact tick")
            check(car.groundVehicle!.effects.contains { $0.kind == .fire },
                "A severe roof detonation has a visible local aftermath even without an engine fire")
            let first = frame("contact-observer", camera: observerCamera)
            _ = frame("contact-external", camera: external)
            if renderer != nil { check(first > 60, "The contact burst is visible from the native daylight observer camera") }
            let impactTime = session.worldTime
            func countDetonations(_ events: [InterceptMissionEvent]) -> Int {
                events.filter { event in
                    if case .effect(let effect) = event.kind { return effect.kind == .explosion }
                    return false
                }.count
            }
            var detonationEvents = countDetonations(session.drainEvents())
            for step in 1...180 {
                previous = player
                _ = session.simulate(deltaTime: 0.05, playerPrevious: previous, player: &player,
                    playerGraph: &graph, playerContacts: .empty, playerClass: .multirotor,
                    weather: .normal, wind: .zero, ground: flat, obstacles: { _, _, _ in [] }, groundVehicleSurface: flat)
                assess(); world.update(session, deltaTime: 0.05, ground: flat)
                detonationEvents += countDetonations(session.drainEvents())
                if [2, 5, 10, 20, 40, 80, 160].contains(step) {
                    let visible = frame("\(step * 50)ms-observer", camera: observerCamera)
                    _ = frame("\(step * 50)ms-external", camera: external)
                    if renderer != nil && step <= 80 {
                        check(visible > 30, "A visible aftermath survives \(Float(step) * 0.05)s in the actual observer feed")
                    }
                }
            }
            check(detonationEvents == 1 && session.worldTime > impactTime + ChargeDetonation.effectLifetime,
                "Exactly one detonation is logged through the whole aftermath")
            check(!session.effects.effects.contains { $0.kind == .explosion },
                "The short burst expires rather than spawning again after the camera handoff")
            world.clear()
        }
        precondition(failures.isEmpty, failures.joined(separator: "\n"))
        print("PASS: \(checks) daylight detonation / camera-handoff checks")
        return checks
    }
}
