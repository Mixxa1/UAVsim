import Foundation

final class KeyboardInputProvider: InputProvider {
    let sourceKind: InputSourceKind = .keyboard
    var isEnabled: Bool = true

    private let keyboardInputService: KeyboardInputProviding
    private var snapshot: InputSnapshot = .neutral(source: .keyboard, isConnected: true)

    init(keyboardInputService: KeyboardInputProviding) {
        self.keyboardInputService = keyboardInputService
    }

    func update(deltaTime: TimeInterval) {
        let keyboardSnapshot = keyboardInputService.currentInputSnapshot()
        let actions = keyboardInputService.consumeActions()
        let boostMode = keyboardSnapshot.axisInput.speedBoost ||
            keyboardSnapshot.yawInput.speedBoost ||
            keyboardSnapshot.lookInput.speedBoost
        let nextSnapshot = InputSnapshot(
            yaw: Double(keyboardSnapshot.yawInput.intent),
            pitch: Double(keyboardSnapshot.axisInput.forward),
            roll: Double(keyboardSnapshot.axisInput.strafe),
            throttle: Double(keyboardSnapshot.axisInput.vertical),
            cameraPan: Double(keyboardSnapshot.lookInput.yaw),
            cameraTilt: Double(keyboardSnapshot.lookInput.pitch),
            uiPointerX: 0.0,
            uiPointerY: 0.0,
            uiScrollX: 0.0,
            uiScrollY: 0.0,
            precisionMode: false,
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

    private static func activityScore(for snapshot: InputSnapshot) -> Double {
        let continuousEnergy = min(
            1.0,
            abs(snapshot.yaw) +
            abs(snapshot.pitch) +
            abs(snapshot.roll) +
            abs(snapshot.throttle) * 0.8 +
            abs(snapshot.cameraPan) +
            abs(snapshot.cameraTilt)
        )
        let modeBonus = snapshot.boostMode ? 0.15 : 0.0
        let actionBonus = snapshot.actions.isEmpty ? 0.0 : 1.0

        return min(1.0, max(actionBonus, continuousEnergy * 0.35 + modeBonus))
    }
}

private extension InputSnapshot {
    func withActivityScore(_ value: Double) -> InputSnapshot {
        var copy = self
        copy.activityScore = value
        return copy
    }
}
