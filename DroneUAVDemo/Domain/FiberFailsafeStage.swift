import Foundation

/// What triggered the currently-running (or most recently completed) failsafe sequence — a
/// severed fiber and a lost radio link drive the exact same `ControlLinkFailsafeStage` machine
/// (the reaction depends on the aircraft's equipment/policy, not on which link type failed), but
/// the HUD text still needs to say which one actually happened.
enum ControlLinkFailsafeTrigger: Equatable {
    case fiberBroken
    case radioLinkLost
}

/// Named, HUD-visible stages of the control-link-loss failsafe — driven by
/// `DroneSimulationViewModel.updateControlLinkFailsafeSequence`, entered once either
/// `FiberLinkState.status` reaches `.broken`, or the radio link is lost on an aircraft whose
/// `linkLossPolicy` isn't `.strandedWithoutInput`. Unlike the `UAVSignalState` freeze (reserved
/// for aircraft with no autopilot to fall back on), the aircraft keeps flying itself through
/// these stages with input locked out.
enum ControlLinkFailsafeStage: Equatable {
    case none

    // Multirotor: brake to a stop, hold briefly, then land in place.
    case braking
    case hoverFailsafe
    case landing

    // Fixed-wing: wings-level/half-throttle hold, then a shallow holding turn, then a controlled
    // descent.
    case stabilize
    case loiterGlide
    case emergencyLanding

    // Shared terminal states — which one is reached is determined for free by the existing
    // collision/damage system's own `DronePhysicalState` classification, not a separate check
    // here.
    case landed
    case crashed

    // Autonomous/mission-bound aircraft reuse the existing `.returnHome` flight mode/state
    // machine directly rather than this sequence; these two cases just record the outcome for
    // HUD/telemetry.
    case returnedHome
    case missionContinued

    var isActive: Bool {
        switch self {
        case .none, .landed, .crashed, .returnedHome, .missionContinued:
            return false
        case .braking, .hoverFailsafe, .landing, .stabilize, .loiterGlide, .emergencyLanding:
            return true
        }
    }

    func titleKey(trigger: ControlLinkFailsafeTrigger) -> String {
        let prefix = trigger == .fiberBroken ? "fiber_failsafe" : "radio_link_failsafe"
        switch self {
        case .none:
            return ""
        case .braking:
            return "\(prefix).stage.braking"
        case .hoverFailsafe:
            return "\(prefix).stage.hover_failsafe"
        case .landing:
            return "\(prefix).stage.landing"
        case .stabilize:
            return "\(prefix).stage.stabilize"
        case .loiterGlide:
            return "\(prefix).stage.loiter_glide"
        case .emergencyLanding:
            return "\(prefix).stage.emergency_landing"
        case .landed:
            return "\(prefix).stage.landed"
        case .crashed:
            return "\(prefix).stage.crashed"
        case .returnedHome:
            return "\(prefix).stage.returned_home"
        case .missionContinued:
            return "\(prefix).stage.mission_continued"
        }
    }
}

/// Why `arm()` was refused — the central, runtime-level gate
/// (`DroneSimulationViewModel.resolveArmAuthorization`), not a SwiftUI button `.disabled()`
/// flag, so no input source (keyboard, controller, remote) can bypass it. A landing completes
/// the aircraft's *motion*; it does not by itself repair whatever caused the control link to be
/// lost in the first place — that's exactly what this gate exists to keep separate.
enum ArmBlockReason: Equatable {
    case none
    case radioLinkUnavailable
    case fiberBroken
    case fiberExhausted
    case linkLossFailsafeLatched
    case vehicleRequiresRecovery

    var titleKey: String {
        switch self {
        case .none:
            return ""
        case .radioLinkUnavailable:
            return "arm_block.reason.radio_link_unavailable"
        case .fiberBroken:
            return "arm_block.reason.fiber_broken"
        case .fiberExhausted:
            return "arm_block.reason.fiber_exhausted"
        case .linkLossFailsafeLatched:
            return "arm_block.reason.link_loss_failsafe_latched"
        case .vehicleRequiresRecovery:
            return "arm_block.reason.vehicle_requires_recovery"
        }
    }
}

struct ArmAuthorization: Equatable {
    var isAllowed: Bool
    var reason: ArmBlockReason

    static let allowed = ArmAuthorization(isAllowed: true, reason: .none)
}
