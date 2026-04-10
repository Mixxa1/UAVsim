import Foundation

enum MissionEventCategory: String, CaseIterable, Codable, Equatable {
    case planning
    case operatorAction
    case execution
    case safety
    case failsafe
    case payload
    case diagnostics

    var titleKey: String {
        switch self {
        case .planning:
            return "mission.event.category.planning"
        case .operatorAction:
            return "mission.event.category.operator"
        case .execution:
            return "mission.event.category.execution"
        case .safety:
            return "mission.event.category.safety"
        case .failsafe:
            return "mission.event.category.failsafe"
        case .payload:
            return "mission.event.category.payload"
        case .diagnostics:
            return "mission.event.category.diagnostics"
        }
    }
}

enum MissionEventSeverity: String, CaseIterable, Codable, Equatable {
    case info
    case warning
    case critical

    var titleKey: String {
        switch self {
        case .info:
            return "mission.event.severity.info"
        case .warning:
            return "mission.event.severity.warning"
        case .critical:
            return "mission.event.severity.critical"
        }
    }

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

enum MissionEventCode: String, Codable, Equatable {
    case missionDraftPrepared
    case missionValidated
    case missionStartRequested
    case missionStarted
    case controlAuthorityGranted
    case controlAuthorityFlap
    case controlAuthorityLost
    case waypointActivated
    case waypointReached
    case segmentCompleted
    case missionPaused
    case missionResumed
    case missionBlocked
    case missionWarningRaised
    case runtimeUnsafeDetected
    case failsafeTriggered
    case returnHomeTriggered
    case missionAborted
    case missionCompleted
    case debriefGenerated
    case payloadActionTriggered
    case payloadActionCompleted
    case diagnosticsCritical

    var titleKey: String {
        "mission.event.code.\(rawValue)"
    }

    var defaultDetailKey: String {
        "mission.event.detail.\(rawValue)"
    }
}

struct MissionEventContext: Codable, Equatable {
    var projectID: String?
    var projectName: String?
    var missionPlanID: UUID?
    var waypointIndex: Int?
    var waypointLabel: String?
    var truthStatusRaw: String?
    var executionStatusRaw: String?
    var planStatusRaw: String?
    var controlAuthorityRaw: String?
    var failsafeModeRaw: String?
    var distanceToTargetMeters: Float?
    var batteryPercent: Float?
    var payloadStateRaw: String?
    var warningReasonRaw: String?
    var noteKey: String?

    static let empty = MissionEventContext(
        projectID: nil,
        projectName: nil,
        missionPlanID: nil,
        waypointIndex: nil,
        waypointLabel: nil,
        truthStatusRaw: nil,
        executionStatusRaw: nil,
        planStatusRaw: nil,
        controlAuthorityRaw: nil,
        failsafeModeRaw: nil,
        distanceToTargetMeters: nil,
        batteryPercent: nil,
        payloadStateRaw: nil,
        warningReasonRaw: nil,
        noteKey: nil
    )
}

struct MissionEvent: Identifiable, Codable, Equatable {
    var id: UUID
    var missionID: UUID?
    var timestamp: Date
    var category: MissionEventCategory
    var severity: MissionEventSeverity
    var code: MissionEventCode
    var titleKey: String
    var detailKey: String
    var context: MissionEventContext

    init(
        id: UUID = UUID(),
        missionID: UUID?,
        timestamp: Date = Date(),
        category: MissionEventCategory,
        severity: MissionEventSeverity,
        code: MissionEventCode,
        detailKey: String? = nil,
        context: MissionEventContext = .empty
    ) {
        self.id = id
        self.missionID = missionID
        self.timestamp = timestamp
        self.category = category
        self.severity = severity
        self.code = code
        self.titleKey = code.titleKey
        self.detailKey = detailKey ?? code.defaultDetailKey
        self.context = context
    }
}
