import Foundation

struct MissionDraft: Equatable {
    var waypoints: [MissionWaypoint]
    var zones: [MissionZone]
    var constraints: MissionConstraints

    static let empty = MissionDraft(
        waypoints: [],
        zones: [],
        constraints: .stageOneDefault
    )

    var hasWaypoints: Bool {
        !waypoints.isEmpty
    }

    var hasZones: Bool {
        !zones.isEmpty
    }

    var hasContent: Bool {
        hasWaypoints || hasZones
    }

    var dropZone: MissionZone? {
        zones.first { $0.type == .dropZone }
    }

    var noFlyZones: [MissionZone] {
        zones.filter { $0.type == .noFlyZone }
    }

    var noFlyZone: MissionZone? {
        noFlyZones.last
    }
}
