import Foundation
import GameController

struct GameControllerDeviceSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let vendorName: String
    let productCategory: String
    let playerIndex: String
    let connectionState: String
    let supportsExtendedGamepad: Bool
    let isActive: Bool
}

enum GameControllerRightStickHorizontalMode: String, CaseIterable, Identifiable {
    case yawLeftRight
    case cameraPan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yawLeftRight:
            return "Yaw (J / L)"
        case .cameraPan:
            return "Camera pan"
        }
    }
}

final class GameControllerInputProvider: InputProvider {
    private enum Mapping {
        static let stickDeadzone: Float = 0.04
        static let triggerDeadzone: Float = 0.02
    }

    private enum Persistence {
        static let rightStickHorizontalModeKey = "input.gamecontroller.rightStickHorizontalMode.v1"
    }

    let sourceKind: InputSourceKind = .gameController
    var isEnabled: Bool = true

    private let userDefaults: UserDefaults
    private let settingsStore: ControllerSettingsStore
    private var activeController: GCController?
    private var previousButtonStates: [InputAction: Bool] = [:]
    private var snapshot: InputSnapshot = .neutral(source: .gameController)
    private var rightStickHorizontalMode: GameControllerRightStickHorizontalMode

    private var connectObserver: Any?
    private var disconnectObserver: Any?

    init(
        userDefaults: UserDefaults = .standard,
        settingsStore: ControllerSettingsStore = ControllerSettingsStore()
    ) {
        self.userDefaults = userDefaults
        self.settingsStore = settingsStore
        self.rightStickHorizontalMode = Self.loadRightStickHorizontalMode(from: userDefaults)
        selectInitialController()
        registerControllerObservers()
    }

    deinit {
        if let connectObserver {
            NotificationCenter.default.removeObserver(connectObserver)
        }
        if let disconnectObserver {
            NotificationCenter.default.removeObserver(disconnectObserver)
        }
    }

    func update(deltaTime: TimeInterval) {
        guard isEnabled else {
            snapshot = .neutral(source: sourceKind)
            return
        }

        refreshActiveControllerIfNeeded()

        guard let controller = activeController,
              let gamepad = controller.extendedGamepad else {
            previousButtonStates.removeAll()
            snapshot = .neutral(source: sourceKind)
            return
        }

        let currentButtons = mappedButtons(from: gamepad)
        let actions = risingEdgeActions(from: currentButtons)
        previousButtonStates = currentButtons

        let roll = normalizedSignedAxis(gamepad.leftThumbstick.xAxis.value)
        let pitch = normalizedSignedAxis(gamepad.leftThumbstick.yAxis.value)
        let rightStickX = normalizedSignedAxis(gamepad.rightThumbstick.xAxis.value)
        let rightStickY = -normalizedSignedAxis(gamepad.rightThumbstick.yAxis.value)
        let shoulderYaw = normalizedSignedAxis(gamepad.leftShoulder.value) - normalizedSignedAxis(gamepad.rightShoulder.value)
        let yaw = min(
            1.0,
            max(
                -1.0,
                shoulderYaw + (rightStickHorizontalMode == .yawLeftRight ? rightStickX : 0.0)
            )
        )
        let throttleUp = normalizedTrigger(gamepad.rightTrigger.value)
        let throttleDown = normalizedTrigger(gamepad.leftTrigger.value)
        let cameraPan = rightStickHorizontalMode == .cameraPan ? rightStickX : 0.0
        let cameraTilt = rightStickY
        let uiPointerX = normalizedSignedAxis(gamepad.leftThumbstick.xAxis.value)
        let uiPointerY = -normalizedSignedAxis(gamepad.leftThumbstick.yAxis.value)
        let uiScrollX = rightStickX
        let uiScrollY = rightStickY
        let boostMode = false
        let precisionMode = false

        let nextSnapshot = InputSnapshot(
            yaw: Double(yaw),
            pitch: Double(pitch),
            roll: Double(roll),
            throttle: Double(throttleUp - throttleDown),
            cameraPan: Double(cameraPan),
            cameraTilt: Double(cameraTilt),
            uiPointerX: Double(uiPointerX),
            uiPointerY: Double(uiPointerY),
            uiScrollX: Double(uiScrollX),
            uiScrollY: Double(uiScrollY),
            precisionMode: precisionMode,
            boostMode: boostMode,
            actions: actions,
            source: sourceKind,
            timestamp: Date().timeIntervalSince1970,
            isConnected: true,
            activityScore: 0.0
        )

        snapshot = nextSnapshot.withActivityScore(
            Self.activityScore(for: nextSnapshot)
        )
    }

