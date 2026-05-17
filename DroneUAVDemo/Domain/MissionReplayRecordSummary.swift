import Foundation

struct MissionReplayRecordSummary: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let startedAt: Date
    let endedAt: Date?
    let durationSeconds: TimeInterval

    let frameCount: Int
    let eventCount: Int
    let warningCount: Int

    let maxSpeedMetersPerSecond: Double?
    let maxAltitudeMeters: Double?

    let title: String

    static func makeTitle(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "Replay \(formatter.string(from: date))"
    }
}
