import AppKit
import SceneKit
import Metal
import simd

// The production storage dependency belongs to the app services layer. This probe requires
// an injected temporary directory and deliberately cannot resolve the user's replay library.
struct InternalStorePaths {
    static func replays(fileManager: FileManager) -> URL { fatalError("Test directory must be injected") }
}

@main
struct ReplayWorldProbe {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }

    static func frame(_ time: Double, _ world: MissionReplayWorldSnapshot?) -> MissionReplayFrame {
        MissionReplayFrame(id: UUID(), timestamp: time,
            position: CodableVector3D(SIMD3<Float>(Float(time), 5, 0)),
            velocity: CodableVector3D(SIMD3<Float>(1, 0, 0)),
            attitude: MissionAttitudeSnapshot(rollRadians: 0, pitchRadians: 0, yawRadians: 0),
            flightModeDescription: "manual", autopilotDescription: nil, activeWaypointIndex: nil,
            batteryPercent: 95, payloadStatusDescription: nil, warningCount: 0,
            machNumber: 0.03, dynamicPressurePa: 45, loadFactor: 1.2, skinTemperatureK: 280, world: world)
    }

    static func main() throws {
        try replay()
        try thermal()
        for band in ELRSBand.allCases {
            let modes = ELRSControlIntent.allCases.map { ELRSLinkCatalog.suggestedMode(for: $0, band: band) }
            check(Set(modes.map(\.id)).count == 3, "Each radio intent must select a distinct supported mode on both bands")
            check(modes[0].packetRateHz > modes[1].packetRateHz && modes[1].packetRateHz > modes[2].packetRateHz,
                "Response, balance and range must offer distinct command rates")
            check(modes[0].sensitivityDBm > modes[1].sensitivityDBm && modes[1].sensitivityDBm > modes[2].sensitivityDBm,
                "The range intent must offer greater receiver sensitivity")
        }
        print("PASS: replay actors, debris, cameras, reversible seeking, legacy JSON, binary assets, trimming; imported thermal materials, weather and streamed LODs")
    }

    static func replay() throws {
        let recorder = MissionReplayRecorder(minFrameInterval: 0.1, maxFrameCount: 3)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let context = MissionReplayContextSnapshot(projectName: "Fixture", selectedDroneProfileID: nil,
            selectedDroneProfileName: nil, selectedUAVProfileID: nil, selectedUAVProfileName: nil, workbenchBuild: nil,
            terrainPresetRawValue: "forest", mapScaleRawValue: "x4", terrainSeed: 42, weatherPresetRawValue: "normal",
            payloadTypeRawValue: nil, payloadResolvedName: nil, hasPayloadAttachedAtStart: false, recordedAtAppVersion: nil,
            terrainDensity: 0.72, importedWorld: MissionReplayImportedWorldReference(kind: .photogrammetric, identifier: "fixture", tileKey: "tile-1"))
        recorder.startSession(at: startedAt, timestamp: 0, context: context)
        let actor = SCNNode()
        actor.name = "target"
        actor.constraints = [SCNLookAtConstraint(target: SCNNode())]
        actor.simdPosition = SIMD3<Float>(10, 15, 20)
        let released = SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0))
        released.name = "attached-module"
        let surviving = SCNNode(geometry: SCNSphere(radius: 0.25))
        surviving.name = "motor"
        surviving.simdPosition = SIMD3<Float>(2, 0, 0)
        actor.addChildNode(released)
        actor.addChildNode(surviving)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera!.fieldOfView = 46
        camera.simdPosition = SIMD3<Float>(0, 1, -0.5)
        actor.addChildNode(camera)
        let before = MissionReplayVisualCapture.snapshot(id: "target", node: actor, recorder: recorder,
            role: "target", displayName: "Fixture", camera: camera)
        released.removeFromParentNode()
        actor.simdPosition.x += 4
        surviving.simdPosition.y = 3
        surviving.opacity = 0.5
        let after = MissionReplayVisualCapture.snapshot(id: "target", node: actor, recorder: recorder,
            role: "target", displayName: "Fixture", camera: camera)
        check(before.assetID == after.assetID, "Detachment must reuse the original geometry asset")
        check(after.absentNodePaths == ["/0"], "Missing nodes must retain their original hierarchy path")
        let debris = MissionReplayVisualCapture.snapshot(id: "fragment", node: released, recorder: recorder)
        let effect = MissionReplayEffectSnapshot(id: UUID(), kind: "smoke", position: SIMD3<Float>(11, 15, 20),
            normal: SIMD3<Float>(0, 1, 0), age: 0.5, lifetime: 12)
        let world0 = MissionReplayWorldSnapshot(nodes: [before], effects: [])
        let world1 = MissionReplayWorldSnapshot(nodes: [after, debris], effects: [effect])
        let world2 = MissionReplayWorldSnapshot(nodes: [after], effects: [])
        let middle = MissionReplayWorldSnapshot.interpolated(world0, world1, fraction: 0.5)!
        check(middle.nodes.count == 1 && middle.effects.isEmpty, "Effects and fragments must not appear before their sample")
        check(abs(middle.nodes[0].pose.position.x - 12) < 0.001, "Actors must interpolate")
        check(abs(middle.nodes[0].camera!.pose.position.x - 12) < 0.001, "Recorded camera transforms must interpolate")
        let scene = SCNScene()
        let playerRoot = SCNNode()
        scene.rootNode.addChildNode(playerRoot)
        let visuals = MissionReplayWorldVisuals()
        visuals.load(assets: recorder.currentSession!.visualAssets!, scene: scene, playerRoot: playerRoot)
        visuals.update(world0)
        let model = visuals.node(for: "target")!
        check(model.constraints == nil, "Scene archives must exclude external constraint references")
        check(model.childNode(withName: "motor", recursively: true)!.geometry != nil, "Geometry archive must decode")
        visuals.update(world1)
        let effectNodeName = "replay.effect.\(effect.id)"
        let plume = scene.rootNode.childNode(withName: effectNodeName, recursively: true)!
        let plumePosition = plume.childNodes[1].simdPosition
        visuals.update(world1)
        check(plume.childNodes[1].simdPosition == plumePosition, "Paused effects must not advance on wall clock")
        check(model.childNode(withName: "attached-module", recursively: true)!.isHidden, "Released module must disappear from the carrier")
        check(model.childNode(withName: "motor", recursively: true)!.simdPosition.y == 3, "Sibling transforms must not shift when a child is removed")
        check(visuals.node(for: "fragment") != nil, "Detached geometry must be present")
        visuals.update(world0)
        check(scene.rootNode.childNode(withName: effectNodeName, recursively: true) == nil, "Backward seek must remove future effects")
        check(!model.childNode(withName: "attached-module", recursively: true)!.isHidden, "Backward seek must reattach the module")
        check(model.childNode(withName: "motor", recursively: true)!.simdPosition.y == 0, "Backward seek must restore baseline child transforms")
        check(model.childNode(withName: "motor", recursively: true)!.opacity == 1, "Backward seek must restore opacity")
        check(visuals.node(for: "fragment") == nil, "Backward seek must remove future debris")
        visuals.update(world2)
        check(!visuals.assetFailures, "Captured assets must all be readable")
        for time in [0.0, 1.0, 2.0, 3.0, 4.0] { recorder.recordFrame(frame(time, time == 0 ? world0 : time == 1 ? world1 : world2)) }
        let interception = InterceptMissionEvent(id: UUID(), runID: UUID(), sequence: 1, timestamp: 12, authorityID: "local",
            kind: .effect(InterceptWorldEffect(id: effect.id, runID: UUID(), impactID: UUID(), vehicleID: "target",
                kind: .smoke, position: effect.position, startedAt: 11.5, lifetime: 12)))
        recorder.recordEvent(MissionReplayEvent(id: interception.id, timestamp: 1, type: .scenarioEvent,
            message: "smoke", position: CodableVector3D(effect.position), interception: interception))
        check(recorder.currentSession!.frames.count == 3, "Frame cap must still apply")
        check(recorder.currentSession!.events.filter { $0.type == .recordingLimitReached }.count == 1, "Frame cap warning must occur once")
        recorder.stopSession(at: startedAt.addingTimeInterval(2), timestamp: 2)
        let session = recorder.lastCompletedSession!
        let player = MissionReplayPlayer()
        player.load(session: session)
        player.seek(to: 1)
        check(player.currentFrame!.world == world1, "Player must retain surrounding scene data at sampled boundaries")
        player.seek(to: 0.5)
        check(player.currentFrame!.machNumber == 0.03, "Interpolation must retain high-speed telemetry")
        player.seek(to: 2)
        check(player.currentFrame!.world == world2, "Final frame must preserve post-impact state")
        let trimmed = ReplayTrimmer().trimmedSession(from: session, range: ReplayTrimRange(startTime: 1, endTime: 2))
        check(trimmed.frames.first!.world == world1 && trimmed.visualAssets == session.visualAssets, "Trimming must retain assets and effects")
        check(trimmed.frames.first!.world!.effects[0].age == 0.5, "Trimming must preserve simulation effect age")
        check(trimmed.events.first(where: { $0.type == .scenarioEvent })?.interception == interception, "Trimmed events must retain structured mission data")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("replay-world-probe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = MissionReplayStorageService(directory: directory)
        try storage.save(session: session, report: MissionReportBuilder().buildReport(from: session))
        let restored = try storage.loadSession(id: session.id)
        check(restored.frames == session.frames && restored.visualAssets == session.visualAssets, "Binary assets and frames must survive disk storage")
        check(restored.context == context, "Terrain density and imported map references must survive storage")

        let ongoingMission = MissionReplayRecorder()
        ongoingMission.startSession(at: startedAt, context: context)
        for (id, data) in session.visualAssets! { _ = ongoingMission.registerVisualAsset(id: id) { data } }
        ongoingMission.recordFrame(frame(0, world0))
        let checkpoint = ongoingMission.checkpoint(at: startedAt.addingTimeInterval(0.02))!
        try storage.save(session: checkpoint, report: MissionReportBuilder().buildReport(from: checkpoint))
        check(ongoingMission.isRecording && ongoingMission.currentSession?.endedAt == nil,
              "Opening the recorder or publishing a mission result must not stop recording aftermath")
        check(abs(checkpoint.duration - 0.02) < 0.001 && checkpoint.events.allSatisfy { $0.type != .sessionStopped },
              "An ongoing replay checkpoint must have a fixed duration without a premature stop event")
        check(storage.listSummaries().contains { $0.id == checkpoint.id }, "An ongoing mission must appear in the replay library")
        // Exit/reset can happen inside the normal 100 ms sampling interval. Its final world
        // sample must still include the collision, fragments and the other aircraft.
        ongoingMission.recordFrame(frame(0.05, world1), force: true)
        ongoingMission.stopSession(at: startedAt.addingTimeInterval(0.05), timestamp: 0.05)
        ongoingMission.stopSession(at: startedAt.addingTimeInterval(0.05), timestamp: 0.05)
        let finishedMission = ongoingMission.lastCompletedSession!
        try storage.save(session: finishedMission, report: MissionReportBuilder().buildReport(from: finishedMission))
        let persistedMission = try storage.loadSession(id: checkpoint.id)
        check(persistedMission.frames.last?.world == world1 && persistedMission.visualAssets == session.visualAssets,
              "Finalization must persist the final surrounding world and binary geometry")
        check(persistedMission.events.filter { $0.type == .sessionStopped }.count == 1,
              "Repeated teardown must not duplicate the stop event")
        check(storage.listSummaries().filter { $0.id == checkpoint.id }.count == 1,
              "Finalization must update the checkpoint, not create a second recording")
        let storedJSON = try Data(contentsOf: directory.appendingPathComponent(session.id.uuidString).appendingPathComponent("session.json"))
        var json = try JSONSerialization.jsonObject(with: storedJSON) as! [String: Any]
        check(json["visualAssets"] == nil && json["visualAssetFiles"] != nil, "Scene archives must stay outside frame JSON")
        json.removeValue(forKey: "visualAssetFiles")
        var oldContext = json["context"] as! [String: Any]
        oldContext.removeValue(forKey: "importedWorld")
        oldContext.removeValue(forKey: "terrainDensity")
        json["context"] = oldContext
        var oldFrames = json["frames"] as! [[String: Any]]
        for index in oldFrames.indices { oldFrames[index].removeValue(forKey: "world") }
        json["frames"] = oldFrames
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(MissionReplaySession.self, from: JSONSerialization.data(withJSONObject: json))
        check(legacy.frames.allSatisfy { $0.world == nil } && legacy.visualAssets == nil, "Old recordings must remain decodable")
        check(legacy.context?.importedWorld == nil && legacy.context?.terrainDensity == nil, "Legacy context must remain decodable")
        let added = SCNNode(geometry: SCNSphere(radius: 0.2))
        actor.addChildNode(added)
        recorder.startSession(at: startedAt)
        let newAsset = MissionReplayVisualCapture.snapshot(id: "target", node: actor, recorder: recorder)
        actor.addChildNode(SCNNode(geometry: SCNSphere(radius: 0.3)))
        let changedAsset = MissionReplayVisualCapture.snapshot(id: "target", node: actor, recorder: recorder)
        check(newAsset.assetID != changedAsset.assetID, "Newly installed geometry requires a new reusable asset")
        recorder.discardCurrentSession()
        let performanceRecorder = MissionReplayRecorder(minFrameInterval: 0.0001)
        performanceRecorder.startSession(at: startedAt)
        let recordStart = Date()
        for i in 0..<10_000 { performanceRecorder.recordFrame(frame(Double(i) * 0.001, world1)) }
        let seconds = Date().timeIntervalSince(recordStart)
        check(performanceRecorder.currentSession?.frames.count == 10_000, "Long recordings must append all samples")
        check(seconds < 2, "Appending frames must not repeatedly copy the recording")
        print(String(format: "10,000 world frames appended in %.3f s", seconds))
    }

    static func thermal() throws {
        let source = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 256, bitsPerPixel: 32)!
        for y in 0..<64 {
            for x in 0..<64 {
                let offset = y * 256 + x * 4
                let values: [UInt8] = x < 32 ? [30, 140, 35, 255] : [110, 110, 110, 255]
                for c in 0..<4 { source.bitmapData![offset + c] = values[c] }
            }
        }
        let image = NSImage(size: NSSize(width: 64, height: 64))
        image.addRepresentation(source)
        let material = SCNMaterial()
        material.diffuse.contents = image
        material.diffuse.wrapS = .repeat
        let context = ThermalEnvironmentContext.neutral
        let normal = ThermalNormalizationModel.make(population: [(.terrain, 1), (.grass, 1)], context: context)
        let scene = SCNScene()
        scene.background.contents = NSColor.black
        let root = SCNNode(); root.name = "world.mesh.root"
        scene.rootNode.addChildNode(root)
        let renderer = ThermalProxyRenderer(sceneRoot: scene.rootNode, groundNode: SCNNode(), importedRoot: root)
        let tile = SCNNode(geometry: SCNPlane(width: 40, height: 30))
        tile.name = "terrain"
        tile.geometry!.firstMaterial = material
        root.addChildNode(tile)
        func update(_ now: Double, _ weather: ThermalEnvironmentContext = context, _ palette: ThermalPalette = .iron) {
            renderer.updatePresentation(context: weather, palette: palette, contrast: 1, brightness: 0,
                noiseAmount: 0.5, normalization: normal, groundClass: .terrain, environmentRevision: 1, now: now)
        }
        update(0)
        check(tile.childNodes.count == 1, "Imported world must receive a thermal proxy")
        let proxy = tile.childNodes[0]
        check(proxy.categoryBitMask == ThermalRenderCategory.proxyBit, "Thermal proxy must be isolated from ordinary cameras")
        check(proxy.categoryBitMask & (1 << 8) == 0, "LiDAR camera must exclude thermal geometry")
        check(material.diffuse.contents as? NSImage === image, "Original colour imagery must not be modified")
        check(proxy.geometry!.firstMaterial!.diffuse.contents as? NSImage === image,
              "Imported thermal must share GPU imagery without producing CPU bitmaps")
        check(proxy.geometry!.firstMaterial!.diffuse.wrapS == .repeat, "Original UV wrapping must be preserved")

        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal device required for the thermal shader probe") }
        try thermalPaletteConsistency(device: device)
        try thermalSpatialVariation(device: device)
        try thermalCityPreview(device: device)
        try thermalPhysicalResponse(device: device)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera!.usesOrthographicProjection = true
        camera.camera!.orthographicScale = 16
        camera.camera!.categoryBitMask = ThermalRenderCategory.proxyBit
        camera.simdPosition = SIMD3<Float>(0, 0, 60)
        scene.rootNode.addChildNode(camera)
        let gpu = SCNRenderer(device: device, options: nil)
        gpu.scene = scene
        gpu.pointOfView = camera
        func snapshot() -> NSBitmapImageRep {
            let rendered = gpu.snapshot(atTime: 0, with: NSSize(width: 256, height: 192), antialiasingMode: .none)
            return NSBitmapImageRep(cgImage: rendered.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        }
        let first = snapshot()
        let firstData = first.representation(using: .png, properties: [:])!
        check(firstData == snapshot().representation(using: .png, properties: [:])!, "Paused thermal gradients must be deterministic")
        var colors: Set<String> = []
        for y in stride(from: 12, to: 180, by: 2) {
            for x in stride(from: 12, to: 244, by: 2) {
                let color = first.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                colors.insert(String(format: "%.2f:%.2f:%.2f", color.redComponent, color.greenComponent, color.blueComponent))
                check(color.greenComponent <= color.redComponent + 0.02,
                      "Metal surface shader must produce ironbow, not the original green imagery")
            }
        }
        check(colors.count > 30, "GPU thermal image must contain spatial gradients")
        var rain = context
        rain.rainIntensity = 1; rain.sunExposure = 0; rain.cloudiness = 1; rain.groundWetness = 1
        update(0.1, rain)
        check(firstData != snapshot().representation(using: .png, properties: [:])!, "Weather must affect the GPU thermal image")
        update(0.2, context, .blackHot)
        check(firstData != snapshot().representation(using: .png, properties: [:])!, "Palette selection must affect the GPU image")
        let mono = snapshot().colorAt(x: 100, y: 100)!.usingColorSpace(.deviceRGB)!
        check(abs(mono.redComponent - mono.greenComponent) < 0.01 && abs(mono.greenComponent - mono.blueComponent) < 0.01,
              "Black-hot output must be monochrome")
        let updates = renderer.importedUniformUpdateCount
        for n in 0..<20 { update(0.21 + Double(n) * 0.01, context, .blackHot) }
        check(renderer.importedUniformUpdateCount == updates, "Stationary conditions must not rebind thermal uniforms")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("uavsim-imported-thermal-probe.png")
        try firstData.write(to: output)

        let streamed = SCNNode(geometry: SCNBox(width: 8, height: 8, length: 8, chamferRadius: 0))
        let secondMaterial = SCNMaterial(); secondMaterial.diffuse.contents = NSColor.gray
        streamed.geometry!.materials = [material, secondMaterial]
        root.addChildNode(streamed)
        update(0.6)
        check(streamed.childNodes.count == 1, "New streamed LOD must be discovered without a world revision")
        check(streamed.childNodes[0].geometry!.materials.count == 2, "All imported material slots must survive")
        streamed.removeFromParentNode()
        update(0.7)
        check(streamed.childNodes.isEmpty, "Evicted LOD must release its thermal geometry")
        renderer.clear()
        check(tile.childNodes.isEmpty && renderer.importedMaterialCount == 0, "Clearing must release proxy nodes and material cache")

        // Real map scale, with shared imagery. No GPU rendering of this fixture is needed: this
        // catches the synchronous construction/bitmap churn that a single plane concealed.
        tile.removeFromParentNode()
        let chunk = SCNNode()
        root.addChildNode(chunk)
        let geometry = SCNBox(width: 5, height: 8, length: 5, chamferRadius: 0)
        geometry.firstMaterial = material
        for n in 0..<6_000 {
            let building = SCNNode(geometry: geometry)
            building.name = "building"
            building.simdPosition = SIMD3<Float>(Float(n % 100) * 7, 0, Float(n / 100) * 7)
            chunk.addChildNode(building)
        }
        var maxBatchSeconds = 0.0
        for n in 0..<450 {
            let start = CACurrentMediaTime()
            let before = renderer.importedGeometryCount
            update(Double(n) * 0.05 + 1)
            maxBatchSeconds = max(maxBatchSeconds, CACurrentMediaTime() - start)
            check(renderer.lastImportedVisitCount <= 96, "Imported traversal must have a node budget")
            check(renderer.importedGeometryCount - before <= 32, "Cold activation must build at most 32 geometries per batch")
            if renderer.importedGeometryCount == 5_200 && !renderer.hasPendingImportedGeometry { break }
        }
        check(renderer.importedGeometryCount == 5_200, "Dense maps must respect the proxy cap")
        check(renderer.importedMaterialCount == 1, "Thousands of buildings must share one thermal material for shared imagery")
        check(maxBatchSeconds < 0.1, "Imported thermal batches must not stall the UI thread")
        chunk.removeFromParentNode()
        for n in 0..<200 { update(Double(n) * 0.05 + 30) }
        check(renderer.importedGeometryCount == 0 && renderer.importedMaterialCount == 0,
              "Evicted dense chunks must release all proxy geometry and cached materials")
        renderer.clear()
        let uniqueChunk = SCNNode()
        root.addChildNode(uniqueChunk)
        for _ in 0..<1_200 {
            let uniqueGeometry = geometry.copy() as! SCNGeometry
            let sourceMaterial = SCNMaterial()
            sourceMaterial.diffuse.contents = NSColor.gray
            uniqueGeometry.materials = [sourceMaterial]
            let building = SCNNode(geometry: uniqueGeometry)
            building.name = "building"
            uniqueChunk.addChildNode(building)
        }
        for n in 0..<300 {
            update(Double(n) * 0.05 + 50)
            if renderer.importedGeometryCount == 1_200 && !renderer.hasPendingImportedGeometry { break }
        }
        check(renderer.importedMaterialCount == 1_200, "Unique imported materials must retain independent slots")
        let beforeWeather = renderer.importedUniformUpdateCount
        update(80, rain)
        check(renderer.importedUniformUpdateCount - beforeWeather <= 64,
              "Weather changes must update at most 64 unique materials per batch")
        for n in 0..<100 {
            let before = renderer.importedUniformUpdateCount
            update(Double(n) * 0.05 + 80.1, rain)
            check(renderer.importedUniformUpdateCount - before <= 64, "Every weather batch must respect the uniform budget")
            if !renderer.hasPendingImportedGeometry { break }
        }
        check(renderer.importedUniformUpdateCount == beforeWeather + 1_200,
              "Weather refresh must eventually reach every material, without repeated bindings")
        renderer.clear()
        print(String(format: "6,000-mesh thermal fixture: largest batch %.1f ms; 1,200 unique materials budgeted; Metal gradients/weather/palettes rendered", maxBatchSeconds * 1_000))
    }

    /// Render the same temperatures through the native NSColor path and the imported shader.
    /// This catches double gamma correction and keeps the image consistent with its legend.
    static func thermalPaletteConsistency(device: MTLDevice) throws {
        let scene = SCNScene()
        scene.background.contents = NSColor.black
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera!.usesOrthographicProjection = true
        camera.camera!.orthographicScale = 16
        camera.simdPosition = SIMD3<Float>(0, 0, 60)
        scene.rootNode.addChildNode(camera)
        let range = ThermalNormalizationState(displayMinCelsius: 0, displayMaxCelsius: 40)
        let temperatures = [2.0, 10, 20, 30, 38]
        for (row, palette) in [ThermalPalette.iron, .whiteHot, .blackHot].enumerated() {
            let materials = ThermalImportedSurfaceMaterials()
            materials.update(context: .neutral, palette: palette, normalization: range,
                             contrast: 1, brightness: 0, noise: 0)
            for (column, temperature) in temperatures.enumerated() {
                let reference = SCNMaterial()
                reference.lightingModel = .constant
                reference.diffuse.contents = ThermalPaletteMapper.color(forTemperature: temperature,
                    displayMin: 0, displayMax: 40, palette: palette, contrast: 1, brightness: 0)
                let source = SCNMaterial()
                source.diffuse.contents = NSColor.gray
                let (_, imported) = materials.acquire(source: source, materialClass: .building)
                imported.setValue(NSNumber(value: temperature), forKey: "thermalBase")
                imported.setValue(NSNumber(value: 0), forKey: "thermalAmplitude")
                imported.setValue(NSNumber(value: 0.0), forKey: "thermalPhysicalEnabled")
                for (offset, material) in [(2.0, reference), (-2.0, imported)] {
                    let node = SCNNode(geometry: SCNPlane(width: 6, height: 3))
                    node.geometry!.firstMaterial = material
                    node.simdPosition = SIMD3<Float>(Float(column * 8 - 16), Float(10 - row * 10) + Float(offset), 0)
                    scene.rootNode.addChildNode(node)
                }
            }
        }
        let gpu = SCNRenderer(device: device, options: nil)
        gpu.scene = scene; gpu.pointOfView = camera
        let image = gpu.snapshot(atTime: 0, with: NSSize(width: 512, height: 384), antialiasingMode: .none)
        let bitmap = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        try bitmap.representation(using: .png, properties: [:])!.write(to:
            FileManager.default.temporaryDirectory.appendingPathComponent("uavsim-thermal-palette-probe.png"))
        var maxError = 0.0
        for row in 0..<3 {
            for column in 0..<5 {
                let x = 256 + (column * 8 - 16) * 12
                let y = 192 - (10 - row * 10) * 12
                let reference = bitmap.colorAt(x: x, y: y - 24)!.usingColorSpace(.sRGB)!
                let imported = bitmap.colorAt(x: x, y: y + 24)!.usingColorSpace(.sRGB)!
                maxError = max(maxError, abs(reference.redComponent - imported.redComponent),
                    abs(reference.greenComponent - imported.greenComponent), abs(reference.blueComponent - imported.blueComponent))
            }
        }
        check(maxError < 0.025, String(format: "Imported palette must match native temperatures/legend; max RGB error %.3f", maxError))
        var whiteLevels: [CGFloat] = []
        var blackLevels: [CGFloat] = []
        for column in 0..<5 {
            let x = 256 + (column * 8 - 16) * 12
            whiteLevels.append(bitmap.colorAt(x: x, y: 216)!.usingColorSpace(.sRGB)!.redComponent)
            blackLevels.append(bitmap.colorAt(x: x, y: 336)!.usingColorSpace(.sRGB)!.redComponent)
        }
        // Compare ordering/endpoints: colour-managed snapshot components need not add linearly.
        check(zip(whiteLevels, whiteLevels.dropFirst()).allSatisfy { $0 < $1 } &&
              zip(blackLevels, blackLevels.dropFirst()).allSatisfy { $0 > $1 } &&
              whiteLevels.first! < 0.1 && blackLevels.last! < 0.1 &&
              whiteLevels.last! > 0.9 && blackLevels.first! > 0.9,
              "White/black-hot must invert brightness instead of brightening both modes")
        print(String(format: "All three GPU thermal palettes match native colours; max RGB error %.3f", maxError))
    }

    /// Compare real GPU fragments with the independent CPU radiance model. This verifies world
    /// normals/view vectors, emitted/reflected LWIR and attenuation, not just colour selection.
    static func thermalPhysicalResponse(device: MTLDevice) throws {
        let context = ThermalEnvironmentContext.neutral
        let towardSun = SIMD3<Double>(0, 0, -1)
        let awayFromSun = -towardSun
        let warm = ThermalMaterialModel.surfaceTemperature(for: .building, context: context, normal: towardSun)
        let cool = ThermalMaterialModel.surfaceTemperature(for: .building, context: context, normal: awayFromSun)
        check(warm > cool + 2, "Solar and shaded facades must have different temperatures")
        var evening = context; evening.timeOfDayHours = 18.5; evening.isNight = true; evening.sunExposure = 0
        check(ThermalMaterialModel.surfaceResponse(for: .building, context: evening).solar.y > 0,
              "Masonry must retain earlier solar heating after sunset")
        var rain = context
        rain.cloudiness = 1; rain.rainIntensity = 1; rain.groundWetness = 1; rain.sunExposure = 0
        check(ThermalMaterialModel.surfaceTemperature(for: .roof, context: rain, normal: SIMD3(0, 1, 0))
            < ThermalMaterialModel.surfaceTemperature(for: .roof, context: context, normal: SIMD3(0, 1, 0)) - 5,
            "Wet cloudy roofs must lose solar heating")
        check(ThermalMaterialModel.skyTemperature(context: rain) > ThermalMaterialModel.skyTemperature(context: context) + 20,
              "Clouds must be warmer in LWIR than clear sky")
        let population: [(ThermalMaterialClass, Double)] = [(.building, 100), (.roof, 20), (.glass, 30), (.asphalt, 10)]
        let dryRange = ThermalNormalizationModel.make(population: population, context: context)
        let wetRange = ThermalNormalizationModel.make(population: population, context: rain)
        check(dryRange.spanCelsius < 30 && wetRange.displayMaxCelsius < dryRange.displayMaxCelsius - 3,
              "City range must fit surface responses and follow cooling")
        check(dryRange == ThermalNormalizationModel.make(population: population + [(.sky, 10000)], context: context),
              "Cold sky must not flatten terrestrial thermal contrast")
        let settling = ThermalNormalizationModel.stabilized(wetRange, previous: dryRange, elapsedSeconds: 0.1)
        check(settling.displayMaxCelsius > wetRange.displayMaxCelsius && settling.displayMaxCelsius < dryRange.displayMaxCelsius,
              "Exposure changes must settle continuously")
        check(ThermalSurfaceClassifier.classifyToken("office tower") == .building, "Office must not be classified as ice")

        let range = ThermalNormalizationState(displayMinCelsius: -20, displayMaxCelsius: 40)
        let scene = SCNScene()
        let camera = SCNNode(); camera.camera = SCNCamera()
        camera.camera!.usesOrthographicProjection = true; camera.camera!.orthographicScale = 1
        camera.camera!.zNear = 0.1; camera.camera!.zFar = 2000
        scene.rootNode.addChildNode(camera)
        let surface = SCNNode(geometry: SCNPlane(width: 6, height: 6))
        scene.rootNode.addChildNode(surface)
        let gpu = SCNRenderer(device: device, options: nil); gpu.scene = scene; gpu.pointOfView = camera
        var maxError = 0.0
        let grazing = simd_normalize(SIMD3<Double>(0, -0.95, 0.31))
        let cases: [(ThermalMaterialClass, ThermalEnvironmentContext, SIMD3<Double>, SIMD3<Double>, Double)] = [
            (.building, context, towardSun, towardSun, 60), (.building, context, awayFromSun, awayFromSun, 60),
            (.roof, context, SIMD3(0, 1, 0), SIMD3(0, 1, 0), 60),
            (.glass, context, awayFromSun, awayFromSun, 60), (.glass, context, awayFromSun, grazing, 60),
            (.metal, context, awayFromSun, grazing, 60), (.body, context, awayFromSun, awayFromSun, 60),
            (.roof, rain, SIMD3(0, 1, 0), SIMD3(0, 1, 0), 500)]
        for (index, item) in cases.enumerated() {
            let (cls, weather, normal, view, distance) = item
            let materials = ThermalImportedSurfaceMaterials()
            materials.update(context: weather, palette: .whiteHot, normalization: range, contrast: 1, brightness: 0, noise: 0)
            let source = SCNMaterial(); source.diffuse.contents = NSColor.gray; source.isDoubleSided = true
            let (_, material) = materials.acquire(source: source, materialClass: cls)
            material.setValue(NSNumber(value: 0.0), forKey: "thermalBuilding") // isolate the selected material response
            SCNTransaction.begin(); SCNTransaction.disableActions = true
            surface.geometry!.firstMaterial = material
            let n = SIMD3<Float>(normal); let v = SIMD3<Float>(view)
            surface.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, 1), to: n)
            camera.simdPosition = v * Float(distance)
            camera.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: -v)
            SCNTransaction.commit(); SCNTransaction.flush()
            let actual = ThermalMaterialModel.apparentSurfaceTemperature(for: cls, context: weather,
                normal: normal, view: view, distance: distance)
            let image = gpu.snapshot(atTime: Double(index) + 1, with: NSSize(width: 64, height: 64), antialiasingMode: .none)
            let bitmap = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            let rendered = bitmap.colorAt(x: 32, y: 32)!.usingColorSpace(.sRGB)!.redComponent
            let reference = SCNMaterial(); reference.lightingModel = .constant; reference.isDoubleSided = true
            reference.diffuse.contents = ThermalPaletteMapper.color(forTemperature: actual, displayMin: -20, displayMax: 40,
                palette: .whiteHot, contrast: 1, brightness: 0)
            surface.geometry!.firstMaterial = reference
            let referenceImage = gpu.snapshot(atTime: Double(index) + 1, with: NSSize(width: 64, height: 64), antialiasingMode: .none)
            let referenceBitmap = NSBitmapImageRep(cgImage: referenceImage.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            // Both paths go through SceneKit's output colour transform, as in the palette test.
            let expected = referenceBitmap.colorAt(x: 32, y: 32)!.usingColorSpace(.sRGB)!.redComponent
            if abs(rendered - expected) >= 0.025 {
                FileHandle.standardError.write(Data("Radiance mismatch \(cls) normal=\(normal) view=\(view) T=\(actual) expected=\(expected) actual=\(rendered)\n".utf8))
            }
            maxError = max(maxError, abs(rendered - expected))
        }
        check(maxError < 0.025, String(format: "GPU solar/reflection/atmosphere must match CPU radiance; error %.3f", maxError))
        let glassFront = ThermalMaterialModel.apparentSurfaceTemperature(for: .glass, context: context,
            normal: awayFromSun, view: awayFromSun)
        let glassSky = ThermalMaterialModel.apparentSurfaceTemperature(for: .glass, context: context,
            normal: awayFromSun, view: grazing)
        check(glassSky < glassFront - 3, "Glass must reflect cold sky more at grazing angles")
        let facadeSource = UAVWorldFacadeMaterialFactory.materials(for: .concretePostwar)[0].copy() as! SCNMaterial
        facadeSource.diffuse.contentsTransform = SCNMatrix4Identity // one semantic tile fills this plane
        let facadeMaterials = ThermalImportedSurfaceMaterials()
        facadeMaterials.update(context: context, palette: .whiteHot,
            normalization: ThermalNormalizationState(displayMinCelsius: 12, displayMaxCelsius: 24),
            contrast: 1, brightness: 0, noise: 0)
        let (_, facadeMaterial) = facadeMaterials.acquire(source: facadeSource, materialClass: .building)
        surface.geometry!.firstMaterial = facadeMaterial
        surface.simdOrientation = simd_quatf()
        camera.simdPosition = SIMD3(0, 0, 60); camera.simdOrientation = simd_quatf()
        camera.camera!.orthographicScale = 3
        let facadeImage = gpu.snapshot(atTime: 20, with: NSSize(width: 256, height: 256), antialiasingMode: .none)
        let facadeBitmap = NSBitmapImageRep(cgImage: facadeImage.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let wallLevel = facadeBitmap.colorAt(x: 26, y: 26)!.usingColorSpace(.sRGB)!.redComponent
        let glassLevel = facadeBitmap.colorAt(x: 102, y: 102)!.usingColorSpace(.sRGB)!.redComponent
        check(abs(wallLevel - glassLevel) > 0.03,
              "Semantic glazing must change actual rendered pixels, not only material metadata")
        let tiledFacade = facadeSource.copy() as! SCNMaterial
        tiledFacade.diffuse.contentsTransform = SCNMatrix4MakeScale(2, 2, 1)
        let (_, tiledMaterial) = facadeMaterials.acquire(source: tiledFacade, materialClass: .building)
        surface.geometry!.firstMaterial = tiledMaterial
        let tiledImage = gpu.snapshot(atTime: 21, with: NSSize(width: 256, height: 256), antialiasingMode: .none)
        let tiledBitmap = NSBitmapImageRep(cgImage: tiledImage.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let tiledGlass = tiledBitmap.colorAt(x: 51, y: 51)!.usingColorSpace(.sRGB)!.redComponent
        let tiledWall = tiledBitmap.colorAt(x: 102, y: 102)!.usingColorSpace(.sRGB)!.redComponent
        check(tiledWall > tiledGlass + 0.03,
              "Glazing must follow the facade texture transform, not the unscaled mesh UVs")
        // Position-only meshes are common in simplified assets. A bound dummy mask can silently
        // make SceneKit demand texcoord0 and skip the entire draw; inspect pixels, not cache flags.
        let simplified = SCNGeometry(sources: [SCNGeometrySource(vertices: [SCNVector3(-6, -6, 0),
            SCNVector3(6, -6, 0), SCNVector3(0, 6, 0)])],
            elements: [SCNGeometryElement(indices: [Int32(0), 1, 2], primitiveType: .triangles)])
        let plainSource = SCNMaterial(); plainSource.diffuse.contents = NSColor.gray
        let (_, plainMaterial) = facadeMaterials.acquire(source: plainSource, materialClass: .building)
        simplified.materials = [plainMaterial]; surface.geometry = simplified
        let simplifiedImage = gpu.snapshot(atTime: 22, with: NSSize(width: 64, height: 64), antialiasingMode: .none)
        let simplifiedBitmap = NSBitmapImageRep(cgImage: simplifiedImage.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        let simplifiedPixel = simplifiedBitmap.colorAt(x: 32, y: 32)!.usingColorSpace(.sRGB)!
        check(simplifiedPixel.alphaComponent > 0.99 && abs(simplifiedPixel.redComponent - wallLevel) < 0.015,
              "Meshes without UVs/normals must render and recover a valid surface direction")
        print(String(format: "Physical thermal: facades %.1f / %.1f C; glass %.1f / %.1f C; CPU/Metal error %.3f; range %.1f..%.1f C",
                     warm, cool, glassFront, glassSky, maxError, dryRange.displayMinCelsius, dryRange.displayMaxCelsius))
    }

    /// Render production world geometry and facade UVs, including exact glazing masks, to inspect
    /// a city in day/night/rain and all three palettes without launching the simulator UI.
    static func thermalCityPreview(device: MTLDevice) throws {
        let scene = SCNScene()
        let root = SCNNode(); scene.rootNode.addChildNode(root)
        let ground = SCNNode(geometry: SCNPlane(width: 400, height: 400))
        ground.name = "asphalt"; ground.eulerAngles.x = -.pi / 2
        ground.geometry!.firstMaterial!.diffuse.contents = NSColor.darkGray
        root.addChildNode(ground)
        let classes: [UAVWorldFacadeClass] = [.brickPrewar, .concretePostwar, .glassCurtainWall, .stoneMasonry, .industrial, .stucco]
        for (index, cls) in classes.enumerated() {
            let x = Float(index % 3 - 1) * 50
            let z = Float(index / 3) * -55
            let heights: [Float] = [36, 54, 76, 30, 25, 43]
            let building = UAVWorldBuilding(id: UUID(), footprint: [SIMD2(x - 17, z - 14), SIMD2(x + 17, z - 14),
                SIMD2(x + 17, z + 14), SIMD2(x - 17, z + 14)], holes: [], baseElevationMeters: 0,
                heightMeters: heights[index], roofHeightMeters: 0, roofForm: .flat, facadeClass: cls,
                levels: nil, yearBuilt: nil, name: "building", provenance: UAVWorldProvenance(datasetIdentifier: "probe",
                    featureIdentifier: "\(index)", heightAccuracy: .estimated, horizontalAccuracyMeters: nil, confidence: 1))
            let geometry = UAVWorldBuildingGeometryFactory.makeGeometry(for: building)!
            geometry.materials = UAVWorldFacadeMaterialFactory.materials(for: cls)
            let node = SCNNode(geometry: geometry); node.name = "building"
            node.simdPosition = SIMD3(x, 0, z); root.addChildNode(node)
        }
        let thermal = ThermalProxyRenderer(sceneRoot: scene.rootNode, groundNode: SCNNode(), importedRoot: root)
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera!.fieldOfView = 50
        camera.camera!.zNear = 0.1; camera.camera!.zFar = 2000
        camera.camera!.categoryBitMask = ThermalRenderCategory.proxyBit
        camera.simdPosition = SIMD3(-125, 100, 170); camera.look(at: SCNVector3(0, 25, -25))
        scene.rootNode.addChildNode(camera)
        let gpu = SCNRenderer(device: device, options: nil); gpu.scene = scene; gpu.pointOfView = camera
        var day = ThermalEnvironmentContext.neutral; day.sceneProfile = .city; day.timeOfDayHours = 14
        var night = day; night.timeOfDayHours = 23; night.isNight = true; night.sunExposure = 0; night.ambientTemperatureCelsius = 11
        var wet = day; wet.rainIntensity = 1; wet.cloudiness = 1; wet.groundWetness = 1; wet.sunExposure = 0; wet.ambientTemperatureCelsius = 8
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("uavsim-thermal-realism", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (index, item) in [("day-iron", day, ThermalPalette.iron), ("day-white", day, .whiteHot),
                              ("day-black", day, .blackHot), ("night-iron", night, .iron), ("rain-iron", wet, .iron)].enumerated() {
            for _ in 0..<4 {
                let population = thermal.normalizationPopulation(groundClass: .asphalt, environmentRevision: 1)
                let range = ThermalNormalizationModel.make(population: population, context: item.1)
                thermal.updatePresentation(context: item.1, palette: item.2, contrast: 1, brightness: 0,
                    noiseAmount: 0.5, normalization: range, groundClass: .asphalt, environmentRevision: 1, now: Double(index))
                scene.background.contents = ThermalPaletteMapper.color(forTemperature: ThermalMaterialModel.skyTemperature(context: item.1),
                    displayMin: range.displayMinCelsius, displayMax: range.displayMaxCelsius, palette: item.2, contrast: 1, brightness: 0)
            }
            let image = gpu.snapshot(atTime: 0, with: NSSize(width: 960, height: 640), antialiasingMode: .multisampling4X)
            let bitmap = NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(item.0 + ".png"))
        }
        let building = root.childNodes.first { $0.name == "building" }!
        check(building.childNodes[0].geometry!.materials.count == 2, "Thermal buildings must retain facade and roof slots")
        check((building.childNodes[0].geometry!.materials[0].value(forKey: "thermalHasGlazingMask") as? NSNumber)?.boolValue == true,
              "Generated facade UVs must use the semantic glazing mask")
        print("Production city thermal previews: \(output.path)")
        thermal.clear()
    }

    static func thermalSpatialVariation(device: MTLDevice) throws {
        let scene = SCNScene()
        let source = SCNMaterial()
        source.diffuse.contents = NSColor.gray
        let materials = ThermalImportedSurfaceMaterials()
        let range = ThermalNormalizationState(displayMinCelsius: 20, displayMaxCelsius: 26)
        materials.update(context: .neutral, palette: .whiteHot, normalization: range,
                         contrast: 1, brightness: 0, noise: 0.5)
        let (_, material) = materials.acquire(source: source, materialClass: .building)
        // This fixture isolates procedural variation; directional heating and reflections are
        // covered separately by the physical-response fixture.
        material.setValue(NSNumber(value: 0.0), forKey: "thermalPhysicalEnabled")
        material.setValue(NSNumber(value: 23), forKey: "thermalBase")
        let facade = SCNNode(geometry: SCNPlane(width: 600, height: 400))
        facade.geometry!.firstMaterial = material
        scene.rootNode.addChildNode(facade)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera!.usesOrthographicProjection = true
        camera.camera!.orthographicScale = 160
        camera.simdPosition = SIMD3<Float>(0, 0, 60)
        scene.rootNode.addChildNode(camera)
        let gpu = SCNRenderer(device: device, options: nil)
        gpu.scene = scene; gpu.pointOfView = camera
        func snapshot(at time: Double) -> NSBitmapImageRep {
            let image = gpu.snapshot(atTime: time, with: NSSize(width: 384, height: 256), antialiasingMode: .none)
            return NSBitmapImageRep(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
        }
        let initial = snapshot(at: 0)
        let data = initial.representation(using: .png, properties: [:])!
        check(data == snapshot(at: 10).representation(using: .png, properties: [:])!,
              "Synthetic temperatures must not swim or flicker as time passes")
        try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("uavsim-thermal-patches-probe.png"))
        // Moving by the old sine wave's period must no longer reveal the same striped facade.
        camera.simdPosition.x = Float(2 * Double.pi / 0.19)
        let shifted = snapshot(at: 10)
        var pairs: [(Double, Double)] = []
        for y in stride(from: 16, to: 240, by: 4) {
            for x in stride(from: 16, to: 368, by: 4) {
                pairs.append((Double(initial.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!.redComponent),
                              Double(shifted.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!.redComponent)))
            }
        }
        let count = Double(pairs.count)
        let meanA = pairs.reduce(0) { $0 + $1.0 } / count
        let meanB = pairs.reduce(0) { $0 + $1.1 } / count
        let varianceA = pairs.reduce(0) { $0 + pow($1.0 - meanA, 2) }
        let varianceB = pairs.reduce(0) { $0 + pow($1.1 - meanB, 2) }
        let covariance = pairs.reduce(0) { $0 + ($1.0 - meanA) * ($1.1 - meanB) }
        check(varianceA / count > 0.001, "A large facade must contain actual spatial temperature variation")
        let correlation = covariance / sqrt(varianceA * varianceB)
        check(correlation < 0.55, String(format: "Facades must not repeat diagonal thermal waves; correlation %.3f", correlation))
        materials.update(context: .neutral, palette: .whiteHot, normalization: range,
                         contrast: 1, brightness: 0, noise: 0)
        material.setValue(NSNumber(value: 23), forKey: "thermalBase")
        let flat = snapshot(at: 10)
        let center = flat.colorAt(x: 192, y: 128)!.usingColorSpace(.sRGB)!.redComponent
        for (x, y) in [(64, 64), (320, 64), (64, 192), (320, 192)] {
            let sample = flat.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!.redComponent
            check(abs(sample - center) < 0.01, "Turning spatial variation off must remove synthetic patches")
        }
        print(String(format: "Thermal patches are stable, switchable and aperiodic; shifted-field correlation %.3f", correlation))
    }
}
