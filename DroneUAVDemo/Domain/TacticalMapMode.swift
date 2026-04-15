import Foundation

enum TacticalMapMode: String, CaseIterable, Identifiable {
    case waypoint
    case launchObject
    case dropZone
    case noFlyZone

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .waypoint:
            return "tactical.map.mode.waypoint"
        case .launchObject:
            return "tactical.map.mode.launch_object"
        case .dropZone:
            return "tactical.map.mode.drop_zone"
        case .noFlyZone:
            return "tactical.map.mode.no_fly_zone"
        }
    }

    var instructionKey: String {
        switch self {
        case .waypoint:
            return "tactical.map.instruction.waypoint"
        case .launchObject:
            return "tactical.map.instruction.launch_object"
        case .dropZone:
            return "tactical.map.instruction.drop_zone"
        case .noFlyZone:
            return "tactical.map.instruction.no_fly_zone"
        }
    }

    var zoneType: MissionZoneType? {
        switch self {
        case .waypoint:
            return nil
        case .launchObject:
            return nil
        case .dropZone:
            return .dropZone
        case .noFlyZone:
            return .noFlyZone
        }
    }
}
