import Foundation

enum LANSessionMessageType: String, Codable {
    case hello
    case welcome
    case roleSelected
    case participantList
    case sessionConfig
    case heartbeat
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
    var text: String?

    init(
        id: UUID = UUID(),
        type: LANSessionMessageType,
        senderID: UUID,
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        participant: LANParticipant? = nil,
        participants: [LANParticipant]? = nil,
        config: LANSessionConfig? = nil,
        text: String? = nil
    ) {
        self.id = id
        self.type = type
        self.senderID = senderID
        self.timestamp = timestamp
        self.participant = participant
        self.participants = participants
        self.config = config
        self.text = text
    }
}
