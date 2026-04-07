import Foundation
import simd

struct CollisionObstacle {
    let id: UUID
    let center: SIMD3<Float>
    let radius: Float
    let source: String
    let baseY: Float
    let topY: Float

    init(
        id: UUID,
        center: SIMD3<Float>,
        radius: Float,
        source: String,
        baseY: Float? = nil,
        topY: Float? = nil
    ) {
        self.id = id
        self.center = center
        self.radius = radius
        self.source = source

        let fallbackBase = center.y - radius
        let fallbackTop = center.y + radius
        let resolvedBase = baseY ?? fallbackBase
        let resolvedTop = topY ?? fallbackTop
        self.baseY = min(resolvedBase, resolvedTop)
        self.topY = max(resolvedBase, resolvedTop)
    }

    var planarCenter: SIMD2<Float> {
        SIMD2<Float>(center.x, center.z)
    }

    func verticalGap(toDroneCenterY centerY: Float, droneRadius: Float) -> Float {
        let droneBottom = centerY - droneRadius
        let droneTop = centerY + droneRadius

        if droneTop < baseY {
            return baseY - droneTop
        }
        if droneBottom > topY {
            return droneBottom - topY
        }
        return 0.0
    }
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
        let dronePlanar = SIMD2<Float>(input.dronePosition.x, input.dronePosition.z)
        let candidates = input.obstacles
            .compactMap { obstacle -> (CollisionObstacle, Float)? in
                let planarDelta = obstacle.planarCenter - dronePlanar
                let planarDistanceSq = simd_length_squared(planarDelta)
                let planarDistance = sqrt(planarDistanceSq)
                let verticalGap = obstacle.verticalGap(
                    toDroneCenterY: input.dronePosition.y,
                    droneRadius: input.droneRadius
                )
                let planarGap = max(0.0, planarDistance - broadPhaseDistance)
                let combinedGapSq = planarGap * planarGap + verticalGap * verticalGap
                if combinedGapSq <= broadPhaseDistanceSq {
                    return (obstacle, combinedGapSq)
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
            let planarDelta = obstacle.planarCenter - dronePlanar
            let planarDistance = simd_length(planarDelta)
            let horizontalClearance = planarDistance - (input.droneRadius + obstacle.radius)
            let verticalGap = obstacle.verticalGap(
                toDroneCenterY: input.dronePosition.y,
                droneRadius: input.droneRadius
            )
            let clearance: Float
            let direction: SIMD3<Float>

            if verticalGap <= 0.0 {
                clearance = horizontalClearance
                if planarDistance > 0.001 {
                    let planarDirection = planarDelta / planarDistance
                    direction = SIMD3<Float>(planarDirection.x, 0.0, planarDirection.y)
                } else {
                    direction = SIMD3<Float>(0.0, 0.0, 1.0)
                }
            } else if horizontalClearance <= 0.0 {
                clearance = verticalGap
                let verticalDirection: Float = obstacle.center.y >= input.dronePosition.y ? 1.0 : -1.0
                direction = SIMD3<Float>(0.0, verticalDirection, 0.0)
            } else {
                clearance = simd_length(SIMD2<Float>(horizontalClearance, verticalGap))

                let planarDirection = planarDistance > 0.001
                    ? (planarDelta / planarDistance)
                    : SIMD2<Float>(0.0, 0.0)
                let verticalDirection: Float = obstacle.center.y >= input.dronePosition.y ? 1.0 : -1.0
                let composite = SIMD3<Float>(
                    planarDirection.x * horizontalClearance,
                    verticalDirection * verticalGap,
                    planarDirection.y * horizontalClearance
                )
                direction = simd_length_squared(composite) > 0.0001
                    ? simd_normalize(composite)
                    : SIMD3<Float>(0.0, 0.0, 1.0)
            }

            if clearance < nearestDistance {
                nearestDistance = clearance
                nearestObstacleID = obstacle.id
                nearestObstacleSource = obstacle.source
            }

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
