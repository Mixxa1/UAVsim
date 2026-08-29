import Foundation
import simd

enum MissionLaunchObjectType: String, CaseIterable, Identifiable {
    case handLaunchPoint
    case catapultLine
    case runwayStrip
    case vtolStartPoint
    /// Sealed launch canister on a ground vehicle. The airframe is ejected by a
    /// rocket booster, unfolds its wings and only then starts its own engine —
    /// which is why it is not a variety of catapult.
    case launchCanister
    /// A release point under a carrier aircraft.
    ///
    /// The only launch object that is not on the ground. It marks where the carrier lets
    /// go — a position, a heading, an altitude and a speed — and after that the aircraft
    /// is simply flying. Four of the six supersonic reference aircraft are launched this
    /// way, because a target drone or a research vehicle that needs to start at altitude
    /// and at speed has no other way to get there.
    case carrierReleasePoint

    var id: String { rawValue }

    var requiresHeading: Bool {
        switch self {
        case .handLaunchPoint, .catapultLine, .runwayStrip, .launchCanister, .carrierReleasePoint:
            return true
        case .vtolStartPoint:
            return false
        }
    }

    var requiresCorridor: Bool {
        switch self {
        case .handLaunchPoint, .catapultLine, .runwayStrip:
            return true
        // A canister fires the airframe steeply upward on a booster; it does not
        // need the long shallow departure corridor a rail or a runway does.
        // A canister fires the airframe steeply upward on a booster, and a carrier
        // release happens kilometres above anything: neither needs the long shallow
        // departure corridor a rail or a runway does.
        case .vtolStartPoint, .launchCanister, .carrierReleasePoint:
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
        case .launchCanister:
            return .canister
        case .carrierReleasePoint:
            return .airLaunch
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
        // Canisters are elevated steeply so the booster carries the airframe clear
        // of the launch vehicle before the wings come out.
        case .launchCanister:
            return 25.0...65.0
        // A carrier flies level or very slightly nose-up when it releases. A drop is
        // not a dive, and this is the carrier's flight-path angle rather than any
        // angle the released aircraft is pointed at.
        case .carrierReleasePoint:
            return -5.0...5.0
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
        case .launchCanister:
            return .canister(
                CanisterLaunchAsset(
                    id: id,
                    position: position,
                    headingDegrees: headingDegrees,
                    elevationDegrees: railAngleDegrees
                )
            )
        case .runwayStrip:
            return .runway(
                RunwayLaunchAsset(
                    id: id,
                    position: position,
                    headingDegrees: launchDirectionDegrees,
                    groundAttitudeDegrees: railAngleDegrees
                )
            )
        case .carrierReleasePoint:
            // Release altitude and speed are not properties of the map object: they
            // belong to the aircraft, which knows what carrier it hangs under and how
            // fast that carrier flies. The placeholders here are filled from the
            // profile's own launch parameters when the sequence is armed.
            return .airLaunch(
                AirLaunchAsset(
                    id: id,
                    position: position,
                    headingDegrees: launchDirectionDegrees,
                    releaseAltitudeMeters: 6_000.0,
                    releaseSpeedMps: 150.0,
                    releasePitchDegrees: railAngleDegrees
                )
            )
        case .vtolStartPoint:
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
