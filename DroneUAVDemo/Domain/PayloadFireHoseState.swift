import Foundation

/// Optics/aim state for the fire-hose payload. Parallel to `PayloadRangefinderOpticsState` — an
/// independent gimbal (own yaw/pitch, own reticle), not slaved to the payload camera.
struct PayloadFireHoseOpticsState: Codable, Equatable {
    var isAvailable: Bool
    var isPowered: Bool
    var isSpraying: Bool

    /// Index into the scene's tracked fire-tree array the nozzle is currently aimed at, or `nil`
    /// if nothing is in reach/cone. Set by the scene-layer raycast each tick.
    var aimedFireTreeIndex: Int?
    /// 0...1 suppression progress of the currently-aimed fire, for HUD feedback.
    var suppressionProgress: Double

    var nozzleThrowMeters: Double

    var gimbalYawDegrees: Double
    var gimbalPitchDegrees: Double

    var feedLabel: String

    init(
        isAvailable: Bool = true,
        isPowered: Bool = true,
        isSpraying: Bool = false,
        aimedFireTreeIndex: Int? = nil,
        suppressionProgress: Double = 0.0,
        nozzleThrowMeters: Double = 16.0,
        gimbalYawDegrees: Double = 0.0,
        gimbalPitchDegrees: Double = -12.0,
        feedLabel: String = "HOSE"
    ) {
        self.isAvailable = isAvailable
        self.isPowered = isPowered
        self.isSpraying = isSpraying
        self.aimedFireTreeIndex = aimedFireTreeIndex
        self.suppressionProgress = suppressionProgress
        self.nozzleThrowMeters = nozzleThrowMeters
        self.gimbalYawDegrees = gimbalYawDegrees
        self.gimbalPitchDegrees = gimbalPitchDegrees
        self.feedLabel = feedLabel
    }
}
