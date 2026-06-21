import Foundation

enum CollisionEmergencyAction: String {
    case none
    case slowDown
    case hover
    case avoid
    case emergencyStop

    var title: String {
        NSLocalizedString(titleKey, comment: "")
    }

    var titleKey: String {
        switch self {
        case .none:
            return "emergency.none"
        case .slowDown:
            return "emergency.slow_down"
        case .hover:
            return "emergency.hover"
        case .avoid:
            return "emergency.avoid"
        case .emergencyStop:
            return "emergency.stop"
        }
    }
}

struct CollisionAnalysisSnapshot {
    var riskScore: Float
    var nearestObstacleDistance: Float
    var nearestObstacleID: UUID?
    var nearestObstacleSource: String?
    var timeToCollision: Float?
    var emergencyAction: CollisionEmergencyAction
    var contactNormal: SIMD3<Float>?

    static let safe = CollisionAnalysisSnapshot(
        riskScore: 0.0,
        nearestObstacleDistance: .infinity,
        nearestObstacleID: nil,
        nearestObstacleSource: nil,
        timeToCollision: nil,
        emergencyAction: .none,
        contactNormal: nil
    )
}
