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
    /// Rocket-boosted rail rather than a pneumatic catapult. Set from the airframe,
    /// because the map object cannot know what it is holding.
    var usesRocketBooster: Bool = false

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

/// How long a strip an airframe is given, and why it is not its takeoff distance.
///
/// `runwayTakeoffDistance` is a published airframe characteristic — the ground
/// roll at weight — and it belongs to the catalogue. The runway is a piece of the
/// world, and no operator lays out a strip barely longer than the roll: an MQ-9
/// works from a 1,500 m runway, not from 500 m of it. Sizing the strip at the
/// declared distance plus a token margin made the sequence abort whenever the
/// model needed a few per cent more than the datasheet quoted, which is a
/// statement about the datasheet rather than about the takeoff.
///
/// Doubling gives the abort its real meaning: the aircraft did not run out of its
/// brochure figure, it ran out of runway.
enum FixedWingRunwayGeometry {
    static func stripLength(for wing: FixedWingParameters) -> Float {
        max(120.0, wing.runwayTakeoffDistance * 2.0)
    }
}

/// A prepared strip the aircraft takes off from under its own power.
///
/// The one launcher here that does not launch anything. A catapult, a hand and a
/// canister all put energy into the airframe; a runway only gives it room and a
/// direction, and every newton comes from the aircraft's own engine. That is why
/// it carries a usable length and a rotation speed instead of a stroke and an
/// exit speed: the sequence is a gate and a set of limits, not an impulse.
struct RunwayLaunchAsset: Identifiable, Equatable, Hashable {
    let id: UUID
    var position: SIMD2<Float>
    var headingDegrees: Float
    /// Attitude the gear holds the airframe at while it rolls, degrees.
    var groundAttitudeDegrees: Float
    /// Usable length from the threshold, metres. The takeoff roll must fit inside it.
    var usableLengthMeters: Float

    init(
        id: UUID = UUID(),
        position: SIMD2<Float>,
        headingDegrees: Float,
        groundAttitudeDegrees: Float = 3.0,
        usableLengthMeters: Float = 240.0
    ) {
        self.id = id
        self.position = position
        self.headingDegrees = headingDegrees
        self.groundAttitudeDegrees = groundAttitudeDegrees
        self.usableLengthMeters = usableLengthMeters
    }

    var horizontalDirection: SIMD2<Float> {
        MissionLaunchGeometry.horizontalDirection(headingDegrees: headingDegrees)
    }

    var direction3D: SIMD3<Float> {
        MissionLaunchGeometry.direction3D(headingDegrees: headingDegrees, pitchDegrees: 0.0)
    }

    var worldYawRadians: Float {
        MissionLaunchGeometry.worldYawRadians(headingDegrees: headingDegrees)
    }
}

/// Which launcher the canisters are carried in.
///
/// Not a cosmetic variant. The two generations of IAI loitering munition are
/// carried in visibly different equipment, and the photographs most people
/// recognise — a truck with a block of large inclined square cells — are the
/// later one. Drawing the earlier aircraft in the later launcher is the same
/// class of error as drawing the wrong airframe.
enum CanisterLauncherPattern: String, Equatable, Hashable {
    /// Older arrangement: a frame carrying a number of separate containerised
    /// rounds, each with its own end cap. The original Harpy.
    case containerRack
    /// One inclined pack whose face is a grid of large square muzzles — the
    /// launcher that appears in almost every published Harop photograph.
    case cellBlock
}

/// Sealed launch canister on a ground vehicle.
///
/// A canister is not a short catapult. Its booster keeps pushing after the
/// airframe has left the tube, and the aircraft's own engine is not running at
/// release — so it carries a burn time and a booster thrust rather than a rail
/// length and an exit speed.
struct CanisterLaunchAsset: Identifiable, Equatable, Hashable {
    let id: UUID
    var position: SIMD2<Float>
    var headingDegrees: Float
    /// Elevation of the tube, degrees above horizontal.
    var elevationDegrees: Float
    /// Length of the tube itself, metres — the part that constrains attitude.
    var tubeLengthMeters: Float
    /// How long the booster burns after the airframe clears the tube.
    var boosterBurnSeconds: Float
    /// Which launcher the round is carried in. Set from the airframe, because the
    /// map object cannot know which generation it is holding.
    var launcherPattern: CanisterLauncherPattern

