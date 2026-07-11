import Foundation

/// Runtime status of the fiber-optic control link — separate from `UAVSignalState` (the radio
/// signal-loss machine), since a physical fiber break behaves nothing like flying out of radio
/// range: no gradual RSSI fade, no countdown, and once broken it never reconnects.
enum FiberLinkStatus: Equatable {
    /// Normal operation.
    case connected
    /// Elevated snag risk or the reel is nearly exhausted — HUD warning only, no control-authority
    /// penalty (mirrors how a real degraded optical signal is still fully functional until it
    /// isn't).
    case degraded
    /// Terminal — fiber physically severed or the reel fully paid out. Never recovers; the
    /// aircraft's own failsafe sequence (`ControlLinkFailsafeStage`) takes over from here.
    case broken
}

struct FiberLinkState: Equatable {
    var status: FiberLinkStatus = .connected
    /// Cumulative flight-path distance consumed from the reel (not straight-line range).
    var deployedLengthMeters: Float = 0.0
    /// Usable path-length budget remaining (already margin-adjusted — see `FiberOpticTetherTuning`).
    var remainingLengthMeters: Float = 0.0
    var usableLengthMeters: Float = 0.0
    var isSnagged: Bool = false
    /// 0...1 accumulated entanglement risk — reaching 1.0 (or the reel running out) severs the
    /// fiber. Crossing `FiberOpticTetherTuning.degradedSnagRiskThreshold` first moves `status` to
    /// `.degraded` as an early warning.
    var snagRiskLevel: Float = 0.0
}
