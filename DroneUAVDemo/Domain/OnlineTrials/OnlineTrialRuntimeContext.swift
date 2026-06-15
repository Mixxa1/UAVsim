import Foundation

struct OnlineTrialRuntimeContext: Codable, Equatable {
    var launchDescriptor: LANTrialLaunchDescriptor
    var localParticipant: LANParticipant
    var localAssignment: LANVehicleAssignment?

    var isHost: Bool {
        localParticipant.isHost
    }

    var role: LANParticipantRole {
        localParticipant.role
    }

    var isSpectator: Bool {
        localParticipant.role == .spectator
    }

    var localVehicleID: UUID? {
        localAssignment?.vehicleID
    }

    init(
        launchDescriptor: LANTrialLaunchDescriptor,
        localParticipant: LANParticipant
    ) {
        self.launchDescriptor = launchDescriptor
        self.localParticipant = localParticipant
        self.localAssignment = launchDescriptor.assignment(for: localParticipant.id)
    }
}
