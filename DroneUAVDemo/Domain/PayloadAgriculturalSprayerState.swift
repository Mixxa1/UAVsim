import Foundation

/// Runtime state for the agricultural sprayer payload. No aim/gimbal (unlike the fire hose) —
/// it just sprays a fixed downward/aft mist cone from the boom while flying a pass.
struct PayloadAgriculturalSprayerState: Codable, Equatable {
    var isAvailable: Bool
    var isPowered: Bool
    var isSpraying: Bool
    var tankCapacityLiters: Double
    var tankRemainingLiters: Double

    init(
        isAvailable: Bool = true,
        isPowered: Bool = true,
        isSpraying: Bool = false,
        tankCapacityLiters: Double = Double(AgriculturalSprayerTuning.tankCapacityLiters),
        tankRemainingLiters: Double = Double(AgriculturalSprayerTuning.tankCapacityLiters)
    ) {
        self.isAvailable = isAvailable
        self.isPowered = isPowered
        self.isSpraying = isSpraying
        self.tankCapacityLiters = tankCapacityLiters
        self.tankRemainingLiters = tankRemainingLiters
    }

    var tankFraction: Double {
        guard tankCapacityLiters > 0.0001 else {
            return 0.0
        }
        return min(1.0, max(0.0, tankRemainingLiters / tankCapacityLiters))
    }
}
