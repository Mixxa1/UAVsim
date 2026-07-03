import AppKit
import Foundation

struct KeyboardAxisInput {
    var forward: Float
    var strafe: Float
    var vertical: Float
    var speedBoost: Bool

    static let zero = KeyboardAxisInput(forward: 0.0, strafe: 0.0, vertical: 0.0, speedBoost: false)
}

struct KeyboardYawInput {
    var intent: Float
    var speedBoost: Bool

    static let zero = KeyboardYawInput(intent: 0.0, speedBoost: false)
}

struct KeyboardLookInput {
    var yaw: Float
    var pitch: Float
    var speedBoost: Bool
    var precisionMode: Bool

    static let zero = KeyboardLookInput(yaw: 0.0, pitch: 0.0, speedBoost: false, precisionMode: false)
}

struct KeyboardInputSnapshot {
    let axisInput: KeyboardAxisInput
    let yawInput: KeyboardYawInput
    let lookInput: KeyboardLookInput
    let activeContinuousCommands: Set<KeyboardCommand>
    let processingMode: InputProcessingMode

    var manualFlightInputActive: Bool {
        guard processingMode == .flight else {
            return false
        }
        return
            abs(axisInput.forward) > 0.001 ||
            abs(axisInput.strafe) > 0.001 ||
            abs(axisInput.vertical) > 0.001 ||
            abs(yawInput.intent) > 0.001
    }
}

enum KeyBindingCategory: String, CaseIterable, Identifiable {
    case flight
    case camera
    case ui
    case debug

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .flight:
            return "keybind.category.flight"
        case .camera:
            return "keybind.category.camera"
        case .ui:
            return "keybind.category.ui"
        case .debug:
            return "keybind.category.debug"
        }
    }
}

enum InputProcessingMode: Equatable {
    case flight
    case spectator
    case editing
    case bindingCapture
}

enum KeyboardCommand: String, CaseIterable, Identifiable {
    case moveForward
    case moveBackward
    case moveLeft
    case moveRight
    case descend
    case ascend
    case yawLeft
    case yawRight
    case accelerate

    case hover
    case resetDrone
    case releasePayload

    case cameraModeFree
    case cameraModeChase
    case cameraModeOrbit
    case cameraModeFPV
    case cameraModeTop
    case cameraModePayloadOptics
    case cameraModePayload
    case toggleFPV
    case cycleCameraMode
    case zoomIn
    case zoomOut
    case cameraYawLeft
    case cameraYawRight
    case cameraPitchUp
    case cameraPitchDown
    case cameraLookPrecision
    case resetCameraOrientation
    case thermalPaletteWhiteHot
    case thermalPaletteBlackHot
    case thermalPaletteIron
    case toggleRangefinderArmed
    case sprayHoseTrigger

    case toggleControlPanel
    case toggleMissionMap
    case togglePayloadPanel
    case toggleTelemetryHUD
    case toggleDamageOverlay
    case toggleThermalOverlay

    var id: String { rawValue }

    var category: KeyBindingCategory {
        switch self {
        case .moveForward, .moveBackward, .moveLeft, .moveRight, .descend, .ascend, .yawLeft, .yawRight, .accelerate, .hover, .resetDrone, .releasePayload:
            return .flight
        case .cameraModeFree, .cameraModeChase, .cameraModeOrbit, .cameraModeFPV, .cameraModeTop, .cameraModePayloadOptics, .cameraModePayload,
             .toggleFPV, .cycleCameraMode, .zoomIn, .zoomOut, .cameraYawLeft, .cameraYawRight, .cameraPitchUp, .cameraPitchDown, .cameraLookPrecision, .resetCameraOrientation,
             .thermalPaletteWhiteHot, .thermalPaletteBlackHot, .thermalPaletteIron, .toggleRangefinderArmed, .sprayHoseTrigger:
            return .camera
        case .toggleControlPanel, .toggleMissionMap, .togglePayloadPanel, .toggleTelemetryHUD:
            return .ui
        case .toggleDamageOverlay, .toggleThermalOverlay:
            return .debug
        }
    }

    var isContinuous: Bool {
        switch self {
        case .moveForward, .moveBackward, .moveLeft, .moveRight, .descend, .ascend, .yawLeft, .yawRight, .accelerate,
             .zoomIn, .zoomOut,
             .cameraYawLeft, .cameraYawRight, .cameraPitchUp, .cameraPitchDown, .cameraLookPrecision, .sprayHoseTrigger:
            return true
        case .hover, .resetDrone, .releasePayload, .cameraModeFree, .cameraModeChase, .cameraModeOrbit, .cameraModeFPV, .cameraModeTop, .cameraModePayloadOptics, .cameraModePayload,
             .toggleFPV, .cycleCameraMode, .resetCameraOrientation,
             .thermalPaletteWhiteHot, .thermalPaletteBlackHot, .thermalPaletteIron, .toggleRangefinderArmed,
             .toggleControlPanel, .toggleMissionMap, .togglePayloadPanel, .toggleTelemetryHUD, .toggleDamageOverlay, .toggleThermalOverlay:
            return false
        }
    }