    init(
        id: UUID = UUID(),
        position: SIMD2<Float>,
        headingDegrees: Float,
        elevationDegrees: Float,
        tubeLengthMeters: Float = 2.6,
        boosterBurnSeconds: Float = 1.1,
        launcherPattern: CanisterLauncherPattern = .cellBlock
    ) {
        self.id = id
        self.position = position
        self.headingDegrees = headingDegrees
        self.elevationDegrees = elevationDegrees
        self.tubeLengthMeters = tubeLengthMeters
        self.boosterBurnSeconds = boosterBurnSeconds
        self.launcherPattern = launcherPattern
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

/// Where a carrier aircraft lets go.
///
/// The only launch object in this file that is not touching the ground, and the only one
/// that adds no energy. A catapult, a hand and a booster all accelerate the airframe; a
/// runway gives it room to accelerate itself. A carrier does neither — the aircraft is
/// already at altitude and already at speed, and the launch consists entirely of the
/// shackle opening.
///
/// That is why this carries a release altitude and a release speed instead of a stroke,
/// a rail or a burn time: those are the whole of what the aircraft inherits.
struct AirLaunchAsset: Identifiable, Equatable, Hashable {
    let id: UUID
    /// Ground track of the release point.
    var position: SIMD2<Float>
    var headingDegrees: Float
    /// Height above the world origin at which the shackle opens, m.
    var releaseAltitudeMeters: Float
    /// The carrier's true airspeed at release, m/s. Inherited whole.
    var releaseSpeedMps: Float
    /// Flight-path angle of the carrier at release, degrees. Almost always level or
    /// slightly climbing; a drop is not a dive.
    var releasePitchDegrees: Float

    init(
        id: UUID = UUID(),
        position: SIMD2<Float>,
        headingDegrees: Float,
        releaseAltitudeMeters: Float,
        releaseSpeedMps: Float,
        releasePitchDegrees: Float = 0.0
    ) {
        self.id = id
        self.position = position
        self.headingDegrees = headingDegrees
        self.releaseAltitudeMeters = max(50.0, releaseAltitudeMeters)
        self.releaseSpeedMps = max(20.0, releaseSpeedMps)
        self.releasePitchDegrees = min(10.0, max(-10.0, releasePitchDegrees))
    }

    var horizontalDirection: SIMD2<Float> {
        MissionLaunchGeometry.horizontalDirection(headingDegrees: headingDegrees)
    }

    var direction3D: SIMD3<Float> {
        MissionLaunchGeometry.direction3D(
            headingDegrees: headingDegrees,
            pitchDegrees: releasePitchDegrees
        )
    }

    var worldYawRadians: Float {
        MissionLaunchGeometry.worldYawRadians(headingDegrees: headingDegrees)
    }

    /// World-space release point.
    var releasePosition: SIMD3<Float> {
        SIMD3<Float>(position.x, releaseAltitudeMeters, position.y)
    }

    /// The velocity the aircraft is handed. Not an impulse and not a scripted path — the
    /// state vector it starts flying from.
    var releaseVelocity: SIMD3<Float> {
        direction3D * releaseSpeedMps
    }
}

enum LaunchAsset: Identifiable, Equatable, Hashable {
    case handLaunch(HandLaunchAsset)
    case catapult(CatapultLaunchAsset)
    case canister(CanisterLaunchAsset)
    case runway(RunwayLaunchAsset)
    case airLaunch(AirLaunchAsset)

    var id: UUID {
        switch self {
        case .handLaunch(let asset):
            return asset.id
        case .catapult(let asset):
            return asset.id
        case .canister(let asset):
            return asset.id
        case .runway(let asset):
            return asset.id
        case .airLaunch(let asset):
            return asset.id
        }
    }

    var position: SIMD2<Float> {
        switch self {
        case .handLaunch(let asset):
            return asset.position
        case .catapult(let asset):
            return asset.position
        case .canister(let asset):
            return asset.position
        case .runway(let asset):
            return asset.position
        case .airLaunch(let asset):
            return asset.position
        }
    }

    var railAngleDegrees: Float {
        switch self {
        case .handLaunch(let asset):
            return asset.launchAngleDegrees
        case .catapult(let asset):
            return asset.rail.railAngleDegrees
        case .canister(let asset):
            return asset.elevationDegrees
        // Not a launch angle at all: the attitude the gear holds while rolling.
        case .runway(let asset):
            return asset.groundAttitudeDegrees
        // Also not a launch angle: the carrier's flight-path angle at release.
        case .airLaunch(let asset):
            return asset.releasePitchDegrees
        }
    }

    var headingDegrees: Float {
        switch self {
        case .handLaunch(let asset):
            return asset.headingDegrees
        case .catapult(let asset):
            return asset.rail.headingDegrees
        case .canister(let asset):
            return asset.headingDegrees
        case .runway(let asset):
            return asset.headingDegrees
        case .airLaunch(let asset):
            return asset.headingDegrees
        }
    }

    var launchDirectionDegrees: Float {
        switch self {
        case .handLaunch(let asset):
            return asset.headingDegrees
        case .catapult(let asset):
            return asset.rail.launchDirectionDegrees
        case .canister(let asset):
            return asset.headingDegrees
        case .runway(let asset):
            return asset.headingDegrees
        case .airLaunch(let asset):
            return asset.headingDegrees
        }
    }

    /// The carrier release this asset describes, if it is one.
    var airLaunchAsset: AirLaunchAsset? {
        if case .airLaunch(let asset) = self { return asset }
        return nil
    }

    var isAirLaunch: Bool { airLaunchAsset != nil }

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
            // A takeoff roll runs along the ground, whatever attitude the gear
            // holds the airframe at — the strip's direction must stay horizontal.
            pitchDegrees: isRunway ? 0.0 : railAngleDegrees
        )
    }

    var worldYawRadians: Float {
        MissionLaunchGeometry.worldYawRadians(headingDegrees: launchDirectionDegrees)
    }

    var isRunway: Bool {
        if case .runway = self { return true }
        return false
    }

    var isCanister: Bool {
        if case .canister = self { return true }
        return false
    }
}
