import AppKit
import Foundation
import SwiftUI
import SceneKit
import Metal
import AVFoundation
import simd
import DroneUAVDemo

@main struct FlightWorkbenchProbe {
    final class Keyboard: KeyboardInputProviding {
        var axis = KeyboardAxisInput.zero
        var heldCommands: Set<KeyboardCommand> = []
        var transition: Float = 0
        var processing = InputProcessingMode.flight
        var bindings = KeyBindingProfile.default
        var pendingActions: [InputAction] = []
        func start() {}
        func stop() {}
        func resetTransientState() { axis = .zero; transition = 0; heldCommands = [] }
        func currentAxisInput() -> KeyboardAxisInput { axis }
        func currentYawInput() -> KeyboardYawInput { .zero }
        func currentLookInput() -> KeyboardLookInput { .zero }
        func currentVTOLTransitionLever() -> Float { transition }
        func currentInputSnapshot() -> KeyboardInputSnapshot {
            KeyboardInputSnapshot(axisInput: axis, yawInput: .zero, lookInput: .zero,
                vtolTransitionLever: transition, activeContinuousCommands: heldCommands, processingMode: processing)
        }
        func consumeActions() -> [InputAction] { defer { pendingActions.removeAll() }; return pendingActions }
        func setInputProcessingMode(_ mode: InputProcessingMode) { processing = mode }
        func currentBindingProfile() -> KeyBindingProfile { bindings }
        func currentBindingConflicts() -> [String] { [] }
        func rebind(command: KeyboardCommand, to keyCode: UInt16, keyLabel: String) {
            bindings.bindings[command] = KeyBindingDescriptor(command: command, keyCode: keyCode, keyLabel: keyLabel)
        }
        func rebind(command: KeyboardCommand, to keyCode: UInt16, keyLabel: String, requiresShift: Bool) {
            bindings.rebind(command: command, keyCode: keyCode, keyLabel: keyLabel, requiresShift: requiresShift)
        }
        func resetBindingsToDefault() { bindings = .default }
        func setRaceBuilderShortcutsEnabled(_ enabled: Bool) {}
    }

    final class Projects: ProjectStorageManaging {
        var autosaves = 0
        func listProjects() -> [ProjectRecordSummary] { [] }
        func saveProject(id: String, name: String, snapshot: ProjectSnapshot) throws -> ProjectRecordSummary { throw ProjectStorageError.writeFailed }
        func loadProject(id: String) throws -> ProjectSnapshot { throw ProjectStorageError.projectNotFound }
        func duplicateProject(id: String, newName: String) throws -> ProjectRecordSummary { throw ProjectStorageError.projectNotFound }
        func deleteProject(id: String) throws {}
        func autosave(projectID: String, snapshot: ProjectSnapshot) throws { autosaves += 1 }
        func loadAutosave(projectID: String) -> ProjectSnapshot? { nil }
        func createProjectID() -> String { "instructor-probe" }
        func defaultProjectName() -> String { "Instructor probe" }
    }

    final class Telemetry: TelemetryExporting {
        func append(snapshot: TelemetrySnapshot) {}
        func exportNow(metadata: TelemetrySessionMetadata, destinationDirectory: URL?) -> Result<URL, Error> { .failure(TelemetryExportError.missingDestination) }
        func persistInternalSession(metadata: TelemetrySessionMetadata) -> Result<URL, Error> { .failure(TelemetryExportError.missingDestination) }
        func finalizeSession() {}
    }

