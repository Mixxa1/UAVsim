import Foundation
import simd

/// A playback adapter; the mixer itself has no knowledge of mission or recorder formats.
extension SimulationAudioService {
    func playReplayDetonations(events: [MissionReplayEvent], after start: TimeInterval,
                              through end: TimeInterval, listener: SIMD3<Float>, rotation: simd_quatf) {
        refreshMasterVolume()
        updateListener(position: listener, forward: simd_act(rotation, SIMD3<Float>(0, 0, -1)),
            up: simd_act(rotation, SIMD3<Float>(0, 1, 0)))
        for effect in ChargeDetonation.replayEffects(events: events, after: start, through: end) {
            playOneShot(.chargeDetonation, at: effect.position)
        }
    }
}
