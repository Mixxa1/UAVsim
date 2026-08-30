import Foundation

/// Non-SwiftUI accessor for the persisted audio settings, mirroring `AppGraphicsSettings`.
///
/// The settings screen writes these through `@AppStorage(<key>)`; the audio service, which has
/// no SwiftUI environment, reads them here.
enum AppAudioSettings {
    static let masterVolumeKey = "app.audio.masterVolume"
    static let mutedKey = "app.audio.muted"

    /// Default volume. Not 1.0: the simulation's loudest events — a critical impact, a close
    /// sonic boom — are authored to sit near full scale, so a default that starts at unity
    /// leaves the operator no room to turn anything up.
    static let defaultMasterVolume: Double = 0.7

    /// 0…1. A stored 0 is a real choice (silence), so "not set" is distinguished by the key's
    /// absence rather than by the value.
    static var masterVolume: Double {
        guard UserDefaults.standard.object(forKey: masterVolumeKey) != nil else {
            return defaultMasterVolume
        }
        return min(1.0, max(0.0, UserDefaults.standard.double(forKey: masterVolumeKey)))
    }

    static var isMuted: Bool { UserDefaults.standard.bool(forKey: mutedKey) }

    /// What the audio graph should actually apply, muting folded in.
    static var effectiveVolume: Float { isMuted ? 0.0 : Float(masterVolume) }
}
