import Foundation

/// Parallel to `PayloadFireHoseController` but simpler — no aim/gimbal, the tank just drains
/// while the trigger is held. Unlike the hose's effectively-unlimited truck feed, the tank is a
/// finite consumable seeded from the mission-setup starting fill level each time the payload is
/// (re)attached.
final class PayloadAgriculturalSprayerController {
    private(set) var state = PayloadAgriculturalSprayerState()

    func setAvailability(isAvailable: Bool, isPowered: Bool, configuredTankLiters: Double) {
        let capacity = Double(AgriculturalSprayerTuning.tankCapacityLiters)
        if isAvailable, !state.isAvailable {
            // Freshly (re)attached — seed the tank from the mission-setup starting fill level.
            state.tankRemainingLiters = min(max(0.0, configuredTankLiters), capacity)
        }
        state.tankCapacityLiters = capacity
        state.isAvailable = isAvailable
        state.isPowered = isPowered
        if !isAvailable || !isPowered {
            state.isSpraying = false
        }
    }

    func setSpraying(_ enabled: Bool) {
        guard state.isAvailable, state.isPowered, state.tankRemainingLiters > 0.001 else {
            state.isSpraying = false
            return
        }
        state.isSpraying = enabled
    }

    /// Transfers water back into the tank at a refill station. Returns the litres actually taken,
    /// so the caller can turn that straight into the matching mass delta — the tank's liquid mass
    /// has to come back exactly the way `drain` took it away, or the airframe would keep the
    /// agility of an empty tank while flying a full one.
    @discardableResult
    func refill(liters: Double) -> Double {
        guard state.isAvailable, liters > 0.0 else { return 0.0 }
        let accepted = min(liters, max(0.0, state.tankCapacityLiters - state.tankRemainingLiters))
        state.tankRemainingLiters += accepted
        return accepted
    }

    /// Returns the liters actually drained this tick (0 when not spraying), so the caller can
    /// convert it straight into a mass delta without recomputing the drain rate itself.
    @discardableResult
    func drain(deltaTime: Float) -> Double {
        guard state.isSpraying else {
            return 0.0
        }
        let drained = min(state.tankRemainingLiters, Double(AgriculturalSprayerTuning.drainRateLitersPerSecond) * Double(deltaTime))
        state.tankRemainingLiters = max(0.0, state.tankRemainingLiters - drained)
        if state.tankRemainingLiters <= 0.0001 {
            state.isSpraying = false
        }
        return drained
    }
}
