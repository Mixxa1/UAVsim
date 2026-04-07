import Foundation
import simd

enum FormationMode: String, CaseIterable, Identifiable {
    case off
    case line
    case triangle

    var id: String { rawValue }

    var title: String {
        NSLocalizedString(titleKey, comment: "")
    }

    var titleKey: String {
        switch self {
        case .off:
            return "fleet.mode.off"
        case .line:
            return "fleet.mode.line"
        case .triangle:
            return "fleet.mode.triangle"
        }
    }
}

struct DroneEntity: Identifiable {
    let id: UUID
    var position: SIMD3<Float>
    var velocity: SIMD3<Float>
    var collisionRadius: Float
}

struct InterDroneCollisionSnapshot {
    var riskScore: Float
    var nearestSeparation: Float
    var nearestPair: (UUID, UUID)?

    static let safe = InterDroneCollisionSnapshot(
        riskScore: 0.0,
        nearestSeparation: .infinity,
        nearestPair: nil
    )
}

struct FleetStatus {
    var enabled: Bool
    var mode: FormationMode
    var wingmanCount: Int
    var separationDistance: Float
    var interDroneRisk: Float
    var nearestInterDroneDistance: Float

    static let disabled = FleetStatus(
        enabled: false,
        mode: .off,
        wingmanCount: 2,
        separationDistance: 6.0,
        interDroneRisk: 0.0,
        nearestInterDroneDistance: .infinity
    )
}
