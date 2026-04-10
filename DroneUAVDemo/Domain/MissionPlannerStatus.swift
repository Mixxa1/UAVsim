import Foundation

enum MissionPlannerStatus: String, Equatable {
    case draft
    case previewReady
    case validated
    case invalid

    var titleKey: String {
        switch self {
        case .draft:
            return "mission.planner.status.draft"
        case .previewReady:
            return "mission.planner.status.preview"
        case .validated:
            return "mission.planner.status.validated"
        case .invalid:
            return "mission.planner.status.invalid"
        }
    }
}

enum MissionOperationalStatus: String, Equatable {
    case idle
    case ready
    case running
    case paused
    case completed
    case aborted
    case failedsafe
    case noControlAuthority
    case routeMismatch
    case trackingUnavailable

    var titleKey: String {
        switch self {
        case .idle:
            return "mission.runtime.status.idle"
        case .ready:
            return "mission.runtime.status.ready"
        case .running:
            return "mission.runtime.status.running"
        case .paused:
            return "mission.runtime.status.paused"
        case .completed:
            return "mission.runtime.status.completed"
        case .aborted:
            return "mission.runtime.status.aborted"
        case .failedsafe:
            return "mission.runtime.status.failedsafe"
        case .noControlAuthority:
            return "mission.runtime.status.no_authority"
        case .routeMismatch:
            return "mission.runtime.status.route_mismatch"
        case .trackingUnavailable:
            return "mission.runtime.status.tracking_unavailable"
        }
    }
}

struct MissionStatusSnapshot: Equatable {
    var plannerStatus: MissionPlannerStatus
    var operationalStatus: MissionOperationalStatus
    var controlAuthority: MissionControlAuthority
    var hasValidatedRoute: Bool
    var executionUsesValidatedRoute: Bool
    var routeMismatch: Bool
    var trackingAvailable: Bool
    var canPrepare: Bool
    var canStart: Bool
    var explanations: [MissionStatusExplanation]

    var primaryExplanation: MissionStatusExplanation? {
        explanations.sorted { lhs, rhs in
            if lhs.severity.priority != rhs.severity.priority {
                return lhs.severity.priority < rhs.severity.priority
            }
            if lhs.isBlocking != rhs.isBlocking {
                return lhs.isBlocking && !rhs.isBlocking
            }
            return lhs.detailKey < rhs.detailKey
        }.first
    }

    var summaryKeys: [String] {
        var keys = [
            plannerStatus.titleKey,
            operationalStatus.titleKey,
            controlAuthority.titleKey
        ]
        keys.append(contentsOf: explanations.map(\.detailKey))
        return Array(NSOrderedSet(array: keys)) as? [String] ?? keys
    }

    var blockingKeys: [String] {
        let keys = explanations
            .filter(\.isBlocking)
            .map(\.detailKey)
        return Array(NSOrderedSet(array: keys)) as? [String] ?? keys
    }

    var isTruthfulReady: Bool {
        plannerStatus == .validated &&
            hasValidatedRoute &&
            !routeMismatch &&
            blockingKeys.isEmpty
    }

    static let empty = MissionStatusSnapshot(
        plannerStatus: .draft,
        operationalStatus: .idle,
        controlAuthority: .none,
        hasValidatedRoute: false,
        executionUsesValidatedRoute: false,
        routeMismatch: false,
        trackingAvailable: false,
        canPrepare: false,
        canStart: false,
        explanations: []
    )
}
