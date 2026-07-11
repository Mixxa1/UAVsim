import Foundation

/// Named, HUD-visible stages of the fiber-severance failsafe — driven by
/// `DroneSimulationViewModel.updateFiberFailsafeSequence`, entered once `FiberLinkState.status`
/// reaches `.broken`. Unlike the generic `UAVSignalState` freeze used for radio range loss, the
/// aircraft keeps flying itself through these stages with input locked out.
enum FiberFailsafeStage: Equatable {
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

    var titleKey: String {
        switch self {
        case .none:
            return ""
        case .braking:
            return "fiber_failsafe.stage.braking"
        case .hoverFailsafe:
            return "fiber_failsafe.stage.hover_failsafe"
        case .landing:
            return "fiber_failsafe.stage.landing"
        case .stabilize:
            return "fiber_failsafe.stage.stabilize"
        case .loiterGlide:
            return "fiber_failsafe.stage.loiter_glide"
        case .emergencyLanding:
            return "fiber_failsafe.stage.emergency_landing"
        case .landed:
            return "fiber_failsafe.stage.landed"
        case .crashed:
            return "fiber_failsafe.stage.crashed"
        case .returnedHome:
            return "fiber_failsafe.stage.returned_home"
        case .missionContinued:
            return "fiber_failsafe.stage.mission_continued"
        }
    }
}