    var titleKey: String {
        switch self {
        case .moveForward:
            return "keybind.flight.forward"
        case .moveBackward:
            return "keybind.flight.backward"
        case .moveLeft:
            return "keybind.flight.left"
        case .moveRight:
            return "keybind.flight.right"
        case .descend:
            return "keybind.flight.descend"
        case .ascend:
            return "keybind.flight.ascend"
        case .yawLeft:
            return "keybind.flight.yaw_left"
        case .yawRight:
            return "keybind.flight.yaw_right"
        case .accelerate:
            return "keybind.flight.accelerate"
        case .hover:
            return "keybind.flight.hover"
        case .resetDrone:
            return "keybind.flight.reset"
        case .releasePayload:
            return "keybind.flight.release_payload"
        case .cameraModeFree:
            return "keybind.camera.mode1"
        case .cameraModeChase:
            return "keybind.camera.mode2"
        case .cameraModeOrbit:
            return "keybind.camera.mode3"
        case .cameraModeFPV:
            return "keybind.camera.mode4"
        case .cameraModeTop:
            return "keybind.camera.mode5"
        case .cameraModePayloadOptics:
            return "keybind.camera.mode8"
        case .cameraModePayload:
            return "keybind.camera.mode6"
        case .toggleFPV:
            return "keybind.camera.toggle_fpv"
        case .cycleCameraMode:
            return "keybind.camera.cycle_mode"
        case .zoomIn:
            return "keybind.camera.zoom_in"
        case .zoomOut:
            return "keybind.camera.zoom_out"
        case .cameraYawLeft:
            return "keybind.camera.yaw_left"
        case .cameraYawRight:
            return "keybind.camera.yaw_right"
        case .cameraPitchUp:
            return "keybind.camera.pitch_up"
        case .cameraPitchDown:
            return "keybind.camera.pitch_down"
        case .cameraLookPrecision:
            return "keybind.camera.look_precision"
        case .resetCameraOrientation:
            return "keybind.camera.reset_orientation"
        case .thermalPaletteWhiteHot:
            return "keybind.camera.thermal_white_hot"
        case .thermalPaletteBlackHot:
            return "keybind.camera.thermal_black_hot"
        case .thermalPaletteIron:
            return "keybind.camera.thermal_iron"
        case .toggleRangefinderArmed:
            return "keybind.camera.rangefinder_arm"
        case .sprayHoseTrigger:
            return "keybind.camera.hose_spray"
        case .toggleControlPanel:
            return "keybind.ui.toggle_panel"
        case .toggleMissionMap:
            return "keybind.ui.toggle_mission_map"
        case .togglePayloadPanel:
            return "keybind.ui.toggle_payload"
        case .toggleTelemetryHUD:
            return "keybind.ui.toggle_hud"
        case .toggleDamageOverlay:
            return "keybind.debug.toggle_damage"
        case .toggleThermalOverlay:
            return "keybind.debug.toggle_thermal"
        }
    }
}

struct KeyBindingDescriptor: Identifiable, Hashable {
    let command: KeyboardCommand
    var keyCode: UInt16
    var keyLabel: String

    var id: String { command.rawValue }
    var category: KeyBindingCategory { command.category }
}

struct KeyBindingProfile {
    var bindings: [KeyboardCommand: KeyBindingDescriptor]

    init(bindings: [KeyboardCommand: KeyBindingDescriptor]) {
        self.bindings = bindings
    }