    func currentSnapshot() -> InputSnapshot {
        snapshot
    }

    var currentRightStickHorizontalMode: GameControllerRightStickHorizontalMode {
        rightStickHorizontalMode
    }

    var activeControllerName: String? {
        activeController?.displayName
    }

    func connectedDeviceSummaries() -> [GameControllerDeviceSummary] {
        availableControllers().enumerated().map { index, controller in
            GameControllerDeviceSummary(
                id: "\(index)-\(controller.displayName)",
                name: controller.displayName,
                vendorName: controller.vendorName ?? "Unknown vendor",
                productCategory: controller.productCategory,
                playerIndex: Self.playerIndexLabel(for: controller.playerIndex),
                connectionState: "Connected",
                supportsExtendedGamepad: controller.extendedGamepad != nil,
                isActive: activeController === controller
            )
        }
    }

    func setRightStickHorizontalMode(_ mode: GameControllerRightStickHorizontalMode) {
        guard rightStickHorizontalMode != mode else {
            return
        }

        rightStickHorizontalMode = mode
        userDefaults.set(mode.rawValue, forKey: Persistence.rightStickHorizontalModeKey)
        debugLog("Right stick X -> \(mode.rawValue)")
    }

    private func registerControllerObservers() {
        connectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let controller = notification.object as? GCController else {
                return
            }

            self.handleControllerDidConnect(controller)
        }

        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let controller = notification.object as? GCController else {
                return
            }

