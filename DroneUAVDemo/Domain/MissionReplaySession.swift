import Foundation

struct MissionReplayRFArtifacts: Codable, Equatable {
    let schemaVersion: Int
    let calibrationReport: RFCalibrationReport?
    let acceptanceResults: [RFAcceptanceResult]
    let qosConfiguration: RFQoSConfiguration?
    /// Optional so Stage 7 and earlier replay artifacts remain decodable.
    var performanceResults: [RFPerformanceBudgetResult]? = nil
}

struct MissionReplaySession: Identifiable, Codable, Equatable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var frames: [MissionReplayFrame]
    var events: [MissionReplayEvent]
    var context: MissionReplayContextSnapshot?
    /// Optional so recordings produced before RF artifact capture remain readable.
    var rfArtifacts: MissionReplayRFArtifacts? = nil

    var duration: TimeInterval {
        if let endedAt { return endedAt.timeIntervalSince(startedAt) }
        return Date().timeIntervalSince(startedAt)
    }

    var frameCount: Int { frames.count }
    var eventCount: Int { events.count }
}
