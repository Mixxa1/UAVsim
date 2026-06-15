import Foundation

enum OnlineTrialEntryMode: String, CaseIterable, Identifiable {
    case lan
    case server

    var id: String { rawValue }
}

enum OnlineTrialRole: String, CaseIterable, Identifiable {
    case pilot
    case spectator

    var id: String { rawValue }
}

enum SimulationRunMode: String {
    case singlePlayer
    case lanHostPilot
    case lanClientPilot
    case lanSpectator

    var isOnlineTrial: Bool {
        self != .singlePlayer
    }

    var isSpectator: Bool {
        self == .lanSpectator
    }

    var hasLocalUAVAuthority: Bool {
        switch self {
        case .singlePlayer, .lanHostPilot, .lanClientPilot:
            return true
        case .lanSpectator:
            return false
        }
    }

    static func lanMode(role: OnlineTrialRole, isHost: Bool) -> SimulationRunMode {
        switch role {
        case .pilot:
            return isHost ? .lanHostPilot : .lanClientPilot
        case .spectator:
            return .lanSpectator
        }
    }
}

struct OnlineTrialSessionConfig: Identifiable {
    let sessionID: UUID
    let hostDisplayName: String
    let mapPreset: TerrainPreset
    let mapScale: MapScale
    let weather: WeatherModel
    let createdAt: Date

    var id: UUID { sessionID }

    init(
        sessionID: UUID = UUID(),
        hostDisplayName: String,
        mapPreset: TerrainPreset = TerrainConfiguration.default.preset,
        mapScale: MapScale = TerrainConfiguration.default.mapScale,
        weather: WeatherModel = .normal,
        createdAt: Date = Date()
    ) {
        self.sessionID = sessionID
        self.hostDisplayName = hostDisplayName
        self.mapPreset = mapPreset
        self.mapScale = mapScale
        self.weather = weather
        self.createdAt = createdAt
    }
}

struct LocalOnlineParticipant: Identifiable, Hashable {
    let id: UUID
    let displayName: String
    let role: OnlineTrialRole
    let controlledUAVID: UUID?
    let isHost: Bool

    init(
        id: UUID = UUID(),
        displayName: String,
        role: OnlineTrialRole,
        controlledUAVID: UUID? = nil,
        isHost: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.controlledUAVID = controlledUAVID
        self.isHost = isHost
    }
}

struct LANVehicleAssignment: Identifiable, Codable, Equatable {
    var id: UUID
    var participantID: UUID
    var participantName: String
    var role: LANParticipantRole
    var vehicleID: UUID?
    var vehicleProfileID: String?
    var spawnIndex: Int?

    init(
        id: UUID = UUID(),
        participantID: UUID,
        participantName: String,
        role: LANParticipantRole,
        vehicleID: UUID?,
        vehicleProfileID: String?,
        spawnIndex: Int?
    ) {
        self.id = id
        self.participantID = participantID
        self.participantName = participantName
        self.role = role
        self.vehicleID = vehicleID
        self.vehicleProfileID = vehicleProfileID
        self.spawnIndex = spawnIndex
    }
}

struct LANTrialLaunchDescriptor: Codable, Equatable {
    var id: UUID
    var hostParticipantID: UUID
    var sessionConfig: LANSessionConfig
    var assignments: [LANVehicleAssignment]
    var launchedAt: Date

    init(
        id: UUID = UUID(),
        hostParticipantID: UUID,
        sessionConfig: LANSessionConfig,
        assignments: [LANVehicleAssignment],
        launchedAt: Date = Date()
    ) {
        self.id = id
        self.hostParticipantID = hostParticipantID
        self.sessionConfig = sessionConfig
        self.assignments = assignments
        self.launchedAt = launchedAt
    }

    func assignment(for participantID: UUID) -> LANVehicleAssignment? {
        assignments.first { $0.participantID == participantID }
    }
}
