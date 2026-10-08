import AppKit
import Foundation
import ImageIO
import Metal
import SceneKit
import simd
import DroneUAVDemo

/// Exercises daylight, the mission's real observer camera and the source-loss ladder together.
/// The first invocation runs before the flame atlas or damage shaders have been used.
struct DetonationPresentationProbe {
    /// Runs the app's actual tick, including damage, camera handoff, RF mapping and presentation.
    /// Only the player's flight integration is scripted so contact is repeatable. No window or
    /// application lifecycle is started; a native Metal renderer records the delivered frames.
    @MainActor static func runLiveTick() {
        let checksPilotFeed = CommandLine.arguments.contains("--live-feed-detonation")
        let repository = LIPODroneModelRepository()
        let profile = checksPilotFeed ? repository.allProfiles.first { $0.id == "fpv-racer-5" }! : repository.defaultProfile
        let physics = ApproachPhysics()
        var configuration = InterceptMissionConfiguration()
        configuration.moduleShape = .charge
        configuration.observerProfileID = repository.defaultProfile.id
        let context = MissionScenarioConfiguration(parameters: MissionScenarioParameters(
            kind: .attachedPayloadIntercept, terrain: .gridDemo, terrainDensity: .sparse,
            difficulty: .easy, seed: 51), selectedUAVProfileID: profile.id,
            payloadType: .cargoBox, interception: configuration)
        let output = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let replayLibrary = ReplayLibraryViewModel(storage: MissionReplayStorageService(
            directory: output.appendingPathComponent("test-replays")), settingsStore: MissionReplaySettingsStore(
                defaults: UserDefaults(suiteName: "uavsim-vfx-probe")!))
        let vm = DroneSimulationViewModel(physicsEngine: physics, projectStorage: ProbeProjectStorage(), initialProjectID: "vfx-probe",
            initialDroneProfile: profile, simulationRunMode: .lanHostPilot, missionScenarioContext: context,
            replayLibraryViewModel: replayLibrary)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        let targetCamera = vm.scene.rootNode.childNode(withName: "\(InterceptCallsign.target)-camera", recursively: true)!
        var car = targetCamera
        while car.parent?.name != "intercept-mission-world" { car = car.parent! }
        physics.targetPosition = { car.simdWorldPosition }
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = vm.scene
        vm.setCameraMode(checksPilotFeed ? .fpv : .free)
        let external = vm.activeCameraNode
        let origin = car.simdWorldPosition
        if !checksPilotFeed {
            external.simdPosition = origin + SIMD3<Float>(16, 10, -18)
            external.look(at: SCNVector3(origin + SIMD3<Float>(0, 2, 0)))
        }
        renderer.pointOfView = external
        WorldDamageEffectVisual.prepareRenderPipelines(device: renderer.device!, antialiasing: .none)
        let prep = vm.scene.rootNode.childNode(withName: "intercept-mission-world", recursively: false)!
            .childNode(withName: WorldDamageEffectVisual.preparationNodeName, recursively: false)!
        precondition(renderer.prepare(prep, shouldAbortBlock: nil))
        _ = renderer.snapshot(atTime: 0, with: CGSize(width: 960, height: 600), antialiasingMode: .none)
        var contactStep: Int?
        for step in 0..<45 {
            let start = CACurrentMediaTime()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            let tickMS = (CACurrentMediaTime() - start) * 1000
            if vm.interceptHUD.payloadState == .consumed, contactStep == nil {
                contactStep = step
                print("LIVE CONTACT: tick=\(step), work=\(tickMS)ms, source=\(vm.interceptHUD.sourceID), video=\(vm.digitalVideoParameters)")
                var hasBurst = false
                vm.scene.rootNode.enumerateChildNodes { node, _ in
                    if node.name?.hasPrefix("effect-") == true && node.childNodes.contains(where: {
                        $0.geometry?.firstMaterial?.name == "HoudiniBurst"
                    }) { hasBurst = true }
                }
                precondition(hasBurst, "Contact tick must already publish its flash")
                precondition(vm.interceptHUD.sourceID == InterceptCallsign.observer,
                    "Full app tick must hand off in the contact frame")
                if checksPilotFeed {
                    precondition(vm.activeCameraNode.name == "\(InterceptCallsign.observer)-camera",
                        "Pilot view must immediately render the observer's actual camera")
                    let observerRF = RFCompatibilityPreset.make(for: repository.defaultProfile).logicalLinks.video!
                    precondition(vm.activeFPVVideoMode == .digital && vm.activeVideoLinkPreset == observerRF.videoLinkPreset,
                        "Observer decoder must use its transmitter, not the player's analog link")
                    precondition(!vm.digitalVideoParameters.requiresPostProcessing,
                        "A healthy observer must not inherit video damage from the carrier")
                }
            }
            if step < 12 || step % 10 == 0 {
                print("LIVE TICK: \(step) \(tickMS)ms, payload=\(vm.interceptHUD.payloadState), source=\(vm.interceptHUD.sourceID)")
            }
            if let contactStep, step < contactStep + 6 || step % 10 == 0 {
                if checksPilotFeed { renderer.pointOfView = vm.activeCameraNode }
                let image = renderer.snapshot(atTime: Double(step) / 60, with: CGSize(width: 960, height: 600), antialiasingMode: .none)
                let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
                try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("live-\(step).png"))
                print("LIVE FRAME: \(step), work=\((CACurrentMediaTime()-start)*1000)ms")
                if checksPilotFeed && step == contactStep {
                    let projected = renderer.projectPoint(SCNVector3(car.simdWorldPosition + SIMD3<Float>(0, 1.7, 0)))
                    precondition(projected.z > 0 && projected.z < 1 && projected.x > 0 && projected.x < 960
                        && projected.y > 0 && projected.y < 600,
                        "The observer must already see the vehicle in the first contact frame")
                    var effects: [SCNNode] = []
                    vm.scene.rootNode.enumerateChildNodes { node, _ in
                        if node.name?.hasPrefix("effect-") == true { effects.append(node) }
                    }
                    SCNTransaction.begin(); SCNTransaction.disableActions = true
                    effects.forEach { $0.isHidden = true }; SCNTransaction.commit()
                    let without = renderer.snapshot(atTime: Double(step) / 60, with: CGSize(width: 960, height: 600), antialiasingMode: .none)
                    let comparison = NSBitmapImageRep(data: without.tiffRepresentation!)!
                    SCNTransaction.begin(); SCNTransaction.disableActions = true
                    effects.forEach { $0.isHidden = false }; SCNTransaction.commit()
                    var changed = 0
                    for y in stride(from: 0, to: 600, by: 2) {
                        for x in stride(from: 0, to: 960, by: 2) {
                            let a = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                            let b = comparison.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                            if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
                                + abs(a.blueComponent - b.blueComponent) > 0.18 { changed += 1 }
                        }
                    }
                    print("LIVE CONTACT PIXELS: \(changed), vehicle at \(projected)")
                    precondition(changed > 30, "The first delivered observer frame must show the contact flash")
                }
            }
        }
        precondition(contactStep != nil, "Scripted approach must contact the vehicle")
        vm.stopRuntimeForExit()
        let summary = replayLibrary.summaries.first!
        let saved = replayLibrary.loadSession(id: summary.id)!
        let assetIDs = Set(saved.frames.flatMap { $0.world?.nodes.map(\.assetID) ?? [] })
        precondition(assetIDs.allSatisfy { saved.visualAssets?[$0] != nil },
            "Every frame/debris asset must be resolved before the final recording is published")
        precondition(saved.frames.contains { $0.world?.effects.contains { $0.kind == "explosion" } == true },
            "Background result checkpoint/final save must retain the contact effect")
        precondition(saved.frames.last!.world!.nodes.contains {
            $0.id.hasPrefix("intercept-debris:") || $0.id.hasPrefix("player-debris:")
        },
            "The ordered final save must include the later aftermath")
        precondition(saved.frames.last!.world!.nodes.contains { $0.id == InterceptCallsign.target },
            "The intercepted aircraft must be in the final recording")
        let replayScene = SCNScene(), replayPlayer = SCNNode()
        replayScene.rootNode.addChildNode(replayPlayer)
        let replayWorld = MissionReplayWorldVisuals()
        replayWorld.load(assets: saved.visualAssets!, scene: replayScene, playerRoot: replayPlayer)
        replayWorld.update(saved.frames.last!.world!)
        precondition(!replayWorld.assetFailures && replayWorld.node(for: InterceptCallsign.target) != nil,
            "The saved deferred geometry must reconstruct the vehicle and detached parts")
        precondition(replayLibrary.selectedReport?.summary.frameCount == saved.frames.count,
            "The selected report must refresh from its earlier checkpoint to the final recording")
        print("PASS: full application collision tick \(checksPilotFeed ? "with pilot video handoff" : "with external view")")
    }

    @MainActor static func runPersistence() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vfx-replay-writes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = MissionReplayStorageService(directory: directory)
        let library = ReplayLibraryViewModel(storage: storage,
            settingsStore: MissionReplaySettingsStore(defaults: UserDefaults(suiteName: "uavsim-vfx-probe")!))
        library.retentionPolicy = MissionReplayRetentionPolicy(isAutoDeleteEnabled: false, maxStoredReplayCount: 3)
        let recorder = MissionReplayRecorder(archivesVisualAssetsInBackground: true)
        recorder.startSession()
        let live = SCNNode(geometry: SCNBox(width: 1, height: 2, length: 3, chamferRadius: 0))
        live.geometry!.firstMaterial!.multiply.contents = NSColor.white
        live.setValue(NSMutableDictionary(dictionary: ["wheelRoll": 0.0]), forKey: "userData")
        let snapshot = MissionReplayVisualCapture.snapshot(id: "fixture", node: live, recorder: recorder)
        (live.geometry as! SCNBox).height = 9
        live.geometry!.firstMaterial!.multiply.contents = NSColor.red
        (live.value(forKey: "userData") as! NSMutableDictionary)["wheelRoll"] = 9.0
        let frozenData = recorder.visualAssetArchives[snapshot.assetID]!.resolvedData()!
        let frozen = try! NSKeyedUnarchiver.unarchivedObject(ofClass: SCNNode.self, from: frozenData)!
        precondition((frozen.geometry as! SCNBox).height == 2,
            "Deferred archives must freeze geometry at capture, before later live damage")
        let tint = (frozen.geometry!.firstMaterial!.multiply.contents as! NSColor).usingColorSpace(.deviceRGB)!
        precondition(tint.greenComponent > 0.99 && tint.blueComponent > 0.99,
            "Deferred material tint must not share mutable wrappers with the vehicle")
        precondition((frozen.value(forKey: "userData") as! NSDictionary)["wheelRoll"] as! Double == 0,
            "Live wheel metadata must not mutate the deferred scene archive")
        func frame(_ time: Double) -> MissionReplayFrame {
            MissionReplayFrame(id: UUID(), timestamp: time, position: CodableVector3D(SIMD3<Float>(0, 20, 0)),
                velocity: CodableVector3D(SIMD3<Float>(0, 0, -10)),
                attitude: MissionAttitudeSnapshot(rollRadians: 0, pitchRadians: 0, yawRadians: 0),
                flightModeDescription: "manual", autopilotDescription: nil, activeWaypointIndex: nil,
                batteryPercent: 70, payloadStatusDescription: nil, warningCount: 0)
        }
        let start = Date()
        let checkpoint = MissionReplaySession(id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(600),
            frames: (0..<6_000).map { frame(Double($0) * 0.1) }, events: [], context: nil,
            visualAssets: ["fixture": Data(repeating: 0xA5, count: 8 * 1_024 * 1_024)])
        let report = MissionReportBuilder().buildReport(from: checkpoint)
        let enqueuedAt = CACurrentMediaTime()
        library.saveAndEnforceInBackground(session: checkpoint, report: report,
            assetArchives: recorder.visualAssetArchives)
        let enqueueMS = (CACurrentMediaTime() - enqueuedAt) * 1000
        precondition(enqueueMS < 15, "A large mission checkpoint must not block a simulation tick")
        var receivedMainCallback = false
        DispatchQueue.main.async { receivedMainCallback = true }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        precondition(receivedMainCallback, "Main must keep delivering frames while a recording saves")
        let deadline = Date(timeIntervalSinceNow: 5)
        while library.summaries.isEmpty && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        precondition(library.summaries.count == 1, "A background checkpoint must become selectable")
        let restored = library.loadSession(id: checkpoint.id)!
        precondition(restored.frames == checkpoint.frames && restored.visualAssets?["fixture"] == checkpoint.visualAssets?["fixture"]
            && restored.visualAssets?[snapshot.assetID] == frozenData,
            "The complete immutable checkpoint must survive a worker save")
        var final = checkpoint
        final.frames.append(frame(601)); final.endedAt = start.addingTimeInterval(601)
        library.saveAndEnforceInBackground(session: checkpoint, report: report)
        library.saveAndEnforce(session: final, report: MissionReportBuilder().buildReport(from: final))
        precondition(library.loadSession(id: final.id)?.frames.last?.timestamp == 601,
            "An older background checkpoint must never overwrite a synchronous final recording")
        precondition(library.selectedReport?.summary.frameCount == 6_001,
            "The selected report must describe the final recording, not its earlier checkpoint")
        precondition(library.summaries.count == 1, "Checkpoints update the same recording")
        library.saveAndEnforceInBackground(session: final, report: MissionReportBuilder().buildReport(from: final))
        library.delete(id: final.id)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        precondition(storage.listSummaries().isEmpty && library.summaries.isEmpty,
            "Deleting a recording must be ordered after its queued write")
        print("PASS: 11 replay archive/persistence/responsiveness checks; enqueued 6,000 frames / 8 MiB in \(enqueueMS)ms")
    }

    private final class ApproachPhysics: DronePhysicsEngine {
        var targetPosition: (() -> SIMD3<Float>)?
        var stepIndex = 0
        func step(state: DroneState, control: DroneControlInput, context: DroneSimulationContext,
                  deltaTime: Float) -> DroneState {
            var next = state
            stepIndex += 1
            if let targetPosition {
                let altitude: Float = stepIndex == 1 ? 45 : max(2.5, 6 - Float(stepIndex - 2) * 0.4)
                next.position = targetPosition() + SIMD3<Float>(0, altitude, 0)
                next.velocity = SIMD3<Float>(0, -40, 0)
                next.physicalState = .airborne
            }
            return next
        }
    }

    private final class ProbeProjectStorage: ProjectStorageManaging {
        func listProjects() -> [ProjectRecordSummary] { [] }
        func saveProject(id: String, name: String, snapshot: ProjectSnapshot) throws -> ProjectRecordSummary {
            throw ProjectStorageError.writeFailed
        }
        func loadProject(id: String) throws -> ProjectSnapshot { throw ProjectStorageError.projectNotFound }
        func duplicateProject(id: String, newName: String) throws -> ProjectRecordSummary { throw ProjectStorageError.projectNotFound }
        func deleteProject(id: String) throws { }
        func autosave(projectID: String, snapshot: ProjectSnapshot) throws { }
        func loadAutosave(projectID: String) -> ProjectSnapshot? { nil }
        func createProjectID() -> String { "vfx-probe" }
        func defaultProjectName() -> String { "VFX probe" }
    }

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
        let videoOutput = output.appendingPathComponent("animation", isDirectory: true)
        let recordsVideo = CommandLine.arguments.contains("--vfx-video")
        if recordsVideo { try! FileManager.default.createDirectory(at: videoOutput, withIntermediateDirectories: true) }
        for model in ["aircraft"] {
            let world = InterceptMissionScene(scene: controller.scene, showsCallsigns: false)
            let origin = SIMD3<Float>(0, 8, -65)
            let car = world.makeActor(id: InterceptCallsign.target, role: .target, profile: profile,
                position: origin, payload: nil, moduleShape: .ballast, seed: 9)
            var configuration = InterceptMissionConfiguration()
            configuration.moduleShape = .charge
            let observer = world.makeActor(id: InterceptCallsign.observer, role: .observer, profile: profile,
                position: configuration.observerOffset, payload: nil, moduleShape: .ballast, seed: 9)
            let session = InterceptMissionSession(configuration: configuration, target: car,
                observer: observer, origin: .zero)
            for _ in 0..<120 { world.update(session, deltaTime: 1.0 / 60, ground: flat) }
            let observerCamera = world.camera(for: observer.id)!
            let external = controller.pointOfView(for: .free)
            external.simdPosition = origin + SIMD3<Float>(16, 10, -18)
            external.look(at: SCNVector3(origin + SIMD3<Float>(0, 2, 0)))
            if recordsVideo { external.camera?.fieldOfView = 42 }
            let renderer = render ? MTLCreateSystemDefaultDevice().map { SCNRenderer(device: $0, options: nil) } : nil
            renderer?.scene = controller.scene
            if let renderer {
                WorldDamageEffectVisual.prepareRenderPipelines(device: renderer.device!, antialiasing: .multisampling4X)
            }
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
                    output.appendingPathComponent("detonation-\(model)-\(label).png"))
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
            previous.position = origin + SIMD3<Float>(0, 1.2, 0); previous.velocity = SIMD3<Float>(0, -40, 0)
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
            check(!car.snapshot.functionalState.canAttempt, "An aircraft charge contact retains its damage mechanics")
            let first = frame("contact-observer", camera: observerCamera)
            _ = frame("contact-external", camera: external)
            if renderer != nil { check(first > 60, "The contact burst is visible from the native daylight observer camera") }
            let impactTime = session.worldTime
            func videoFrame(_ index: Int) {
                guard recordsVideo, model == "aircraft", let renderer else { return }
                renderer.pointOfView = external
                let image = renderer.snapshot(atTime: session.worldTime, with: CGSize(width: 960, height: 600), antialiasingMode: .multisampling4X)
                var rectangle = CGRect(x: 0, y: 0, width: 960, height: 600)
                let pixels = image.cgImage(forProposedRect: &rectangle, context: nil, hints: nil)!
                let filename = String(format: "frame-%04d.png", index)
                let destination = CGImageDestinationCreateWithURL(videoOutput.appendingPathComponent(filename) as CFURL,
                    "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, pixels, nil)
                precondition(CGImageDestinationFinalize(destination))
            }
            videoFrame(0)
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
                if step <= 160 { videoFrame(step) }
                detonationEvents += countDetonations(session.drainEvents())
                if [2, 5, 10, 20, 40, 80, 160].contains(step) {
                    let visible = frame("\(step * 50)ms-observer", camera: observerCamera)
                    _ = frame("\(step * 50)ms-external", camera: external)
                    if renderer != nil && step <= 20 {
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
