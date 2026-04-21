import Foundation
import simd

enum MissionLaunchObjectType: String, CaseIterable, Identifiable {
    case handLaunchPoint
    case catapultLine
    case runwayStrip
    case vtolStartPoint

    var id: String { rawValue }

    var requiresHeading: Bool {
        switch self {
        case .catapultLine, .runwayStrip:
            return true
        case .handLaunchPoint, .vtolStartPoint:
            return false
        }
    }

    var requiresCorridor: Bool {
        switch self {
        case .catapultLine, .runwayStrip:
            return true
        case .handLaunchPoint, .vtolStartPoint:
            return false
        }
    }

    var launchMode: LaunchMode {
        switch self {
        case .handLaunchPoint:
            return .handLaunch
        case .catapultLine:
            return .catapult
        case .runwayStrip:
            return .runway
        case .vtolStartPoint:
            return .vtol
        }
    }

    var titleKey: String {
        "tactical.map.launch.object.\(rawValue)"
    }
}

struct MissionLaunchObject: Identifiable, Equatable, Hashable {
    let id: UUID
    var type: MissionLaunchObjectType
    var position: SIMD2<Float>
    var headingDegrees: Float
    var railAngleDegrees: Float
    var transitionHeadingDegrees: Float?

    init(
        id: UUID = UUID(),
        type: MissionLaunchObjectType,
        position: SIMD2<Float>,
        headingDegrees: Float = 0.0,
        railAngleDegrees: Float = 12.0,
        transitionHeadingDegrees: Float? = nil
    ) {
        self.id = id
        self.type = type
        self.position = position
        self.headingDegrees = headingDegrees
        self.railAngleDegrees = railAngleDegrees
        self.transitionHeadingDegrees = transitionHeadingDegrees
    }

    var headingRadians: Float {
        headingDegrees * .pi / 180.0
    }

    var transitionHeadingRadians: Float? {
        transitionHeadingDegrees.map { $0 * .pi / 180.0 }
    }

    var launchDirectionDegrees: Float {
        transitionHeadingDegrees ?? headingDegrees
    }

    var launchDirectionRadians: Float {
        launchDirectionDegrees * .pi / 180.0
    }

    var launchAsset: LaunchAsset? {
        switch type {
        case .catapultLine:
            return .catapult(
                CatapultLaunchAsset(
                    id: id,
                    position: position,
                    rail: LaunchRailConfiguration(
                        headingDegrees: headingDegrees,
                        railAngleDegrees: railAngleDegrees,
                        launchDirectionDegrees: launchDirectionDegrees
                    )
                )
            )
        case .handLaunchPoint, .runwayStrip, .vtolStartPoint:
            return nil
        }
    }
}

struct MissionDraft: Equatable {
    var waypoints: [MissionWaypoint]
    var zones: [MissionZone]
    var constraints: MissionConstraints
    var selectedLaunchMode: LaunchMode
    var launchObject: MissionLaunchObject?

    static let empty = MissionDraft(
        waypoints: [],
        zones: [],
        constraints: .stageOneDefault,
        selectedLaunchMode: .standard,
        launchObject: nil
    )

    var hasWaypoints: Bool {
        !waypoints.isEmpty
    }

    var hasZones: Bool {
        !zones.isEmpty
    }

    var hasContent: Bool {
        hasWaypoints || hasZones || launchObject != nil
    }

    var dropZone: MissionZone? {
        zones.first { $0.type == .dropZone }
    }

    var noFlyZones: [MissionZone] {
        zones.filter { $0.type == .noFlyZone }
    }

    var noFlyZone: MissionZone? {
        noFlyZones.last
    }

    var effectiveLaunchObjectType: MissionLaunchObjectType? {
        launchObject?.type ?? selectedLaunchMode.defaultLaunchObjectType
    }
}