            self.handleControllerDidDisconnect(controller)
        }
    }

    private func handleControllerDidConnect(_ controller: GCController) {
        guard controller.extendedGamepad != nil else {
            debugLog("Ignoring unsupported controller profile: \(controller.displayName)")
            return
        }

        debugLog("Connected: \(controller.displayName)")
        if activeController == nil || activeController?.extendedGamepad == nil {
            activateController(controller)
        }
    }

    private func handleControllerDidDisconnect(_ controller: GCController) {
        guard activeController === controller else {
            return
        }

        debugLog("Disconnected: \(controller.displayName)")
        activeController = nil
        previousButtonStates.removeAll()
        snapshot = .neutral(source: sourceKind)
        refreshActiveControllerIfNeeded()
    }

    private func selectInitialController() {
        if let controller = availableControllers().first {
            activateController(controller)
        }
    }

    private func refreshActiveControllerIfNeeded() {
        if let activeController,
           activeController.extendedGamepad != nil,
           availableControllers().contains(where: { $0 === activeController }) {
            return
        }

        if let replacement = availableControllers().first {
            activateController(replacement)
        } else if activeController != nil {
            activeController = nil
            previousButtonStates.removeAll()
        }
    }

    private func activateController(_ controller: GCController) {
        activeController = controller
        previousButtonStates = controller.extendedGamepad.map(mappedButtons(from:)) ?? [:]
        debugLog("Active controller: \(controller.displayName)")
    }

    private func availableControllers() -> [GCController] {
        GCController.controllers().filter { $0.extendedGamepad != nil }
    }

    private func mappedButtons(from gamepad: GCExtendedGamepad) -> [InputAction: Bool] {
        let openHubBinding = resolvedBinding(
            settingsStore.binding(for: .openControllerHub),
            on: gamepad
        )
        let payloadPanelPressed = payloadPanelButtonPressed(
            on: gamepad,
            reservedBinding: openHubBinding
        )
        let returnHomePressed = openHubBinding == .menu
            ? false
            : gamepad.buttonMenu.isPressed

        return [
            .armAircraft: gamepad.buttonA.isPressed,
            .disarmAircraft: gamepad.buttonB.isPressed,
            .toggleFPV: gamepad.buttonY.isPressed,
            .toggleMissionMap: gamepad.buttonX.isPressed,
            .toggleControlPanel: gamepad.dpad.left.isPressed,
            .togglePayloadPanel: payloadPanelPressed,
            .returnHome: returnHomePressed,
            .dropPayload: gamepad.dpad.right.isPressed,
            .pauseMission: gamepad.dpad.up.isPressed,
            .resumeMission: gamepad.dpad.down.isPressed,
            .toggleControllerCursor: isPressed(
                settingsStore.binding(for: .toggleCursor),
                on: gamepad
            ),
            .openControllerHub: isPressed(
                settingsStore.binding(for: .openControllerHub),
                on: gamepad
            ),
            .uiSectionPrevious: isPressed(
                settingsStore.binding(for: .previousSection),
                on: gamepad
            ),
            .uiSectionNext: isPressed(
                settingsStore.binding(for: .nextSection),
                on: gamepad
            ),
            .uiPrimary: isPressed(
                settingsStore.binding(for: .confirm),
                on: gamepad
            ),
            .uiSecondary: isPressed(
                settingsStore.binding(for: .cancel),
                on: gamepad
            ),
            .uiFocusUp: gamepad.dpad.up.isPressed,
            .uiFocusDown: gamepad.dpad.down.isPressed,
            .uiFocusLeft: gamepad.dpad.left.isPressed,
            .uiFocusRight: gamepad.dpad.right.isPressed
        ]
    }

    private func risingEdgeActions(from currentButtons: [InputAction: Bool]) -> [InputAction] {
        currentButtons.keys
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { action in
                let isPressed = currentButtons[action] ?? false
                let wasPressed = previousButtonStates[action] ?? false
                return isPressed && !wasPressed ? action : nil
            }
    }

    private func normalizedSignedAxis(_ value: Float) -> Float {
        let magnitude = abs(value)
        guard magnitude > Mapping.stickDeadzone else {
            return 0.0
        }

        let scaledMagnitude = min(
            1.0,
            (magnitude - Mapping.stickDeadzone) / (1.0 - Mapping.stickDeadzone)
        )
        return value.sign == .minus ? -scaledMagnitude : scaledMagnitude
    }

    private func normalizedTrigger(_ value: Float) -> Float {
        guard value > Mapping.triggerDeadzone else {
            return 0.0
        }

        return min(1.0, (value - Mapping.triggerDeadzone) / (1.0 - Mapping.triggerDeadzone))
    }

    private static func activityScore(for snapshot: InputSnapshot) -> Double {
        let continuousEnergy = min(
            1.0,
            abs(snapshot.yaw) +
            abs(snapshot.pitch) +
            abs(snapshot.roll) +
            abs(snapshot.throttle) * 0.8 +
            abs(snapshot.cameraPan) * 0.8 +
            abs(snapshot.cameraTilt) * 0.8 +
            abs(snapshot.uiPointerX) * 0.9 +
            abs(snapshot.uiPointerY) * 0.9
        )
        let actionBonus = snapshot.actions.isEmpty ? 0.0 : 1.0

        return min(1.0, max(actionBonus, continuousEnergy * 0.35))
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[GameControllerInputProvider] \(message)")
        #endif
    }

    private func isPressed(
        _ binding: ControllerButtonBinding,
        on gamepad: GCExtendedGamepad
    ) -> Bool {
        switch resolvedBinding(binding, on: gamepad) {
        case .buttonA:
            return gamepad.buttonA.isPressed
        case .buttonB:
            return gamepad.buttonB.isPressed
        case .buttonX:
            return gamepad.buttonX.isPressed
        case .buttonY:
            return gamepad.buttonY.isPressed
        case .dpadUp:
            return gamepad.dpad.up.isPressed
        case .dpadDown:
            return gamepad.dpad.down.isPressed
        case .dpadLeft:
            return gamepad.dpad.left.isPressed
        case .dpadRight:
            return gamepad.dpad.right.isPressed
        case .leftShoulder:
            return gamepad.leftShoulder.isPressed
        case .rightShoulder:
            return gamepad.rightShoulder.isPressed
        case .leftThumbstickButton:
            return gamepad.leftThumbstickButton?.isPressed ?? false
        case .rightThumbstickButton:
            return gamepad.rightThumbstickButton?.isPressed ?? false
        case .menu:
            return gamepad.buttonMenu.isPressed
        case .options:
            return gamepad.buttonOptions?.isPressed ?? false
        case .home:
            return gamepad.buttonHome?.isPressed ?? false
        case .secondaryMenu:
            return false
        }
    }

    private func resolvedBinding(
        _ binding: ControllerButtonBinding,
        on gamepad: GCExtendedGamepad
    ) -> ControllerButtonBinding {
        switch binding {
        case .secondaryMenu:
            if gamepad.buttonOptions != nil {
                return .options
            }
            if gamepad.buttonHome != nil {
                return .home
            }
            return .menu
        default:
            return binding
        }
    }

    private func payloadPanelButtonPressed(
        on gamepad: GCExtendedGamepad,
        reservedBinding: ControllerButtonBinding
    ) -> Bool {
        if reservedBinding != .options,
           let options = gamepad.buttonOptions,
           options.isPressed {
            return true
        }

        if reservedBinding != .home,
           let home = gamepad.buttonHome,
           home.isPressed {
            return true
        }

        return false
    }

    private static func loadRightStickHorizontalMode(
        from userDefaults: UserDefaults
    ) -> GameControllerRightStickHorizontalMode {
        guard let rawValue = userDefaults.string(forKey: Persistence.rightStickHorizontalModeKey),
              let mode = GameControllerRightStickHorizontalMode(rawValue: rawValue) else {
            return .yawLeftRight
        }

        return mode
    }

    private static func playerIndexLabel(
        for playerIndex: GCControllerPlayerIndex
    ) -> String {
        switch playerIndex {
        case .index1:
            return "Player 1"
        case .index2:
            return "Player 2"
        case .index3:
            return "Player 3"
        case .index4:
            return "Player 4"
        default:
            return "Unassigned"
        }
    }
}

