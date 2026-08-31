import Foundation
import simd

/// Another aircraft the operator can hear but is not flying.
///
/// Two kinds arrive here and they differ in how much is known about them. A formation wingman
/// is the operator's own aircraft duplicated — the scene draws it with the same model and
/// spins its rotors from the same throttle — so its mechanical state is known exactly. A LAN
/// participant's aircraft is not: the wire format carries a pose, a velocity, an armed flag
/// and a profile id, and nothing about how fast anything is turning.
struct RemoteVehicleAudioSource {
    let id: UUID
    let profile: VehicleAudioProfile
    let worldPosition: SIMD3<Float>
    let worldVelocity: SIMD3<Float>
    /// Whether it is running at all. A disarmed aircraft on a pad is silent.
    let isRunning: Bool
    /// Shaft speed, rad/s, when the caller actually knows it — a wingman does. `nil` for a
    /// networked aircraft, whose speed is inferred instead.
    let shaftSpeedRadPerSec: Float?
}

/// What other aircraft sound like, and how many of them are worth hearing.
///
/// Deliberately simpler than the operator's own aircraft. The local machine gets a motor, a
/// propeller, lift rotors, airflow, servos and a whole life cycle; everything else gets one
/// loop. That is not laziness about the model — it is what a second aircraft two hundred
/// metres away actually resolves to, and it is what keeps a five-ship formation from
/// consuming every voice in the mixer.
enum RemoteVehicleAudio {

    /// How many other aircraft may sound at once.
    ///
    /// Four is chosen against the loop-voice pool rather than against taste: the operator's
    /// own aircraft can hold four loops, a scrape and a carrier take one each, and the pool
    /// has twelve. Beyond this the nearest four are heard and the rest are dropped — which is
    /// also roughly what happens in the air.
    static let maximumVoices = 4

    /// Beyond this an aircraft is not quiet, it is inaudible, and holding a voice for it is
    /// waste. Shorter than the one-shot cull distance: a continuous machine at two kilometres
    /// is below wind noise, where a crash at two kilometres still arrives.
    static let maximumAudibleDistance: Float = 1_200.0

    /// Which sources deserve a voice this tick: running, close enough, nearest first.
    static func select(
        _ sources: [RemoteVehicleAudioSource],
        listenerPosition: SIMD3<Float>,
        limit: Int = maximumVoices
    ) -> [RemoteVehicleAudioSource] {
        sources
            .filter { $0.isRunning }
            .filter { simd_distance($0.worldPosition, listenerPosition) < maximumAudibleDistance }
            .sorted { lhs, rhs in
                let leftDistance = simd_distance_squared(lhs.worldPosition, listenerPosition)
                let rightDistance = simd_distance_squared(rhs.worldPosition, listenerPosition)
                // Distance decides; the id only breaks ties, so the selection cannot flicker
                // between two aircraft sitting at the same range.
                if abs(leftDistance - rightDistance) > 0.01 { return leftDistance < rightDistance }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// Shaft speed for an aircraft that does not report one.
    ///
    /// A proxy, and named as one: the LAN snapshot carries no throttle and no RPM, so the only
    /// evidence available is how fast the thing is moving. It is mapped into a narrow band
    /// around the profile's own reference speed — a machine that is airborne at all is working
    /// somewhere near its cruise, and pretending to know more than that would be invention
    /// rather than modelling.
    static func inferredShaftSpeed(profile: VehicleAudioProfile, speedMps: Float) -> Float {
        let reference = max(1.0, profile.referenceShaftSpeedRadPerSec)
        let airspeedFraction = min(1.5, max(0.0, speedMps / max(1.0, profile.referenceAirspeedMps)))
        return reference * (0.85 + 0.25 * airspeedFraction)
    }

    /// How badly a networked damage event hurt, 0…1.
    ///
    /// The local damage model reports a *pair* — integrity before and after — and severity is
    /// the difference. The wire format carries only the value after, so the difference cannot
    /// be recovered: what is available is how broken the part is now. That is a different
    /// quantity and it is used as a stand-in knowingly, because the alternative is to play
    /// every remote failure at one arbitrary level.
    ///
    /// Residual strength is preferred when present because a connection event reports that and
    /// leaves integrity nil.
    static func severity(integrity: Float?, residualStrength: Float?) -> Float {
        if let integrity { return min(1.0, max(0.0, 1.0 - integrity)) }
        if let residualStrength { return min(1.0, max(0.0, 1.0 - residualStrength)) }
        // Something failed and said nothing about how much. Mid-scale is the honest guess.
        return 0.5
    }

    /// Whether a batch of events arriving from a newly-seen aircraft should be heard.
    ///
    /// It should not. A participant that comes into range carries its whole damage history in
    /// the snapshot, and playing it would sound like an aircraft disintegrating on arrival for
    /// something that happened a minute ago somewhere else. The first sight of a vehicle
    /// records where its history has got to; everything after that is live.
    static func shouldPlayOnFirstSight() -> Bool { false }

    /// The one layer this aircraft contributes.
    static func layer(
        for source: RemoteVehicleAudioSource,
        listenerPosition: SIMD3<Float>,
        listenerVelocity: SIMD3<Float>,
        speedOfSoundMps: Float
    ) -> VehicleAudioLayer? {
        guard source.isRunning, let asset = source.profile.propulsionLoop else { return nil }

        let speed = simd_length(source.worldVelocity)
        let shaftSpeed = source.shaftSpeedRadPerSec
            ?? inferredShaftSpeed(profile: source.profile, speedMps: speed)
        let reference = max(1.0, source.profile.referenceShaftSpeedRadPerSec)
        let speedRatio = shaftSpeed / reference

        let doppler = VehicleAudioRuntime.dopplerRatio(
            sourcePosition: source.worldPosition,
            sourceVelocity: source.worldVelocity,
            listenerPosition: listenerPosition,
            listenerVelocity: listenerVelocity,
            speedOfSoundMps: speedOfSoundMps
        )

        // Trimmed down from what the same aircraft would get if the operator were flying it.
        // The distance law already makes it quieter; this is on top, and it is the difference
        // between a machine you are inside the sound of and one you are watching.
        var gain = source.profile.propulsionTrimDb - 4.0
        gain += VehicleAudioProfile.speedToLevelExponent * log10(max(0.08, speedRatio))

        return VehicleAudioLayer(
            id: asset,
            gainDb: min(0.0, gain),
            pitchRatio: pow(max(0.05, speedRatio), 0.7) * doppler,
            worldPosition: source.worldPosition
        )
    }
}
