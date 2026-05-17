import Foundation

struct MissionReportSummary: Codable, Equatable {
    let durationSeconds: TimeInterval
    let frameCount: Int
    let eventCount: Int
    let warningCount: Int

    let maxSpeedMetersPerSecond: Double
    let averageSpeedMetersPerSecond: Double
    let maxAltitudeMeters: Double

    let startBatteryPercent: Double?
    let minBatteryPercent: Double?
    let batteryUsedPercent: Double?

    let autopilotEventCount: Int
    let missionRelatedEventCount: Int
}

struct MissionReport: Identifiable, Codable, Equatable {
    let id: UUID
    let generatedAt: Date
    let sessionID: UUID

    let summary: MissionReportSummary
    let events: [MissionReplayEvent]
    let warnings: [MissionReplayEvent]
    let textSummary: String
}
