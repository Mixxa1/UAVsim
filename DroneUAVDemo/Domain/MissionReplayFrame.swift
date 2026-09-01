import Foundation

struct MissionAttitudeSnapshot: Codable, Equatable {
    let rollRadians: Double
    let pitchRadians: Double
    let yawRadians: Double
}

/// Compact RF state sampled with replay kinematics. Raw enum values and optional measurements
/// keep old recordings decodable and avoid coupling stored sessions to runtime-only RF structs.
struct MissionReplayRFSnapshot: Codable, Equatable {
    let rolloutModeRawValue: String
    let controlAvailabilityRawValue: String
    let rssiDBm: Double?
    let sinrDB: Double?
    let linkMarginDB: Double?
    let packetErrorRate: Double?
    let commandAgeSeconds: Double
    let deliveryRatio: Double?
    let mcsRawValue: String?
    let queueDepth: Int?
    let throughputBPS: Double?
    let retryAttempts: UInt64?
    let expiredPackets: UInt64?
    let sharedChannelUtilization: Double?
    let backpressuredLinkRawValues: [String]
}

struct MissionReplayFrame: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: TimeInterval

    let position: CodableVector3D
    let velocity: CodableVector3D
    let attitude: MissionAttitudeSnapshot

    let flightModeDescription: String
    let autopilotDescription: String?

    let activeWaypointIndex: Int?
    let batteryPercent: Double?
    let payloadStatusDescription: String?
    let warningCount: Int

    // MARK: High-speed flight state
    //
    // Optional, and that is the point rather than an omission: replays recorded before
    // these existed decode with `nil` here instead of failing outright, so every session
    // already on disk stays playable. A viewer that finds `nil` says the recording
    // predates the measurement — which is true — rather than showing a Mach number of
    // zero, which would be a lie about a flight that happened.
    let machNumber: Double?
    let dynamicPressurePa: Double?
    let loadFactor: Double?
    let skinTemperatureK: Double?
    let envelopeLimitKey: String?
    let envelopeWorstFraction: Double?
    let rfSnapshot: MissionReplayRFSnapshot?

    init(
        id: UUID,
        timestamp: TimeInterval,
        position: CodableVector3D,
        velocity: CodableVector3D,
        attitude: MissionAttitudeSnapshot,
        flightModeDescription: String,
        autopilotDescription: String?,
        activeWaypointIndex: Int?,
        batteryPercent: Double?,
        payloadStatusDescription: String?,
        warningCount: Int,
        machNumber: Double? = nil,
        dynamicPressurePa: Double? = nil,
        loadFactor: Double? = nil,
        skinTemperatureK: Double? = nil,
        envelopeLimitKey: String? = nil,
        envelopeWorstFraction: Double? = nil,
        rfSnapshot: MissionReplayRFSnapshot? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.position = position
        self.velocity = velocity
        self.attitude = attitude
        self.flightModeDescription = flightModeDescription
        self.autopilotDescription = autopilotDescription
        self.activeWaypointIndex = activeWaypointIndex
        self.batteryPercent = batteryPercent
        self.payloadStatusDescription = payloadStatusDescription
        self.warningCount = warningCount
        self.machNumber = machNumber
        self.dynamicPressurePa = dynamicPressurePa
        self.loadFactor = loadFactor
        self.skinTemperatureK = skinTemperatureK
        self.envelopeLimitKey = envelopeLimitKey
        self.envelopeWorstFraction = envelopeWorstFraction
        self.rfSnapshot = rfSnapshot
    }
}
