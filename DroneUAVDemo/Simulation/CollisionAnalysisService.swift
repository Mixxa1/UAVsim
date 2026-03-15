import Foundation
import simd

struct CollisionObstacle {
    let id: UUID
    let center: SIMD3<Float>
    let radius: Float
    let source: String
}

struct CollisionAnalysisInput {
    let dronePosition: SIMD3<Float>
    let droneVelocity: SIMD3<Float>
    let droneRadius: Float
    let obstacles: [CollisionObstacle]
    let weather: WeatherModel
}

final class CollisionAnalysisService {
    func analyze(input: CollisionAnalysisInput) -> CollisionAnalysisSnapshot {
        guard !input.obstacles.isEmpty else {
            return .safe
        }

        let broadPhaseDistance: Float = 26.0
        let broadPhaseDistanceSq = broadPhaseDistance * broadPhaseDistance
        let candidates = input.obstacles
            .compactMap { obstacle -> (CollisionObstacle, Float)? in
                let delta = obstacle.center - input.dronePosition
                let distanceSq = simd_dot(delta, delta)
                if distanceSq <= broadPhaseDistanceSq {
                    return (obstacle, distanceSq)
                }
                return nil
            }
            .sorted { $0.1 < $1.1 }
            .prefix(48)
            .map(\.0)

        guard !candidates.isEmpty else {
            return .safe
        }

        var nearestDistance = Float.greatestFiniteMagnitude
        var nearestObstacleID: UUID?
        var nearestObstacleSource: String?
        var timeToCollision: Float?
        var maxRisk: Float = 0.0

        for obstacle in candidates {
            let relative = obstacle.center - input.dronePosition
            let centerDistance = simd_length(relative)
            let clearance = centerDistance - (input.droneRadius + obstacle.radius)
            if clearance < nearestDistance {
                nearestDistance = clearance
                nearestObstacleID = obstacle.id
                nearestObstacleSource = obstacle.source
            }

            let direction = centerDistance > 0.001 ? relative / centerDistance : SIMD3<Float>(0, 0, 0)
            let closingSpeed = simd_dot(input.droneVelocity, direction)

            var obstacleRisk: Float = 0.0
            if clearance <= 0 {
                obstacleRisk = 1.0
                timeToCollision = 0.0
            } else {
                let distanceRisk = (1.0 - clearance / 10.0).clamped(to: 0.0...1.0)
                obstacleRisk = distanceRisk * 0.65

                if closingSpeed > 0.05 {
                    let ttc = clearance / closingSpeed
                    if timeToCollision == nil || ttc < (timeToCollision ?? .greatestFiniteMagnitude) {
                        timeToCollision = ttc
                    }
                    let ttcRisk = (1.0 - (ttc / 6.0)).clamped(to: 0.0...1.0)
                    obstacleRisk += ttcRisk * 0.35
                }
            }

            maxRisk = max(maxRisk, obstacleRisk)
        }

        let weatherRisk = input.weather.effectiveFactors.collisionRiskMultiplier
        let visibilityPenalty = 1.0 + (1.0 - input.weather.effectiveFactors.visibilityFactor) * 0.55
        let risk = (maxRisk * weatherRisk * visibilityPenalty).clamped(to: 0.0...1.0)

        let emergencyAction: CollisionEmergencyAction
        switch risk {
        case 0.85...:
            emergencyAction = .emergencyStop
        case 0.65..<0.85:
            emergencyAction = .avoid
        case 0.45..<0.65:
            emergencyAction = .hover
        case 0.25..<0.45:
            emergencyAction = .slowDown
        default:
            emergencyAction = .none
        }

        return CollisionAnalysisSnapshot(
            riskScore: risk,
            nearestObstacleDistance: nearestDistance,
            nearestObstacleID: nearestObstacleID,
            nearestObstacleSource: nearestObstacleSource,
            timeToCollision: timeToCollision,
            emergencyAction: emergencyAction
        )
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
