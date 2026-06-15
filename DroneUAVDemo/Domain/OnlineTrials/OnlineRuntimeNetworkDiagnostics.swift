import Foundation

struct OnlineRuntimeNetworkDiagnostics: Equatable {
    // Snapshot throughput
    var outgoingSnapshotCount: Int = 0
    var incomingSnapshotCount: Int = 0

    // Shared event throughput
    var sharedEventSentCount: Int = 0
    var sharedEventReceivedCount: Int = 0

    // Session topology
    var connectedParticipantCount: Int = 0

    // Ghost replica health (updated by DroneSimulationViewModel after each interpolation pass)
    var remoteGhostVisibleCount: Int = 0
    var remoteGhostStaleCount: Int = 0

    // Runtime handoff timestamp
    var lastRuntimeHandoffAt: TimeInterval? = nil

    // Ping/pong RTT
    var lastPingAt: TimeInterval? = nil
    var lastPongAt: TimeInterval? = nil
    var lastPingRoundtripMs: Double? = nil

    var pingLabel: String {
        guard let rtt = lastPingRoundtripMs else { return "—" }
        return String(format: "%.0f ms", rtt)
    }
}
