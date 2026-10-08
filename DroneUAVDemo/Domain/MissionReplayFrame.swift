import Foundation
import simd

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
    /// Nil identifies recordings made before surrounding vehicles and visual effects were sampled.
    let world: MissionReplayWorldSnapshot?

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
        rfSnapshot: MissionReplayRFSnapshot? = nil,
        world: MissionReplayWorldSnapshot? = nil
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
        self.world = world
    }
}

struct MissionReplayPose: Codable, Equatable {
    var position: SIMD3<Float>
    var rotation: SIMD4<Float>
    var scale: SIMD3<Float>
}

struct MissionReplayCameraSnapshot: Codable, Equatable {
    var pose: MissionReplayPose
    var fieldOfView: Double
}

struct MissionReplayNodeState: Codable, Equatable {
    var pose: MissionReplayPose
    var opacity: Double
    var materialTint: SIMD4<Float>? = nil
    var wheelRoll: Double? = nil
}

/// Assets are stored once per session; frames contain only poses and visibility changes.
struct MissionReplayVisualSnapshot: Codable, Equatable, Identifiable {
    var id: String
    var assetID: String
    var role: String?
    var displayName: String?
    var pose: MissionReplayPose
    var opacity: Double
    var isHidden: Bool
    var hiddenNodePaths: [String]
    var absentNodeNames: [String]
    var camera: MissionReplayCameraSnapshot?
    var nodeStates: [String: MissionReplayNodeState]? = nil
    var absentNodePaths: [String]? = nil
}

struct MissionReplayEffectSnapshot: Codable, Equatable, Identifiable {
    var id: UUID
    var kind: String
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    /// Age in the authoritative simulation, independent of playback speed and wall clock.
    var age: Double
    var lifetime: Double
    var scale: Float? = nil
    var wind: SIMD3<Float>? = nil
}

struct MissionReplayWheelTrack: Codable, Equatable, Identifiable {
    var id: UUID
    var corners: [SIMD3<Float>]
    var length: Float
    var opacity: Float
}

struct MissionReplayWorldSnapshot: Codable, Equatable {
    var nodes: [MissionReplayVisualSnapshot]
    var effects: [MissionReplayEffectSnapshot]
    var wheelTracks: [MissionReplayWheelTrack]? = nil

    static func interpolated(_ start: Self?, _ end: Self?, fraction: Double) -> Self? {
        guard let start, let end else { return start ?? end }
        // Appearance/disappearance belongs to the sampled boundary, never half a frame early.
        guard fraction < 1 else { return end }
        let destinations = Dictionary(end.nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let nodes = start.nodes.map { node -> MissionReplayVisualSnapshot in
            guard let next = destinations[node.id], node.assetID == next.assetID else { return node }
            var value = node
            value.pose = interpolatePose(node.pose, next.pose, fraction)
            value.opacity += (next.opacity - node.opacity) * fraction
            if let states = node.nodeStates, let nextStates = next.nodeStates {
                value.nodeStates = states
                for (path, state) in states {
                    guard let other = nextStates[path] else { continue }
                    var changed = state
                    changed.pose = interpolatePose(state.pose, other.pose, fraction)
                    changed.opacity += (other.opacity - state.opacity) * fraction
                    if let a = state.wheelRoll, let b = other.wheelRoll {
                        changed.wheelRoll = a + (b - a) * fraction
                        let angle = Float(changed.wheelRoll!.truncatingRemainder(dividingBy: 2 * .pi))
                        changed.pose.rotation = simd_quatf(angle: angle, axis: SIMD3<Float>(1, 0, 0)).vector
                    }
                    value.nodeStates?[path] = changed
                }
            }
            if let camera = node.camera, let nextCamera = next.camera {
                value.camera = MissionReplayCameraSnapshot(
                    pose: interpolatePose(camera.pose, nextCamera.pose, fraction),
                    fieldOfView: camera.fieldOfView + (nextCamera.fieldOfView - camera.fieldOfView) * fraction
                )
            }
            return value
        }
        let effectsByID = Dictionary(end.effects.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let effects = start.effects.map { effect -> MissionReplayEffectSnapshot in
            var value = effect
            if let next = effectsByID[effect.id] { value.age += (next.age - value.age) * fraction }
            return value
        }
        return Self(nodes: nodes, effects: effects, wheelTracks: start.wheelTracks)
    }

    private static func interpolatePose(_ a: MissionReplayPose, _ b: MissionReplayPose, _ t: Double) -> MissionReplayPose {
        let fraction = Float(t)
        // Normalized shortest-arc quaternion interpolation, stable across ±q representations.
        var destination = b.rotation
        if (a.rotation * destination).sum() < 0 { destination = -destination }
        let rotation = a.rotation + (destination - a.rotation) * fraction
        let length = sqrt((rotation * rotation).sum())
        return MissionReplayPose(
            position: a.position + (b.position - a.position) * fraction,
            rotation: length > 0.0001 ? rotation / length : a.rotation,
            scale: a.scale + (b.scale - a.scale) * fraction
        )
    }
}
