import Foundation

enum OnlineCollisionObjectKind: String, Codable, Equatable, CaseIterable {
    case vehicle
    case payload
    case environment
    case unknown
}

enum OnlineCollisionSeverity: String, Codable, Equatable, CaseIterable {
    case contact
    case minor
    case major
    case critical
}

enum OnlineCollisionResult: String, Codable, Equatable, CaseIterable {
    case ignored
    case damaged
    case disabled
    case crashed
}

struct OnlineCollisionParticipant: Identifiable, Codable, Equatable {
    var id: UUID
    var objectID: UUID
    var objectKind: OnlineCollisionObjectKind
    var ownerParticipantID: UUID?
    var ownerVehicleID: UUID?
    var displayName: String

    init(
        id: UUID = UUID(),
        objectID: UUID,
        objectKind: OnlineCollisionObjectKind,
        ownerParticipantID: UUID?,
        ownerVehicleID: UUID?,
        displayName: String
    ) {
        self.id = id
        self.objectID = objectID
        self.objectKind = objectKind
        self.ownerParticipantID = ownerParticipantID
        self.ownerVehicleID = ownerVehicleID
        self.displayName = displayName
    }
}

struct OnlineCollisionEvent: Identifiable, Codable, Equatable {
    var id: UUID
    var sessionID: UUID
    var sequenceNumber: UInt64
    var timestamp: TimeInterval
    var positionX: Double
    var positionY: Double
    var positionZ: Double
    var relativeSpeedMetersPerSecond: Double
    var severity: OnlineCollisionSeverity
    var result: OnlineCollisionResult
    var participants: [OnlineCollisionParticipant]
    var confirmedByHostParticipantID: UUID?

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        sequenceNumber: UInt64,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        positionX: Double,
        positionY: Double,
        positionZ: Double,
        relativeSpeedMetersPerSecond: Double,
        severity: OnlineCollisionSeverity,
        result: OnlineCollisionResult,
        participants: [OnlineCollisionParticipant],
        confirmedByHostParticipantID: UUID?
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.positionX = positionX
        self.positionY = positionY
        self.positionZ = positionZ
        self.relativeSpeedMetersPerSecond = relativeSpeedMetersPerSecond
        self.severity = severity
        self.result = result
        self.participants = participants
        self.confirmedByHostParticipantID = confirmedByHostParticipantID
    }

    var affectedVehicleIDs: [UUID] {
        participants.compactMap { p in
            p.objectKind == .vehicle ? p.objectID : p.ownerVehicleID
        }
    }
}
