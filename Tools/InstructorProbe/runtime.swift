import AppKit
import Darwin
import Foundation
import Metal
import SceneKit
import SwiftUI
import simd
import DroneUAVDemo

/// A static render surface around production instructor and button views. It does not open or
/// operate the desktop UI; anchors let the offscreen render verify actual leader placement.
@MainActor
private struct InstructorPreviewWorkspace: View {
    let viewModel: DroneSimulationViewModel
    let sceneImage: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("instructor.project_name").font(.system(size: 15, weight: .semibold))
                Spacer()
                Image(systemName: "archivebox"); Image(systemName: "keyboard")
                Image(systemName: "map").instructorTarget("simulation.map")
            }.padding(14).background(GroundControlPalette.shell)
            HStack(spacing: 10) {
                ForEach(ControlModule.allCases) { module in
                    Label(LocalizedStringKey(module.toolbarTitleKey), systemImage: module.iconSystemName)
                        .font(.system(size: 12, weight: .semibold)).padding(12)
                        .background(GroundControlPalette.panelRaised, in: RoundedRectangle(cornerRadius: 10))
                        .instructorTarget("simulation.\(module.rawValue)")
                }
                Spacer()
            }.padding(12).background(GroundControlPalette.shell).instructorTarget("simulation.toolbar")
            HStack(spacing: 0) {
                if viewModel.isParametersPanelVisible {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(LocalizedStringKey(viewModel.activeControlModule?.titleKey ?? "module.flight_ops.title"))
                            .font(.system(size: 20, weight: .bold)).padding(.top, 14)
                        Text("module.flight_ops.command_stack").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            OperationalActionButton(titleKey: "command.arm", systemImage: "lock.fill", prominent: true) {}
                                .instructorTarget("simulation.command.arm")
                            OperationalActionButton(titleKey: "command.takeoff", systemImage: "arrow.up.circle.fill", prominent: true) {}
                                .instructorTarget("simulation.command.takeoff")
                        }
                        HStack {
                            OperationalActionButton(titleKey: "command.hover", systemImage: "pause.circle.fill") {}
                                .instructorTarget("simulation.command.hover")
                            OperationalActionButton(titleKey: "command.auto_path", systemImage: "point.topleft.down.curvedto.point.bottomright.up") {}
                                .instructorTarget("simulation.command.autoPath")
                        }
                        OperationalActionButton(titleKey: "command.return_home", systemImage: "house.fill") {}
                            .instructorTarget("simulation.command.returnHome")
                        Spacer()
                    }.padding(.horizontal, 14).frame(width: 430)
                        .background(GroundControlPalette.panel)
                }
                GeometryReader { area in
                ZStack(alignment: .topLeading) {
                    if let sceneImage {
                        Image(nsImage: sceneImage).resizable().scaledToFill()
                            .frame(width: area.size.width, height: area.size.height).clipped()
                    } else { GroundControlPalette.inset }
                    CompactTelemetryHUDView(telemetry: viewModel.telemetry, warningKeys: [])
                        .instructorTarget("simulation.instruments").padding(14)
                }.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).clipped()
                }
                    .instructorTarget("simulation.viewport")
            }
        }.foregroundStyle(GroundControlPalette.textPrimary)
            .overlayPreferenceValue(InstructorTargetPreferenceKey.self) { targets in
                FlightInstructorOverlayView(viewModel: viewModel, targets: targets, onExit: {}, animateEntrance: false)
            }
    }
}

