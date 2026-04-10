import Foundation

struct MissionTimeline: Identifiable, Codable, Equatable {
    var id: UUID
    var projectID: String
    var projectName: String
    var missionPlanID: UUID?
    var startedAt: Date
    var endedAt: Date?
    var outcome: MissionOutcome?
    var events: [MissionEvent]
    var lastUpdatedAt: Date

    var isActive: Bool {
        endedAt == nil
    }

    var latestCriticalEvent: MissionEvent? {
        events.last(where: { $0.severity == .critical })
    }

    var latestWarningEvent: MissionEvent? {
        events.last(where: { $0.severity == .warning })
    }

    var warningCount: Int {
        events.filter { $0.severity == .warning }.count
    }

    var criticalCount: Int {
        events.filter { $0.severity == .critical }.count
    }
}
