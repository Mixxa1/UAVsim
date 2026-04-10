import Foundation

enum MissionDraftIssueSeverity: String, Equatable {
    case info
    case warning
    case error
}

struct MissionDraftIssue: Identifiable, Equatable {
    var id: String { "\(severity.rawValue):\(reason.rawValue):\(messageKey)" }
    var severity: MissionDraftIssueSeverity
    var reason: MissionFailureReason
    var messageKey: String
}

enum MissionDraftStatusKind: String, Equatable {
    case empty
    case editing
    case ready
    case invalid
    case previewUnavailable
}

struct MissionDraftStatus: Equatable {
    var kind: MissionDraftStatusKind
    var titleKey: String
    var detailKey: String
    var issues: [MissionDraftIssue]
    var isPreviewAvailable: Bool
    var canSave: Bool

    static let empty = MissionDraftStatus(
        kind: .empty,
        titleKey: "tactical.map.status.empty.title",
        detailKey: "tactical.map.status.empty.detail",
        issues: [],
        isPreviewAvailable: false,
        canSave: false
    )
}
