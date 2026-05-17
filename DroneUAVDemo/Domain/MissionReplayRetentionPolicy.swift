import Foundation

struct MissionReplayRetentionPolicy: Codable, Equatable {
    var isAutoDeleteEnabled: Bool
    var maxStoredReplayCount: Int

    static let defaultPolicy = MissionReplayRetentionPolicy(
        isAutoDeleteEnabled: true,
        maxStoredReplayCount: 5
    )

    var clamped: MissionReplayRetentionPolicy {
        MissionReplayRetentionPolicy(
            isAutoDeleteEnabled: isAutoDeleteEnabled,
            maxStoredReplayCount: max(1, min(100, maxStoredReplayCount))
        )
    }
}
