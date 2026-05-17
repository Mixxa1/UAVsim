import Foundation

struct MissionReplaySession: Identifiable, Codable, Equatable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var frames: [MissionReplayFrame]
    var events: [MissionReplayEvent]
    var context: MissionReplayContextSnapshot?

    var duration: TimeInterval {
        if let endedAt { return endedAt.timeIntervalSince(startedAt) }
        return Date().timeIntervalSince(startedAt)
    }

    var frameCount: Int { frames.count }
    var eventCount: Int { events.count }
}
