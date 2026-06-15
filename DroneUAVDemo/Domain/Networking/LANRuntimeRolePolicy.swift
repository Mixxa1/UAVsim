import Foundation

struct LANRuntimeRolePolicy {
    static func shouldShowFlightPanels(role: LANParticipantRole?) -> Bool {
        role == .pilot || role == nil
    }

    static func shouldShowScenarioAdminPanels(role: LANParticipantRole?, isHost: Bool) -> Bool {
        isHost
    }

    static func shouldUseSpectatorCamera(role: LANParticipantRole?) -> Bool {
        role == .spectator
    }

    static func shouldCreateLocalVehicle(role: LANParticipantRole?) -> Bool {
        role == .pilot || role == nil
    }

    static func canControlVehicle(context: OnlineTrialRuntimeContext?) -> Bool {
        guard let context else { return true }
        return context.role == .pilot && context.localVehicleID != nil
    }

    static func canUseScenarioAdmin(context: OnlineTrialRuntimeContext?) -> Bool {
        guard let context else { return true }
        return context.localParticipant.isHost
    }

    static func isSpectator(context: OnlineTrialRuntimeContext?) -> Bool {
        context?.role == .spectator
    }
}
