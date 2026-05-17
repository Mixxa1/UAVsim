import Foundation

enum MissionReplayEventType: String, Codable, Equatable {
    case sessionStarted
    case sessionStopped
    case recordingLimitReached

    case armed
    case disarmed

    case autopilotEnabled
    case autopilotDisabled

    case warning

    case takeoff
    case landing
    case waypointReached
    case missionCompleted
    case missionAborted
    case payloadAttached
    case payloadReleased
    case payloadImpact
}

struct MissionReplayEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: TimeInterval
    let type: MissionReplayEventType
    let message: String
    let position: CodableVector3D?
}
