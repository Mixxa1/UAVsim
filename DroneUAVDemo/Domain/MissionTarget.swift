import Foundation
import simd

struct MissionTarget: Identifiable, Equatable {
    let id: UUID
    var waypointID: UUID
    var index: Int
    var label: String
    var position: SIMD2<Float>
    var countsTowardMissionProgress: Bool

    init(
        id: UUID = UUID(),
        waypointID: UUID,
        index: Int,
        label: String,
        position: SIMD2<Float>,
        countsTowardMissionProgress: Bool
    ) {
        self.id = id
        self.waypointID = waypointID
        self.index = index
        self.label = label
        self.position = position
        self.countsTowardMissionProgress = countsTowardMissionProgress
    }

    init(waypoint: MissionWaypoint) {
        self.init(
            id: waypoint.id,
            waypointID: waypoint.id,
            index: waypoint.index,
            label: waypoint.label,
            position: waypoint.position,
            countsTowardMissionProgress: true
        )
    }
}
