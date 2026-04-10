import Foundation

enum MissionWaypointProgressState: String, Equatable {
    case pending
    case active
    case completed
}

struct MissionWaypointProgress: Identifiable, Equatable {
    var id: UUID { target.id }
    var target: MissionTarget
    var state: MissionWaypointProgressState
    var reachedAt: Date?
}