    @MainActor static func main() throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "uavsim.flight-workbench.probe.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let previewPreferenceKeys = [AppGraphicsSettings.interfaceScaleKey, AppGraphicsSettings.renderScaleKey]
        let previewPreferences = Dictionary(uniqueKeysWithValues: previewPreferenceKeys.compactMap { key in
            UserDefaults.standard.object(forKey: key).map { (key, $0) }
        })
        defer {
            for key in previewPreferenceKeys {
                if let value = previewPreferences[key] { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1; precondition(value(), message)
        }
        func near(_ a: Double, _ b: Double, tolerance: Double = 0.00001) -> Bool { abs(a - b) < tolerance }
        let nativeKeyboard = KeyboardInputService(profile: .default, userDefaults: defaults)
        nativeKeyboard.start()
        let inputWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        inputWindow.contentView = NSView(); inputWindow.makeFirstResponder(inputWindow.contentView)
        func sendKey(_ down: Bool, code: UInt16) {
            NSApp.sendEvent(NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: inputWindow.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: code)!)
        }
        sendKey(true, code: 51)
        check(nativeKeyboard.currentInputSnapshot().activeContinuousCommands.contains(.rewindFlight) && nativeKeyboard.consumeActions().isEmpty, "Native key down must hold rewind without a toggle action")
        sendKey(false, code: 51)
        check(!nativeKeyboard.currentInputSnapshot().activeContinuousCommands.contains(.rewindFlight), "Native key up must release rewind")
        nativeKeyboard.rebind(command: .rewindFlight, to: 90, keyLabel: "F20")
        sendKey(true, code: 90)
        check(nativeKeyboard.currentInputSnapshot().activeContinuousCommands.contains(.rewindFlight), "Remapped rewind must also support hold")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        check(nativeKeyboard.currentInputSnapshot().activeContinuousCommands.isEmpty, "Focus loss must release held rewind")
        nativeKeyboard.stop()
        var history = FlightHistory<Int>(capacity: 5)
        for i in 0..<10 { history.append(time: Float(i), value: i) }
        check(history.count == 5 && history.oldestTime == 5, "History must evict old samples")
        check(history.entry(at: 6.8)?.value == 6 && history.entry(at: -5)?.value == 5, "Seek must resolve nearest earlier sample and clamp")
        history.discard(after: 6); history.append(time: 7, value: 777)
        check(history.entries.map(\.value) == [5, 6, 777], "Continuing from the past must discard the old future")
        let calibration = USBAxisCalibration(minimum: 100, center: 300, maximum: 1100)
        check(near(calibration.normalized(100), -1) && near(calibration.normalized(1100), 1), "Asymmetric endpoints must normalize fully")
        check(near(calibration.normalized(300), 0) && near(calibration.normalized(310), 0), "Neutral noise must be removed")
        check(near(calibration.normalized(100, inverted: true), 1), "Inversion must change axis direction")
        check(USBAxisCalibration(minimum: 0, center: 0, maximum: 0).normalized(12) == 0, "Invalid hardware calibration must never produce NaN")
        let keyboard = Keyboard()
        let bindingStore = InputBindingsStore(keyboardInputService: keyboard)
        let controller = ControllerSettingsStore(userDefaults: defaults)
        var config = USBDeviceConfiguration(deviceName: "Probe radio", calibration: [:], axes: [:], buttons: ["button": .arm])
        for (index, function) in ControllerAxisFunction.flightAxes.enumerated() {
            let channel = "axis\(index)"
            config.calibration[channel] = calibration
            config.axes[function.rawValue] = USBAxisAssignment(channel: channel)
        }
        try config.validate()
        let profile = ControlProfile(name: "Probe", keyboard: bindingStore.exportKeyboard(), controller: controller.exportConfiguration(), usb: ["radio":config], usbDeviceID: "radio")
        try profile.validate()
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ControlProfile.self, from: data)
        try decoded.validate()
        check(decoded.keyboard.count == profile.keyboard.count && decoded.usb == profile.usb, "Combined layout must survive JSON round trip")
        var invalid = profile; invalid.keyboard[0].keyCode = invalid.keyboard[1].keyCode; invalid.keyboard[0].requiresShift = invalid.keyboard[1].requiresShift
        check((try? invalid.validate()) == nil, "Duplicate key chords must be rejected before applying a file")
        var invalidRates = profile; invalidRates.controller.rateProfile?.yaw.expo = .infinity
        check((try? invalidRates.validate()) == nil, "Nonfinite input curves must be rejected")
        var duplicatedAxes = config; duplicatedAxes.axes[ControllerAxisFunction.yaw.rawValue] = duplicatedAxes.axes[ControllerAxisFunction.throttle.rawValue]
        check((try? duplicatedAxes.validate()) == nil, "Two flight controls cannot share a USB channel")
        let usb = USBControllerStore(defaults: defaults)
        config.buttons["button"] = .armSwitch
        config.buttons["rewind"] = .rewind
        let device = USBDevice(id: "12:34:portA", name: "Probe radio", channels:
            (0..<4).map { USBChannel(id: "axis\($0)", name: "Axis \($0)", minimum: 100, maximum: 1100, isButton: false) }
            + [USBChannel(id: "button", name: "Switch", minimum: 0, maximum: 1, isButton: true), USBChannel(id: "rewind", name: "Rewind", minimum: 0, maximum: 1, isButton: true)])
        usb.injectReportsForTesting(device: device, values: [:])
        usb.importConfigurations(["12:34:portB": config], selectedID: "12:34:portB")
        check(usb.selectedDeviceID == device.id, "Import must recognize the same transmitter in another USB port")
        check(usb.inputSnapshot(rates: controller.rateProfile)?.isConnected == false, "Missing HID reports must never become half throttle")
        var reports = Dictionary(uniqueKeysWithValues: (0..<4).map { ("axis\($0)", 300.0) })
        reports[config.axes[ControllerAxisFunction.throttle.rawValue]!.channel] = 100
        reports["button"] = 1; reports["rewind"] = 0
        usb.injectReportsForTesting(device: device, values: reports)
        let firstUSB = usb.inputSnapshot(rates: controller.rateProfile)!
        check(firstUSB.actions.isEmpty && firstUSB.absoluteThrottle == controller.rateProfile.throttle.shaped(0), "Connecting with an ARM switch already held must remain disarmed at idle")
        reports["button"] = 0; usb.injectReportsForTesting(device: device, values: reports)
        check(usb.inputSnapshot(rates: controller.rateProfile)!.actions == [.disarmAircraft], "Releasing an ARM switch must disarm")
        reports["button"] = 1; usb.injectReportsForTesting(device: device, values: reports)
        check(usb.inputSnapshot(rates: controller.rateProfile)!.actions == [.armAircraft], "ARM must act on the rising edge")
        check(usb.inputSnapshot(rates: controller.rateProfile)!.actions.isEmpty, "Holding ARM must not repeat the action")
        reports["rewind"] = 1; usb.injectReportsForTesting(device: device, values: reports)
        check(usb.isRewindHeld && usb.inputSnapshot(rates: controller.rateProfile)!.actions.isEmpty, "USB rewind must remain held without emitting toggle actions")
        reports["rewind"] = 0; usb.injectReportsForTesting(device: device, values: reports)
        check(!usb.isRewindHeld, "USB release must end rewind")
        usb.isCalibrating = true
        check(usb.inputSnapshot(rates: controller.rateProfile)!.isConnected == false, "Calibration must suppress flight input")
        usb.isCalibrating = false
        check(usb.inputSnapshot(rates: controller.rateProfile)!.actions.isEmpty, "Closing calibration with a held switch must not arm")
        usb.injectReportsForTesting(device: device, values: [:], disconnected: true)
        let disconnected = usb.inputSnapshot(rates: controller.rateProfile)!
        check(!disconnected.isConnected && disconnected.actions == [.disarmAircraft], "Unplugging the selected transmitter must disarm once")
        check(usb.inputSnapshot(rates: controller.rateProfile)!.actions.isEmpty, "Disconnect disarm must not repeat")
        var terrain = TerrainConfiguration.default; terrain.reliefEnabled = true; terrain.reliefAmplitude = 90
        check(near(Double(terrain.surfaceHeight(x: 0, z: 0)), 0), "Launch platform must remain level")
        check(terrain.surfaceHeight(x: 250, z: 300) > 1, "Relief must change the land height outside launch area")
        let heightGrid = terrain.reliefVertices.map(\.y)
        for point in [SIMD2<Float>(0, 0), SIMD2(250, 300), SIMD2(-270, 310), SIMD2(440, -320)] {
            let hit = terrain.reliefRayDistance(origin: SIMD3(point.x, 500, point.y), direction: SIMD3(0, -1, 0), maxDistance: 600, heights: heightGrid)
            check(hit != nil && abs(hit! - (500 - terrain.surfaceHeight(x: point.x, z: point.y))) < 0.002, "Vertical sensors must hit the exact physical terrain triangle")
        }
        check(terrain.reliefRayDistance(origin: SIMD3(250, 500, 300), direction: SIMD3(1, 0, 0), maxDistance: 300, heights: heightGrid) == nil, "A clear ray above hills must remain unobstructed")
        let obliqueOrigin = SIMD3<Float>(-250, 170, -200), obliqueDirection = simd_normalize(SIMD3<Float>(1, -0.5, 0.6))
        let oblique = terrain.reliefRayDistance(origin: obliqueOrigin, direction: obliqueDirection, maxDistance: 1500, heights: heightGrid)!
        let pointOnRay = obliqueOrigin + obliqueDirection * oblique
        check(abs(pointOnRay.y - terrain.surfaceHeight(x: pointOnRay.x, z: pointOnRay.z)) < 0.002, "Oblique sensors must intersect the rendered hillside")
        let corners = terrain.reliefCorners
        for triangle in stride(from: 4020, to: 6000, by: 60) {
            let point = (corners[triangle] + corners[triangle + 1] + corners[triangle + 2]) / 3
            check(abs(terrain.surfaceHeight(x: point.x, z: point.z) - point.y) < 0.002, "Physical support must lie on the rendered triangle")
        }
        var wind = WeatherModel.normal; wind.windSpeedMps = 12; wind.gusts = 0.6; wind.spatialWindEnabled = true
        let at = SIMD3<Float>(100, 40, 200)
        check(wind.wind(at: at, time: 5) == wind.wind(at: at, time: 5), "Wind must reproduce exactly after rewinding time")
        check(wind.wind(at: at, time: 5) != wind.wind(at: SIMD3(300, 40, 200), time: 5), "Wind must vary spatially")
        check(wind.wind(at: at, time: 5) != wind.wind(at: at, time: 6), "Gusts must vary with simulation time")
        check(wind.wind(at: SIMD3(0, 1, 0), time: 5) != wind.wind(at: SIMD3(0, 100, 0), time: 5), "Wind shear must vary with height")
        wind.spatialWindEnabled = false
        check(wind.wind(at: at, time: 5) == wind.windVector, "Uniform wind option must retain legacy behavior")
        let recorder = MissionReplayRecorder(minFrameInterval: 0.01)
        recorder.startSession(at: Date().addingTimeInterval(-8))
        func frame(_ timestamp: Double) -> MissionReplayFrame {
            MissionReplayFrame(id: UUID(), timestamp: timestamp, position: CodableVector3D(x: 0, y: 10, z: 0),
                velocity: CodableVector3D(x: 0, y: 0, z: 0), attitude: MissionAttitudeSnapshot(rollRadians: 0, pitchRadians: 0, yawRadians: 0),
                flightModeDescription: "Manual", autopilotDescription: nil, activeWaypointIndex: nil, batteryPercent: 90, payloadStatusDescription: nil, warningCount: 0)
        }
        for time in [1.0, 2.0, 4.0] { recorder.recordFrame(frame(time), force: true) }
        recorder.recordEvent(MissionReplayEvent(id: UUID(), timestamp: 3, type: .sessionStopped, message: "Old future", position: nil))
        recorder.pauseTimeline()
        let pausedClock = recorder.timelineTimestamp
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        check(recorder.timelineTimestamp == pausedClock, "Rewind must freeze the recording clock")
        recorder.resumeTimeline(at: 2)
        check(recorder.currentSession?.frames.map(\.timestamp) == [1, 2], "Continuing a past recording must discard later frames")
        check(recorder.currentSession?.events.contains(where: { $0.message == "Old future" }) == false, "Continuing must discard future recording events")
        check(abs(recorder.timelineTimestamp - 2) < 0.1, "Recording clock must restart at the selected time")
        recorder.recordFrame(frame(2.1))
        check(recorder.currentSession?.frames.last?.timestamp == 2.1, "Recording must accept new frames after a branch")
        check(recorder.currentSession?.duration == 2.1, "Recording duration must use the branched flight timeline")
        recorder.stopSession(timestamp: 2.1)
        check(recorder.lastCompletedSession?.duration == 2.1, "Saved duration must exclude time spent rewinding")
        check(KeyboardCommand.rewindFlight.isContinuous, "Rewind binding must track key down and key up")
        let rewindAudioURL = Bundle.main.resourceURL!.appendingPathComponent("Audio/UI/flight_rewind_loop.wav")
        let rewindAudio = try AVAudioFile(forReading: rewindAudioURL)
        check(rewindAudio.fileFormat.channelCount == 1 && rewindAudio.fileFormat.sampleRate == 48000 && rewindAudio.length == 192000, "Rewind must bundle a decoded four-second looping sound")
        let library = ReplayLibraryViewModel(storage: MissionReplayStorageService(directory: output.appendingPathComponent("replays")), settingsStore: MissionReplaySettingsStore(defaults: defaults))
        let vm = DroneSimulationViewModel(keyboardInputService: keyboard, controllerSettingsStore: controller,
            telemetryExporter: Telemetry(), projectStorage: Projects(),
            initialDroneProfile: LIPODroneModelRepository.abstractProfile(from: .default), replayLibraryViewModel: library, instructorProgressDefaults: defaults)
        defer { vm.stopRuntimeForExit() }
        vm.setTerrainPreset(.gridDemo)
        _ = vm.advanceFlightTrainingForTesting(steps: 2)
        vm.arm(); vm.setThrottle(0.65); vm.setPitch(8)
        let present = vm.advanceFlightTrainingForTesting(steps: 420)
        check(vm.rewindAvailableSeconds > 4, "Running physical flight must create rewind history")
        check(present.position.y > 1, "Rewind integration must exercise an airborne aircraft")
        let battery = vm.batteryState.chargePercent
        vm.setFlightRewindHeld(true)
        check(vm.rewindOffsetSeconds == 0, "Pressing rewind must start at the present without jumping")
        check(vm.isRewindingFlight, "Rewind must pause live physics")
        let past = vm.advanceFlightTrainingForTesting(steps: 60)
        check(past.position != present.position && abs(vm.rewindOffsetSeconds - 3) < 0.01, "Holding rewind must move continuously backwards at three times flight speed")
        check(vm.batteryState.chargePercent >= battery, "Scrubbing must restore earlier battery charge")
        vm.cancelFlightRewind()
        let cancelled = vm.advanceFlightTrainingForTesting(steps: 0)
        check(cancelled.position == present.position && cancelled.velocity == present.velocity, "Cancel must restore the exact present state")
        check(vm.batteryState.chargePercent == battery, "Cancel must restore present battery charge")
        let beforeCalibration = vm.advanceFlightTrainingForTesting(steps: 0)
        let beforeCalibrationCharge = vm.batteryState.chargePercent
        USBControllerStore.shared.isCalibrating = true
        check(vm.advanceFlightTrainingForTesting(steps: 180).position == beforeCalibration.position && vm.batteryState.chargePercent == beforeCalibrationCharge, "Calibrating must freeze the aircraft and battery")
        check(vm.scene.isPaused, "Calibrating must also freeze SceneKit physics")
        USBControllerStore.shared.isCalibrating = false
        _ = vm.advanceFlightTrainingForTesting(steps: 2)
        check(!vm.scene.isPaused, "Closing calibration must restore scene playback")
        vm.setFlightRewindHeld(true); vm.seekFlightRewind(secondsBack: 2)
        let selected = vm.advanceFlightTrainingForTesting(steps: 0)
        vm.setFlightRewindHeld(false)
        check(!vm.isRewindingFlight && vm.mode == .manual, "Resume must hand control to the pilot")
        check(vm.advanceFlightTrainingForTesting(steps: 0).position == selected.position, "Resume must start at the selected position")
        let continued = vm.advanceFlightTrainingForTesting(steps: 90)
        check(continued.position != selected.position, "Physics must run after resuming a past state")
        keyboard.heldCommands = [.rewindFlight]
        _ = vm.advanceFlightTrainingForTesting(steps: 1)
        check(vm.isRewindingFlight, "Holding the remappable keyboard command must start rewind")
        let rewindFrameCount = vm.flightReplayForTesting()?.frameCount
        vm.seekFlightRewind(secondsBack: vm.rewindAvailableSeconds)
        let paused = vm.advanceFlightTrainingForTesting(steps: 0)
        check(vm.advanceFlightTrainingForTesting(steps: 180).position == paused.position, "Holding at the oldest state must clamp instead of resuming automatically")
        check(vm.flightReplayForTesting()?.frameCount == rewindFrameCount, "Rewinding must never append reverse motion to the replay")
        keyboard.heldCommands = []
        _ = vm.advanceFlightTrainingForTesting(steps: 1)
        check(!vm.isRewindingFlight && vm.mode == .manual, "Keyboard release must resume pilot control")
        let branchReplay = vm.flightReplayForTesting()!
        check(simd_distance(branchReplay.frames.last!.position.simdFloat, paused.position) < 0.001, "Replays must record the exact resumed boundary position")
        check(branchReplay.frames.allSatisfy { $0.timestamp <= branchReplay.frames.last!.timestamp }, "Replays must discard the previous future")
        _ = vm.advanceFlightTrainingForTesting(steps: 60)
        vm.setFlightRewindHeld(true)
        _ = vm.advanceFlightTrainingForTesting(steps: 10)
        func save<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat) throws {
            let host = NSHostingView(rootView: view.frame(width: width, height: height).background(GroundControlPalette.shell)
                .environment(\.locale, Locale(identifier: "ru")).preferredColorScheme(.dark))
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw ControlProfileError.invalid("Cannot render \(name)") }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ControlProfileError.invalid("Cannot encode \(name)") }
            try png.write(to: output.appendingPathComponent(name + ".png"))
            func findScene(_ view: NSView) -> SCNView? {
                if let scene = view as? SCNView { return scene }
                return view.subviews.lazy.compactMap(findScene).first
            }
            if let sceneView = findScene(host), let scene = sceneView.scene {
                let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
                renderer.scene = scene; renderer.pointOfView = sceneView.pointOfView
                let rendered = renderer.snapshot(atTime: 0.5, with: CGSize(width: 1000, height: 520), antialiasingMode: .multisampling4X)
                if let tiff = rendered.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let bytes = rep.representation(using: .png, properties: [:]) {
                    try bytes.write(to: output.appendingPathComponent(name + "-scene.png"))
                }
            }
            window.contentView = nil
        }
        try save(FlightRewindOverlay(viewModel: vm), name: "rewind", width: 1100, height: 700)
        vm.cancelFlightRewind()
        try save(FPVOSDEditorView(), name: "osd", width: 1120, height: 680)
        try save(SettingsView(onClose: {}, initialPage: .video), name: "interface-settings", width: 1000, height: 720)
        UserDefaults.standard.set(1.5, forKey: AppGraphicsSettings.interfaceScaleKey)
        try save(ScaledSettingsPanel { SettingsView(onClose: {}, initialPage: .video) }, name: "interface-150", width: 1000, height: 720)
        UserDefaults.standard.set(1.0, forKey: AppGraphicsSettings.interfaceScaleKey)
        try save(MapSelectionView(airframeClass: .multirotor, onConfirm: { _ in }, onCancel: {}), name: "map-selection", width: 1000, height: 720)
        try save(MapSelectionView(airframeClass: .multirotor, onConfirm: { _ in }, onCancel: {}, relief: true), name: "map-selection-relief", width: 1000, height: 720)
        try save(TransmitterResponsePreview(axes: [.roll: 0.4, .pitch: -0.3, .yaw: 0.5, .throttle: 0.6], pressed: [0, 8], profile: vm.selectedDroneProfile), name: "transmitter", width: 1000, height: 520)
        let realAircraft = DroneModelBuilder.build(profile: LIPODroneModelRepository().defaultProfile)
        check(realAircraft.rootNode.childNode(withName: "uavRoot.model.dji-matrice-350-rtk", recursively: true) != nil,
              "The default preview aircraft must load the real catalogue USDZ model")
        vm.setReliefTerrain(enabled: true, amplitude: 90)
        vm.setSpatialWindEnabled(true)
        let storedTerrain = ProjectSnapshot.Terrain(presetRaw: "field", mapScaleRaw: "x16", density: 0.2, seed: 42, safeSpawnRadius: 15, reliefEnabled: true, reliefAmplitude: 90, showsBoundaryBarrier: false)
        let reloadedTerrain = try JSONDecoder().decode(ProjectSnapshot.Terrain.self, from: JSONEncoder().encode(storedTerrain))
        check(reloadedTerrain.reliefEnabled == true && reloadedTerrain.reliefAmplitude == 90, "Projects must preserve procedural relief")
        let surface = vm.groundSurfaceForTesting(at: SIMD2(250, 300))
        check(surface != nil && surface! > 1, "A step into a hillside must hit solid ground rather than tunnel under it")
        let rig = TransmitterResponsePreview.makeTransmitterNode()
        let leftGimbal = rig.childNode(withName: "GimbalLeft", recursively: true)
        let rightGimbal = rig.childNode(withName: "GimbalRight", recursively: true)
        check(leftGimbal != nil && rightGimbal != nil, "USDZ must contain independently articulated gimbals")
        check(rig.childNode(withName: "Switch7", recursively: true) != nil && rig.childNode(withName: "Button5", recursively: true) != nil, "USDZ must contain individual switches and push buttons")
        var meshCount = 0
        rig.enumerateChildNodes { node, _ in if node.geometry != nil { meshCount += 1 } }
        check(meshCount >= 100, "Transmitter must load the detailed 3D asset rather than primitive stand-ins")
        let tip = leftGimbal!.childNode(withName: "StickCap_01", recursively: true)!
        let bounds = tip.boundingBox
        let center = SIMD3<Float>(Float((bounds.min.x + bounds.max.x) / 2), Float((bounds.min.y + bounds.max.y) / 2), Float((bounds.min.z + bounds.max.z) / 2))
        let before = rig.simdConvertPosition(center, from: tip)
        leftGimbal!.eulerAngles.x = 0.4
        check(simd_distance(before, rig.simdConvertPosition(center, from: tip)) > 0.005 && rightGimbal!.eulerAngles.x == 0, "A stick pivot must move its shaft in 3D without moving the other gimbal")
        let sceneryRoot = SCNNode(); var naturalTerrain = terrain; naturalTerrain.preset = .field; naturalTerrain.mapScale = .x8
        let scenery = ScenePopulationService(rootNode: sceneryRoot)
        let (objects, _) = scenery.populate(with: naturalTerrain)
        check(objects.contains { $0.kind == .tree } && objects.contains { $0.kind == .rock }, "Relief must populate real vegetation and rocks")
        check(objects.allSatisfy { abs($0.position.y - naturalTerrain.surfaceHeight(x: $0.position.x, z: $0.position.z)) < 0.001 }, "Procedural scenery must stand on the physical relief")
        var assetTrees = 0
        sceneryRoot.enumerateChildNodes { node, _ in if node.name == "environment.pine_tree" { assetTrees += 1 } }
        check(assetTrees > 0, "Relief vegetation must use the existing tree USDZ asset")
        let reliefNode = TerrainMeshFactory.makeReliefNode(configuration: naturalTerrain)!
        check(reliefNode.geometry?.sources(for: .texcoord).isEmpty == false && reliefNode.geometry?.firstMaterial?.value(forKey: "reliefDirt") != nil && reliefNode.geometry?.firstMaterial?.shaderModifiers?[.surface] != nil, "Relief must use tiled grass, dirt and stone asset materials")
        let reliefCamera = SCNNode(); reliefCamera.camera = SCNCamera()
        reliefCamera.camera?.zFar = 10000
        reliefCamera.position = SCNVector3(460, 280, 460); reliefCamera.look(at: SCNVector3(0, 30, 0))
        vm.scene.rootNode.addChildNode(reliefCamera)
        let reliefRenderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        reliefRenderer.scene = vm.scene; reliefRenderer.pointOfView = reliefCamera
        let reliefImage = reliefRenderer.snapshot(atTime: 0, with: CGSize(width: 1100, height: 720), antialiasingMode: .multisampling4X)
        if let tiff = reliefImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: output.appendingPathComponent("relief.png"))
        }
        let previousSurface = vm.scene.rootNode.childNode(withName: "world.procedural.relief", recursively: false)!
        vm.setTerrainPreset(.forest)
        vm.setReliefTerrain(enabled: true, amplitude: 90)
        let forestSurface = vm.scene.rootNode.childNode(withName: "world.procedural.relief", recursively: false)!
        check(forestSurface !== previousSurface && abs(Float(forestSurface.boundingBox.max.x) - (vm.terrain.beltOuterRadius + 24)) < 0.02,
              "Changing relief biome must regenerate the mesh at the new physical extent")
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        _ = vm.advanceFlightTrainingForTesting(steps: 2)
        let currentReplay = vm.flightReplayForTesting()!
        print("Replay probe: rewinding=\(vm.isRewindingFlight) running=\(vm.isSimulationRunning) frames=\(currentReplay.frameCount) changes=\(currentReplay.environmentChanges?.count ?? 0) duration=\(currentReplay.duration)")
        let context = currentReplay.environmentChanges!.last!.context
        let decodedContext = try JSONDecoder().decode(MissionReplayContextSnapshot.self, from: JSONEncoder().encode(context))
        check(decodedContext == context && context.terrainSafeSpawnRadius == vm.terrain.safeSpawnRadius && context.spatialWindEnabled == true, "Replay context must preserve the exact relief and spatial wind settings")
        let trimmingRecorder = MissionReplayRecorder()
        trimmingRecorder.startSession(context: context)
        var firstEnvironment = context; firstEnvironment.terrainReliefAmplitude = 45
        var futureEnvironment = context; futureEnvironment.terrainReliefAmplitude = 180
        trimmingRecorder.recordEnvironment(firstEnvironment, at: 1)
        trimmingRecorder.recordEnvironment(futureEnvironment, at: 4)
        trimmingRecorder.pauseTimeline(); trimmingRecorder.resumeTimeline(at: 2)
        check(trimmingRecorder.currentSession?.environmentChanges?.map(\.timestamp) == [1], "Rewind branching must also remove future terrain changes")
        check(trimmingRecorder.currentSession?.environmentChanges?.last?.context == firstEnvironment, "The resumed branch must retain the previous world settings")
        let mapSnapshot = vm.terrainMapSnapshot
        check(mapSnapshot.reliefEnabled && mapSnapshot.reliefConfiguration.surfaceHeight(x: 250, z: 300) == vm.terrain.surfaceHeight(x: 250, z: 300), "Map and physics must use the identical seeded height field")
        let mapImage = TerrainMapReliefTextureProvider.texture(for: mapSnapshot)
        check(mapImage === TerrainMapReliefTextureProvider.texture(for: mapSnapshot), "Relief map must cache its raster across flight ticks")
        try save(TerrainMapCanvas(snapshot: mapSnapshot, routeTargetPosition: nil, dropZone: nil, highlightDropZone: false), name: "relief-map", width: 800, height: 700)
        let replayScene = MissionReplaySceneController()
        var reliefSession = currentReplay; reliefSession.context = context; reliefSession.environmentChanges = nil
        replayScene.loadSession(reliefSession)
        let replayRelief = replayScene.scene.rootNode.childNode(withName: "world.procedural.relief", recursively: true)
        check(replayRelief != nil && !replayRelief!.isHidden, "Replay must reconstruct visible relief alongside recorded world assets")
        let expectedRelief = TerrainMeshFactory.makeReliefNode(configuration: vm.terrain)!
        check(replayRelief!.boundingBox.max.y == expectedRelief.boundingBox.max.y, "Replay relief must reproduce the recorded terrain height")
        var changingSession = currentReplay
        changingSession.context = branchReplay.context
        replayScene.loadSession(changingSession)
        replayScene.update(frame: currentReplay.frames.last!, replayTime: currentReplay.frames.last!.timestamp, duration: currentReplay.duration)
        let changedRelief = replayScene.scene.rootNode.childNode(withName: "world.procedural.relief", recursively: true)!
        check(changedRelief.boundingBox.max.y == expectedRelief.boundingBox.max.y, "Seeking a replay must restore terrain changes made during the flight")
        replayScene.update(frame: currentReplay.frames.first!, replayTime: 0, duration: currentReplay.duration)
        check(replayScene.scene.rootNode.childNode(withName: "world.procedural.relief", recursively: true) == nil, "Seeking before relief creation must restore the original flat world")
        let placement = MissionScenarioPlacement(sectorCenter: SIMD2(250, 300), sectorRadius: 40, targetPosition: SIMD2(270, 310), candidatePositions: [])
        let scenarioScene = DroneSceneController(initialProfile: vm.selectedDroneProfile)
        scenarioScene.regenerateEnvironment(vm.terrain)
        let target = scenarioScene.spawnMissionSearchScenario(placement: placement)
        check(abs(target.y - (vm.terrain.surfaceHeight(x: 270, z: 310) + 1)) < 0.001, "Search targets must stand on the relief")
        let belowGround = SIMD3<Float>(250, vm.terrain.surfaceHeight(x: 250, z: 300) - 2, 300)
        check(!scenarioScene.isLineOfSightClearToMissionTarget(from: SIMD3(250, 500, 300), to: belowGround), "Scenario cameras must be blocked by relief")
        check(scenarioScene.isLineOfSightClearToMissionTarget(from: SIMD3(250, 500, 300), to: SIMD3(350, 500, 300)), "Scenario cameras must see an unobstructed line above relief")
        let firePlacement = FireZonePlacement(zoneCenter: SIMD2(250, 300), zoneRadius: 20, treePositions: [SIMD2(250, 300), SIMD2(265, 308)], initiallyBurningIndices: [0], truckStandoffMeters: 10)
        let fireAnchors = scenarioScene.spawnFireResponseScenario(placement: firePlacement)
        check(fireAnchors.enumerated().allSatisfy { $0.element.y > vm.terrain.surfaceHeight(x: firePlacement.treePositions[$0.offset].x, z: firePlacement.treePositions[$0.offset].y) }, "Fire anchors must be above the local hillside")
        var fireTrees: [SCNNode] = []
        scenarioScene.scene.rootNode.enumerateChildNodes { node, _ in if node.name == "mission.fire_tree" { fireTrees.append(node) } }
        check(fireTrees.count == 2 && fireTrees.allSatisfy { abs($0.simdPosition.y - vm.terrain.surfaceHeight(x: $0.simdPosition.x, z: $0.simdPosition.z)) < 0.001 }, "Burning trees must stand on their individual terrain heights")
        let agriPlacement = AgriFieldPlacement(fieldCenter: SIMD2(250, 300), fieldHalfExtent: 12, rowHeadingRadians: 0.4, stationPosition: SIMD2(230, 300), cellsPerSide: 8)
        let station = scenarioScene.spawnAgriSprayScenario(placement: agriPlacement, difficulty: .easy)
        check(abs(station.y - vm.terrain.surfaceHeight(x: station.x, z: station.z)) < 0.001, "Agricultural refill station must sit on the local ground")
        let soil = scenarioScene.scene.rootNode.childNode(withName: "agri.field.soil", recursively: true)!
        let soilSource = soil.geometry!.sources(for: .vertex)[0]
        check(soilSource.vectorCount > 4, "Agricultural soil must conform to relief rather than remain a flat quad")
        soilSource.data.withUnsafeBytes { data in
            func scalar(_ offset: Int) -> Float {
                soilSource.bytesPerComponent == 4 ? data.loadUnaligned(fromByteOffset: offset, as: Float.self) : Float(data.loadUnaligned(fromByteOffset: offset, as: Double.self))
            }
            for index in stride(from: 0, to: soilSource.vectorCount, by: 17) {
                let base = soilSource.dataOffset + index * soilSource.dataStride
                let p = SIMD3<Float>(scalar(base), scalar(base + soilSource.bytesPerComponent), scalar(base + soilSource.bytesPerComponent * 2))
                check(abs(p.y - vm.terrain.surfaceHeight(x: p.x, z: p.z) - 0.04) < 0.001, "Field vertices must lie directly above the physical hillside")
            }
        }
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(currentReplay)) as! [String: Any]
        legacy.removeValue(forKey: "recordedDuration"); legacy.removeValue(forKey: "environmentChanges")
        check((try? JSONDecoder().decode(MissionReplaySession.self, from: JSONSerialization.data(withJSONObject: legacy))) != nil, "Older replay sessions must still decode without timeline metadata")
        let params = MissionScenarioParameters(terrain: .field, seed: 42, reliefEnabled: true, reliefAmplitude: 120)
        let mission = MissionScenarioConfiguration(parameters: params, selectedUAVProfileID: LIPODroneModelRepository().defaultProfile.id, payloadType: .thermalCamera)
        let missionVM = DroneSimulationViewModel(keyboardInputService: Keyboard(), controllerSettingsStore: controller, telemetryExporter: Telemetry(), projectStorage: Projects(), initialDroneProfile: LIPODroneModelRepository.abstractProfile(from: .default), missionScenarioContext: mission, replayLibraryViewModel: library, instructorProgressDefaults: defaults)
        defer { missionVM.stopRuntimeForExit() }
        _ = missionVM.advanceFlightTrainingForTesting(steps: 12)
        check(missionVM.terrain.reliefEnabled && missionVM.terrain.reliefAmplitude == 120 && missionVM.terrain.seed == 42, "Launching a mission must apply its chosen relief before spawning actors")
        let missionContext = missionVM.flightReplayForTesting()!.context!
        check(missionContext.terrainReliefEnabled == true && missionContext.terrainReliefAmplitude == 120 && missionContext.terrainSafeSpawnRadius == missionVM.terrain.safeSpawnRadius && missionContext.windSpeedMps == missionVM.weather.windSpeedMps, "Mission recordings must capture exact terrain and wind settings")
        print("PASS: \(checks) checks — history branching, calibration, import validation, physical rewind/cancel/resume, relief collision and spatial wind")
    }
}
