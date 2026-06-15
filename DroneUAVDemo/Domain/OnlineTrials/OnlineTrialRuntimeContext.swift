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

extension OnlineTrialRuntimeContext {
    var vehicleSlots: [OnlineTrialVehicleSlot] {
        launchDescriptor.assignments.compactMap { assignment in
            guard assignment.role == .pilot,
                  let vehicleID = assignment.vehicleID,
                  let profileID = assignment.vehicleProfileID,
                  let spawnIndex = assignment.spawnIndex else {
                return nil
            }

            return OnlineTrialVehicleSlot(
                vehicleID: vehicleID,
                participantID: assignment.participantID,
                participantName: assignment.participantName,
                vehicleProfileID: profileID,
                spawnIndex: spawnIndex,
                isLocalControlled: assignment.participantID == localParticipant.id,
                isHostOwned: assignment.participantID == launchDescriptor.hostParticipantID
            )
        }
    }

    var localVehicleSlot: OnlineTrialVehicleSlot? {
        vehicleSlots.first { $0.isLocalControlled }
    }

    var isLocalPilot: Bool {
        role == .pilot
    }

    var isLocalSpectator: Bool {
        role == .spectator
    }
}