private extension GCController {
    var displayName: String {
        if let vendorName,
           !vendorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return vendorName
        }

        if !productCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return productCategory
        }

        return "Unknown Controller"
    }
}

private extension InputAction {
    var sortOrder: Int {
        switch self {
        case .armAircraft:
            return 0
        case .disarmAircraft:
            return 1
        case .toggleFPV:
            return 2
        case .toggleMissionMap:
            return 3
        case .toggleTopView:
            return 4
        case .togglePayloadPanel:
            return 5
        case .returnHome:
            return 6
        case .dropPayload:
            return 7
        case .requestHover:
            return 8
        case .requestReset:
            return 9
        case .selectFreeCamera:
            return 10
        case .selectChaseCamera:
            return 11
        case .selectOrbitCamera:
            return 12
        case .selectFPVCamera:
            return 13
        case .selectTopCamera:
            return 14
        case .selectPayloadOpticsCamera:
            return 15
        case .selectPayloadCamera:
            return 16
        case .toggleTerrainMap:
            return 17
        case .toggleCompassOverlay:
            return 18
        case .toggleThermalOverlay:
            return 19
        case .toggleDamageOverlay:
            return 20
        case .cycleCameraMode:
            return 21
        case .toggleControlPanel:
            return 22
        case .toggleToolPanel:
            return 23
        case .toggleTelemetryHUD:
            return 24
        case .zoomInCamera:
            return 25
        case .zoomOutCamera:
            return 26
        case .resetCameraOrientation:
            return 27
        case .pauseMission:
            return 28
        case .resumeMission:
            return 29
        case .toggleControllerCursor:
            return 30
        case .openControllerHub:
            return 31
        case .uiSectionPrevious:
            return 32
        case .uiSectionNext:
            return 33
        case .uiPrimary:
            return 34
        case .uiSecondary:
            return 35
        case .uiFocusUp:
            return 36
        case .uiFocusDown:
            return 37
        case .uiFocusLeft:
            return 38
        case .uiFocusRight:
            return 39
        case .selectThermalPaletteWhiteHot:
            return 40
        case .selectThermalPaletteBlackHot:
            return 41
        case .selectThermalPaletteIron:
            return 42
        case .toggleRangefinderArmed:
            return 43
        }
    }
}

private extension InputSnapshot {
    func withActivityScore(_ value: Double) -> InputSnapshot {
        var copy = self
        copy.activityScore = value
        return copy
    }
}
