import Foundation

struct MissionAttitudeSnapshot: Codable, Equatable {
    let rollRadians: Double
    let pitchRadians: Double
    let yawRadians: Double
}

struct MissionReplayFrame: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: TimeInterval

    let position: CodableVector3D
    let velocity: CodableVector3D
    let attitude: MissionAttitudeSnapshot

    let flightModeDescription: String
    let autopilotDescription: String?

    let activeWaypointIndex: Int?
    let batteryPercent: Double?
    let payloadStatusDescription: String?
    let warningCount: Int
}
