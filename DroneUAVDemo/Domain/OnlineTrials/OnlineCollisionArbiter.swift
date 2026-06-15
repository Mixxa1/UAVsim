import Foundation

struct OnlineCollisionCandidate: Identifiable, Equatable {
    var id: UUID = UUID()
    var vehicleA: OnlineVehicleStateSnapshot
    var vehicleB: OnlineVehicleStateSnapshot
    var distanceMeters: Double
    var relativeSpeedMetersPerSecond: Double
    var positionX: Double
    var positionY: Double
    var positionZ: Double
}

struct OnlineCollisionArbiter {
    var collisionRadiusMeters: Double = 1.2
    var minimumRelativeSpeedMetersPerSecond: Double = 1.0

    func findVehicleCollisionCandidates(
        snapshots: [OnlineVehicleStateSnapshot]
    ) -> [OnlineCollisionCandidate] {
        guard snapshots.count >= 2 else { return [] }

        var result: [OnlineCollisionCandidate] = []

        for i in 0..<(snapshots.count - 1) {
            for j in (i + 1)..<snapshots.count {
                let a = snapshots[i]
                let b = snapshots[j]

                let dx = a.pose.positionX - b.pose.positionX
                let dy = a.pose.positionY - b.pose.positionY
                let dz = a.pose.positionZ - b.pose.positionZ
                let distance = sqrt(dx * dx + dy * dy + dz * dz)

                guard distance <= collisionRadiusMeters else { continue }

                let rvx = a.kinematics.velocityX - b.kinematics.velocityX
                let rvy = a.kinematics.velocityY - b.kinematics.velocityY
                let rvz = a.kinematics.velocityZ - b.kinematics.velocityZ
                let relativeSpeed = sqrt(rvx * rvx + rvy * rvy + rvz * rvz)

                guard relativeSpeed >= minimumRelativeSpeedMetersPerSecond else { continue }

                result.append(
                    OnlineCollisionCandidate(
                        vehicleA: a,
                        vehicleB: b,
                        distanceMeters: distance,
                        relativeSpeedMetersPerSecond: relativeSpeed,
                        positionX: (a.pose.positionX + b.pose.positionX) / 2,
                        positionY: (a.pose.positionY + b.pose.positionY) / 2,
                        positionZ: (a.pose.positionZ + b.pose.positionZ) / 2
                    )
                )
            }
        }

        return result
    }

    func severity(for relativeSpeed: Double) -> OnlineCollisionSeverity {
        if relativeSpeed >= 12 { return .critical }
        if relativeSpeed >= 6  { return .major }
        if relativeSpeed >= 2  { return .minor }
        return .contact
    }

    func result(for severity: OnlineCollisionSeverity) -> OnlineCollisionResult {
        switch severity {
        case .contact:  return .ignored
        case .minor:    return .damaged
        case .major:    return .disabled
        case .critical: return .crashed
        }
    }
}
