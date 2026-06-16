import Foundation

// P2P v1.2: Shared Event Replication Core — unified shared event model.
// Replaces the former OnlineCollisionEvent (host-side detection).
// Owner-reported events flow: local detect → submitSharedEvent → host relay/order/dedup → all apply.

enum OnlineSharedEventKind: String, Codable, Equatable, CaseIterable {
    case vehicleCollision
    case payloadReleased
    case missionZoneEntered
    case trialEnded
    case unknown
}

enum OnlineSharedEventResult: String, Codable, Equatable, CaseIterable {
    case none
    case ignored
    case damaged
    case disabled
    case crashed
    case completed
    case failed
}

struct OnlineSharedEventParticipant: Identifiable, Codable, Equatable {
    var id: UUID
    var objectID: UUID
    var objectKind: OnlineReplicatedObjectKind
    var ownerParticipantID: UUID?
    var ownerVehicleID: UUID?
    var displayName: String

    init(
        id: UUID = UUID(),
        objectID: UUID,
        objectKind: OnlineReplicatedObjectKind,
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

struct OnlineSharedEvent: Identifiable, Codable, Equatable {
    var id: UUID
    var sessionID: UUID
    var kind: OnlineSharedEventKind
    var sequenceNumber: UInt64
    var emittedAt: TimeInterval
    var orderedAt: TimeInterval?
    var reporterParticipantID: UUID
    var reporterObjectID: UUID?
    var pairKey: String?
    var positionX: Double
    var positionY: Double
    var positionZ: Double
    var result: OnlineSharedEventResult
    var participants: [OnlineSharedEventParticipant]
    var note: String?

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        kind: OnlineSharedEventKind,
        sequenceNumber: UInt64 = 0,
        emittedAt: TimeInterval = Date().timeIntervalSince1970,
        orderedAt: TimeInterval? = nil,
        reporterParticipantID: UUID,
        reporterObjectID: UUID?,
        pairKey: String?,
        positionX: Double,
        positionY: Double,
        positionZ: Double,
        result: OnlineSharedEventResult,
        participants: [OnlineSharedEventParticipant],
        note: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.sequenceNumber = sequenceNumber
        self.emittedAt = emittedAt
        self.orderedAt = orderedAt
        self.reporterParticipantID = reporterParticipantID
        self.reporterObjectID = reporterObjectID
        self.pairKey = pairKey
        self.positionX = positionX
        self.positionY = positionY
        self.positionZ = positionZ
        self.result = result
        self.participants = participants
        self.note = note
    }

    var affectedVehicleIDs: [UUID] {
        participants.compactMap { p in
            p.objectKind == .vehicle ? p.objectID : p.ownerVehicleID
        }
    }
}
