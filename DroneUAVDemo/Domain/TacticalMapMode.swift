import Foundation

enum TacticalMapMode: String, CaseIterable, Identifiable {
    case waypoint
    case launchObject
    case dropZone

    var id: String { rawValue }

    static var planningModes: [TacticalMapMode] {
        allCases
    }

    var titleKey: String {
        switch self {
        case .waypoint:
            return "tactical.map.mode.waypoint"
        case .launchObject:
            return "tactical.map.mode.launch_object"
        case .dropZone:
            return "tactical.map.mode.drop_zone"
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
        }
    }

    var zoneType: MissionZoneType? {
        switch self {
        case .waypoint, .launchObject:
            return nil
        case .dropZone:
            return .dropZone
        }
    }
}
