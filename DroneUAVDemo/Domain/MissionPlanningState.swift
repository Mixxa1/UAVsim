import Foundation
import simd

enum MissionMapMode: String, CaseIterable, Identifiable {
    case navigation
    case dropZone

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .navigation:
            return "mission.mode.navigation"
        case .dropZone:
            return "mission.mode.drop_zone"
        }
    }
}

struct DropZoneState: Equatable {
    var center: SIMD2<Float>
    var radius: Float

    init(center: SIMD2<Float>, radius: Float) {
        self.center = center
        self.radius = max(1.0, radius)
    }

    func contains(_ planarPosition: SIMD2<Float>, tolerance: Float = 0.0) -> Bool {
        simd_distance(center, planarPosition) <= max(0.0, radius + tolerance)
    }
}

struct MissionPlanningState: Equatable {
    var routeTarget: TargetMarkerState?
    var dropZone: DropZoneState?
    var autoReleaseEnabled: Bool

    static let empty = MissionPlanningState(
        routeTarget: nil,
        dropZone: nil,
        autoReleaseEnabled: true
    )

    var hasRoute: Bool {
        routeTarget != nil
    }

    var hasDropZone: Bool {
        dropZone != nil
    }

    var isDeliveryMissionReady: Bool {
        routeTarget != nil && dropZone != nil
    }
}
