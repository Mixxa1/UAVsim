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
}
