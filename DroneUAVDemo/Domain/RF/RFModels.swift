import Foundation

enum RFSystemSchema {
    static let currentVersion = 1
}

enum RFSystemConfigurationOrigin: String, Codable, Hashable, Sendable {
    case authored
    case compatibilityPreset
}

enum RFSystemRolloutMode: String, Codable, CaseIterable, Hashable, Sendable {
    case legacyRange
    case shadowRFCore
    case physicalRFCore
}

struct RFSystemRuntimeOptions: Hashable, Sendable {
    var rolloutMode: RFSystemRolloutMode

    /// Migration is complete: ordinary radio links are authoritative from the physical RF core.
    static let migrationDefault = RFSystemRuntimeOptions(rolloutMode: .physicalRFCore)
}

enum LogicalLinkKind: String, Codable, CaseIterable, Hashable, Sendable {
    case control
    case video
    case telemetry
    case payloadData
}

enum RFVideoTransmissionMode: String, Codable, CaseIterable, Hashable, Sendable {
    case analog
    case digital
}

enum RFQoSSchema {
    static let currentVersion = 1
}

struct RFQoSLinkPolicy: Codable, Hashable, Identifiable, Sendable {
    var kind: LogicalLinkKind
    /// Smaller values are scheduled first.
    var priority: Int
    var minimumReservedBitrateBPS: Double
    var maximumShareFraction: Double
    var packetsPerSecond: Double?
    var packetSizeBytes: Int?
    var queueCapacity: Int?
    var packetTTLSeconds: Double?
    var retryLimit: Int?

    var id: LogicalLinkKind { kind }
}

struct RFQoSConfiguration: Codable, Hashable, Sendable {
    var version: Int
    var dynamicReservationEnabled: Bool
    var reservationBorrowingEnabled: Bool
    var controlBoostCommandAgeSeconds: Double
    var controlBoostMultiplier: Double
    var linkPolicies: [RFQoSLinkPolicy]

    static let migrationDefault = RFQoSConfiguration(
        version: RFQoSSchema.currentVersion,
        dynamicReservationEnabled: true,
        reservationBorrowingEnabled: true,
        controlBoostCommandAgeSeconds: 0.15,
        controlBoostMultiplier: 3,
        linkPolicies: [
            RFQoSLinkPolicy(
                kind: .control,
                priority: 0,
                minimumReservedBitrateBPS: 64_000,
                maximumShareFraction: 1,
                packetsPerSecond: nil,
                packetSizeBytes: nil,
                queueCapacity: nil,
                packetTTLSeconds: nil,
                retryLimit: nil
            ),
            RFQoSLinkPolicy(
                kind: .telemetry,
                priority: 1,
                minimumReservedBitrateBPS: 32_000,
                maximumShareFraction: 1,
                packetsPerSecond: nil,
                packetSizeBytes: nil,
                queueCapacity: nil,
                packetTTLSeconds: nil,
                retryLimit: nil
            ),
            RFQoSLinkPolicy(
                kind: .payloadData,
                priority: 2,
                minimumReservedBitrateBPS: 96_000,
                maximumShareFraction: 1,
                packetsPerSecond: nil,
                packetSizeBytes: nil,
                queueCapacity: nil,
                packetTTLSeconds: nil,
                retryLimit: nil
            ),
            RFQoSLinkPolicy(
                kind: .video,
                priority: 3,
                minimumReservedBitrateBPS: 0,
                maximumShareFraction: 1,
                packetsPerSecond: nil,
                packetSizeBytes: nil,
                queueCapacity: nil,
                packetTTLSeconds: nil,
                retryLimit: nil
            ),
        ]
    )

    func policy(for kind: LogicalLinkKind) -> RFQoSLinkPolicy {
        linkPolicies.first(where: { $0.kind == kind })
            ?? Self.migrationDefault.linkPolicies.first(where: { $0.kind == kind })!
    }
}

enum RFDeviceKind: String, Codable, Hashable, Sendable {
    case transmitter
    case receiver
    case transceiver
}

enum RFEndpointKind: String, Codable, Hashable, Sendable {
    case airborne
    case ground
    case relay
}

enum RFPolarization: String, Codable, Hashable, Sendable {
    case linearVertical
    case linearHorizontal
    case lhcp
    case rhcp
    case custom
}

