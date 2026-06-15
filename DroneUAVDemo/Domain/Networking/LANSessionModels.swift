import Foundation

// P2P v1.0: authority model enum. Only distributedVehicleAuthority is implemented.
enum OnlineAuthorityMode: String, Codable, CaseIterable, Identifiable, Equatable {
    case distributedVehicleAuthority
    case listenServer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .distributedVehicleAuthority: return "Distributed Vehicle Authority"
        case .listenServer:                return "Listen Server"
        }
    }

    var shortDescription: String {
        switch self {
        case .distributedVehicleAuthority:
            return "Каждый пилот считает свой БЛА локально. Host управляет сессией и relay."
        case .listenServer:
            return "Host считает все аппараты. Режим зарезервирован для будущих строгих испытаний."
        }
    }

    var isImplemented: Bool { self == .distributedVehicleAuthority }
}

enum LANSessionMode: String, Codable, Equatable {
    case host
    case client
}

enum LANParticipantRole: String, Codable, CaseIterable, Identifiable {
    case pilot
    case spectator

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pilot:
            return "Полет"
        case .spectator:
            return "Наблюдатель"
        }
    }
}

enum LANConnectionState: String, Codable, Equatable {
    case idle
    case hosting
    case joining
    case connected
    case disconnected
    case failed
}

enum LANTrialPhase: String, Codable, Equatable {
    case lobby
    case launching
    case running
    case ended
}

struct LANParticipant: Identifiable, Codable, Equatable {
    var id: UUID
    var displayName: String
    var role: LANParticipantRole
    var isHost: Bool
    var assignedVehicleID: UUID?
    var lastSeenTime: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        role: LANParticipantRole,
        isHost: Bool = false,
        assignedVehicleID: UUID? = nil,
        lastSeenTime: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.isHost = isHost
        self.assignedVehicleID = assignedVehicleID
        self.lastSeenTime = lastSeenTime
    }
}

struct LANSessionConfig: Codable, Equatable {
    var sessionName: String
    var hostParticipantID: UUID
    var mapID: String
    var mapScale: Int
    var weatherPresetID: String
    var timeOfDayID: String
    var maxPilots: Int
    var allowSpectators: Bool
    var authorityMode: OnlineAuthorityMode

    init(
        sessionName: String,
        hostParticipantID: UUID,
        mapID: String,
        mapScale: Int,
        weatherPresetID: String,
        timeOfDayID: String,
        maxPilots: Int,
        allowSpectators: Bool,
        authorityMode: OnlineAuthorityMode = .distributedVehicleAuthority
    ) {
        self.sessionName = sessionName
        self.hostParticipantID = hostParticipantID
        self.mapID = mapID
        self.mapScale = mapScale
        self.weatherPresetID = weatherPresetID
        self.timeOfDayID = timeOfDayID
        self.maxPilots = maxPilots
        self.allowSpectators = allowSpectators
        self.authorityMode = authorityMode
    }

    // Backward-compatible decoding: old sessions without authorityMode default to DVA.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionName      = try c.decode(String.self, forKey: .sessionName)
        hostParticipantID = try c.decode(UUID.self,   forKey: .hostParticipantID)
        mapID            = try c.decode(String.self, forKey: .mapID)
        mapScale         = try c.decode(Int.self,    forKey: .mapScale)
        weatherPresetID  = try c.decode(String.self, forKey: .weatherPresetID)
        timeOfDayID      = try c.decode(String.self, forKey: .timeOfDayID)
        maxPilots        = try c.decode(Int.self,    forKey: .maxPilots)
        allowSpectators  = try c.decode(Bool.self,   forKey: .allowSpectators)
        authorityMode    = try c.decodeIfPresent(OnlineAuthorityMode.self, forKey: .authorityMode) ?? .distributedVehicleAuthority
    }

    static func defaultConfig(hostParticipantID: UUID) -> LANSessionConfig {
        LANSessionConfig(
            sessionName: "LAN испытание",
            hostParticipantID: hostParticipantID,
            mapID: "default",
            mapScale: 8,
            weatherPresetID: "clear",
            timeOfDayID: "day",
            maxPilots: 4,
            allowSpectators: true
        )
    }
}

struct LANSessionState: Codable, Equatable {
    var mode: LANSessionMode?
    var connectionState: LANConnectionState
    var trialPhase: LANTrialPhase
    var localParticipant: LANParticipant?
    var participants: [LANParticipant]
    var config: LANSessionConfig?
    var joinAddress: String
    var port: UInt16
    var lastErrorMessage: String?

    static let idle = LANSessionState(
        mode: nil,
        connectionState: .idle,
        trialPhase: .lobby,
        localParticipant: nil,
        participants: [],
        config: nil,
        joinAddress: "",
        port: 7777,
        lastErrorMessage: nil
    )
}
