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
    var railLengthMeters: Float = 4.2

    var headingRadians: Float {
        headingDegrees * .pi / 180.0
    }

    var launchDirectionRadians: Float {
        launchDirectionDegrees * .pi / 180.0
    }

    var horizontalDirection: SIMD2<Float> {
        MissionLaunchGeometry.horizontalDirection(headingDegrees: headingDegrees)
    }

    var direction3D: SIMD3<Float> {
        MissionLaunchGeometry.direction3D(
            headingDegrees: headingDegrees,
            pitchDegrees: railAngleDegrees
        )
    }

    var worldYawRadians: Float {
        MissionLaunchGeometry.worldYawRadians(headingDegrees: headingDegrees)
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

struct HandLaunchAsset: Identifiable, Equatable, Hashable {
    let id: UUID
    var position: SIMD2<Float>
    var headingDegrees: Float
    var launchAngleDegrees: Float
    var releaseHeightMeters: Float

    init(
        id: UUID = UUID(),
        position: SIMD2<Float>,
        headingDegrees: Float,
        launchAngleDegrees: Float = 8.0,
        releaseHeightMeters: Float = 1.45
    ) {
        self.id = id
        self.position = position
        self.headingDegrees = headingDegrees
        self.launchAngleDegrees = launchAngleDegrees
        self.releaseHeightMeters = releaseHeightMeters
    }

    var horizontalDirection: SIMD2<Float> {
        MissionLaunchGeometry.horizontalDirection(headingDegrees: headingDegrees)
    }

    var direction3D: SIMD3<Float> {
        MissionLaunchGeometry.direction3D(
            headingDegrees: headingDegrees,
            pitchDegrees: launchAngleDegrees
        )
    }

    var worldYawRadians: Float {
        MissionLaunchGeometry.worldYawRadians(headingDegrees: headingDegrees)
    }
}

enum LaunchAsset: Identifiable, Equatable, Hashable {
    case handLaunch(HandLaunchAsset)
    case catapult(CatapultLaunchAsset)

    var id: UUID {
        switch self {
        case .handLaunch(let asset):
            return asset.id
        case .catapult(let asset):
            return asset.id
        }
    }

    var position: SIMD2<Float> {
        switch self {
        case .handLaunch(let asset):
            return asset.position
        case .catapult(let asset):
            return asset.position
        }
    }

    var railAngleDegrees: Float {
        switch self {
        case .handLaunch(let asset):
            return asset.launchAngleDegrees
        case .catapult(let asset):
            return asset.rail.railAngleDegrees
        }
    }

    var headingDegrees: Float {
        switch self {
        case .handLaunch(let asset):
            return asset.headingDegrees
        case .catapult(let asset):
            return asset.rail.headingDegrees
        }
    }

    var launchDirectionDegrees: Float {
        switch self {
        case .handLaunch(let asset):
            return asset.headingDegrees
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

    var horizontalDirection: SIMD2<Float> {
        MissionLaunchGeometry.horizontalDirection(headingDegrees: launchDirectionDegrees)
    }

    var direction3D: SIMD3<Float> {
        MissionLaunchGeometry.direction3D(
            headingDegrees: launchDirectionDegrees,
            pitchDegrees: railAngleDegrees
        )
    }

    var worldYawRadians: Float {
        MissionLaunchGeometry.worldYawRadians(headingDegrees: launchDirectionDegrees)
    }
}
