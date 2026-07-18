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

    // Physical damage lifecycle. These are deliberately separate from
    // `warning`/`disarmed`: replay must preserve what happened to the
    // airframe after control authority or propulsion was lost.
    case impact
    case componentDamaged
    case componentDetached
    case subsystemFailed
    case massPropertiesChanged
    case controlAuthorityReduced
    case vehicleSettled
}

struct MissionReplayEvent: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: TimeInterval
    let type: MissionReplayEventType
    let message: String
    let position: CodableVector3D?
    /// Structured physical-damage data. Optional keeps replays recorded by
    /// older builds decodable while allowing the player/export/LAN layers to
    /// reproduce the actual event instead of parsing a display string.
    let damage: MissionReplayDamagePayload?

    init(
        id: UUID,
        timestamp: TimeInterval,
        type: MissionReplayEventType,
        message: String,
        position: CodableVector3D?,
        damage: MissionReplayDamagePayload? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.message = message
        self.position = position
        self.damage = damage
    }
}

struct MissionReplayDamagePayload: Codable, Equatable {
    let sequenceNumber: UInt64
    let canonicalEventTypeRawValue: String?
    let vehicleID: UUID?
    let componentID: String?
    let connectionID: String?
    let colliderID: String?
    let impulseNs: Float?
    let energyJ: Float?
    let integrityBefore: Float?
    let integrityAfter: Float?
    let residualStrengthBefore: Float?
    let residualStrengthAfter: Float?
    let failureModeRawValue: String?
    let detachedComponentIDs: [String]
    let massPropertiesRevision: UInt64?
    let rotorThrustFactors: [String: Float]?
    let reason: String
}
