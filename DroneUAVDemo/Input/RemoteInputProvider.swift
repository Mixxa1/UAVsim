import Foundation

final class RemoteInputProvider: InputProvider {
    private struct PacketActionState {
        var armPressed: Bool
        var disarmPressed: Bool
        var toggleFPVPressed: Bool
        var toggleTopViewPressed: Bool
        var toggleMapPressed: Bool
        var togglePayloadPressed: Bool
        var dropPayloadPressed: Bool
        var returnHomePressed: Bool
        var pauseMissionPressed: Bool
        var resumeMissionPressed: Bool

        init(packet: RemoteControlPacket) {
            self.armPressed = packet.armPressed
            self.disarmPressed = packet.disarmPressed
            self.toggleFPVPressed = packet.toggleFPVPressed
            self.toggleTopViewPressed = packet.toggleTopViewPressed
            self.toggleMapPressed = packet.toggleMapPressed
            self.togglePayloadPressed = packet.togglePayloadPressed
            self.dropPayloadPressed = packet.dropPayloadPressed
            self.returnHomePressed = packet.returnHomePressed
            self.pauseMissionPressed = packet.pauseMissionPressed
            self.resumeMissionPressed = packet.resumeMissionPressed
        }

        static let neutral = PacketActionState(
            armPressed: false,
            disarmPressed: false,
            toggleFPVPressed: false,
            toggleTopViewPressed: false,
            toggleMapPressed: false,
            togglePayloadPressed: false,
            dropPayloadPressed: false,
            returnHomePressed: false,
            pauseMissionPressed: false,
            resumeMissionPressed: false
        )

        private init(
            armPressed: Bool,
            disarmPressed: Bool,
            toggleFPVPressed: Bool,
            toggleTopViewPressed: Bool,
            toggleMapPressed: Bool,
            togglePayloadPressed: Bool,
            dropPayloadPressed: Bool,
            returnHomePressed: Bool,
            pauseMissionPressed: Bool,
            resumeMissionPressed: Bool
        ) {
            self.armPressed = armPressed
            self.disarmPressed = disarmPressed
            self.toggleFPVPressed = toggleFPVPressed
            self.toggleTopViewPressed = toggleTopViewPressed
            self.toggleMapPressed = toggleMapPressed
            self.togglePayloadPressed = togglePayloadPressed
            self.dropPayloadPressed = dropPayloadPressed
            self.returnHomePressed = returnHomePressed
            self.pauseMissionPressed = pauseMissionPressed
            self.resumeMissionPressed = resumeMissionPressed
        }

        func risingActions(since previous: PacketActionState) -> [InputAction] {
            var actions: [InputAction] = []

            if armPressed && !previous.armPressed { actions.append(.armAircraft) }
            if disarmPressed && !previous.disarmPressed { actions.append(.disarmAircraft) }
            if toggleFPVPressed && !previous.toggleFPVPressed { actions.append(.toggleFPV) }
            if toggleTopViewPressed && !previous.toggleTopViewPressed { actions.append(.toggleTopView) }
            if toggleMapPressed && !previous.toggleMapPressed { actions.append(.toggleMissionMap) }
            if togglePayloadPressed && !previous.togglePayloadPressed { actions.append(.togglePayloadPanel) }
            if dropPayloadPressed && !previous.dropPayloadPressed { actions.append(.dropPayload) }
            if returnHomePressed && !previous.returnHomePressed { actions.append(.returnHome) }
            if pauseMissionPressed && !previous.pauseMissionPressed { actions.append(.pauseMission) }
            if resumeMissionPressed && !previous.resumeMissionPressed { actions.append(.resumeMission) }

            return actions
        }
    }

    let sourceKind: InputSourceKind = .remote
    var isEnabled: Bool = true

    private let transport: RemoteTransport?
    private let connectionTimeout: TimeInterval
    private let now: () -> TimeInterval
    private let stateLock = NSLock()

    private var latestSequence: Int?
    private var lastReceivedAt: TimeInterval?
    private var latestContinuousSnapshot: InputSnapshot = .neutral(source: .remote)
    private var latestActionState: PacketActionState = .neutral
    private var pendingActions: [InputAction] = []
    private var snapshot: InputSnapshot = .neutral(source: .remote)

