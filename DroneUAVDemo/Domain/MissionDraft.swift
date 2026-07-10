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
        case .handLaunchPoint, .catapultLine, .runwayStrip:
            return true
        case .vtolStartPoint:
            return false
        }
    }

    var requiresCorridor: Bool {
        switch self {
        case .handLaunchPoint, .catapultLine, .runwayStrip:
            return true
        case .vtolStartPoint:
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

    var launchAngleRange: ClosedRange<Float> {
        switch self {
        case .handLaunchPoint:
            return FixedWingHandLaunchTuning.minimumLaunchAngleDegrees...20.0
        case .catapultLine:
            return 4.0...22.0
        case .runwayStrip:
            return 0.0...12.0
        case .vtolStartPoint:
            return 0.0...0.0
        }
    }

    var titleKey: String {
        "tactical.map.launch.object.\(rawValue)"
    }
}

/// Canonical conversion between the tactical map's compass bearing and the
/// fixed-wing/SceneKit attitude convention. Tactical bearings use 0° = +Z
/// (north) and 90° = +X (east), while aircraft point along their local -Z
/// axis. Keeping the conversion here prevents map, preview, physics and scene
/// rendering from silently disagreeing about the sign of a launch heading.
enum MissionLaunchGeometry {
    static func normalizedHeadingDegrees(_ headingDegrees: Float) -> Float {
        var normalized = headingDegrees.truncatingRemainder(dividingBy: 360.0)
        if normalized < 0.0 {
            normalized += 360.0
        }
        return normalized
    }

    static func horizontalDirection(headingDegrees: Float) -> SIMD2<Float> {
        let radians = normalizedHeadingDegrees(headingDegrees) * .pi / 180.0
        return SIMD2<Float>(sin(radians), cos(radians))
    }

    static func worldYawRadians(headingDegrees: Float) -> Float {
        let direction = horizontalDirection(headingDegrees: headingDegrees)
        return atan2(-direction.x, -direction.y)
    }

    static func direction3D(headingDegrees: Float, pitchDegrees: Float) -> SIMD3<Float> {
        let horizontal = horizontalDirection(headingDegrees: headingDegrees)
        let pitch = pitchDegrees * .pi / 180.0
        return simd_normalize(
            SIMD3<Float>(
                horizontal.x * cos(pitch),
                sin(pitch),
                horizontal.y * cos(pitch)
            )
        )
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

    var horizontalLaunchDirection: SIMD2<Float> {
        MissionLaunchGeometry.horizontalDirection(headingDegrees: launchDirectionDegrees)
    }

    var worldYawRadians: Float {
        MissionLaunchGeometry.worldYawRadians(headingDegrees: launchDirectionDegrees)
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
        case .handLaunchPoint:
            return .handLaunch(
                HandLaunchAsset(
                    id: id,
                    position: position,
                    headingDegrees: launchDirectionDegrees,
                    launchAngleDegrees: railAngleDegrees
                )
            )
        case .catapultLine:
            return .catapult(
                CatapultLaunchAsset(
                    id: id,
                    position: position,
                    rail: LaunchRailConfiguration(
                        headingDegrees: headingDegrees,
                        railAngleDegrees: railAngleDegrees,
                        launchDirectionDegrees: launchDirectionDegrees,
                        railLengthMeters: 4.2
                    )
                )
            )
        case .runwayStrip, .vtolStartPoint:
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
        hasWaypoints || hasZones || launchObject != nil || selectedLaunchMode != .standard
    }

    var dropZone: MissionZone? {
        zones.first { $0.type == .dropZone }
    }

    var effectiveLaunchObjectType: MissionLaunchObjectType? {
        launchObject?.type ?? selectedLaunchMode.defaultLaunchObjectType
    }
}
