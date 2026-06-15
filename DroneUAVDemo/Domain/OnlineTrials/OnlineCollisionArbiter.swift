import Foundation

// P2P v1.2: Local collision detector — called by the authority owner, not the host.
// Detects proximity between the local pilot's UAV and remote ghost replicas.
// Owner emits OnlineSharedEvent; host only relays/orders/deduplicates.

struct OnlineLocalCollisionCandidate: Equatable {
    var localVehicleID: UUID
    var remoteVehicleID: UUID
    var remoteParticipantID: UUID
    var remoteParticipantName: String
    var positionX: Double
    var positionY: Double
    var positionZ: Double
    var distanceMeters: Double
    var relativeSpeedMetersPerSecond: Double
}

struct OnlineLocalCollisionDetector {
    var collisionRadiusMeters: Double = 1.2
    var minimumRelativeSpeedMetersPerSecond: Double = 1.0

    func detect(
        localSnapshot: OnlineVehicleStateSnapshot,
        remoteStates: [OnlineVehicleInterpolatedState]
    ) -> [OnlineLocalCollisionCandidate] {
        remoteStates.compactMap { remote in
            guard remote.vehicleID != localSnapshot.vehicleID else { return nil }

            let dx = localSnapshot.pose.positionX - remote.pose.positionX
            let dy = localSnapshot.pose.positionY - remote.pose.positionY
            let dz = localSnapshot.pose.positionZ - remote.pose.positionZ
            let distance = sqrt(dx * dx + dy * dy + dz * dz)
            guard distance <= collisionRadiusMeters else { return nil }

            let rvx = localSnapshot.kinematics.velocityX - remote.kinematics.velocityX
            let rvy = localSnapshot.kinematics.velocityY - remote.kinematics.velocityY
            let rvz = localSnapshot.kinematics.velocityZ - remote.kinematics.velocityZ
            let relativeSpeed = sqrt(rvx * rvx + rvy * rvy + rvz * rvz)
            guard relativeSpeed >= minimumRelativeSpeedMetersPerSecond else { return nil }

            return OnlineLocalCollisionCandidate(
                localVehicleID: localSnapshot.vehicleID,
                remoteVehicleID: remote.vehicleID,
                remoteParticipantID: remote.participantID,
                remoteParticipantName: remote.participantName,
                positionX: (localSnapshot.pose.positionX + remote.pose.positionX) / 2,
                positionY: (localSnapshot.pose.positionY + remote.pose.positionY) / 2,
                positionZ: (localSnapshot.pose.positionZ + remote.pose.positionZ) / 2,
                distanceMeters: distance,
                relativeSpeedMetersPerSecond: relativeSpeed
            )
        }
    }

    func result(for relativeSpeed: Double) -> OnlineSharedEventResult {
        if relativeSpeed >= 12 { return .crashed }
        if relativeSpeed >= 6  { return .disabled }
        if relativeSpeed >= 2  { return .damaged }
        return .ignored
    }
}