    init(
        transport: RemoteTransport? = nil,
        connectionTimeout: TimeInterval = 0.35,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.transport = transport
        self.connectionTimeout = connectionTimeout
        self.now = now

        self.transport?.packetHandler = { [weak self] packet in
            self?.ingestRemotePacket(packet)
        }
        self.transport?.disconnectHandler = { [weak self] in
            self?.handleTransportDisconnected()
        }
        self.transport?.start()
    }

    deinit {
        transport?.stop()
    }

    func ingestRemotePacket(_ packet: RemoteControlPacket) {
        let receivedAt = now()
        var didConnect = false

        stateLock.lock()
        defer {
            stateLock.unlock()
            if didConnect {
                debugLog("Remote connected with packet seq \(packet.seq)")
            }
        }

        if let latestSequence, packet.seq <= latestSequence {
            return
        }

        didConnect = !isFreshLocked(at: receivedAt)

        let actionState = PacketActionState(packet: packet)
        for action in actionState.risingActions(since: latestActionState)
        where !pendingActions.contains(action) {
            pendingActions.append(action)
        }
        latestActionState = actionState
        latestSequence = packet.seq
        lastReceivedAt = receivedAt
        latestContinuousSnapshot = InputSnapshot(
            yaw: packet.yaw,
            pitch: packet.pitch,
            roll: packet.roll,
            throttle: packet.throttle,
            cameraPan: packet.cameraPan,
            cameraTilt: packet.cameraTilt,
            uiPointerX: 0.0,
            uiPointerY: 0.0,
            uiScrollX: 0.0,
            uiScrollY: 0.0,
            precisionMode: packet.precisionMode,
            boostMode: packet.boostMode,
            actions: [],
            source: sourceKind,
            timestamp: packet.timestamp,
            isConnected: true,
            activityScore: 0.0
        )
    }

    func update(deltaTime: TimeInterval) {
        guard isEnabled else {
            stateLock.lock()
            latestSequence = nil
            lastReceivedAt = nil
            latestContinuousSnapshot = .neutral(source: sourceKind)
            latestActionState = .neutral
            pendingActions.removeAll()
            snapshot = .neutral(source: sourceKind)
            stateLock.unlock()
            return
        }

        let currentTime = now()
        var didTimeout = false

        stateLock.lock()
        defer {
            stateLock.unlock()
            if didTimeout {
                debugLog("Remote timed out after \(connectionTimeout)s")
            }
        }

        guard isFreshLocked(at: currentTime) else {
            didTimeout = snapshot.isConnected
            pendingActions.removeAll()
            latestActionState = .neutral
            snapshot = .neutral(source: sourceKind, timestamp: currentTime, isConnected: false)
            return
        }

        var nextSnapshot = latestContinuousSnapshot
        nextSnapshot.actions = pendingActions
        pendingActions.removeAll()
        nextSnapshot.isConnected = true
        nextSnapshot.activityScore = Self.activityScore(for: nextSnapshot)
        snapshot = nextSnapshot
    }

    func currentSnapshot() -> InputSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return snapshot
    }

    private func handleTransportDisconnected() {
        stateLock.lock()
        latestSequence = nil
        lastReceivedAt = nil
        latestContinuousSnapshot = .neutral(source: sourceKind)
        latestActionState = .neutral
        pendingActions.removeAll()
        snapshot = .neutral(source: sourceKind, timestamp: now(), isConnected: false)
        stateLock.unlock()

        debugLog("Remote transport disconnected")
    }

    private func isFreshLocked(at currentTime: TimeInterval) -> Bool {
        guard let lastReceivedAt else {
            return false
        }

        return currentTime - lastReceivedAt <= connectionTimeout
    }

    private static func activityScore(for snapshot: InputSnapshot) -> Double {
        let continuousEnergy = min(
            1.0,
            abs(snapshot.yaw) +
            abs(snapshot.pitch) +
            abs(snapshot.roll) +
            abs(snapshot.throttle) * 0.8 +
            abs(snapshot.cameraPan) * 0.8 +
            abs(snapshot.cameraTilt) * 0.8
        )
        let modeBonus = snapshot.boostMode ? 0.15 : 0.0
        let actionBonus = snapshot.actions.isEmpty ? 0.0 : 1.0

        return min(1.0, max(actionBonus, continuousEnergy * 0.35 + modeBonus))
    }

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[RemoteInputProvider] \(message)")
        #endif
    }
}
