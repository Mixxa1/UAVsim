import Foundation

struct OnlineVehiclePose: Codable, Equatable {
    var positionX: Double
    var positionY: Double
    var positionZ: Double
    var yaw: Double
    var pitch: Double
    var roll: Double

    static let zero = OnlineVehiclePose(
        positionX: 0,
        positionY: 0,
        positionZ: 0,
        yaw: 0,
        pitch: 0,
        roll: 0
    )
}

struct OnlineVehicleKinematics: Codable, Equatable {
    var velocityX: Double
    var velocityY: Double
    var velocityZ: Double
    var speedMetersPerSecond: Double
    var altitudeMeters: Double

    static let zero = OnlineVehicleKinematics(
        velocityX: 0,
        velocityY: 0,
        velocityZ: 0,
        speedMetersPerSecond: 0,
        altitudeMeters: 0
    )
}

/// Compact, transport-safe projection of one component in the authoritative
/// Simulation component graph. Strings are used for attachment/failure enums
/// so peers running a newer build can still forward values unknown locally.
struct OnlineVehicleComponentDamageSnapshot: Codable, Equatable {
    var componentID: String
    var integrity: Float
    var residualStrength: Float
    var attachmentState: String
    var failureMode: String?

    init(
        componentID: String,
        integrity: Float,
        residualStrength: Float,
        attachmentState: String,
        failureMode: String? = nil
    ) {
        self.componentID = componentID
        self.integrity = integrity
        self.residualStrength = residualStrength
        self.attachmentState = attachmentState
        self.failureMode = failureMode
    }
}

/// Ordered LAN representation of a canonical damage event. The component
/// graph above remains the source of truth; this small event tail lets remote
/// peers reproduce effects and telemetry without inferring them from pose.
struct OnlineVehicleDamageEventSnapshot: Codable, Equatable {
    var sequenceNumber: UInt64
    var timestamp: TimeInterval
    var type: String
    var componentID: String?
    var connectionID: String?
    var colliderID: String?
    var worldPointX: Float?
    var worldPointY: Float?
    var worldPointZ: Float?
    var impulseNs: Float?
    var energyJ: Float?
    var integrity: Float?
    var residualStrength: Float?
    var failureMode: String?
    var reason: String
    var detachedComponentIDs: [String]
    var massPropertiesRevision: UInt64?

    init(
        sequenceNumber: UInt64,
        timestamp: TimeInterval,
        type: String,
        componentID: String? = nil,
        connectionID: String? = nil,
        colliderID: String? = nil,
        worldPointX: Float? = nil,
        worldPointY: Float? = nil,
        worldPointZ: Float? = nil,
        impulseNs: Float? = nil,
        energyJ: Float? = nil,
        integrity: Float? = nil,
        residualStrength: Float? = nil,
        failureMode: String? = nil,
        reason: String = "",
        detachedComponentIDs: [String] = [],
        massPropertiesRevision: UInt64? = nil
    ) {
        self.sequenceNumber = sequenceNumber
        self.timestamp = timestamp
        self.type = type
        self.componentID = componentID
        self.connectionID = connectionID
        self.colliderID = colliderID
        self.worldPointX = worldPointX
        self.worldPointY = worldPointY
        self.worldPointZ = worldPointZ
        self.impulseNs = impulseNs
        self.energyJ = energyJ
        self.integrity = integrity
        self.residualStrength = residualStrength
        self.failureMode = failureMode
        self.reason = reason
        self.detachedComponentIDs = detachedComponentIDs
        self.massPropertiesRevision = massPropertiesRevision
    }
}

struct OnlineVehicleStateSnapshot: Identifiable, Codable, Equatable {
    var id: UUID
    var sequenceNumber: UInt64
    var vehicleID: UUID
    var participantID: UUID
    var participantName: String
    var timestamp: TimeInterval
    var pose: OnlineVehiclePose
    var kinematics: OnlineVehicleKinematics
    var isArmed: Bool
    var flightModeLabel: String
    var componentDamage: [OnlineVehicleComponentDamageSnapshot]
    var massPropertiesRevision: UInt64
    var damageEventSequence: UInt64
    var damageEvents: [OnlineVehicleDamageEventSnapshot]

    init(
        id: UUID = UUID(),
        sequenceNumber: UInt64,
        vehicleID: UUID,
        participantID: UUID,
        participantName: String,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        pose: OnlineVehiclePose,
        kinematics: OnlineVehicleKinematics,
        isArmed: Bool,
        flightModeLabel: String,
        componentDamage: [OnlineVehicleComponentDamageSnapshot] = [],
        massPropertiesRevision: UInt64 = 0,
        damageEventSequence: UInt64 = 0,
        damageEvents: [OnlineVehicleDamageEventSnapshot] = []
    ) {
        self.id = id
        self.sequenceNumber = sequenceNumber
        self.vehicleID = vehicleID
        self.participantID = participantID
        self.participantName = participantName
        self.timestamp = timestamp
        self.pose = pose
        self.kinematics = kinematics
        self.isArmed = isArmed
        self.flightModeLabel = flightModeLabel
        self.componentDamage = componentDamage
        self.massPropertiesRevision = massPropertiesRevision
        self.damageEventSequence = damageEventSequence
        self.damageEvents = damageEvents
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sequenceNumber
        case vehicleID
        case participantID
        case participantName
        case timestamp
        case pose
        case kinematics
        case isArmed
        case flightModeLabel
        case componentDamage
        case massPropertiesRevision
        case damageEventSequence
        case damageEvents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sequenceNumber = try container.decode(UInt64.self, forKey: .sequenceNumber)
        vehicleID = try container.decode(UUID.self, forKey: .vehicleID)
        participantID = try container.decode(UUID.self, forKey: .participantID)
        participantName = try container.decode(String.self, forKey: .participantName)
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        pose = try container.decode(OnlineVehiclePose.self, forKey: .pose)
        kinematics = try container.decode(OnlineVehicleKinematics.self, forKey: .kinematics)
        isArmed = try container.decode(Bool.self, forKey: .isArmed)
        flightModeLabel = try container.decode(String.self, forKey: .flightModeLabel)

        // P2P snapshots produced before the damage model did not contain any
        // of these keys. Missing values mean an intact graph at revision zero.
        componentDamage = try container.decodeIfPresent(
            [OnlineVehicleComponentDamageSnapshot].self,
            forKey: .componentDamage
        ) ?? []
        massPropertiesRevision = try container.decodeIfPresent(
            UInt64.self,
            forKey: .massPropertiesRevision
        ) ?? 0
        damageEventSequence = try container.decodeIfPresent(
            UInt64.self,
            forKey: .damageEventSequence
        ) ?? 0
        damageEvents = try container.decodeIfPresent(
            [OnlineVehicleDamageEventSnapshot].self,
            forKey: .damageEvents
        ) ?? []
    }
}

struct OnlineVehicleStateSnapshotBatch: Codable, Equatable {
    var sessionID: UUID
    var senderParticipantID: UUID
    var snapshots: [OnlineVehicleStateSnapshot]
    var timestamp: TimeInterval

    init(
        sessionID: UUID,
        senderParticipantID: UUID,
        snapshots: [OnlineVehicleStateSnapshot],
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.sessionID = sessionID
        self.senderParticipantID = senderParticipantID
        self.snapshots = snapshots
        self.timestamp = timestamp
    }
}
