import Foundation
import simd

enum UAVAirframeKind: String, CaseIterable, Equatable, Hashable {
    case multicopter
    case fixedWing

    init(_ airframeClass: AirframeClass) {
        switch airframeClass {
        case .multirotor:
            self = .multicopter
        case .fixedWing, .hybridVTOL:
            self = .fixedWing
        }
    }

    var airframeClass: AirframeClass {
        switch self {
        case .multicopter:
            return .multirotor
        case .fixedWing:
            return .fixedWing
        }
    }
}

typealias AirframeKind = UAVAirframeKind

enum MissionRouteKind: String, Equatable {
    case multicopterPolyline
    case fixedWingFlyable
}

struct LaunchRailConfiguration: Equatable, Hashable {
    var headingDegrees: Float
    var railAngleDegrees: Float
    var launchDirectionDegrees: Float

    var headingRadians: Float {
        headingDegrees * .pi / 180.0
    }

    var launchDirectionRadians: Float {
        launchDirectionDegrees * .pi / 180.0
    }
}

struct CatapultLaunchAsset: Identifiable, Equatable, Hashable {
    let id: UUID
    var position: SIMD2<Float>
    var rail: LaunchRailConfiguration

    init(
        id: UUID = UUID(),
        position: SIMD2<Float>,
        rail: LaunchRailConfiguration
    ) {
        self.id = id
        self.position = position
        self.rail = rail
    }
}

enum LaunchAsset: Identifiable, Equatable, Hashable {
    case catapult(CatapultLaunchAsset)

    var id: UUID {
        switch self {
        case .catapult(let asset):
            return asset.id
        }
    }

    var position: SIMD2<Float> {
        switch self {
        case .catapult(let asset):
            return asset.position
        }
    }

    var railAngleDegrees: Float {
        switch self {
        case .catapult(let asset):
            return asset.rail.railAngleDegrees
        }
    }

    var headingDegrees: Float {
        switch self {
        case .catapult(let asset):
            return asset.rail.headingDegrees
        }
    }

    var launchDirectionDegrees: Float {
        switch self {
        case .catapult(let asset):
            return asset.rail.launchDirectionDegrees
        }
    }

    var headingRadians: Float {
        headingDegrees * .pi / 180.0
    }

    var launchDirectionRadians: Float {
        launchDirectionDegrees * .pi / 180.0
    }
}
