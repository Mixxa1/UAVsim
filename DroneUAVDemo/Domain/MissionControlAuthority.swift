import Foundation

enum MissionControlAuthority: String, Equatable, Codable {
    case none
    case manual
    case targetMarker
    case mission
    case failsafe

    var title: String {
        NSLocalizedString(titleKey, comment: "")
    }

    var titleKey: String {
        switch self {
        case .none:
            return "control_authority.none"
        case .manual:
            return "control_authority.manual"
        case .targetMarker:
            return "control_authority.marker"
        case .mission:
            return "control_authority.mission"
        case .failsafe:
            return "control_authority.failsafe"
        }
    }
}