enum RFAntennaPatternKind: String, Codable, Hashable, Sendable {
    case isotropic
    case omnidirectional
    case directional
    case custom
}

struct RFVector3D: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    static let zero = RFVector3D(x: 0, y: 0, z: 0)

    static func + (lhs: RFVector3D, rhs: RFVector3D) -> RFVector3D {
        RFVector3D(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
    }

    func distance(to other: RFVector3D) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        let dz = z - other.z
        return sqrt(dx * dx + dy * dy + dz * dz)
    }
}

struct RFOrientation: Codable, Hashable, Sendable {
    var yawDegrees: Double
    var pitchDegrees: Double
    var rollDegrees: Double

    static let identity = RFOrientation(yawDegrees: 0, pitchDegrees: 0, rollDegrees: 0)
}

/// Authored world placement relative to the mission home/dock. Airborne device transforms still
/// come from the aircraft; ground and relay endpoints use this offset and orientation.
struct RFEndpointPlacement: Codable, Hashable, Sendable {
    var offsetFromHomeM: RFVector3D
    var orientation: RFOrientation

    static let atHome = RFEndpointPlacement(
        offsetFromHomeM: .zero,
        orientation: .identity
    )
}

struct RFFrequencyRange: Codable, Hashable, Sendable {
    var lowerBoundHz: Double
    var upperBoundHz: Double

    init(lowerBoundHz: Double, upperBoundHz: Double) {
        self.lowerBoundHz = min(lowerBoundHz, upperBoundHz)
        self.upperBoundHz = max(lowerBoundHz, upperBoundHz)
    }

    func contains(_ frequencyHz: Double) -> Bool {
        frequencyHz >= lowerBoundHz && frequencyHz <= upperBoundHz
    }
}

struct RFDeviceProfile: Codable, Hashable, Sendable {
    var id: String
    var kind: RFDeviceKind
    var frequencyRanges: [RFFrequencyRange]
    var maxTxPowerDBm: Double?
    var receiverSensitivityDBm: Double?
    var noiseFigureDB: Double?
    var supportedBandwidthsHz: [Double]
    var modulationProfiles: [String]
}

struct RFDeviceInstance: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var endpoint: RFEndpointKind
    var profile: RFDeviceProfile
    var centerFrequencyHz: Double
    var bandwidthHz: Double
    var txPowerDBm: Double?
    var dutyCycle: Double
    var connectorLossDB: Double
    var enabled: Bool
}

struct RFAntennaProfile: Codable, Hashable, Sendable {
    var id: String
    var frequencyRange: RFFrequencyRange
    var peakGainDBi: Double
    var patternKind: RFAntennaPatternKind
    var polarization: RFPolarization
    var efficiency: Double
    var connectorLossDB: Double
    /// Half-power beam widths. Nil selects a conservative built-in pattern for the antenna kind.
    var horizontalBeamwidthDegrees: Double? = nil
    var verticalBeamwidthDegrees: Double? = nil
    /// Maximum attenuation behind the main lobe / at an elevation null.
    var frontToBackRatioDB: Double? = nil
}

struct RFAntennaInstance: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var deviceID: String
    var profile: RFAntennaProfile
    var mountPositionM: RFVector3D
    var orientation: RFOrientation
    var cableLengthM: Double
    var cableLossDBPerM: Double
    /// 0 means undamaged; 1 means no usable RF efficiency remains.
    var damageFraction: Double
    var enabled: Bool
}

struct RFAntennaConnection: Codable, Hashable, Sendable {
    var deviceID: String
    var antennaID: String
}

struct RFLinkQualityProfile: Codable, Hashable, Sendable {
    var id: String
    var modulationProfile: String
    var requiredRxLevelDBm: Double
    var requiredSINRDB: Double
    var nominalBitrateBps: Double
    var baseLatencyMS: Double
}

struct RFLinkConfiguration: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var kind: LogicalLinkKind
    var transmitterDeviceID: String
    var receiverDeviceID: String
    var transmitterAntennaID: String
    var receiverAntennaID: String
    var qualityProfile: RFLinkQualityProfile
    /// Only meaningful for `.video`; nil decodes legacy configurations as digital video.
    var videoMode: RFVideoTransmissionMode? = nil
}