/// Links the production app objects. No window, app lifecycle or desktop input is created.
@main
struct InstructorRuntimeProbe {
    final class Keyboard: KeyboardInputProviding {
        var axis = KeyboardAxisInput.zero
        var transition: Float = 0
        var processing = InputProcessingMode.flight
        var bindings = KeyBindingProfile.default
        var pendingActions: [InputAction] = []
        func start() {}
        func stop() {}
        func resetTransientState() { axis = .zero; transition = 0 }
        func currentAxisInput() -> KeyboardAxisInput { axis }
        func currentYawInput() -> KeyboardYawInput { .zero }
        func currentLookInput() -> KeyboardLookInput { .zero }
        func currentVTOLTransitionLever() -> Float { transition }
        func currentInputSnapshot() -> KeyboardInputSnapshot {
            KeyboardInputSnapshot(axisInput: axis, yawInput: .zero, lookInput: .zero,
                vtolTransitionLever: transition, activeContinuousCommands: [], processingMode: processing)
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

    @MainActor static func main() {
        setbuf(stdout, nil)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "uavsim.instructor.runtime.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keyboard = Keyboard()
        let projects = Projects()
        let library = ReplayLibraryViewModel(
            storage: MissionReplayStorageService(directory: output.appendingPathComponent("replays")),
            settingsStore: MissionReplaySettingsStore(defaults: defaults))
        let vm = DroneSimulationViewModel(keyboardInputService: keyboard, telemetryExporter: Telemetry(),
            projectStorage: projects, replayLibraryViewModel: library, instructorProgressDefaults: defaults)
        defer { vm.stopRuntimeForExit() }
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(value(), message)
        }
        func state() -> DroneState { vm.advanceFlightTrainingForTesting(steps: 0) }
        func tick(_ count: Int = 1) { vm.advanceFlightTrainingForTesting(steps: count) }
        func waitForCheckpoint(seconds: Int = 40) {
            let step = vm.flightTrainingProgress!.step
            for _ in 0..<(seconds * 60) {
                vm.advanceFlightTrainingForTesting(steps: 1)
                if vm.flightTrainingProgress?.phase != .flying { break }
            }
            print("LIVE \(step.rawValue): \(vm.flightTrainingProgress!.phase) y=\(state().position.y) vy=\(state().velocity.y) speed=\(state().forwardAirspeed) mode=\(vm.mode) why=\(vm.lastModeTransitionReason) physical=\(vm.physicalState) vtol=\(state().vtolTransitionProgress) phase=\(state().vtolPhase) blocked=\(state().vtolTransitionBlocked) throttle=\(vm.controlValues.throttle)")
            check(vm.flightTrainingProgress?.phase == .checkpoint, "Live lesson did not complete: \(step)")
        }
        func next() { vm.continueFlightTraining(deferPreparation: false) }
        func save(_ image: NSImage, name: String) {
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
        }
        func renderCard(_ name: String, locale: String = "ru") {
            let view = FlightInstructorOverlayView(viewModel: vm, targets: [:], onExit: {}, animateEntrance: false)
                .frame(width: 1100, height: 720)
                .background(LinearGradient(colors: [Color(red: 0.19, green: 0.26, blue: 0.31), .black],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                .environment(\.locale, Locale(identifier: locale))
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let image = renderer.nsImage else { preconditionFailure("Instructor card cannot render") }
            save(image, name: name)
        }
        func renderWorkspace(_ name: String, locale: String = "ru") {
            var sceneImage: NSImage?
            if let device = MTLCreateSystemDefaultDevice() {
                let renderer = SCNRenderer(device: device, options: nil)
                renderer.scene = vm.scene
                renderer.pointOfView = vm.activeCameraNode
                sceneImage = renderer.snapshot(atTime: 0, with: CGSize(width: 1100, height: 720), antialiasingMode: .multisampling4X)
            }
            let view = InstructorPreviewWorkspace(viewModel: vm, sceneImage: sceneImage)
                .frame(width: 1100, height: 720)
                .environment(\.locale, Locale(identifier: locale)).environment(\.colorScheme, .dark)
            save(ImageRenderer(content: view).nsImage!, name: name)
        }

        vm.startFlightTraining(deferPreparation: false)
        check(vm.selectedDroneProfile.id == TrainingAircraft.copter.profileID, "Copter lesson must use its declared profile")
        check(vm.flightTrainingProgress?.phase == .briefing && !vm.shouldPromptBeforeExit, "Training starts paused and is transient")
        let position = state().position
        tick(120)
        check(state().position == position, "Briefings must freeze actual flight physics")
        keyboard.pendingActions = [.openCameraPanel]
        tick(2)
        check(vm.activeControlModule == .camera, "Interface shortcuts must work during a paused briefing")
        check(state().position == position, "Interface shortcuts cannot unpause flight")
        vm.setActiveControlModule(nil)
        vm.performAutosaveIfNeeded()
        check(projects.autosaves == 0, "Training must not autosave over normal projects")
        keyboard.rebind(command: .ascend, to: 40, keyLabel: "K")
        check(vm.flightTrainingBindings.first(where: { $0.command == .ascend })?.keyLabel == "K", "Instructor hints must follow rebound controls")
        renderCard("copter-intro-ru.png")
        renderCard("copter-intro-en.png", locale: "en")
        renderWorkspace("chapter-intro.png")

        next(); keyboard.pendingActions = [.openFlightPanel]; waitForCheckpoint()
        next(); renderWorkspace("arm-coach-ru.png")
        renderWorkspace("arm-coach-en.png", locale: "en")
        keyboard.pendingActions = [.armAircraft]; waitForCheckpoint()
        renderWorkspace("checkpoint.png")
        next(); keyboard.pendingActions = [.requestTakeoff]; tick(2)
        check(vm.activeControlModule == nil, "Takeoff must give gamepad flight axes back to the pilot")
        keyboard.axis.vertical = 1
        waitForCheckpoint()
        next(); check(vm.flightTrainingProgress?.step == .instruments, "Instrument tour follows takeoff")
        next(); check(vm.flightTrainingProgress?.step == .simulationPanels, "Simulation panels have a dedicated explanation")
        next(); vm.hover()
        let manualThrottle = vm.controlValues.throttle
        vm.takeFlightTrainingManualControl()
        keyboard.axis.forward = 0.25
        vm.setThrottle(manualThrottle)
        let beforeRemapping = state().position
        vm.setBindingsPanelVisible(true, showKeys: true)
        check(vm.bindingsViewModel.opensKeyBindingsPage, "Rebinding opens the Keys settings page directly")
        tick(120)
        check(state().position == beforeRemapping, "Flight physics must pause while editing tutorial bindings")
        vm.bindingsViewModel.beginCapture(for: .autoPath)
        vm.bindingsViewModel.rebindCurrentCommand(keyCode: 16, keyLabel: "⇧Y", requiresShift: true)
        check(vm.bindingsViewModel.descriptor(for: .autoPath)?.requiresShift == true,
              "Chord changes must be reflected in instructor controls")
        vm.setBindingsPanelVisible(false)
        check(vm.flightTrainingProgress?.step == .copterManual && vm.flightTrainingProgress?.phase == .flying,
              "Editing bindings must resume the same objective")
        keyboard.axis.forward = 0.25
        waitForCheckpoint()
        next(); keyboard.pendingActions = [.requestHover]; waitForCheckpoint()
        next(); keyboard.pendingActions = [.openCameraPanel]; waitForCheckpoint()
        next(); vm.setCameraMode(.top); waitForCheckpoint()
        next(); vm.openMissionMap(); waitForCheckpoint()
        next(); keyboard.pendingActions = [.activateAutoPath]; waitForCheckpoint()
        next(); keyboard.pendingActions = [.returnHome]; waitForCheckpoint()
        next()
        check(vm.selectedDroneProfile.id == TrainingAircraft.airplane.profileID, "Airplane lesson selects the correct aircraft")
        next(); keyboard.pendingActions = [.armAircraft, .requestTakeoff]; waitForCheckpoint(seconds: 60)
        next(); keyboard.axis.strafe = 0.25
        waitForCheckpoint()
        next(); keyboard.pendingActions = [.activateAltitudeHold]; waitForCheckpoint()
        next()
        check(vm.selectedDroneProfile.id == TrainingAircraft.vtol.profileID, "VTOL lesson selects the correct aircraft")
        next(); keyboard.pendingActions = [.armAircraft, .requestTakeoff]; tick(2); keyboard.axis.vertical = 1
        waitForCheckpoint()
        next(); keyboard.transition = 1
        keyboard.axis.forward = 0.3
        vm.setThrottle(0.5)
        waitForCheckpoint(seconds: 60)
        next(); vm.hover(); waitForCheckpoint(seconds: 60)
        next(); keyboard.pendingActions = [.activateAutoPath]; waitForCheckpoint()
        next()
        check(vm.selectedDroneProfile.id == TrainingAircraft.copter.profileID, "Final lesson returns to the copter")
        let sphereRoot = vm.scene.rootNode.childNode(withName: "instructor.spheres", recursively: false)
        check(sphereRoot?.childNodes.count == 5, "Five real sphere markers must exist in the scene")
        check(sphereRoot?.childNodes.allSatisfy { $0.physicsBody == nil } == true, "Training spheres must not collide with the aircraft")
        renderCard("examination-ru.png")
        next()
        check(vm.mode == .manual && vm.flightControlMode == .stabilized, "Final challenge starts in manual control")
        vm.reset()
        check(vm.flightTrainingProgress?.step == .examinationIntro, "Reset must restart the final lesson")
        check(!defaults.bool(forKey: InstructorProgressStore.flightCourseCompletedKey), "Unfinished training must not be marked complete")

        if let device = MTLCreateSystemDefaultDevice() {
            let renderer = SCNRenderer(device: device, options: nil)
            renderer.scene = vm.scene
            vm.setCameraMode(.free)
            renderer.pointOfView = vm.activeCameraNode
            renderer.pointOfView?.simdPosition = SIMD3<Float>(30, 32, 22)
            renderer.pointOfView?.look(at: SCNVector3(0, 12, -65))
            save(renderer.snapshot(atTime: 0, with: CGSize(width: 1100, height: 720), antialiasingMode: .multisampling4X),
                 name: "five-spheres.png")
        }

        for locale in ["ru", "en"] {
            let tour = InstructorTourOverlayView(step: .ready, targets: [:], onBack: {}, onNext: {}, onDismiss: {}, onOpenTraining: {}, animateEntrance: false)
                .frame(width: 1100, height: 720).background(GroundControlPalette.shell)
                .environment(\.locale, Locale(identifier: locale)).environment(\.colorScheme, .dark)
            save(ImageRenderer(content: tour).nsImage!, name: "app-tour-\(locale).png")
            let settings = InstructorSettingsView(completed: false, onFlight: {}, onTour: {}, animateEntrance: false)
                .padding(24).frame(width: 800).background(GroundControlPalette.shell)
                .environment(\.locale, Locale(identifier: locale)).environment(\.colorScheme, .dark)
            save(ImageRenderer(content: settings).nsImage!, name: "training-settings-\(locale).png")
        }
        let bounds = CGSize(width: 1100, height: 720)
        for target in [CGRect(x: 10, y: 140, width: 190, height: 60), CGRect(x: 850, y: 70, width: 150, height: 45),
                       CGRect(x: 50, y: 570, width: 220, height: 70)] {
            let frame = InstructorOverlayLayout.frame(size: CGSize(width: 390, height: 380), canvas: bounds, target: target)
            check(frame.minX >= 20 && frame.maxX <= 1080 && frame.minY >= 20 && frame.maxY <= 700,
                  "A coach card must fit the window near edge targets")
            check(!frame.intersects(target), "A coach card must not cover its target")
            let leader = InstructorOverlayLayout.connector(card: frame, target: target)
            check(leader.start.x.isFinite && leader.end.y.isFinite, "Pointer endpoints must be finite")
        }
        let small = InstructorOverlayLayout.frame(size: CGSize(width: 530, height: 520), canvas: CGSize(width: 720, height: 560),
            viewport: CGRect(x: 430, y: 100, width: 290, height: 460), hero: true)
        check(small.minX >= 430 && small.maxX <= 700, "Chapter cards must fit narrow viewport layouts")
        print("Instructor runtime probe passed: \(checks) integration checks; live copter, airplane and VTOL lessons; offscreen RU/EN previews in \(output.path).")
    }
}
