import Foundation

enum MissionOutcome: String, CaseIterable, Codable, Equatable {
    case success
    case partialSuccess
    case aborted
    case failed
    case returnedHome
    case safetyTerminated

    var titleKey: String {
        switch self {
        case .success:
            return "mission.outcome.success"
        case .partialSuccess:
            return "mission.outcome.partial_success"
        case .aborted:
            return "mission.outcome.aborted"
        case .failed:
            return "mission.outcome.failed"
        case .returnedHome:
            return "mission.outcome.returned_home"
        case .safetyTerminated:
            return "mission.outcome.safety_terminated"
        }
    }

    var verdictKey: String {
        switch self {
        case .success:
            return "mission.debrief.verdict.success"
        case .partialSuccess:
            return "mission.debrief.verdict.partial_success"
        case .aborted:
            return "mission.debrief.verdict.aborted"
        case .failed:
            return "mission.debrief.verdict.failed"
        case .returnedHome:
            return "mission.debrief.verdict.returned_home"
        case .safetyTerminated:
            return "mission.debrief.verdict.safety_terminated"
        }
    }
}