struct RFLogicalLinksConfiguration: Codable, Hashable, Sendable {
    var control: RFLinkConfiguration?
    var video: RFLinkConfiguration?
    var telemetry: RFLinkConfiguration?
    var payloadData: RFLinkConfiguration?

    func link(for kind: LogicalLinkKind) -> RFLinkConfiguration? {
        switch kind {
        case .control: return control
        case .video: return video
        case .telemetry: return telemetry
        case .payloadData: return payloadData
        }
    }

    var all: [RFLinkConfiguration] {
        [control, video, telemetry, payloadData].compactMap { $0 }
    }
}

struct RFSystemConfiguration: Codable, Hashable, Sendable {
    var version: Int
    var origin: RFSystemConfigurationOrigin
    var devices: [RFDeviceInstance]
    var antennas: [RFAntennaInstance]
    var connections: [RFAntennaConnection]
    var logicalLinks: RFLogicalLinksConfiguration
    /// Optional so RF files authored before Stage 7 continue to decode unchanged.
    var qos: RFQoSConfiguration? = nil
    /// Optional for backward compatibility with RF schema v1 files created before endpoint
    /// placement was authored. Missing ground placements resolve to the home/dock transform.
    var endpointPlacements: [String: RFEndpointPlacement]? = nil

    var isAutoGenerated: Bool { origin == .compatibilityPreset }

    func endpointPlacement(for deviceID: String) -> RFEndpointPlacement {
        endpointPlacements?[deviceID] ?? .atHome
    }
}

struct RFSupplementalLosses: Codable, Hashable, Sendable {
    var diffractionDB: Double = 0
    var vegetationDB: Double = 0
    var materialDB: Double = 0
    var clutterDB: Double = 0
    var polarizationDB: Double = 0
    var bodyShadowDB: Double = 0
    var miscellaneousDB: Double = 0

    var totalDB: Double {
        diffractionDB + vegetationDB + materialDB + clutterDB
            + polarizationDB + bodyShadowDB + miscellaneousDB
    }
}

struct RFLinkState: Equatable, Sendable {
    var distanceM: Double
    var frequencyHz: Double
    var bandwidthHz: Double
    var txPowerDBm: Double
    var txGainDBi: Double
    var rxGainDBi: Double
    var freeSpaceLossDB: Double
    var diffractionLossDB: Double
    var vegetationLossDB: Double
    var materialLossDB: Double
    var clutterLossDB: Double
    var polarizationLossDB: Double
    var bodyShadowLossDB: Double
    var cableLossDB: Double
    var miscellaneousLossDB: Double
    var atmosphericLossDB: Double
    var weatherLossDB: Double
    /// Signed: positive values improve RSSI, negative values deepen the fade.
    var fadingAdjustmentDB: Double
    var hasLineOfSight: Bool
    var obstructionCount: Int
    var receivedPowerDBm: Double
    var noiseFloorDBm: Double
    var interferenceDBm: Double?
    var snrDB: Double
    var sinrDB: Double
    var linkMarginDB: Double
    var lastUpdateTime: TimeInterval
}

enum RFLinkHealth: String, Codable, Equatable, Sendable {
    case healthy
    case degraded
    case critical
    case lost
}

struct RFLinkQualityState: Equatable, Sendable {
    var health: RFLinkHealth
    var packetErrorRate: Double
    var packetLoss: Double
    var latencyMS: Double
    var jitterMS: Double
    var effectiveBitrateBps: Double
}

struct RFLinkEvaluation: Equatable, Sendable {
    var rf: RFLinkState
    var quality: RFLinkQualityState
}

struct RFVideoPresentationState: Equatable, Sendable {
    var mode: RFVideoTransmissionMode
    var health: RFLinkHealth
    var analogNoiseIntensity: Double
    var digitalArtifactIntensity: Double
    var isFrozen: Bool
    var effectiveBitrateBPS: Double
    var latencyMS: Double

    static let unavailable = RFVideoPresentationState(
        mode: .digital,
        health: .lost,
        analogNoiseIntensity: 0,
        digitalArtifactIntensity: 1,
        isFrozen: true,
        effectiveBitrateBPS: 0,
        latencyMS: 0
    )
}
