import Foundation

final class InputManager {
    private struct SmoothedAxes {
        var yaw: Double = 0.0
        var pitch: Double = 0.0
        var roll: Double = 0.0
        var throttle: Double = 0.0
        var cameraPan: Double = 0.0
        var cameraTilt: Double = 0.0
    }

    private let deadzoneThreshold: Double
    private let dominantSourceHoldBias: Double
    private let activeSourceThreshold: Double
    private let flightAxisResponse: Double
    private let throttleResponse: Double
    private let cameraAxisResponse: Double

    private var smoothedAxes = SmoothedAxes()
    private var lastDominantSource: InputSourceKind?
    private var latestSnapshotsBySource: [InputSourceKind: InputSnapshot] = [:]

    private(set) var providers: [any InputProvider]
    private(set) var currentState: ResolvedControlState

    init(
        providers: [any InputProvider] = [],
        deadzoneThreshold: Double = 0.12,
        dominantSourceHoldBias: Double = 0.08,
        activeSourceThreshold: Double = 0.05,
        flightAxisResponse: Double = 60.0,
        throttleResponse: Double = 72.0,
        cameraAxisResponse: Double = 90.0
    ) {
        self.providers = providers
        self.deadzoneThreshold = deadzoneThreshold
        self.dominantSourceHoldBias = dominantSourceHoldBias
        self.activeSourceThreshold = activeSourceThreshold
        self.flightAxisResponse = flightAxisResponse
        self.throttleResponse = throttleResponse
        self.cameraAxisResponse = cameraAxisResponse
        self.currentState = .neutral
    }

    func addProvider(_ provider: any InputProvider) {
        providers.append(provider)
    }

    func update(deltaTime: TimeInterval) {
        let safeDeltaTime = max(0.0, deltaTime)
        let activeProviders = providers.filter { $0.isEnabled }

        for provider in activeProviders {
            provider.update(deltaTime: safeDeltaTime)
        }

        let snapshots = activeProviders.map { $0.currentSnapshot() }
        latestSnapshotsBySource = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.source, $0) })
        let dominantSnapshot = resolveDominantSnapshot(in: snapshots)
        let targetSnapshot = dominantSnapshot ?? InputSnapshot.neutral(
            source: lastDominantSource ?? .keyboard,
            isConnected: false
        )

        smoothedAxes.yaw = smooth(
            current: smoothedAxes.yaw,
            target: applyDeadzone(to: targetSnapshot.yaw),
            response: flightAxisResponse,
            deltaTime: safeDeltaTime
        )
        smoothedAxes.pitch = smooth(
            current: smoothedAxes.pitch,
            target: applyDeadzone(to: targetSnapshot.pitch),
            response: flightAxisResponse,
            deltaTime: safeDeltaTime
        )
        smoothedAxes.roll = smooth(
            current: smoothedAxes.roll,
            target: applyDeadzone(to: targetSnapshot.roll),
            response: flightAxisResponse,
            deltaTime: safeDeltaTime
        )
        smoothedAxes.throttle = smooth(
            current: smoothedAxes.throttle,
            target: targetSnapshot.throttle,
            response: throttleResponse,
            deltaTime: safeDeltaTime
        )
        smoothedAxes.cameraPan = smooth(
            current: smoothedAxes.cameraPan,
            target: applyDeadzone(to: targetSnapshot.cameraPan),
            response: cameraAxisResponse,
            deltaTime: safeDeltaTime
        )
        smoothedAxes.cameraTilt = smooth(
            current: smoothedAxes.cameraTilt,
            target: applyDeadzone(to: targetSnapshot.cameraTilt),
            response: cameraAxisResponse,
            deltaTime: safeDeltaTime
        )

        let actionSnapshots = snapshots.filter { $0.isConnected }
        let actions = mergeActions(from: actionSnapshots)

        currentState = ResolvedControlState(
            yaw: smoothedAxes.yaw,
            pitch: smoothedAxes.pitch,
            roll: smoothedAxes.roll,
            throttle: smoothedAxes.throttle,
            cameraPan: smoothedAxes.cameraPan,
            cameraTilt: smoothedAxes.cameraTilt,
            uiPointerX: applyDeadzone(to: targetSnapshot.uiPointerX),
            uiPointerY: applyDeadzone(to: targetSnapshot.uiPointerY),
            uiScrollX: applyDeadzone(to: targetSnapshot.uiScrollX),
            uiScrollY: applyDeadzone(to: targetSnapshot.uiScrollY),
            precisionMode: targetSnapshot.precisionMode,
            boostMode: targetSnapshot.boostMode,
            isHoseSprayHeld: targetSnapshot.isHoseSprayHeld,
            actions: actions,
            dominantSource: dominantSnapshot?.source
        )
    }

    func reset() {
        smoothedAxes = SmoothedAxes()
        lastDominantSource = nil
        latestSnapshotsBySource = [:]
        currentState = .neutral
    }

    func snapshot(for source: InputSourceKind) -> InputSnapshot? {
        latestSnapshotsBySource[source]
    }

    func isSourceConnected(_ source: InputSourceKind) -> Bool {
        latestSnapshotsBySource[source]?.isConnected ?? false
    }

    private func resolveDominantSnapshot(in snapshots: [InputSnapshot]) -> InputSnapshot? {
        let connectedSnapshots = snapshots.filter { $0.isConnected }
        guard !connectedSnapshots.isEmpty else {
            lastDominantSource = nil
            return nil
        }

        let previousSnapshot = lastDominantSource.flatMap { source in
            connectedSnapshots.first { $0.source == source }
        }
        let bestSnapshot = connectedSnapshots.max { lhs, rhs in
            lhs.activityScore < rhs.activityScore
        }

        let resolvedSnapshot: InputSnapshot?
        if let previousSnapshot,
           previousSnapshot.activityScore > activeSourceThreshold,
           let bestSnapshot,
           bestSnapshot.source != previousSnapshot.source,
           bestSnapshot.activityScore < previousSnapshot.activityScore + dominantSourceHoldBias {
            resolvedSnapshot = previousSnapshot
        } else if let bestSnapshot, bestSnapshot.activityScore > activeSourceThreshold {
            resolvedSnapshot = bestSnapshot
        } else {
            resolvedSnapshot = previousSnapshot ?? connectedSnapshots.first
        }

        lastDominantSource = resolvedSnapshot?.source
        return resolvedSnapshot
    }

    private func mergeActions(from snapshots: [InputSnapshot]) -> [InputAction] {
        var seen = Set<InputAction>()
        var merged: [InputAction] = []

        for snapshot in snapshots {
            for action in snapshot.actions where seen.insert(action).inserted {
                merged.append(action)
            }
        }

        return merged
    }

    private func applyDeadzone(to value: Double) -> Double {
        let magnitude = abs(value)
        guard magnitude > deadzoneThreshold else {
            return 0.0
        }

        let normalized = (magnitude - deadzoneThreshold) / (1.0 - deadzoneThreshold)
        return value.sign == .minus ? -normalized : normalized
    }

    private func smooth(
        current: Double,
        target: Double,
        response: Double,
        deltaTime: TimeInterval
    ) -> Double {
        guard deltaTime > 0.0 else {
            return target
        }

        let blend = 1.0 - exp(-response * deltaTime)
        return current + (target - current) * blend
    }
}
