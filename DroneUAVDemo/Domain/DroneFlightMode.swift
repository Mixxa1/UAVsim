import Foundation

enum DroneFlightMode: String, CaseIterable {
    case manual
    case autoPath
    case returnHome
    case hover
    case emergencyStop
    case takeoff
    case landing

    var title: String {
        switch self {
        case .manual:
            return "Manual"
        case .autoPath:
            return "Auto-Path"
        case .returnHome:
            return "Return/Home"
        case .hover:
            return "Hover"
        case .emergencyStop:
            return "Emergency Stop"
        case .takeoff:
            return "Takeoff"
        case .landing:
            return "Landing"
        }
    }

    var titleKey: String {
        switch self {
        case .manual:
            return "mode.manual"
        case .autoPath:
            return "mode.auto_path"
        case .returnHome:
            return "mode.return_home"
        case .hover:
            return "mode.hover"
        case .emergencyStop:
            return "mode.emergency_stop"
        case .takeoff:
            return "mode.takeoff"
        case .landing:
            return "mode.landing"
        }
    }
}

enum FlightControlMode: String, CaseIterable, Identifiable {
    case stabilized
    case acro
    case hoverAssist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stabilized:
            return "Angle"
        case .acro:
            return "Acro"
        case .hoverAssist:
            return "Hover Assist"
        }
    }

    var titleKey: String {
        switch self {
        case .stabilized:
            return "control_mode.angle"
        case .acro:
            return "control_mode.acro"
        case .hoverAssist:
            return "control_mode.hover_assist"
        }
    }

    var isAngleMode: Bool {
        switch self {
        case .stabilized, .hoverAssist:
            return true
        case .acro:
            return false
        }
    }

    var isRateMode: Bool {
        self == .acro
    }
}
