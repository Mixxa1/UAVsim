import Foundation

enum FlightControlAuthority: String, Equatable {
    case none
    case manual
    case markerGuidance
    case failsafe
    case blocked

    var title: String {
        NSLocalizedString(titleKey, comment: "")
    }

    var titleKey: String {
        switch self {
        case .none:
            return "control_authority.none"
        case .manual:
            return "control_authority.manual"
        case .markerGuidance:
            return "control_authority.marker"
        case .failsafe:
            return "control_authority.failsafe"
        case .blocked:
            return "control_authority.blocked"
        }
    }
}

struct FlightInputState {
    let controlState: ResolvedControlState
    let payloadViewActive: Bool
    let mapOverlayActive: Bool

    var manualAxisInput: KeyboardAxisInput {
        KeyboardAxisInput(
            forward: Float(controlState.pitch),
            strafe: Float(controlState.roll),
            vertical: Float(controlState.throttle),
            absoluteThrottle: controlState.absoluteThrottle.map(Float.init),
            speedBoost: controlState.boostMode
        )
    }

    var manualYawInput: KeyboardYawInput {
        KeyboardYawInput(
            intent: Float(controlState.yaw),
            speedBoost: controlState.boostMode
        )
    }

    var manualInputActive: Bool {
        abs(controlState.pitch) > 0.001 ||
        abs(controlState.roll) > 0.001 ||
        abs(controlState.throttle) > 0.001 ||
        abs(controlState.yaw) > 0.001
    }
}

struct FlightControlRoutingContext {
    let isArmed: Bool
    let isInteractionBlocked: Bool
    let isSignalLost: Bool
    let isBlockedState: Bool
    let isDisarmedState: Bool
    let hasMarkerTarget: Bool
    let canUseMarkerGuidance: Bool
    let markerGuidanceRequested: Bool
}

struct FlightControlRoute {
    let authority: FlightControlAuthority
    let axisInput: KeyboardAxisInput
    let yawInput: KeyboardYawInput
    let shouldAttemptMarkerGuidance: Bool
    let shouldCancelMarkerGuidance: Bool
}

struct FlightControlDiagnostics: Equatable {
    let authority: FlightControlAuthority
    let manualInputActive: Bool
    let markerGuidanceActive: Bool
    let payloadViewActive: Bool
    let mapOverlayActive: Bool
    let disarmed: Bool
    let blocked: Bool
    let lostSignal: Bool

    static let zero = FlightControlDiagnostics(
        authority: .none,
        manualInputActive: false,
        markerGuidanceActive: false,
        payloadViewActive: false,
        mapOverlayActive: false,
        disarmed: true,
        blocked: false,
        lostSignal: false
    )
}

final class ControlAuthorityManager {
    private(set) var currentAuthority: FlightControlAuthority = .none
    private let manualAuthorityHoldDuration: Float
    private var manualAuthorityHoldRemaining: Float = 0.0

    init(manualAuthorityHoldDuration: Float = 0.18) {
        self.manualAuthorityHoldDuration = max(0.0, manualAuthorityHoldDuration)
    }

    func resolveAuthority(
        inputState: FlightInputState,
        context: FlightControlRoutingContext,
        deltaTime: Float
    ) -> FlightControlAuthority {
        if inputState.manualInputActive {
            manualAuthorityHoldRemaining = manualAuthorityHoldDuration
        } else {
            manualAuthorityHoldRemaining = max(0.0, manualAuthorityHoldRemaining - max(0.0, deltaTime))
        }

        let authority: FlightControlAuthority
        if context.isSignalLost || context.isInteractionBlocked {
            authority = .failsafe
        } else if context.isBlockedState {
            authority = .blocked
        } else if !context.isArmed || context.isDisarmedState {
            authority = .none
        } else if inputState.manualInputActive || manualAuthorityHoldRemaining > 0.0 {
            authority = .manual
        } else if context.markerGuidanceRequested && context.hasMarkerTarget && context.canUseMarkerGuidance {
            authority = .markerGuidance
        } else {
            authority = .none
        }

        currentAuthority = authority
        return authority
    }

    func reset() {
        manualAuthorityHoldRemaining = 0.0
        currentAuthority = .none
    }
}

final class FlightControlRouter {
    private let authorityManager: ControlAuthorityManager

    init(authorityManager: ControlAuthorityManager = ControlAuthorityManager()) {
        self.authorityManager = authorityManager
    }

    var currentAuthority: FlightControlAuthority {
        authorityManager.currentAuthority
    }

    func route(
        inputState: FlightInputState,
        context: FlightControlRoutingContext,
        deltaTime: Float
    ) -> FlightControlRoute {
        let authority = authorityManager.resolveAuthority(
            inputState: inputState,
            context: context,
            deltaTime: deltaTime
        )

        switch authority {
        case .manual:
            return FlightControlRoute(
                authority: authority,
                axisInput: inputState.manualAxisInput,
                yawInput: inputState.manualYawInput,
                shouldAttemptMarkerGuidance: false,
                shouldCancelMarkerGuidance: context.markerGuidanceRequested && context.hasMarkerTarget
            )
        case .markerGuidance:
            return FlightControlRoute(
                authority: authority,
                axisInput: .zero,
                yawInput: .zero,
                shouldAttemptMarkerGuidance: true,
                shouldCancelMarkerGuidance: false
            )
        case .failsafe, .blocked, .none:
            return FlightControlRoute(
                authority: authority,
                axisInput: .zero,
                yawInput: .zero,
                shouldAttemptMarkerGuidance: false,
                shouldCancelMarkerGuidance: context.markerGuidanceRequested && context.hasMarkerTarget
            )
        }
    }

    func diagnostics(
        authority: FlightControlAuthority,
        inputState: FlightInputState,
        context: FlightControlRoutingContext
    ) -> FlightControlDiagnostics {
        FlightControlDiagnostics(
            authority: authority,
            manualInputActive: inputState.manualInputActive,
            markerGuidanceActive: authority == .markerGuidance,
            payloadViewActive: inputState.payloadViewActive,
            mapOverlayActive: inputState.mapOverlayActive,
            disarmed: context.isDisarmedState || !context.isArmed,
            blocked: context.isBlockedState,
            lostSignal: context.isSignalLost
        )
    }

    func reset() {
        authorityManager.reset()
    }
}
