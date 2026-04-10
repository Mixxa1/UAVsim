import Foundation
import simd

enum MissionZoneType: String, CaseIterable, Identifiable {
    case dropZone
    case noFlyZone

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .dropZone:
            return "tactical.map.zone.drop_zone"
        case .noFlyZone:
            return "tactical.map.zone.no_fly_zone"
        }
    }
}

struct MissionZone: Identifiable, Equatable {
    let id: UUID
    var type: MissionZoneType
    var center: SIMD2<Float>
    var radius: Float

    init(
        id: UUID = UUID(),
        type: MissionZoneType,
        center: SIMD2<Float>,
        radius: Float
    ) {
        self.id = id
        self.type = type
        self.center = center
        self.radius = max(1.0, radius)
    }

    func contains(_ position: SIMD2<Float>, tolerance: Float = 0.0) -> Bool {
        simd_distance(center, position) <= max(0.0, radius + tolerance)
    }
}
