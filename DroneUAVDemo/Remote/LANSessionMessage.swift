import Foundation

enum LANSessionMessageType: String, Codable {
    case hello
    case welcome
    case roleSelected
    case participantList
    case sessionConfig
    case heartbeat
    case trialLaunch
    case trialStarted
    case trialEnded
    case vehicleSnapshot
    case vehicleSnapshotBatch
    case disconnect
}

struct LANSessionMessage: Codable, Equatable {
    var id: UUID
    var type: LANSessionMessageType
    var senderID: UUID
    var timestamp: TimeInterval
    var participant: LANParticipant?
    var participants: [LANParticipant]?
    var config: LANSessionConfig?
    var trialLaunch: LANTrialLaunchDescriptor?
    var vehicleSnapshot: OnlineVehicleStateSnapshot?
    var vehicleSnapshotBatch: OnlineVehicleStateSnapshotBatch?
    var text: String?

    init(
        id: UUID = UUID(),
        type: LANSessionMessageType,
        senderID: UUID,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        participant: LANParticipant? = nil,
        participants: [LANParticipant]? = nil,
        config: LANSessionConfig? = nil,
        trialLaunch: LANTrialLaunchDescriptor? = nil,
        vehicleSnapshot: OnlineVehicleStateSnapshot? = nil,
        vehicleSnapshotBatch: OnlineVehicleStateSnapshotBatch? = nil,
        text: String? = nil
    ) {
        self.id = id
        self.type = type
        self.senderID = senderID
        self.timestamp = timestamp
        self.participant = participant
        self.participants = participants
        self.config = config
        self.trialLaunch = trialLaunch
        self.vehicleSnapshot = vehicleSnapshot
        self.vehicleSnapshotBatch = vehicleSnapshotBatch
        self.text = text
    }
}