    static let `default` = KeyBindingProfile(
        bindings: [
            .moveForward: KeyBindingDescriptor(command: .moveForward, keyCode: 13, keyLabel: "W"),
            .moveBackward: KeyBindingDescriptor(command: .moveBackward, keyCode: 1, keyLabel: "S"),
            .moveLeft: KeyBindingDescriptor(command: .moveLeft, keyCode: 0, keyLabel: "A"),
            .moveRight: KeyBindingDescriptor(command: .moveRight, keyCode: 2, keyLabel: "D"),
            .descend: KeyBindingDescriptor(command: .descend, keyCode: 12, keyLabel: "Q"),
            .ascend: KeyBindingDescriptor(command: .ascend, keyCode: 14, keyLabel: "E"),
            .yawLeft: KeyBindingDescriptor(command: .yawLeft, keyCode: 38, keyLabel: "J"),
            .yawRight: KeyBindingDescriptor(command: .yawRight, keyCode: 37, keyLabel: "L"),
            .accelerate: KeyBindingDescriptor(command: .accelerate, keyCode: 56, keyLabel: "Shift"),
            .hover: KeyBindingDescriptor(command: .hover, keyCode: 49, keyLabel: NSLocalizedString("keybind.key.space", comment: "")),
            .resetDrone: KeyBindingDescriptor(command: .resetDrone, keyCode: 15, keyLabel: "R"),
            .releasePayload: KeyBindingDescriptor(command: .releasePayload, keyCode: 5, keyLabel: "G"),
            .cameraModeFree: KeyBindingDescriptor(command: .cameraModeFree, keyCode: 18, keyLabel: "1"),
            .cameraModeChase: KeyBindingDescriptor(command: .cameraModeChase, keyCode: 19, keyLabel: "2"),
            .cameraModeOrbit: KeyBindingDescriptor(command: .cameraModeOrbit, keyCode: 20, keyLabel: "3"),
            .cameraModeFPV: KeyBindingDescriptor(command: .cameraModeFPV, keyCode: 21, keyLabel: "4"),
            .cameraModeTop: KeyBindingDescriptor(command: .cameraModeTop, keyCode: 23, keyLabel: "5"),
            .cameraModePayloadOptics: KeyBindingDescriptor(command: .cameraModePayloadOptics, keyCode: 31, keyLabel: "O"),
            .cameraModePayload: KeyBindingDescriptor(command: .cameraModePayload, keyCode: 29, keyLabel: "0"),
            .toggleFPV: KeyBindingDescriptor(command: .toggleFPV, keyCode: UInt16.max, keyLabel: "—"),
            .cycleCameraMode: KeyBindingDescriptor(command: .cycleCameraMode, keyCode: 8, keyLabel: "C"),
            .zoomIn: KeyBindingDescriptor(command: .zoomIn, keyCode: 24, keyLabel: "+"),
            .zoomOut: KeyBindingDescriptor(command: .zoomOut, keyCode: 27, keyLabel: "-"),
            .cameraYawLeft: KeyBindingDescriptor(command: .cameraYawLeft, keyCode: 123, keyLabel: "←"),
            .cameraYawRight: KeyBindingDescriptor(command: .cameraYawRight, keyCode: 124, keyLabel: "→"),
            .cameraPitchUp: KeyBindingDescriptor(command: .cameraPitchUp, keyCode: 126, keyLabel: "↑"),
            .cameraPitchDown: KeyBindingDescriptor(command: .cameraPitchDown, keyCode: 125, keyLabel: "↓"),
            .cameraLookPrecision: KeyBindingDescriptor(command: .cameraLookPrecision, keyCode: 58, keyLabel: "⌥"),
            .resetCameraOrientation: KeyBindingDescriptor(command: .resetCameraOrientation, keyCode: 9, keyLabel: "V"),
            .thermalPaletteWhiteHot: KeyBindingDescriptor(command: .thermalPaletteWhiteHot, keyCode: 22, keyLabel: "6"),
            .thermalPaletteBlackHot: KeyBindingDescriptor(command: .thermalPaletteBlackHot, keyCode: 26, keyLabel: "7"),
            .thermalPaletteIron: KeyBindingDescriptor(command: .thermalPaletteIron, keyCode: 28, keyLabel: "8"),
            .toggleRangefinderArmed: KeyBindingDescriptor(command: .toggleRangefinderArmed, keyCode: 25, keyLabel: "9"),
            .sprayHoseTrigger: KeyBindingDescriptor(command: .sprayHoseTrigger, keyCode: 6, keyLabel: "Z"),
            .toggleControlPanel: KeyBindingDescriptor(command: .toggleControlPanel, keyCode: UInt16.max, keyLabel: "—"),
            .toggleMissionMap: KeyBindingDescriptor(command: .toggleMissionMap, keyCode: 3, keyLabel: "F"),
            .togglePayloadPanel: KeyBindingDescriptor(command: .togglePayloadPanel, keyCode: 35, keyLabel: "P"),
            .toggleTelemetryHUD: KeyBindingDescriptor(command: .toggleTelemetryHUD, keyCode: 17, keyLabel: "T"),
            .toggleDamageOverlay: KeyBindingDescriptor(command: .toggleDamageOverlay, keyCode: 4, keyLabel: "H"),
            .toggleThermalOverlay: KeyBindingDescriptor(command: .toggleThermalOverlay, keyCode: 11, keyLabel: "B")
        ]
    )

    func descriptor(for command: KeyboardCommand) -> KeyBindingDescriptor? {
        bindings[command]
    }

    func commands(for keyCode: UInt16) -> [KeyboardCommand] {
        bindings.values
            .filter { $0.keyCode == keyCode }
            .map(\.command)
            .sorted { $0.rawValue < $1.rawValue }
    }

    mutating func rebind(command: KeyboardCommand, keyCode: UInt16, keyLabel: String) {
        guard let previous = bindings[command] else {
            bindings[command] = KeyBindingDescriptor(command: command, keyCode: keyCode, keyLabel: keyLabel)
            return
        }

        if let conflicting = bindings.first(where: { $0.key != command && $0.value.keyCode == keyCode })?.key {
            bindings[conflicting] = KeyBindingDescriptor(
                command: conflicting,
                keyCode: previous.keyCode,
                keyLabel: previous.keyLabel
            )
        }

        bindings[command] = KeyBindingDescriptor(command: command, keyCode: keyCode, keyLabel: keyLabel)
    }

    func groupedBindings() -> [KeyBindingCategory: [KeyBindingDescriptor]] {
        Dictionary(grouping: bindings.values, by: \.category).mapValues {
            $0.sorted { $0.command.rawValue < $1.command.rawValue }
        }
    }

    func conflicts() -> [String] {
        let grouped = Dictionary(grouping: bindings.values, by: \.keyCode)
        var conflicts: [String] = []
        for entry in grouped where entry.value.count > 1 {
            let commandTitles = entry.value
                .map { NSLocalizedString($0.command.titleKey, comment: "") }
                .sorted()
            let keyName = entry.value.first?.keyLabel ?? String(entry.key)
            conflicts.append("\(keyName): \(commandTitles.joined(separator: ", "))")
        }
        return conflicts.sorted()
    }
}

