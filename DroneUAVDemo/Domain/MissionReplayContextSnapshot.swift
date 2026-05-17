import Foundation

/// Context snapshot captured at ARM time, stored with MissionReplaySession.
/// All fields are optional so older sessions without context decode without error.
/// Raw string fields are used for enum types that do not conform to Codable.
/// TODO: Replace raw-value fields with typed fields when TerrainConfiguration / WeatherModel / PayloadConfiguration conform to Codable.
struct MissionReplayContextSnapshot: Codable, Equatable {
    let projectName: String?
    let selectedDroneProfileID: String?
    let selectedDroneProfileName: String?
    let selectedUAVProfileID: String?
    let selectedUAVProfileName: String?

    let terrainPresetRawValue: String?
    let mapScaleRawValue: String?
    let terrainSeed: UInt64?

    let weatherPresetRawValue: String?

    let payloadTypeRawValue: String?
    let payloadResolvedName: String?
    let hasPayloadAttachedAtStart: Bool

    let recordedAtAppVersion: String?
}
