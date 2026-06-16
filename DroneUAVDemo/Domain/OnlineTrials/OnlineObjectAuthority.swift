import Foundation

// P2P v1.1: Distributed Object Authority Layer.
// Each participant is the authority for their own vehicle and its attached objects.
// The host manages session/world authority and arbitrates shared events.

enum OnlineReplicatedObjectKind: String, Codable, Equatable, CaseIterable {
    case vehicle
    case payload
    case sensor
    case missionMarker
    case environmentObject
    case unknown
}

enum OnlineAuthorityScope: String, Codable, Equatable, CaseIterable {
    case sessionHost
    case participantOwned
    case vehicleAttached
    case sharedWorld
    case spectatorNone
}

enum OnlineAuthorityState: String, Codable, Equatable, CaseIterable {
    case localAuthority
    case remoteReplica
    case hostManaged
    case unowned
}

struct OnlineObjectAuthorityRecord: Identifiable, Codable, Equatable {
    var id: UUID
    var objectID: UUID
    var objectKind: OnlineReplicatedObjectKind
    var ownerParticipantID: UUID?
    var ownerVehicleID: UUID?
    var authorityScope: OnlineAuthorityScope
    var authorityState: OnlineAuthorityState
    var displayName: String
    var lastUpdatedAt: TimeInterval

    init(
        id: UUID = UUID(),
        objectID: UUID,
        objectKind: OnlineReplicatedObjectKind,
        ownerParticipantID: UUID?,
        ownerVehicleID: UUID?,
        authorityScope: OnlineAuthorityScope,
        authorityState: OnlineAuthorityState,
        displayName: String,
        lastUpdatedAt: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.objectID = objectID
        self.objectKind = objectKind
        self.ownerParticipantID = ownerParticipantID
        self.ownerVehicleID = ownerVehicleID
        self.authorityScope = authorityScope
        self.authorityState = authorityState
        self.displayName = displayName
        self.lastUpdatedAt = lastUpdatedAt
    }

    var hasLocalSimulationAuthority: Bool {
        authorityState == .localAuthority || authorityState == .hostManaged
    }

    var isRemoteReplica: Bool {
        authorityState == .remoteReplica
    }
}

// MARK: – Registry

struct OnlineObjectAuthorityRegistry: Codable, Equatable {
    var localParticipantID: UUID
    var localVehicleID: UUID?
    var recordsByObjectID: [UUID: OnlineObjectAuthorityRecord]

    init(
        localParticipantID: UUID,
        localVehicleID: UUID?,
        recordsByObjectID: [UUID: OnlineObjectAuthorityRecord] = [:]
    ) {
        self.localParticipantID = localParticipantID
        self.localVehicleID = localVehicleID
        self.recordsByObjectID = recordsByObjectID
    }

    var records: [OnlineObjectAuthorityRecord] {
        recordsByObjectID.values.sorted { $0.displayName < $1.displayName }
    }

    func record(for objectID: UUID) -> OnlineObjectAuthorityRecord? {
        recordsByObjectID[objectID]
    }

    mutating func upsert(_ record: OnlineObjectAuthorityRecord) {
        recordsByObjectID[record.objectID] = record
    }

    mutating func remove(objectID: UUID) {
        recordsByObjectID.removeValue(forKey: objectID)
    }

    func hasLocalAuthority(objectID: UUID) -> Bool {
        recordsByObjectID[objectID]?.hasLocalSimulationAuthority == true
    }

    // MARK: – Payload helpers (Task 9 v1.1 — prepared, not wired to physics yet)

    mutating func attachPayload(
        payloadID: UUID,
        displayName: String,
        ownerParticipantID: UUID,
        ownerVehicleID: UUID,
        isLocalAuthority: Bool
    ) {
        let record = OnlineObjectAuthorityRecord(
            objectID: payloadID,
            objectKind: .payload,
            ownerParticipantID: ownerParticipantID,
            ownerVehicleID: ownerVehicleID,
            authorityScope: .vehicleAttached,
            authorityState: isLocalAuthority ? .localAuthority : .remoteReplica,
            displayName: displayName
        )
        upsert(record)
    }

    mutating func releaseToSharedWorld(
        objectID: UUID,
        hostParticipantID: UUID?,
        isHostLocal: Bool
    ) {
        guard var record = recordsByObjectID[objectID] else { return }
        record.authorityScope = .sharedWorld
        record.ownerParticipantID = hostParticipantID
        record.ownerVehicleID = nil
        record.authorityState = isHostLocal ? .hostManaged : .remoteReplica
        record.lastUpdatedAt = Date().timeIntervalSince1970
        recordsByObjectID[objectID] = record
    }
}
