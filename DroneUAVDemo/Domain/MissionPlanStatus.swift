import Foundation

enum MissionPlanStatus: String, Equatable {
    case draft
    case invalid
    case validated

    var titleKey: String {
        switch self {
        case .draft:
            return "mission.plan.status.draft"
        case .invalid:
            return "mission.plan.status.invalid"
        case .validated:
            return "mission.plan.status.validated"
        }
    }
}
