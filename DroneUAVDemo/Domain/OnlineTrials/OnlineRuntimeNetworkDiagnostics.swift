import Foundation

struct OnlineRuntimeNetworkDiagnostics: Equatable {
    // Snapshot throughput (measured per second on the receiver side)
    var outgoingSnapshotCount: Int = 0
    var incomingSnapshotCount: Int = 0
    var outgoingSnapshotHz: Double = 0
    var incomingSnapshotHz: Double = 0
    var sceneApplyHz: Double = 0
    var renderFPS: Double = 0

    // Shared event throughput
    var sharedEventSentCount: Int = 0
    var sharedEventReceivedCount: Int = 0

    // Session topology
    var connectedParticipantCount: Int = 0

    // Ghost replica health (receiver-local time, no sender-clock dependency)
    var remoteGhostVisibleCount: Int = 0
    var remoteGhostStaleCount: Int = 0
    var remoteVisualLagMs: Double? = nil
    var remoteSnapshotBufferDepthMax: Int = 0
    var remoteDroppedOldSnapshotCount: UInt64 = 0
    var remoteOutOfOrderDropCount: UInt64 = 0

    // Runtime handoff timestamp
    var lastRuntimeHandoffAt: TimeInterval? = nil

    // Ping/pong RTT
    var lastPingAt: TimeInterval? = nil
    var lastPongAt: TimeInterval? = nil
    var lastPingRoundtripMs: Double? = nil

    // Window / scene state
    var visibilityStateLabel: String = "active"
    var sceneIsPlaying: Bool = true
    var scenePreferredFPS: Int = 60

    var pingLabel: String {
        guard let rtt = lastPingRoundtripMs else { return "—" }
        return String(format: "%.0f ms", rtt)
    }
}
