import Foundation
import simd

final class InterDroneCollisionAnalyzer {
    func analyze(leader: DroneEntity, wingmen: [DroneEntity]) -> InterDroneCollisionSnapshot {
        guard !wingmen.isEmpty else {
            return .safe
        }

        var nearestSeparation = Float.greatestFiniteMagnitude
        var nearestPair: (UUID, UUID)?

        var all = [leader]
        all.append(contentsOf: wingmen)

        for i in 0..<all.count {
            for j in (i + 1)..<all.count {
                let lhs = all[i]
                let rhs = all[j]
                let clearance = simd_distance(lhs.position, rhs.position) - (lhs.collisionRadius + rhs.collisionRadius)
                if clearance < nearestSeparation {
                    nearestSeparation = clearance
                    nearestPair = (lhs.id, rhs.id)
                }
            }
        }

        let risk = (1.0 - nearestSeparation / 8.0).clamped(to: 0.0...1.0)
        return InterDroneCollisionSnapshot(
            riskScore: risk,
            nearestSeparation: nearestSeparation,
            nearestPair: nearestPair
        )
    }
}

final class DroneFleetManager {
    private let collisionAnalyzer = InterDroneCollisionAnalyzer()

    func initializeWingmen(
        count: Int,
        leaderPosition: SIMD3<Float>,
        leaderYaw: Float,
        mode: FormationMode,
        separation: Float,
        radius: Float
    ) -> [DroneEntity] {
        let targets = formationTargets(
            leaderPosition: leaderPosition,
            leaderYaw: leaderYaw,
            mode: mode,
            separation: separation,
            requestedCount: count
        )

        return targets.map {
            DroneEntity(
                id: UUID(),
                position: $0,
                velocity: SIMD3<Float>(repeating: 0.0),
                collisionRadius: radius
            )
        }
    }

    func stepWingmen(
        current: [DroneEntity],
        leaderPosition: SIMD3<Float>,
        leaderVelocity: SIMD3<Float>,
        leaderYaw: Float,
        mode: FormationMode,
        requestedCount: Int,
        separation: Float,
        radius: Float,
        deltaTime: Float
    ) -> [DroneEntity] {
        guard mode != .off, requestedCount > 0 else {
            return []
        }

        var wingmen = current
        let targetCount = max(1, min(requestedCount, 5))

        if wingmen.count < targetCount {
            let newUnits = initializeWingmen(
                count: targetCount - wingmen.count,
                leaderPosition: leaderPosition,
                leaderYaw: leaderYaw,
                mode: mode,
                separation: separation + Float(wingmen.count) * 0.4,
                radius: radius
            )
            wingmen.append(contentsOf: newUnits)
        } else if wingmen.count > targetCount {
            wingmen = Array(wingmen.prefix(targetCount))
        }

        let targets = formationTargets(
            leaderPosition: leaderPosition,
            leaderYaw: leaderYaw,
            mode: mode,
            separation: separation,
            requestedCount: targetCount
        )

        let dt = max(0.001, min(deltaTime, 0.05))
        let targetSpeed = max(2.0, simd_length(leaderVelocity) + 2.4)

        for index in wingmen.indices {
            let target = targets[index]
            let offset = target - wingmen[index].position
            let distance = simd_length(offset)

            let direction = distance > 0.001 ? offset / distance : SIMD3<Float>(repeating: 0.0)
            let desiredVelocity = direction * min(targetSpeed, distance * 2.2)

            var nextVelocity = simd_mix(wingmen[index].velocity, desiredVelocity, SIMD3<Float>(repeating: dt * 3.5))
            let speed = simd_length(nextVelocity)
            if speed > targetSpeed {
                nextVelocity = (nextVelocity / speed) * targetSpeed
            }

            wingmen[index].velocity = nextVelocity
            wingmen[index].position += nextVelocity * dt
            wingmen[index].position.y = max(0.5, wingmen[index].position.y)
            wingmen[index].collisionRadius = radius
        }

        applySeparationCorrection(wingmen: &wingmen, minDistance: separation * 0.75, deltaTime: dt)

        return wingmen
    }

    func interDroneCollisionSnapshot(leader: DroneEntity, wingmen: [DroneEntity]) -> InterDroneCollisionSnapshot {
        collisionAnalyzer.analyze(leader: leader, wingmen: wingmen)
    }

    func collisionObstacles(for wingmen: [DroneEntity]) -> [CollisionObstacle] {
        wingmen.map {
            CollisionObstacle(
                id: $0.id,
                center: $0.position,
                radius: $0.collisionRadius,
                source: "wingman",
                baseY: $0.position.y - $0.collisionRadius,
                topY: $0.position.y + $0.collisionRadius
            )
        }
    }

    private func formationTargets(
        leaderPosition: SIMD3<Float>,
        leaderYaw: Float,
        mode: FormationMode,
        separation: Float,
        requestedCount: Int
    ) -> [SIMD3<Float>] {
        guard mode != .off else {
            return []
        }

        let right = SIMD3<Float>(cos(leaderYaw), 0.0, -sin(leaderYaw))
        let forward = SIMD3<Float>(sin(leaderYaw), 0.0, cos(leaderYaw))
        let elevatedLeader = leaderPosition + SIMD3<Float>(0.0, 0.1, 0.0)

        switch mode {
        case .line:
            var targets: [SIMD3<Float>] = []
            for i in 0..<requestedCount {
                let side: Float = (i % 2 == 0) ? -1.0 : 1.0
                let row = Float(i / 2)
                let local = right * side * separation * (1.0 + row * 0.8) - forward * row * separation * 0.35
                targets.append(elevatedLeader + local)
            }
            return targets

        case .triangle:
            var targets: [SIMD3<Float>] = []
            let baseOffsets: [SIMD3<Float>] = [
                -right * separation,
                right * separation,
                -forward * separation * 1.2,
                -forward * separation * 2.0 - right * separation * 0.5,
                -forward * separation * 2.0 + right * separation * 0.5
            ]

            for i in 0..<requestedCount {
                let offset = baseOffsets[min(i, baseOffsets.count - 1)]
                targets.append(elevatedLeader + offset)
            }
            return targets

        case .off:
            return []
        }
    }

    private func applySeparationCorrection(wingmen: inout [DroneEntity], minDistance: Float, deltaTime: Float) {
        guard wingmen.count > 1 else {
            return
        }

        for i in 0..<wingmen.count {
            for j in (i + 1)..<wingmen.count {
                let delta = wingmen[i].position - wingmen[j].position
                let distance = simd_length(delta)
                if distance < max(0.2, minDistance) {
                    let direction = distance > 0.0001 ? delta / distance : SIMD3<Float>(1.0, 0.0, 0.0)
                    let correction = direction * (minDistance - distance) * 0.5 * deltaTime * 8.0
                    wingmen[i].position += correction
                    wingmen[j].position -= correction
                    wingmen[i].velocity += correction * 2.0
                    wingmen[j].velocity -= correction * 2.0
                }
            }
        }
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
