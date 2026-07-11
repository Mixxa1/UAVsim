import Foundation
import simd

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

/// One vertex of the deployed-fiber polyline (see `DroneSimulationViewModel.updateFiberOpticTether`).
/// Laid fiber stays where it fell — checkpoints are only ever appended, never removed mid-sortie.
enum FiberPolylineCheckpointKind: Equatable {
    /// Where the sortie's line starts (the launch point).
    case anchor
    /// A macroscopic course change — fixes the laid line's geometry so consumption reflects the
    /// actual flown path, while micro-jitter between turn points costs nothing (a real payout
    /// drum doesn't feed line for centimeter-scale hover oscillation).
    case turn
    /// The line is bent around an actual obstacle — the only thing that accumulates snag risk.
    case contact
}

struct FiberPolylineCheckpoint: Equatable {
    var position: SIMD3<Float>
    var kind: FiberPolylineCheckpointKind
}

/// Runtime accounting for the fiber-optic tether — a laid-line polyline (anchor → turn/contact
/// checkpoints → aircraft) rather than a full flexible-cable simulation. Consumption is the
/// polyline's length (monotonic — a reel never rewinds); snag risk comes only from the *line*
/// actually contacting obstacles, never from the aircraft merely flying near one.
enum FiberOpticTetherTuning {
    /// Fraction of the rated reel length usable as flight-path budget — a small residual margin
    /// for winding tension/leader length. The polyline does real 3D bookkeeping now (altitude and
    /// route bends are measured, not estimated), so this is much closer to 1.0 than the old flat
    /// 0.85 haircut that stood in for unmeasured slack.
    static let usableLengthFraction: Float = 0.95
    /// Live leg must be at least this long before a turn checkpoint can be fixed — filters
    /// hover/wind jitter out of the laid geometry entirely.
    static let turnMinLegLengthMeters: Float = 10.0
    /// Fix a turn checkpoint at the leg's farthest point once the aircraft has come back toward
    /// the previous checkpoint by this much — an out-and-back leg lays fiber both ways.
    static let turnBacktrackThresholdMeters: Float = 5.0
    /// Fix a turn checkpoint once the aircraft deviates this far sideways from the current leg's
    /// axis — captures real course changes at macro scale.
    static let turnLateralDeviationMeters: Float = 12.0
    /// One-time risk bump when the line newly wraps an obstacle (a fresh contact point).
    static let contactRiskPerNewContact: Float = 0.10
    /// Abrasion: risk per meter of fiber paid out *while* the line is bent over at least one
    /// contact — dragging line over an edge is what actually damages it, scaled by how many
    /// contacts the line currently runs over (capped, see `contactCountRiskCap`).
    static let contactAbrasionRiskPerMeter: Float = 0.004
    static let contactCountRiskCap: Float = 4.0
    /// Risk decays at this rate per second while the line has no contact points at all.
    static let snagRiskDecayPerSecondWhenFree: Float = 0.03
    /// Contact pivots are placed this far short of the raycast hit, plus a small vertical lift —
    /// approximating the line riding over the obstacle's near edge rather than passing through it.
    static let contactPivotClearanceMeters: Float = 0.35
    /// Minimum spacing between consecutive checkpoints — stops contact-pivot spam when the line
    /// creeps around one trunk over many ticks.
    static let minCheckpointSpacingMeters: Float = 1.2
    /// Hard cap on stored checkpoints (length accounting keeps working past it; only geometry
    /// detail stops growing).
    static let maxCheckpoints: Int = 96
    /// Snag risk crossing this moves `FiberLinkState.status` to `.degraded` (HUD warning only)
    /// before it reaches 1.0 and actually severs the fiber.
    static let degradedSnagRiskThreshold: Float = 0.4
    /// Remaining-usable-length fraction below which the link is also considered `.degraded`,
    /// independent of snag risk — running low on reel is its own warning.
    static let degradedRemainingLengthFraction: Float = 0.10
}
