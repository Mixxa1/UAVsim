import Foundation

/// State for the fire-capsule launcher. Simpler than `PayloadFireHoseOpticsState` — no gimbal/aim
/// fields at all, since the launcher drops straight down from wherever the drone is currently
/// hovering (the bombardier camera is a fixed nadir view, not an aimable gimbal).
struct PayloadFireCapsuleState: Codable, Equatable {
    var isAvailable: Bool
    var isPowered: Bool
    var capsuleSize: FireCapsuleSize
    var remainingCapsules: Int
    var feedLabel: String
    /// True while landed in the truck's recharge zone with capacity remaining to refill.
    var isRecharging: Bool
    /// 0...1 progress toward the next capsule while `isRecharging`.
    var rechargeProgress01: Double

    init(
        isAvailable: Bool = true,
        isPowered: Bool = true,
        capsuleSize: FireCapsuleSize = .medium,
        remainingCapsules: Int = 2,
        feedLabel: String = "CAPSULES",
        isRecharging: Bool = false,
        rechargeProgress01: Double = 0.0
    ) {
        self.isAvailable = isAvailable
        self.isPowered = isPowered
        self.capsuleSize = capsuleSize
        self.remainingCapsules = remainingCapsules
        self.feedLabel = feedLabel
        self.isRecharging = isRecharging
        self.rechargeProgress01 = rechargeProgress01
    }
}
