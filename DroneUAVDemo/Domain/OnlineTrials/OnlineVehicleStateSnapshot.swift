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
        flightModeLabel: String
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