enum InputAction: Equatable, Hashable {
    case requestHover
    case requestReset
    case dropPayload
    case armAircraft
    case disarmAircraft
    case selectFreeCamera
    case selectChaseCamera
    case selectOrbitCamera
    case selectFPVCamera
    case selectTopCamera
    case selectPayloadOpticsCamera
    case selectPayloadCamera
    case toggleFPV
    case toggleTopView
    case toggleMissionMap
    case togglePayloadPanel
    case toggleTerrainMap
    case toggleCompassOverlay
    case toggleThermalOverlay
    case toggleDamageOverlay
    case selectThermalPaletteWhiteHot
    case selectThermalPaletteBlackHot
    case selectThermalPaletteIron
    case toggleRangefinderArmed
    case cycleCameraMode
    case toggleControlPanel
    case toggleToolPanel
    case toggleTelemetryHUD
    case zoomInCamera
    case zoomOutCamera
    case resetCameraOrientation
    case returnHome
    case pauseMission
    case resumeMission
    case toggleControllerCursor
    case openControllerHub
    case uiSectionPrevious
    case uiSectionNext
    case uiPrimary
    case uiSecondary
    case uiFocusUp
    case uiFocusDown
    case uiFocusLeft
    case uiFocusRight
}

protocol KeyboardInputProviding {
    func start()
    func stop()
    func resetTransientState()
    func currentAxisInput() -> KeyboardAxisInput
    func currentYawInput() -> KeyboardYawInput
    func currentLookInput() -> KeyboardLookInput
    func currentInputSnapshot() -> KeyboardInputSnapshot
    func consumeActions() -> [InputAction]
    func setInputProcessingMode(_ mode: InputProcessingMode)
    func currentBindingProfile() -> KeyBindingProfile
    func currentBindingConflicts() -> [String]
    func rebind(command: KeyboardCommand, to keyCode: UInt16, keyLabel: String)
    func resetBindingsToDefault()
}

final class KeyboardInputService: KeyboardInputProviding {
    private static let reservedDirectShortcutKeyCodes: Set<UInt16> = [30, 33, 34, 40] // ] / [ / I / K
    private static let parametersPanelToggleKeyCode: UInt16 = 33 // [
    private static let toolPanelToggleKeyCode: UInt16 = 30 // ]
    private static let cameraLookKeyCodes: Set<UInt16> = [123, 124, 125, 126] // ← / → / ↓ / ↑

    private var localKeyDownMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var localFlagsChangedMonitor: Any?
    private var resignActiveObserver: Any?

    private var activeContinuousCommands: Set<KeyboardCommand> = []
    private var activeContinuousByKey: [UInt16: Set<KeyboardCommand>] = [:]
    private var pendingActions: [InputAction] = []

    private var processingMode: InputProcessingMode = .flight
    private var profile: KeyBindingProfile
    private let userDefaults: UserDefaults

    private let alternateKeyCodes: [UInt16: KeyboardCommand] = [
        69: .zoomIn,  // keypad +
        78: .zoomOut  // keypad -
    ]

    private let bindingsStorageKey = "input.bindings.profile.v3"
    private let canonicalFlightCameraBindings: [KeyboardCommand: KeyBindingDescriptor] = [
        .moveForward: KeyBindingDescriptor(command: .moveForward, keyCode: 13, keyLabel: "W"),
        .moveBackward: KeyBindingDescriptor(command: .moveBackward, keyCode: 1, keyLabel: "S"),
        .moveLeft: KeyBindingDescriptor(command: .moveLeft, keyCode: 0, keyLabel: "A"),
        .moveRight: KeyBindingDescriptor(command: .moveRight, keyCode: 2, keyLabel: "D"),
        .descend: KeyBindingDescriptor(command: .descend, keyCode: 12, keyLabel: "Q"),
        .ascend: KeyBindingDescriptor(command: .ascend, keyCode: 14, keyLabel: "E"),
        .yawLeft: KeyBindingDescriptor(command: .yawLeft, keyCode: 38, keyLabel: "J"),
        .yawRight: KeyBindingDescriptor(command: .yawRight, keyCode: 37, keyLabel: "L"),
        .accelerate: KeyBindingDescriptor(command: .accelerate, keyCode: 56, keyLabel: "Shift"),
        .hover: KeyBindingDescriptor(command: .hover, keyCode: 49, keyLabel: NSLocalizedString("keybind.key.space", comment: "")),
        .resetDrone: KeyBindingDescriptor(command: .resetDrone, keyCode: 15, keyLabel: "R"),
        .releasePayload: KeyBindingDescriptor(command: .releasePayload, keyCode: 5, keyLabel: "G"),
        .cameraModePayloadOptics: KeyBindingDescriptor(command: .cameraModePayloadOptics, keyCode: 31, keyLabel: "O"),
        .cameraModePayload: KeyBindingDescriptor(command: .cameraModePayload, keyCode: 29, keyLabel: "0"),
        .cameraYawLeft: KeyBindingDescriptor(command: .cameraYawLeft, keyCode: 123, keyLabel: "←"),
        .cameraYawRight: KeyBindingDescriptor(command: .cameraYawRight, keyCode: 124, keyLabel: "→"),
        .cameraPitchUp: KeyBindingDescriptor(command: .cameraPitchUp, keyCode: 126, keyLabel: "↑"),
        .cameraPitchDown: KeyBindingDescriptor(command: .cameraPitchDown, keyCode: 125, keyLabel: "↓"),
        .resetCameraOrientation: KeyBindingDescriptor(command: .resetCameraOrientation, keyCode: 9, keyLabel: "V")
    ]

