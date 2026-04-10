import Foundation

enum MissionStatusExplanationSeverity: String, Equatable {
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

struct MissionStatusExplanation: Identifiable, Equatable {
    var id: String
    var reason: MissionFailureReason
    var severity: MissionStatusExplanationSeverity
    var titleKey: String
    var detailKey: String
    var isBlocking: Bool

    init(
        reason: MissionFailureReason,
        severity: MissionStatusExplanationSeverity,
        titleKey: String? = nil,
        detailKey: String,
        isBlocking: Bool? = nil
    ) {
        self.reason = reason
        self.severity = severity
        self.titleKey = titleKey ?? reason.titleKey
        self.detailKey = detailKey
        self.isBlocking = isBlocking ?? (severity == .critical)
        self.id = [
            reason.rawValue,
            self.titleKey,
            detailKey,
            severity.rawValue
        ].joined(separator: "::")
    }
}
