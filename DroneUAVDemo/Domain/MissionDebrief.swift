import Foundation

struct MissionDebriefSummary: Codable, Equatable {
    var outcome: MissionOutcome
    var missionTypeKey: String
    var finalReasonKey: String
    var verdictKey: String
}

struct MissionPerformanceSnapshot: Codable, Equatable {
    var durationSec: TimeInterval
    var routeLengthMeters: Float
    var flownDistanceEstimateMeters: Float
    var averageSpeedMps: Float
    var maxAltitudeMeters: Float
    var averageAltitudeMeters: Float
}

struct MissionExecutionSummary: Codable, Equatable {
    var reachedWaypointCount: Int
    var totalWaypointCount: Int
    var finalTruthStatusRaw: String
    var finalExecutionStatusRaw: String
    var finalFailsafeModeRaw: String?
}

struct MissionEnergySummary: Codable, Equatable {
    var startBatteryPercent: Float?
    var endBatteryPercent: Float
    var consumedBatteryPercent: Float?
    var batteryUnsafeTriggered: Bool
}

struct MissionPayloadSummary: Codable, Equatable {
    var triggeredActionCount: Int
    var completedActionCount: Int
    var finalPayloadStateRaw: String
}

struct MissionWarningSnapshot: Codable, Equatable {
    var warningCount: Int
    var criticalCount: Int
    var latestWarningKey: String?
    var latestCriticalKey: String?
}

struct MissionDebrief: Codable, Equatable {
    var generatedAt: Date
    var timelineID: UUID
    var summary: MissionDebriefSummary
    var performance: MissionPerformanceSnapshot
    var execution: MissionExecutionSummary
    var energy: MissionEnergySummary
    var payload: MissionPayloadSummary
    var warnings: MissionWarningSnapshot
    var keyEvents: [MissionEvent]
}
