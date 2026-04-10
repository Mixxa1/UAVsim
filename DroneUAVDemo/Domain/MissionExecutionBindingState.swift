import Foundation

enum MissionExecutionBindingState: String, Equatable {
    case unbound
    case bound
    case failed

    var titleKey: String {
        switch self {
        case .unbound:
            return "mission.binding.status.unbound"
        case .bound:
            return "mission.binding.status.bound"
        case .failed:
            return "mission.binding.status.failed"
        }
    }
}

enum MissionExecutionReadiness: String, Equatable {
    case draft
    case validated
    case executionUnbound
    case ready
    case failedBinding

    var titleKey: String {
        switch self {
        case .draft:
            return "mission.execution.readiness.draft"
        case .validated:
            return "mission.execution.readiness.validated"
        case .executionUnbound:
            return "mission.execution.readiness.unbound"
        case .ready:
            return "mission.execution.readiness.ready"
        case .failedBinding:
            return "mission.execution.readiness.failed"
        }
    }
}
