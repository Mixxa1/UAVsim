import Foundation

/// Tuning constants for the agricultural sprayer payload. Unlike the fire hose/fiber-optic
/// reel there is only one flagship tank size (no size tiers) — the user asked for the
/// spraying mechanic itself, not a tank-capacity picker.
enum AgriculturalSprayerTuning {
    static let tankCapacityLiters: Float = 44.0
    /// Typical density of a mixed agricultural spray solution (water + chemical concentrate).
    static let liquidDensityKgPerLiter: Float = 1.05
    /// Tank shell, boom arms, pump, and nozzle bar hardware mass, independent of liquid level.
    static let hardwareOverheadKg: Float = 1.4
    /// Liters drained per second of continuous spraying — a full tank lasts a little over a
    /// minute of continuous spray, long enough for a real pass over a field without being
    /// effectively unlimited.
    static let drainRateLitersPerSecond: Float = 0.55

    static func massForTankLevel(_ liters: Float) -> Float {
        hardwareOverheadKg + max(0.0, liters) * liquidDensityKgPerLiter
    }

    static func massForFullTank() -> Float {
        massForTankLevel(tankCapacityLiters)
    }
}
