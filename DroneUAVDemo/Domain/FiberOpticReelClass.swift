import Foundation

/// Reel-length tiers for the fiber-optic tether payload, mirroring `FireHoseDiameterClass`'s
/// shape (a rig class + a length within that class's range, together determining mass). Unlike
/// the hose, the rated reel length is *not* usable straight-line range — see
/// `FiberOpticTetherTuning` for the path-length/margin accounting applied at runtime.
enum FiberOpticReelClass: String, CaseIterable, Codable, Hashable, Identifiable {
    case short
    case medium
    case long

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .short: return "payload.fiber.reel.short"
        case .medium: return "payload.fiber.reel.medium"
        case .long: return "payload.fiber.reel.long"
        }
    }

    /// Fiber + protective coating mass per meter — heavier/more rugged coating for the longer,
    /// more abrasion-exposed tiers.
    var massPerMeterKg: Float {
        switch self {
        case .short: return 0.0008
        case .medium: return 0.0013
        case .long: return 0.0018
        }
    }

    /// Fixed reel spool/payout-motor hardware mass, independent of length.
    var hardwareOverheadKg: Float {
        switch self {
        case .short: return 0.6
        case .medium: return 1.2
        case .long: return 2.0
        }
    }

    var lengthRangeMeters: ClosedRange<Float> {
        switch self {
        case .short: return 500.0...2000.0
        case .medium: return 2000.0...10000.0
        case .long: return 10000.0...20000.0
        }
    }

    var lengthStepMeters: Float {
        switch self {
        case .short: return 100.0
        case .medium: return 500.0
        case .long: return 1000.0
        }
    }

    func massForLength(_ meters: Float) -> Float {
        max(0.0, meters) * massPerMeterKg + hardwareOverheadKg
    }
}

/// Runtime accounting for the fiber-optic tether — deliberately approximate (a flat usable-length
/// haircut and a proximity/turn-rate risk accumulator), the same spirit as the fire hose's
/// straight-line tether standing in for a real flexible-rope simulation.
enum FiberOpticTetherTuning {
    /// Fraction of the rated reel length usable as flight-path budget — the rest implicitly
    /// covers altitude gain, route slack, and safety margin (L_reel >= L_trajectory + L_altitude
    /// + L_margin), approximated as a flat haircut rather than full 3D bookkeeping.
    static let usableLengthFraction: Float = 0.85
    /// Distance to the nearest obstacle at which entanglement risk starts accumulating.
    static let snagRiskProximityMeters: Float = 6.0
    /// Baseline risk accumulation per second at maximum proximity, before the turn-rate term.
    /// Tuned so sustained flying right next to an obstacle takes tens of seconds to snag, not a
    /// single brief pass — a real trailing fiber can graze a branch without necessarily catching.
    static let snagRiskBaseRatePerSecond: Float = 0.02
    /// Extra risk accumulation per second per radian/second of yaw rate at maximum proximity —
    /// sharp turns near obstacles (or backtracking a complex route) are what actually snags a
    /// trailing fiber, not just flying near something in a straight line. A typical route-following
    /// turn is ~1-1.5 rad/s, so this is deliberately small — one turn near a tree shouldn't sever
    /// the fiber in under a second.
    static let snagRiskTurnRateMultiplier: Float = 0.15
    /// Risk decays at this rate per second whenever clear of the proximity radius — an isolated
    /// close pass or turn shouldn't permanently doom the rest of the flight, only sustained
    /// weaving through obstacles should actually accumulate toward a snag.
    static let snagRiskDecayPerSecondWhenClear: Float = 0.05
    /// Snag risk crossing this moves `FiberLinkState.status` to `.degraded` (HUD warning only)
    /// before it reaches 1.0 and actually severs the fiber.
    static let degradedSnagRiskThreshold: Float = 0.4
    /// Remaining-usable-length fraction below which the link is also considered `.degraded`,
    /// independent of snag risk — running low on reel is its own warning.
    static let degradedRemainingLengthFraction: Float = 0.10
}
