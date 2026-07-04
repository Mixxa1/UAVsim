import Foundation

/// Parallel to `PayloadFireHoseController` — same availability/power-state conventions, adapted
/// to the capsule launcher's ammo-count semantics instead of continuous aim/spray. No gimbal: a
/// real capsule launcher just drops straight down over whatever the drone is currently hovering.
final class PayloadFireCapsuleController {
    private(set) var state = PayloadFireCapsuleState()

    private var pendingMissionSignals: [PayloadMissionSignal] = []
    private var lastEmittedPowerState: Bool?
    private var lastMountedRigSize: FireCapsuleSize?
    private var lastMountedRigCount: Int?
    private var rechargeAccumulatedSeconds: Double = 0.0

    /// Resets `remainingCapsules` from the rigged count whenever a launcher is (re)mounted with a
    /// different rig — matches the hose's "rigging determines runtime state" pattern, just for
    /// ammo instead of nozzle throw distance.
    func setAvailability(
        isAvailable: Bool,
        isPowered: Bool,
        rigSize: FireCapsuleSize,
        rigCount: Int,
        feedLabel: String? = nil
    ) {
        state.isAvailable = isAvailable
        state.isPowered = isPowered
        if let feedLabel {
            state.feedLabel = feedLabel
        }

        if isAvailable, (lastMountedRigSize != rigSize || lastMountedRigCount != rigCount) {
            state.capsuleSize = rigSize
            state.remainingCapsules = rigCount
            lastMountedRigSize = rigSize
            lastMountedRigCount = rigCount
        }

        if !isAvailable {
            lastMountedRigSize = nil
            lastMountedRigCount = nil
        }

        if lastEmittedPowerState != isPowered {
            pendingMissionSignals.append(.capsuleLauncherPowered(isPowered))
            lastEmittedPowerState = isPowered
        }
    }

    /// Returns `false` (a no-op, no ammo consumed) if the launcher is unavailable/unpowered or
    /// already empty — caller is expected to check this before actually spawning a capsule drop.
    @discardableResult
    func consumeCapsule() -> Bool {
        guard state.isAvailable, state.isPowered, state.remainingCapsules > 0 else {
            return false
        }
        state.remainingCapsules -= 1
        pendingMissionSignals.append(.capsuleDropped(remaining: state.remainingCapsules))
        return true
    }

    func consumeMissionSignals() -> [PayloadMissionSignal] {
        let output = pendingMissionSignals
        pendingMissionSignals.removeAll(keepingCapacity: true)
        return output
    }

    /// Call every tick with the caller's already-computed eligibility (landed, close enough to the
    /// truck, mission active — see `DroneSimulationViewModel.isCapsuleRechargeEligible`). Accumulates
    /// real time while eligible and not already at the rigged capacity; resets the moment eligibility
    /// breaks, matching a "channel while stationary" reload feel rather than banking partial credit.
    func updateRecharge(isEligible: Bool, secondsPerCapsule: Double, deltaTime: TimeInterval) {
        guard state.isAvailable, state.isPowered,
              let capacity = lastMountedRigCount,
              state.remainingCapsules < capacity,
              isEligible, secondsPerCapsule > 0.0001 else {
            rechargeAccumulatedSeconds = 0.0
            state.isRecharging = false
            state.rechargeProgress01 = 0.0
            return
        }

        state.isRecharging = true
        rechargeAccumulatedSeconds += deltaTime
        if rechargeAccumulatedSeconds >= secondsPerCapsule {
            rechargeAccumulatedSeconds -= secondsPerCapsule
            state.remainingCapsules = min(capacity, state.remainingCapsules + 1)
            pendingMissionSignals.append(.capsulesRecharged(remaining: state.remainingCapsules))
        }
        state.rechargeProgress01 = min(1.0, rechargeAccumulatedSeconds / secondsPerCapsule)
    }
}
