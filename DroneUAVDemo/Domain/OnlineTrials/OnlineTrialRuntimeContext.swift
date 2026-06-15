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

            let slot = OnlineTrialVehicleSlot(
                vehicleID: vehicleID,
                participantID: assignment.participantID,
                participantName: assignment.participantName,
                vehicleProfileID: profileID,
                spawnIndex: spawnIndex,
                isLocalControlled: assignment.participantID == localParticipant.id,
                isHostOwned: assignment.participantID == launchDescriptor.hostParticipantID
            )
            #if DEBUG
            print("[LAN][PROFILE] slot participant=\(slot.participantName) vehicle=\(slot.vehicleID) profileID=\(slot.vehicleProfileID) isLocal=\(slot.isLocalControlled)")
            #endif
            return slot
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

    // P2P v1.0: authority semantics
    var authorityMode: OnlineAuthorityMode {
        launchDescriptor.sessionConfig.authorityMode
    }

    var usesDistributedVehicleAuthority: Bool {
        authorityMode == .distributedVehicleAuthority
    }

    /// True when the local participant computes physics for a locally-owned UAV.
    var localHasVehicleAuthority: Bool {
        role == .pilot && localVehicleID != nil
    }

    /// True when the local participant is the host (session/world authority).
    var isWorldAuthorityHost: Bool {
        localParticipant.isHost
    }

    // P2P v1.1: build the initial object authority registry for this participant.
    func makeInitialAuthorityRegistry() -> OnlineObjectAuthorityRegistry {
        var registry = OnlineObjectAuthorityRegistry(
            localParticipantID: localParticipant.id,
            localVehicleID: localVehicleID
        )

        for slot in vehicleSlots {
            let isLocal = slot.vehicleID == localVehicleID
            let record = OnlineObjectAuthorityRecord(
                objectID: slot.vehicleID,
                objectKind: .vehicle,
                ownerParticipantID: slot.participantID,
                ownerVehicleID: slot.vehicleID,
                authorityScope: .participantOwned,
                authorityState: isLocal ? .localAuthority : .remoteReplica,
                displayName: "UAV · \(slot.participantName)"
            )
            registry.upsert(record)
        }

        return registry
    }
}