    init(profile: KeyBindingProfile? = nil, userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let explicitProfile = profile {
            self.profile = explicitProfile
        } else if let stored = Self.loadPersistedProfile(from: userDefaults, key: bindingsStorageKey) {
            self.profile = stored
        } else {
            self.profile = .default
        }
        sanitizeLegacyPanelToggleBinding()
        sanitizeCanonicalFlightCameraBindings()
        sanitizeMissionOverlayBindings()
        sanitizeRangefinderAndThermalQuickBindings()
    }

    func start() {
        guard localKeyDownMonitor == nil, localKeyUpMonitor == nil else {
            return
        }

        clearInputState(keepPendingActions: true)

        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event)
        }

        localKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyUp(event)
        }

        localFlagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Prevent "stuck key" drift when keyUp is missed during focus changes.
            self?.clearInputState(keepPendingActions: true)
        }
    }

    func stop() {
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
            self.localKeyDownMonitor = nil
        }

        if let localKeyUpMonitor {
            NSEvent.removeMonitor(localKeyUpMonitor)
            self.localKeyUpMonitor = nil
        }

        if let localFlagsChangedMonitor {
            NSEvent.removeMonitor(localFlagsChangedMonitor)
            self.localFlagsChangedMonitor = nil
        }

        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }

        clearInputState(keepPendingActions: false)
    }

    func resetTransientState() {
        clearInputState(keepPendingActions: false)
    }

    func currentAxisInput() -> KeyboardAxisInput {
        let forward: Float = (activeContinuousCommands.contains(.moveForward) ? 1.0 : 0.0) - (activeContinuousCommands.contains(.moveBackward) ? 1.0 : 0.0)
        let strafe: Float = (activeContinuousCommands.contains(.moveRight) ? 1.0 : 0.0) - (activeContinuousCommands.contains(.moveLeft) ? 1.0 : 0.0)
        let vertical: Float = (activeContinuousCommands.contains(.ascend) ? 1.0 : 0.0) - (activeContinuousCommands.contains(.descend) ? 1.0 : 0.0)
        let speedBoost = activeContinuousCommands.contains(.accelerate)

        return KeyboardAxisInput(
            forward: forward,
            strafe: strafe,
            vertical: vertical,
            speedBoost: speedBoost
        )
    }

    func currentYawInput() -> KeyboardYawInput {
        let intent: Float = (activeContinuousCommands.contains(.yawLeft) ? 1.0 : 0.0) - (activeContinuousCommands.contains(.yawRight) ? 1.0 : 0.0)
        let speedBoost = activeContinuousCommands.contains(.accelerate)
        return KeyboardYawInput(intent: intent, speedBoost: speedBoost)
    }

    func currentLookInput() -> KeyboardLookInput {
        let yaw: Float = (activeContinuousCommands.contains(.cameraYawRight) ? 1.0 : 0.0) - (activeContinuousCommands.contains(.cameraYawLeft) ? 1.0 : 0.0)
        let pitch: Float = (activeContinuousCommands.contains(.cameraPitchDown) ? 1.0 : 0.0) - (activeContinuousCommands.contains(.cameraPitchUp) ? 1.0 : 0.0)
        let speedBoost = activeContinuousCommands.contains(.accelerate)
        let precisionMode = activeContinuousCommands.contains(.cameraLookPrecision)

        return KeyboardLookInput(yaw: yaw, pitch: pitch, speedBoost: speedBoost, precisionMode: precisionMode)
    }

    func currentInputSnapshot() -> KeyboardInputSnapshot {
        KeyboardInputSnapshot(
            axisInput: currentAxisInput(),
            yawInput: currentYawInput(),
            lookInput: currentLookInput(),
            activeContinuousCommands: activeContinuousCommands,
            processingMode: processingMode
        )
    }

    func consumeActions() -> [InputAction] {
        defer {
            pendingActions.removeAll(keepingCapacity: true)
        }
        return pendingActions
    }

    func setInputProcessingMode(_ mode: InputProcessingMode) {
        guard processingMode != mode else {
            return
        }
        processingMode = mode
        clearInputState(keepPendingActions: true)
    }

    func currentBindingProfile() -> KeyBindingProfile {
        profile
    }

    func currentBindingConflicts() -> [String] {
        profile.conflicts()
    }

    func rebind(command: KeyboardCommand, to keyCode: UInt16, keyLabel: String) {
        profile.rebind(command: command, keyCode: keyCode, keyLabel: keyLabel)
        sanitizeCanonicalFlightCameraBindings()
        // Prevent stale pressed-state links when a command changes key while held.
        activeContinuousCommands.removeAll()
        activeContinuousByKey.removeAll()
        persistProfile()
    }

    func resetBindingsToDefault() {
        profile = .default
        activeContinuousCommands.removeAll()
        activeContinuousByKey.removeAll()
        persistProfile()
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        if processingMode == .bindingCapture {
            return event
        }

        if isTextInputActive(for: event) {
            clearInputState(keepPendingActions: true)
            return event
        }

        let blockingModifiers = event.modifierFlags.intersection([.command, .control, .option])
        if !blockingModifiers.isEmpty {
            let isOptionOnlyOnCameraLookKey = blockingModifiers == [.option] && Self.cameraLookKeyCodes.contains(event.keyCode)
            if !isOptionOnlyOnCameraLookKey {
                return event
            }
        }

        guard processingMode == .flight || processingMode == .spectator else {
            return event
        }

        if !event.isARepeat, handleDirectUIShortcut(for: event.keyCode) {
            return nil
        }

        if !event.isARepeat, let action = directAction(for: event) {
            enqueueAction(action)
            return nil
        }

        let commands = commands(for: event.keyCode)
        guard !commands.isEmpty else {
            return event
        }

        var consumed = false
        var continuousForKey = activeContinuousByKey[event.keyCode] ?? Set<KeyboardCommand>()

        for command in commands {
            if processingMode == .spectator, !isSpectatorCameraCommand(command) {
                continue
            }
            if command.isContinuous {
                activeContinuousCommands.insert(command)
                continuousForKey.insert(command)
                consumed = true
            } else if !event.isARepeat {
                mapCommandToAction(command)
                consumed = true
            }
        }

        if !continuousForKey.isEmpty {
            activeContinuousByKey[event.keyCode] = continuousForKey
        }

        return consumed ? nil : event
    }

    private func handleKeyUp(_ event: NSEvent) -> NSEvent? {
        if isTextInputActive(for: event) {
            clearInputState(keepPendingActions: true)
            return event
        }

        let continuousForKey = activeContinuousByKey.removeValue(forKey: event.keyCode) ?? []
        if !continuousForKey.isEmpty {
            activeContinuousCommands.subtract(continuousForKey)
            return nil
        }
        return event
    }

    private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
        if isTextInputActive(for: event) {
            clearInputState(keepPendingActions: true)
            return event
        }

        if isAccelerateBoundToShift {
            if event.modifierFlags.contains(.shift) {
                activeContinuousCommands.insert(.accelerate)
            } else if !isAccelerateHeldByOtherKey {
                activeContinuousCommands.remove(.accelerate)
            }
        }

        if isCameraLookPrecisionBoundToOption {
            if event.modifierFlags.contains(.option) {
                activeContinuousCommands.insert(.cameraLookPrecision)
            } else if !isCameraLookPrecisionHeldByOtherKey {
                activeContinuousCommands.remove(.cameraLookPrecision)
            }
        }
        return event
    }

    private func clearInputState(keepPendingActions: Bool) {
        activeContinuousCommands.removeAll()
        activeContinuousByKey.removeAll()
        if !keepPendingActions {
            pendingActions.removeAll()
        }
    }

    private func isTextInputActive(for event: NSEvent) -> Bool {
        let responder = event.window?.firstResponder ?? NSApp.keyWindow?.firstResponder
        guard let textView = responder as? NSTextView else {
            return false
        }
        return textView.isEditable || textView.isFieldEditor
    }

    private var isAccelerateBoundToShift: Bool {
        profile.commands(for: 56).contains(.accelerate) || profile.commands(for: 60).contains(.accelerate)
    }

    private var isAccelerateHeldByOtherKey: Bool {
        activeContinuousByKey
            .filter { $0.key != 56 && $0.key != 60 }
            .contains { $0.value.contains(.accelerate) }
    }

    private var isCameraLookPrecisionBoundToOption: Bool {
        profile.commands(for: 58).contains(.cameraLookPrecision) || profile.commands(for: 61).contains(.cameraLookPrecision)
    }

    private var isCameraLookPrecisionHeldByOtherKey: Bool {
        activeContinuousByKey
            .filter { $0.key != 58 && $0.key != 61 }
            .contains { $0.value.contains(.cameraLookPrecision) }
    }

    private func mapCommandToAction(_ command: KeyboardCommand) {
        switch command {
        case .hover:
            enqueueAction(.requestHover)
        case .resetDrone:
            enqueueAction(.requestReset)
        case .releasePayload:
            enqueueAction(.dropPayload)
        case .cameraModeFree:
            enqueueAction(.selectFreeCamera)
        case .cameraModeChase:
            enqueueAction(.selectChaseCamera)
        case .cameraModeOrbit:
            enqueueAction(.selectOrbitCamera)
        case .cameraModeFPV:
            enqueueAction(.selectFPVCamera)
        case .cameraModeTop:
            enqueueAction(.selectTopCamera)
        case .cameraModePayloadOptics:
            enqueueAction(.selectPayloadOpticsCamera)
        case .cameraModePayload:
            enqueueAction(.selectPayloadCamera)
        case .toggleFPV:
            enqueueAction(.toggleFPV)
        case .cycleCameraMode:
            enqueueAction(.cycleCameraMode)
        case .zoomIn:
            enqueueAction(.zoomInCamera)
        case .zoomOut:
            enqueueAction(.zoomOutCamera)
        case .resetCameraOrientation:
            enqueueAction(.resetCameraOrientation)
        case .toggleControlPanel:
            enqueueAction(.toggleControlPanel)
        case .toggleMissionMap:
            enqueueAction(.toggleMissionMap)
        case .togglePayloadPanel:
            enqueueAction(.togglePayloadPanel)
        case .toggleTelemetryHUD:
            enqueueAction(.toggleTelemetryHUD)
        case .toggleDamageOverlay:
            enqueueAction(.toggleDamageOverlay)
        case .toggleThermalOverlay:
            enqueueAction(.toggleThermalOverlay)
        case .thermalPaletteWhiteHot:
            enqueueAction(.selectThermalPaletteWhiteHot)
        case .thermalPaletteBlackHot:
            enqueueAction(.selectThermalPaletteBlackHot)
        case .thermalPaletteIron:
            enqueueAction(.selectThermalPaletteIron)
        case .toggleRangefinderArmed:
            enqueueAction(.toggleRangefinderArmed)
        case .cameraYawLeft, .cameraYawRight, .cameraPitchUp, .cameraPitchDown, .cameraLookPrecision,
             .moveForward, .moveBackward, .moveLeft, .moveRight, .descend, .ascend, .yawLeft, .yawRight, .accelerate,
             .sprayHoseTrigger:
            break
        }
    }

    private func directAction(for event: NSEvent) -> InputAction? {
        if processingMode == .spectator {
            return nil
        }
        if matchesCompassOverlayToggle(event) {
            return .toggleCompassOverlay
        }
        if matchesTerrainMapToggle(event) {
            return .toggleTerrainMap
        }
        if matchesArmShortcut(event) {
            return .armAircraft
        }
        if matchesDisarmShortcut(event) {
            return .disarmAircraft
        }
        return nil
    }

    private func isSpectatorCameraCommand(_ command: KeyboardCommand) -> Bool {
        switch command {
        case .moveForward, .moveBackward, .moveLeft, .moveRight, .accelerate:
            return true
        default:
            return command.category != .flight
        }
    }

    private func matchesTerrainMapToggle(_ event: NSEvent) -> Bool {
        if event.keyCode == 46 {
            return true
        }

        guard let characters = event.charactersIgnoringModifiers?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !characters.isEmpty else {
            return false
        }

        return characters == "m"
    }

    private func matchesCompassOverlayToggle(_ event: NSEvent) -> Bool {
        if event.keyCode == 44 || event.keyCode == 42 {
            return true
        }

        guard let characters = event.charactersIgnoringModifiers?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !characters.isEmpty else {
            return false
        }

        return characters == "/" || characters == "\\"
    }

    private func matchesArmShortcut(_ event: NSEvent) -> Bool {
        if event.characters == "<" {
            return true
        }

        if event.keyCode == 43 {
            return true
        }

        return event.charactersIgnoringModifiers == ","
    }

    private func matchesDisarmShortcut(_ event: NSEvent) -> Bool {
        if event.characters == ">" {
            return true
        }

        if event.keyCode == 47 {
            return true
        }

        return event.charactersIgnoringModifiers == "."
    }

    private func handleDirectUIShortcut(for keyCode: UInt16) -> Bool {
        switch keyCode {
        case Self.parametersPanelToggleKeyCode:
            enqueueAction(.toggleControlPanel)
            return true
        case Self.toolPanelToggleKeyCode:
            enqueueAction(.toggleToolPanel)
            return true
        default:
            return false
        }
    }

    private func enqueueAction(_ action: InputAction) {
        guard !pendingActions.contains(action) else {
            return
        }
        pendingActions.append(action)
    }

    private func commands(for keyCode: UInt16) -> [KeyboardCommand] {
        guard !Self.reservedDirectShortcutKeyCodes.contains(keyCode) else {
            return []
        }
        let direct = profile.commands(for: keyCode)
        if !direct.isEmpty {
            return direct
        }
        if let alternate = alternateKeyCodes[keyCode] {
            return [alternate]
        }
        return []
    }

    private func persistProfile() {
        guard let data = try? JSONEncoder().encode(profile.toPersisted()) else {
            return
        }
        userDefaults.set(data, forKey: bindingsStorageKey)
    }

    private func sanitizeLegacyPanelToggleBinding() {
        guard let descriptor = profile.descriptor(for: .toggleControlPanel) else {
            return
        }
        guard descriptor.keyCode != UInt16.max else {
            return
        }
        profile.rebind(command: .toggleControlPanel, keyCode: UInt16.max, keyLabel: "—")
        persistProfile()
    }

    private func sanitizeCanonicalFlightCameraBindings() {
        let canonicalKeyCodes = Set(canonicalFlightCameraBindings.values.map(\.keyCode))
        var didChange = false

        for (command, descriptor) in profile.bindings {
            guard canonicalFlightCameraBindings[command] == nil,
                  canonicalKeyCodes.contains(descriptor.keyCode),
                  let fallback = KeyBindingProfile.default.descriptor(for: command) else {
                continue
            }

            if descriptor.keyCode != fallback.keyCode || descriptor.keyLabel != fallback.keyLabel {
                profile.bindings[command] = fallback
                didChange = true
            }
        }

        for (command, descriptor) in profile.bindings {
            guard canonicalFlightCameraBindings[command] == nil,
                  Self.reservedDirectShortcutKeyCodes.contains(descriptor.keyCode),
                  let fallback = KeyBindingProfile.default.descriptor(for: command) else {
                continue
            }

            if descriptor.keyCode != fallback.keyCode || descriptor.keyLabel != fallback.keyLabel {
                profile.bindings[command] = fallback
                didChange = true
            }
        }

        for retiredKeyCode in Self.reservedDirectShortcutKeyCodes {
            let commandsOnRetiredKey = profile.commands(for: retiredKeyCode)
            for command in commandsOnRetiredKey {
                guard let fallback = KeyBindingProfile.default.descriptor(for: command) else {
                    continue
                }
                if profile.bindings[command] != fallback {
                    profile.bindings[command] = fallback
                    didChange = true
                }
            }
        }

        for (command, descriptor) in canonicalFlightCameraBindings {
            let current = profile.bindings[command]
            if current?.keyCode != descriptor.keyCode || current?.keyLabel != descriptor.keyLabel {
                profile.bindings[command] = descriptor
                didChange = true
            }
        }

        if didChange {
            persistProfile()
        }
    }

    private func sanitizeMissionOverlayBindings() {
        let requiredBindings: [KeyboardCommand: KeyBindingDescriptor] = [
            .toggleMissionMap: KeyBindingDescriptor(command: .toggleMissionMap, keyCode: 3, keyLabel: "F"),
            .togglePayloadPanel: KeyBindingDescriptor(command: .togglePayloadPanel, keyCode: 35, keyLabel: "P")
        ]
        var didChange = false

        for (command, descriptor) in requiredBindings {
            let current = profile.bindings[command]
            if current?.keyCode != descriptor.keyCode || current?.keyLabel != descriptor.keyLabel {
                profile.rebind(
                    command: command,
                    keyCode: descriptor.keyCode,
                    keyLabel: descriptor.keyLabel
                )
                didChange = true
            }
        }

        let unboundDescriptor = KeyBindingDescriptor(
            command: .toggleFPV,
            keyCode: UInt16.max,
            keyLabel: "—"
        )
        if profile.bindings[.toggleFPV] == nil {
            profile.bindings[.toggleFPV] = unboundDescriptor
            didChange = true
        } else if profile.bindings[.toggleFPV]?.keyCode == requiredBindings[.toggleMissionMap]?.keyCode {
            profile.bindings[.toggleFPV] = unboundDescriptor
            didChange = true
        }

        if didChange {
            persistProfile()
        }
    }

    private func sanitizeRangefinderAndThermalQuickBindings() {
        var didChange = false

        func apply(_ command: KeyboardCommand, keyCode: UInt16, keyLabel: String) {
            let current = profile.bindings[command]
            if current?.keyCode != keyCode || current?.keyLabel != keyLabel {
                profile.rebind(command: command, keyCode: keyCode, keyLabel: keyLabel)
                didChange = true
            }
        }

        // Vacate the legacy "6"/"8" camera-mode slots first so the quick-select
        // commands below can claim them without tripping the rebind conflict-swap.
        apply(.cameraModePayload, keyCode: 29, keyLabel: "0")
        apply(.cameraModePayloadOptics, keyCode: 31, keyLabel: "O")
        apply(.thermalPaletteWhiteHot, keyCode: 22, keyLabel: "6")
        apply(.thermalPaletteBlackHot, keyCode: 26, keyLabel: "7")
        apply(.thermalPaletteIron, keyCode: 28, keyLabel: "8")
        apply(.toggleRangefinderArmed, keyCode: 25, keyLabel: "9")
        apply(.sprayHoseTrigger, keyCode: 6, keyLabel: "Z")
        apply(.cameraLookPrecision, keyCode: 58, keyLabel: "⌥")

        if didChange {
            persistProfile()
        }
    }

    private static func loadPersistedProfile(from defaults: UserDefaults, key: String) -> KeyBindingProfile? {
        guard let data = defaults.data(forKey: key),
              let persisted = try? JSONDecoder().decode(PersistedKeyBindingProfile.self, from: data) else {
            return nil
        }
        return persisted.toRuntimeProfile()
    }
}

private struct PersistedKeyBindingProfile: Codable {
    struct Entry: Codable {
        let command: String
        let keyCode: UInt16
        let keyLabel: String
    }

    let bindings: [Entry]

    func toRuntimeProfile() -> KeyBindingProfile {
        var resolved = KeyBindingProfile.default
        for entry in bindings {
            guard let command = KeyboardCommand(rawValue: entry.command) else {
                continue
            }
            resolved.rebind(command: command, keyCode: entry.keyCode, keyLabel: entry.keyLabel)
        }
        return resolved
    }
}

private extension KeyBindingProfile {
    func toPersisted() -> PersistedKeyBindingProfile {
        let entries = bindings.values
            .sorted { $0.command.rawValue < $1.command.rawValue }
            .map {
                PersistedKeyBindingProfile.Entry(
                    command: $0.command.rawValue,
                    keyCode: $0.keyCode,
                    keyLabel: $0.keyLabel
                )
            }
        return PersistedKeyBindingProfile(bindings: entries)
    }
}
