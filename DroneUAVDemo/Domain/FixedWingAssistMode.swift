import Foundation
import simd

enum FixedWingAssistMode: String, CaseIterable, Identifiable {
    case manual
    case headingHold
    case altitudeHold
    case waypointIntercept

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .manual:
            return "mode.manual"
        case .headingHold:
            return "mode.fixed_wing_heading_hold"
        case .altitudeHold:
            return "mode.fixed_wing_altitude_hold"
        case .waypointIntercept:
            return "mode.fixed_wing_waypoint_intercept"
        }
    }
}

struct FixedWingAssistWaypointOption: Identifiable, Equatable {
    let id: UUID
    let label: String
    let position: SIMD2<Float>
}

struct FixedWingAssistState: Equatable {
    var mode: FixedWingAssistMode
    var selectedWaypointID: UUID?
    var targetHeadingRadians: Float?
    var targetAltitudeMeters: Float?
    var interceptCompleted: Bool

    static let manual = FixedWingAssistState(
        mode: .manual,
        selectedWaypointID: nil,
        targetHeadingRadians: nil,
        targetAltitudeMeters: nil,
        interceptCompleted: false
    )
}
