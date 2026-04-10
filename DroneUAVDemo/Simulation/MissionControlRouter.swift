import Foundation

struct MissionControlRoutingContext {
    let executionState: MissionExecutionState
    let flightAuthority: FlightControlAuthority
    let isInteractionBlocked: Bool
    let isSignalLost: Bool
    let hasMarkerTarget: Bool
}

final class MissionControlRouter {
    private(set) var currentAuthority: MissionControlAuthority = .none

    func resolve(
        context: MissionControlRoutingContext,
        updateStoredAuthority: Bool = true
    ) -> MissionControlAuthority {
        let authority: MissionControlAuthority

        if context.executionState.controlAuthority == .failsafe || context.isSignalLost || context.isInteractionBlocked {
            authority = .failsafe
        } else if context.executionState.controlAuthority == .mission || context.executionState.isMissionControlActive {
            authority = .mission
        } else {
            switch context.flightAuthority {
            case .manual:
                authority = .manual
            case .markerGuidance:
                authority = context.hasMarkerTarget ? .targetMarker : .none
            case .mission:
                authority = .mission
            case .failsafe:
                authority = .failsafe
            case .blocked, .none:
                authority = .none
            }
        }

        if updateStoredAuthority {
            currentAuthority = authority
        }
        return authority
    }

    func reset() {
        currentAuthority = .none
    }
}
