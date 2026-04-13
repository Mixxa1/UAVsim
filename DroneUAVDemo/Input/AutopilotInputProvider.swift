import Foundation

final class AutopilotInputProvider: InputProvider {
    let sourceKind: InputSourceKind = .autopilot
    var isEnabled: Bool = false

    private var snapshot: InputSnapshot = .neutral(source: .autopilot)

    func update(deltaTime: TimeInterval) {
        // TODO: Expose mission/autopilot directives through the shared input pipeline.
        snapshot = .neutral(source: sourceKind)
    }

    func currentSnapshot() -> InputSnapshot {
        snapshot
    }
}
