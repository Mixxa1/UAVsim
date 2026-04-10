import Foundation

enum MissionWarningSeverity: String, Equatable {
    case info
    case warning
    case critical

    var priority: Int {
        switch self {
        case .critical:
            return 0
        case .warning:
            return 1
        case .info:
            return 2
        }
    }
}

struct MissionWarning: Identifiable, Equatable {
    var id: String
    var reason: MissionFailureReason
    var severity: MissionWarningSeverity
    var detailKey: String

    init(
        reason: MissionFailureReason,
        severity: MissionWarningSeverity,
        detailKey: String
    ) {
        self.reason = reason
        self.severity = severity
        self.detailKey = detailKey
        self.id = [reason.rawValue, severity.rawValue, detailKey].joined(separator: "::")
    }
}
