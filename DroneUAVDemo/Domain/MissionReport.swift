import Foundation

struct MissionReportRFSummary: Codable, Equatable {
    let sampleCount: Int
    let minimumRSSIDBm: Double?
    let minimumSINRDB: Double?
    let minimumLinkMarginDB: Double?
    let averagePacketErrorRate: Double?
    let averageDeliveryRatio: Double?
    let maximumCommandAgeSeconds: Double
    let maximumQueueDepth: Int
    let retryAttempts: UInt64
    let expiredPackets: UInt64
    let maximumSharedChannelUtilization: Double?
    let backpressureSampleCount: Int
    let lostSampleCount: Int
    let baselineBucketCount: Int?
    let acceptanceScenarioCount: Int?
    let acceptancePassedCount: Int?
    let qosPolicyCount: Int?
    let performanceGateCount: Int?
    let performanceGatePassedCount: Int?
}

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
    let rf: MissionReportRFSummary?
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
