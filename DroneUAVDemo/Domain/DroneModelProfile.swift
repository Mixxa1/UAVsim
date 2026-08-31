import Foundation
import simd

enum AirframeClass: String, CaseIterable {
    case multirotor
    case fixedWing
    case hybridVTOL
}

enum DroneOperationalCategory: String, CaseIterable {
    case multirotor
    case fixedWing
    case fixedWingVTOL
}

enum AirframeStyle: String, CaseIterable {
    case multirotorQuad
    case conventionalFixedWing
    case flyingWing
    case tailsitterVTOL
    case surveyEVTOL
}

enum LaunchMethod: String, CaseIterable {
    case vertical
    case handLaunch
    case catapult
    case runway
    case canister
    /// Released from a carrier aircraft at altitude and speed.
    case airLaunch

    static func resolved(from mode: LaunchMode, fallback: LaunchMethod) -> LaunchMethod {
        switch mode {
        case .handLaunch:
            return .handLaunch
        case .catapult:
            return .catapult
        case .runway:
            return .runway
        case .vtol:
            return .vertical
        case .canister:
            return .canister
        case .airLaunch:
            return .airLaunch
        case .standard:
            return fallback
        }
    }
}

/// Shared physical assumptions for a hand throw. Keeping these values in one
/// place makes the release impulse, preflight validation and initial attitude
/// controller agree instead of handing the aircraft three different launch
/// envelopes.
enum FixedWingHandLaunchTuning {
    static let minimumLaunchAngleDegrees: Float = 6.0
    static let releaseAngleOfAttackDegrees: Float = 6.0
    static let releaseAttitudeHoldSeconds: Float = 1.2
    static let minimumReleaseAirspeedFactor: Float = 1.12
}

enum LaunchMode: String, CaseIterable, Identifiable, Hashable {
    case standard
    case handLaunch
    case catapult
    case runway
    case vtol
    /// Rocket-boosted ejection from a sealed canister. Distinct from a catapult in
    /// the one way that matters to the flight model: the engine is not running at
    /// release. It is started in the air once the booster has separated and the
    /// airframe has flying speed.
    case canister
    /// Carried aloft by another aircraft and released at altitude and speed.
    ///
    /// Distinct from every other mode in the one way that matters to the flight model:
    /// nothing accelerates the aircraft. It is already moving, because the carrier was,
    /// and the whole launch consists of stopping being attached to it. The plan is
    /// explicit that what follows must be ordinary 6DOF flight with no scripted
    /// trajectory, which is exactly what "inherit the carrier's kinematics and then let
    /// go" produces.
    case airLaunch

    var id: String { rawValue }

    var requiresLaunchObject: Bool {
        self != .standard
    }

    var defaultLaunchObjectType: MissionLaunchObjectType? {
        switch self {
        case .standard:
            return nil
        case .handLaunch:
            return .handLaunchPoint
        case .catapult:
            return .catapultLine
        case .runway:
            return .runwayStrip
        case .vtol:
            return .vtolStartPoint
        case .canister:
            return .launchCanister
        case .airLaunch:
            return .carrierReleasePoint
        }
    }

    var titleKey: String {
        "tactical.map.launch.mode.\(rawValue)"
    }

    /// Mission-placed VTOL starts remain a separate future feature. Do not expose
    /// them through the assisted fixed-wing launch workflow until they have their
    /// own transition dynamics.
    var isRuntimeImplemented: Bool {
        switch self {
        case .standard, .handLaunch, .catapult, .canister, .runway, .airLaunch:
            return true
        case .vtol:
            return false
        }
    }

    /// Does this mode run the fixed-wing launch state machine?
    ///
    /// Everything except `.standard`, which is "already airborne, fly it" and has
    /// no sequence to run. Written once here because it used to be spelled out as
    /// `mode == .handLaunch || mode == .catapult` in a dozen places across the
    /// view model, and adding a mode meant finding all of them — `.canister` was
    /// declared runtime-implemented for a whole release while every one of those
    /// gates still turned it away, so its sequence never actually ran.
    var runsLaunchSequence: Bool {
        switch self {
        case .handLaunch, .catapult, .canister, .runway, .airLaunch:
            return true
        case .standard, .vtol:
            return false
        }
    }

    /// Is the aircraft accelerated by something other than its own engine?
    ///
    /// True for a rail, a throw and a booster. False for a runway, where the
    /// sequence only holds the brakes, watches the airspeed and calls the
    /// rotation — every newton comes from the aircraft itself.
    var usesExternalLaunchEnergy: Bool {
        switch self {
        // An air launch adds no energy at release — the carrier already gave the
        // aircraft all of it, on the way up. Listed here anyway because everything
        // downstream reads this as "did the aircraft get its flying speed from
        // somewhere other than its own engine", and it did.
        case .handLaunch, .catapult, .canister, .airLaunch:
            return true
        case .standard, .runway, .vtol:
            return false
        }
    }

    /// Must the engine be running and warm before the aircraft is released?
    ///
    /// False for a canister launch, whose airframe is sealed in a tube until the booster
    /// fires — asking it to run its engine on the rail would mean running it inside the
    /// tube. True for an air launch: a target drone hanging under a DC-130's wing has its
    /// turbojet started and stabilised long before the shackle opens, because there is no
    /// second chance at 10,000 metres.
    var requiresRunningEngineBeforeRelease: Bool {
        self != .canister
    }
}

enum LaunchState: String, CaseIterable, Equatable {
    case idle
    case prelaunchCheck
    case aligning
    case launchCommit
    case assistedAcceleration
    case rotation
    case initialClimb
    case transitionToFlight
    case completed
    case aborted

    var titleKey: String {
        "launch.state.\(rawValue)"
    }

    var blocksRouteCapture: Bool {
        switch self {
        case .idle, .completed, .aborted:
            return false
        case .prelaunchCheck, .aligning, .launchCommit, .assistedAcceleration, .rotation, .initialClimb, .transitionToFlight:
            return true
        }
    }
}

enum LandingMethod: String, CaseIterable {
    case vertical
    case bellyLanding
    case linearBellyLanding
    case tailsitterVerticalLanding
}

enum FixedWingFamily: String, CaseIterable, Codable {
    case rectangular
    case delta
    case swept
    case flyingWing
    case conventionalSurvey
    case tailsitterVTOL
    case surveyEVTOL
    // Supersonic planforms. Added with the supersonic scope, and added as three rather
    // than one because the differences between them are exactly what decides how each
    // behaves through Mach 1 — the plan is explicit that one universal supersonic
    // coefficient set must not be handed to every delta.
    /// Slender body, small cropped or trapezoidal wing, cruciform tail. The shape of a
    /// supersonic target drone: almost all of the volume is fuselage, the wing is there
    /// to trim rather than to lift, and it pays very little wave drag for it.
    case supersonicCruciform
    /// Thin delta with a single fin. High usable angle of attack from vortex lift and a
    /// large rearward shift of the aerodynamic centre through the transonic — which is
    /// most of why a tailless delta needs so much nose-up trim supersonically.
    case supersonicDelta
    /// Close-coupled canard ahead of a swept or delta wing. The canard carries lift and,
    /// more importantly here, holds the aerodynamic centre nearly still through the
    /// transonic — the real aerodynamic reason for the configuration, and the reason a
    /// canard aircraft does not need to re-trim as violently through Mach 1.
    case canardDelta
}

enum DroneVisualClass: String, CaseIterable {
    case miniCompact
    case vectorMidDual
    case atlasProTriple
    case abstract
    case fixedWingRectangular
    case fixedWingDelta
    case fixedWingSwept
    case ebeeClass
    case delairUX11Class
    case wingtraClass
    case trinityClass

    var titleKey: String {
        switch self {
        case .miniCompact:
            return "drone.visual.mini"
        case .vectorMidDual:
            return "drone.visual.vector"
        case .atlasProTriple:
            return "drone.visual.atlas"
        case .abstract:
            return "drone.visual.abstract"
        case .fixedWingRectangular:
            return "drone.visual.fixed_rect"
        case .fixedWingDelta:
            return "drone.visual.fixed_delta"
        case .fixedWingSwept:
            return "drone.visual.fixed_swept"
        case .ebeeClass:
            return "drone.visual.ebee_class"
        case .delairUX11Class:
            return "drone.visual.ux11_class"
        case .wingtraClass:
            return "drone.visual.wingtra_class"
        case .trinityClass:
            return "drone.visual.trinity_class"
        }
    }
}

struct DroneDimensionsMM: Hashable {
    var x: Float
    var y: Float
    var z: Float

    var meters: SIMD3<Float> {
        SIMD3<Float>(x / 1000.0, y / 1000.0, z / 1000.0)
    }
}

struct DroneCameraPreset: Hashable {
    let fpvFov: Float
    let followDistance: Float
    let followHeight: Float
}

struct FixedWingParameters: Hashable {
    let family: FixedWingFamily
    let minSustainableSpeedMps: Float
    let cruiseSpeedMps: Float
    let climbSpeedMps: Float
    let stallWarningSpeedMps: Float
    let waypointAcceptanceRadiusMeters: Float
    let nominalTurnRateDegPerSec: Float
    let bankResponseGain: Float
    let climbResponseGain: Float
    let descentResponseGain: Float
    let dragFactor: Float
    let throttleResponseGain: Float
    let turnAuthority: Float
    let maxBankAngleDeg: Float
    let supportedLaunchModes: [LaunchMode]
    let preferredLaunchMode: LaunchMode
    let minSafeAirspeed: Float
    let climbAirspeed: Float
    let cruiseAirspeed: Float
    let maxAirspeed: Float
    let nominalClimbRateMps: Float
    let nominalSinkRateMps: Float
    let loiterRadiusMeters: Float
    let maxPitchUpDeg: Float
    let maxPitchDownDeg: Float
    let minThrottle: Float
    let maxThrottle: Float
    let speedRecoveryPitchCeilingDeg: Float
    let takeoffRotationSpeed: Float
    let initialClimbPitchDeg: Float
    let maxInitialBankDeg: Float
    let handThrowSpeed: Float
    let catapultExitSpeed: Float
    let handLaunchAngleDegrees: Float
    let handReleaseHeightMeters: Float
    let catapultRailAngleDegrees: Float
    let catapultRailLengthMeters: Float
    let maxCatapultAccelerationG: Float
    /// Is the rail driven by a rocket booster rather than a catapult?
    ///
    /// Same launch geometry, different equipment and a different order of
    /// acceleration — and the operator can see which it is, because a bottle
    /// firing off a rail looks nothing like a shuttle running down one.
    let catapultUsesRocketBooster: Bool
    let launchPreSpoolSeconds: Float
    let runwayTakeoffDistance: Float
    let initialClimbTargetAltitude: Float
    /// Height above the world origin at which a carrier releases this aircraft, m.
    ///
    /// A property of the aircraft rather than of the map object, because it is a
    /// property of the pairing: a Firebee II comes off a DC-130's wing at around 10 km
    /// because that is where a DC-130 flies, and a HiMAT comes off an NB-52B at 13.7 km
    /// for the same reason.
    let airLaunchReleaseAltitude: Float
    /// The carrier's true airspeed at release, m/s. The aircraft inherits it whole.
    let airLaunchReleaseSpeed: Float

    init(
        family: FixedWingFamily,
        minSustainableSpeedMps: Float,
        cruiseSpeedMps: Float,
        climbSpeedMps: Float,
        stallWarningSpeedMps: Float,
        waypointAcceptanceRadiusMeters: Float,
        nominalTurnRateDegPerSec: Float,
        bankResponseGain: Float,
        climbResponseGain: Float,
        descentResponseGain: Float,
        dragFactor: Float,
        throttleResponseGain: Float,
        turnAuthority: Float,
        maxBankAngleDeg: Float,
        supportedLaunchModes: [LaunchMode]? = nil,
        preferredLaunchMode: LaunchMode? = nil,
        minSafeAirspeed: Float? = nil,
        climbAirspeed: Float? = nil,
        cruiseAirspeed: Float? = nil,
        maxAirspeed: Float? = nil,
        nominalClimbRateMps: Float? = nil,
        nominalSinkRateMps: Float? = nil,
        loiterRadiusMeters: Float? = nil,
        maxPitchUpDeg: Float? = nil,
        maxPitchDownDeg: Float? = nil,
        minThrottle: Float? = nil,
        maxThrottle: Float? = nil,
        speedRecoveryPitchCeilingDeg: Float? = nil,
        takeoffRotationSpeed: Float? = nil,
        initialClimbPitchDeg: Float = 10.0,
        maxInitialBankDeg: Float? = nil,
        handThrowSpeed: Float? = nil,
        catapultExitSpeed: Float? = nil,
        handLaunchAngleDegrees: Float = 8.0,
        handReleaseHeightMeters: Float = 1.45,
        catapultRailAngleDegrees: Float = 12.0,
        catapultRailLengthMeters: Float? = nil,
        maxCatapultAccelerationG: Float = 8.0,
        catapultUsesRocketBooster: Bool = false,
        launchPreSpoolSeconds: Float = 0.45,
        runwayTakeoffDistance: Float = 45.0,
        initialClimbTargetAltitude: Float = 18.0,
        airLaunchReleaseAltitude: Float? = nil,
        airLaunchReleaseSpeed: Float? = nil
    ) {
        self.family = family
        self.minSustainableSpeedMps = minSustainableSpeedMps
        self.cruiseSpeedMps = cruiseSpeedMps
        self.climbSpeedMps = climbSpeedMps
        self.stallWarningSpeedMps = stallWarningSpeedMps
        self.waypointAcceptanceRadiusMeters = waypointAcceptanceRadiusMeters
        self.nominalTurnRateDegPerSec = nominalTurnRateDegPerSec
        self.bankResponseGain = bankResponseGain
        self.climbResponseGain = climbResponseGain
        self.descentResponseGain = descentResponseGain
        self.dragFactor = dragFactor
        self.throttleResponseGain = throttleResponseGain
        self.turnAuthority = turnAuthority
        self.maxBankAngleDeg = maxBankAngleDeg

        let resolvedMinSafeAirspeed = minSafeAirspeed ?? max(minSustainableSpeedMps, stallWarningSpeedMps + 0.8)
        let resolvedClimbAirspeed = climbAirspeed ?? max(climbSpeedMps, minSustainableSpeedMps + 1.2)
        let resolvedCruiseAirspeed = cruiseAirspeed ?? cruiseSpeedMps
        let resolvedMaxAirspeed = maxAirspeed ?? max(resolvedCruiseAirspeed * 1.35, resolvedClimbAirspeed * 1.18)
        let resolvedNominalClimbRate = nominalClimbRateMps ?? max(1.2, min(climbSpeedMps * 0.24, resolvedCruiseAirspeed * 0.30))
        let resolvedNominalSinkRate = nominalSinkRateMps ?? max(1.0, min(resolvedCruiseAirspeed * 0.22, resolvedNominalClimbRate * 1.15))
        let turnReferenceSpeed = max(resolvedCruiseAirspeed, resolvedMinSafeAirspeed)
        let turnBankRad = max(5.0, maxBankAngleDeg) * Float.pi / 180.0
        let resolvedTurnRadius = max(
            waypointAcceptanceRadiusMeters * 1.1,
            (turnReferenceSpeed * turnReferenceSpeed) / (9.81 * tan(turnBankRad))
        )
        let resolvedMaxPitchUpDeg = maxPitchUpDeg ?? max(10.0, min(18.0, initialClimbPitchDeg + 4.0))

        let resolvedSupportedModes: [LaunchMode]
        if let supportedLaunchModes, !supportedLaunchModes.isEmpty {
            resolvedSupportedModes = supportedLaunchModes.reduce(into: []) { modes, mode in
                if !modes.contains(mode) {
                    modes.append(mode)
                }
            }
        } else if let preferredLaunchMode, preferredLaunchMode != .standard {
            resolvedSupportedModes = [.standard, preferredLaunchMode]
        } else {
            resolvedSupportedModes = [.standard]
        }
        self.supportedLaunchModes = resolvedSupportedModes
        if let preferredLaunchMode, resolvedSupportedModes.contains(preferredLaunchMode) {
            self.preferredLaunchMode = preferredLaunchMode
        } else {
            self.preferredLaunchMode = resolvedSupportedModes.first ?? .standard
        }
        self.minSafeAirspeed = resolvedMinSafeAirspeed
        self.climbAirspeed = resolvedClimbAirspeed
        self.cruiseAirspeed = resolvedCruiseAirspeed
        self.maxAirspeed = resolvedMaxAirspeed
        self.nominalClimbRateMps = resolvedNominalClimbRate
        self.nominalSinkRateMps = resolvedNominalSinkRate
        self.loiterRadiusMeters = loiterRadiusMeters ?? max(waypointAcceptanceRadiusMeters * 1.4, resolvedTurnRadius)
        self.maxPitchUpDeg = resolvedMaxPitchUpDeg
        self.maxPitchDownDeg = maxPitchDownDeg ?? max(8.0, min(14.0, resolvedMaxPitchUpDeg * 0.8))
        self.minThrottle = minThrottle ?? 0.36
        self.maxThrottle = maxThrottle ?? 1.0
        self.speedRecoveryPitchCeilingDeg = speedRecoveryPitchCeilingDeg ?? max(1.5, min(4.0, initialClimbPitchDeg * 0.25))
        self.takeoffRotationSpeed = takeoffRotationSpeed ?? max(resolvedMinSafeAirspeed * 0.94, minSustainableSpeedMps)
        self.initialClimbPitchDeg = initialClimbPitchDeg
        self.maxInitialBankDeg = min(maxBankAngleDeg, maxInitialBankDeg ?? max(10.0, maxBankAngleDeg * 0.55))
        // Release speeds must clear the stall regime with margin: the aero
        // model's lift scales with v², so a throw at ~0.6x of minSafeAirspeed
        // produces barely a third of the required lift and the airframe drops
        // out of the operator's hand. 1.22x (not 1.12x): at 1.12x the level-
        // flight angle of attack still exceeds the 6° nose-up the thrower
        // imparts, and flight tests showed the airframe settling into a
        // ground skim off the hand instead of climbing.
        self.handThrowSpeed = max(
            handThrowSpeed ?? 0.0,
            max(7.0, self.minSafeAirspeed * 1.22)
        )
        // Also the canister booster's burnout speed: both are "the launcher must
        // hand the airframe over above its stall speed, with margin".
        self.catapultExitSpeed = max(
            catapultExitSpeed ?? 0.0,
            max(self.minSafeAirspeed * 1.28, self.climbAirspeed)
        )
        self.handLaunchAngleDegrees = handLaunchAngleDegrees.clamped(
            to: FixedWingHandLaunchTuning.minimumLaunchAngleDegrees...20.0
        )
        self.handReleaseHeightMeters = handReleaseHeightMeters.clamped(to: 0.8...2.2)
        self.catapultRailAngleDegrees = catapultRailAngleDegrees.clamped(to: 4.0...22.0)
        // Ceiling 30 g, not 12: a pneumatic or bungee catapult lives at the bottom
        // of this range, but a rocket-assisted rail does not. A jet target drone
        // leaves its launcher at flying speed off a bottle that would tear a
        // catapult shuttle apart, and capping it at a catapult's figure forced a
        // twenty-metre rail onto a trailer that is nine metres long.
        self.maxCatapultAccelerationG = maxCatapultAccelerationG.clamped(to: 2.0...30.0)
        self.catapultUsesRocketBooster = catapultUsesRocketBooster
        // A catapult shuttle has to deliver the whole release speed before the rail
        // ends, so its rail cannot be shorter than that takes. A rocket bottle does
        // not: it keeps burning after the round is clear, so its rail is whatever
        // the trailer carries.
        let minimumRailLength = catapultUsesRocketBooster
            ? 2.0
            : (self.catapultExitSpeed * self.catapultExitSpeed) /
                (2.0 * self.maxCatapultAccelerationG * 9.81)
        self.catapultRailLengthMeters = max(
            minimumRailLength,
            catapultRailLengthMeters ?? max(4.2, minimumRailLength)
        )
        self.launchPreSpoolSeconds = launchPreSpoolSeconds.clamped(to: 0.15...2.0)
        self.runwayTakeoffDistance = runwayTakeoffDistance
        self.initialClimbTargetAltitude = initialClimbTargetAltitude
        // Defaulted rather than required, so no existing profile changes by the field
        // appearing. The defaults describe an ordinary transport-altitude drop at a
        // comfortable margin over this airframe's own cruise, which is what a carrier
        // release is when nothing more specific is known.
        self.airLaunchReleaseAltitude = max(200.0, airLaunchReleaseAltitude ?? 6_000.0)
        self.airLaunchReleaseSpeed = max(
            self.minSafeAirspeed * 1.15,
            airLaunchReleaseSpeed ?? (resolvedCruiseAirspeed * 0.95)
        )
    }

    /// Lift-based turn radius `R = V²/(g·tan(bank))`, not the old kinematic
    /// `V/turnRate` — a banked aircraft's radius is set by how much lift it
    /// can redirect sideways at a given bank angle, not by a flat assumed
    /// turn rate. `maxBankAngleDeg` is the same limit the autopilot itself
    /// commands during a route turn, so this reflects what it can actually fly.
    func minimumTurnRadius(airspeed: Float? = nil) -> Float {
        let referenceSpeed = max(airspeed ?? cruiseAirspeed, minSafeAirspeed)
        let bankRad = max(5.0, maxBankAngleDeg) * Float.pi / 180.0
        return max(
            waypointAcceptanceRadiusMeters * 1.1,
            (referenceSpeed * referenceSpeed) / (9.81 * tan(bankRad))
        )
    }

    /// Does the airframe roll on wheels, or sit on its belly?
    ///
    /// Declared runway capability is the honest test. `landingMethod` is not: every
    /// fixed wing in the catalogue recovers belly-down — including the MQ-9A, the
    /// MQ-9B and the Hermes 900, which all have retractable tricycle gear — because
    /// that field describes how the recovery is *modelled*, not what the aircraft
    /// stands on. Using it to pick rolling resistance gave a 900 shp turboprop the
    /// friction of a skid dragging through grass and it could not move.
    ///
    /// `supportedLaunchModes` is read here rather than `DroneModelProfile`'s
    /// runtime-filtered list on purpose: the undercarriage is a property of the
    /// airframe, not of which launch modes the simulation happens to implement.
    var hasWheeledUndercarriage: Bool {
        supportedLaunchModes.contains(.runway)
    }

    /// Radius of the waypoint volume that is both rendered to the operator and
    /// used by route guidance to decide that the waypoint was actually crossed.
    ///
    /// Keep this separate from guidance lookahead: lookahead may be much larger
    /// than the visible sphere, but it must never make the autopilot advance to
    /// the next leg before the aircraft enters this volume.
    func waypointCaptureRadius(airspeed: Float? = nil) -> Float {
        let baseRadius = max(waypointAcceptanceRadiusMeters, 4.0)
        let referenceSpeed = max(airspeed ?? cruiseAirspeed, minSafeAirspeed)
        return max(
            baseRadius * 1.45,
            min(
                minimumTurnRadius(airspeed: referenceSpeed) * 0.50,
                baseRadius * 5.0
            )
        )
    }

    func guidanceLookaheadDistance(airspeed: Float? = nil) -> Float {
        let referenceSpeed = max(airspeed ?? cruiseAirspeed, minSafeAirspeed)
        return max(
            minimumTurnRadius(airspeed: referenceSpeed) * 1.25,
            referenceSpeed * 1.15,
            waypointAcceptanceRadiusMeters * 2.0
        )
    }

    func corridorLength(for mode: LaunchMode) -> Float {
        switch mode {
        case .standard:
            return 0.0
        case .handLaunch:
            return max(12.0, climbAirspeed * 1.2)
        case .catapult:
            return max(18.0, catapultExitSpeed * 1.4)
        case .runway:
            return max(24.0, runwayTakeoffDistance)
        case .vtol:
            return max(8.0, waypointAcceptanceRadiusMeters * 0.9)
        case .canister:
            // A booster throws the airframe up and clear rather than along a
            // shallow departure path, so the corridor it needs is short.
            return max(10.0, waypointAcceptanceRadiusMeters * 1.1)
        case .airLaunch:
            // Released with kilometres of clear air under it. There is no departure
            // corridor to keep clear because there is no ground anywhere near it.
            return 0.0
        }
    }
}

/// How much water the airframe can take before it stops being an aircraft.
///
/// Deliberately not a number. Real ingress ratings do not form a scale that predicts ditching: an
/// IP55 airframe is sealed against a hose from any direction and still floods in a second under the
/// surface, because immersion is a different test from spray. So the cases here are the three
/// outcomes that actually differ in flight, and the ratings map onto them rather than the reverse.
enum WaterIngressProtection: String, Codable, Hashable, CaseIterable {
    /// No meaningful sealing. Touching the surface ends the flight.
    case unsealed
    /// IP4x-IP5x class: rain and spray are survivable, and so is a brief touch of the surface, but
    /// going under is still terminal.
    case weatherSealed
    /// Purpose-built to float and be recovered — hulled airframes and marine-rescue platforms.
    case buoyant

    var localizationKey: String {
        switch self {
        case .unsealed: return "uav.water.protection.unsealed"
        case .weatherSealed: return "uav.water.protection.weather_sealed"
        case .buoyant: return "uav.water.protection.buoyant"
        }
    }

    /// Seconds the airframe keeps flying while in contact with the surface but not submerged.
    /// Zero means contact alone is immediately fatal.
    var surfaceContactToleranceSeconds: Float {
        switch self {
        case .unsealed: return 0.0
        case .weatherSealed: return 2.5
        case .buoyant: return .greatestFiniteMagnitude
        }
    }

    /// Does going under the surface end the flight regardless of how briefly?
    var submersionIsTerminal: Bool { self != .buoyant }
}

struct AbstractDroneParameters: Hashable {
    var massKg: Float
    var unfoldedMm: DroneDimensionsMM
    var batteryEnergyWh: Float
    var maxHorizontalSpeedMps: Float
    var maxAscentSpeedMps: Float
    var maxDescentSpeedMps: Float
    var maxWindResistanceMps: Float
    var controlResponsiveness: Float
    var collisionRadiusMeters: Float

    static let `default` = AbstractDroneParameters(
        massKg: 0.82,
        unfoldedMm: DroneDimensionsMM(x: 340, y: 320, z: 120),
        batteryEnergyWh: 58.0,
        maxHorizontalSpeedMps: 18.0,
        maxAscentSpeedMps: 7.0,
        maxDescentSpeedMps: 6.0,
        maxWindResistanceMps: 11.0,
        controlResponsiveness: 0.80,
        collisionRadiusMeters: 0.29
    )
}

struct DroneModelProfile: Identifiable, Hashable {
    let id: String
    let displayName: String
    let displayNameKey: String
    let manufacturer: String

    let takeoffMassKg: Float
    let dimensionsFoldedMm: DroneDimensionsMM
    let dimensionsUnfoldedMm: DroneDimensionsMM

    let maxHorizontalSpeedMps: Float
    let maxAscentSpeedMps: Float
    let maxDescentSpeedMps: Float
    let maxFlightTimeMin: Float
    let maxHoverTimeMin: Float
    let maxWindResistanceMps: Float

    let batteryCapacitymAh: Float
    let batteryEnergyWh: Float

    let cameraLayoutKey: String
    let visualClass: DroneVisualClass
    let operationalCategory: DroneOperationalCategory
    let airframeClass: AirframeClass
    let airframeStyle: AirframeStyle
    let fixedWingParameters: FixedWingParameters?
    let launchMethod: LaunchMethod
    let landingMethod: LandingMethod

    let controlResponsiveness: Float
    let hoverThrottle: Float
    let cameraPreset: DroneCameraPreset
    let collisionRadiusMeters: Float

    /// Static template of propulsion units seeded into `DroneState.propulsionUnits`
    /// on arm/spawn/reset. Empty for airframes that aren't hybridVTOL.
    let propulsionUnitTemplate: [PropulsionUnit]
    /// Structural build-quality multiplier scaling `VehicleComponentGraphBuilder`'s
    /// per-component-kind strength table for this specific airframe. 1.0 = unmodified table.
    let structuralQualityFactor: Float

    /// What the airframe's skin is made of.
    ///
    /// Only matters once the aircraft is fast enough for the air to heat it, which is
    /// why it defaults to aluminium and why every existing subsonic profile can ignore
    /// it. Above Mach 2 it stops being a detail: it is the difference between an
    /// aircraft that can hold a speed and one that can only dash to it.
    var skinMaterial: UAVSkinMaterial = .aluminium

    /// Defaulted to `.unsealed` because that is what almost every real airframe is: consumer and
    /// commercial multirotors carry no immersion rating at all. Aircraft that genuinely differ are
    /// marked individually in the catalogue rather than the default being softened for everyone.
    var waterProtection: WaterIngressProtection = .unsealed

    let notes: String
    let sourceURL: URL?
    let uavProfileID: String?
    /// Exact self-contained Workbench assembly used for user-authored models.
    /// Nil for the built-in and legacy abstract catalog profiles.
    let workbenchBuild: WorkbenchBuild?

    init(
        id: String,
        displayName: String,
        displayNameKey: String,
        manufacturer: String,
        takeoffMassKg: Float,
        dimensionsFoldedMm: DroneDimensionsMM,
        dimensionsUnfoldedMm: DroneDimensionsMM,
        maxHorizontalSpeedMps: Float,
        maxAscentSpeedMps: Float,
        maxDescentSpeedMps: Float,
        maxFlightTimeMin: Float,
        maxHoverTimeMin: Float,
        maxWindResistanceMps: Float,
        batteryCapacitymAh: Float,
        batteryEnergyWh: Float,
        cameraLayoutKey: String,
        visualClass: DroneVisualClass,
        operationalCategory: DroneOperationalCategory,
        airframeClass: AirframeClass,
        airframeStyle: AirframeStyle,
        fixedWingParameters: FixedWingParameters?,
        launchMethod: LaunchMethod,
        landingMethod: LandingMethod,
        controlResponsiveness: Float,
        hoverThrottle: Float,
        cameraPreset: DroneCameraPreset,
        collisionRadiusMeters: Float,
        propulsionUnitTemplate: [PropulsionUnit] = [],
        notes: String,
        sourceURL: URL?,
        uavProfileID: String? = nil,
        workbenchBuild: WorkbenchBuild? = nil,
        structuralQualityFactor: Float = 1.0
    ) {
        self.id = id
        self.displayName = displayName
        self.displayNameKey = displayNameKey
        self.manufacturer = manufacturer
        self.takeoffMassKg = takeoffMassKg
        self.dimensionsFoldedMm = dimensionsFoldedMm
        self.dimensionsUnfoldedMm = dimensionsUnfoldedMm
        self.maxHorizontalSpeedMps = maxHorizontalSpeedMps
        self.maxAscentSpeedMps = maxAscentSpeedMps
        self.maxDescentSpeedMps = maxDescentSpeedMps
        self.maxFlightTimeMin = maxFlightTimeMin
        self.maxHoverTimeMin = maxHoverTimeMin
        self.maxWindResistanceMps = maxWindResistanceMps
        self.batteryCapacitymAh = batteryCapacitymAh
        self.batteryEnergyWh = batteryEnergyWh
        self.cameraLayoutKey = cameraLayoutKey
        self.visualClass = visualClass
        self.operationalCategory = operationalCategory
        self.airframeClass = airframeClass
        self.airframeStyle = airframeStyle
        self.fixedWingParameters = fixedWingParameters
        self.launchMethod = fixedWingParameters.map {
            LaunchMethod.resolved(from: $0.preferredLaunchMode, fallback: launchMethod)
        } ?? launchMethod
        self.landingMethod = landingMethod
        self.controlResponsiveness = controlResponsiveness
        self.hoverThrottle = hoverThrottle
        self.cameraPreset = cameraPreset
        self.collisionRadiusMeters = collisionRadiusMeters
        self.propulsionUnitTemplate = propulsionUnitTemplate
        self.notes = notes
        self.sourceURL = sourceURL
        self.uavProfileID = uavProfileID
        self.workbenchBuild = workbenchBuild
        self.structuralQualityFactor = structuralQualityFactor
    }

    var isAbstract: Bool {
        id == "abstract-uav"
    }

    var resolvedUAVProfile: UAVProfile? {
        if let workbenchBuild {
            return UAVBuildProfileSynthesizer.catalogProfile(for: workbenchBuild)
        }
        guard let uavProfileID else {
            return nil
        }
        return UAVReferenceCatalog.profile(id: uavProfileID)
    }

    var uiDisplayName: String {
        if resolvedUAVProfile != nil || displayNameKey == displayName {
            return displayName
        }

        let localizedName = NSLocalizedString(displayNameKey, comment: "")
        return localizedName == displayNameKey ? displayName : localizedName
    }

    var massKg: Float { takeoffMassKg }
    var batteryCapacityWh: Float { batteryEnergyWh }
    var collisionRadius: Float { collisionRadiusMeters }

    /// LiPo cell count (S rating) bracketed by pack energy — a computed default rather than a
    /// per-profile field so it applies consistently across the whole catalog without threading a
    /// new constructor parameter through every call site. Brackets follow real-world pack scaling
    /// (micro/toy packs 2S ~7.4V, small consumer/prosumer 4S ~14.8V, professional enterprise 6S
    /// ~22.2V, heavy professional/cargo 12S ~44.4V, heavy industrial/agri 18S ~66.6V, extreme
    /// heavy-lift/military-scale 24S ~88.8V). Cell counts are always even in practice.
    var batteryCellCount: Int {
        switch batteryEnergyWh {
        case ..<20: return 2
        case ..<150: return 4
        case ..<600: return 6
        case ..<3000: return 12
        case ..<10000: return 18
        default: return 24
        }
    }

    var dimensions: DroneDimensionsMeters {
        let meters = dimensionsUnfoldedMm.meters
        return DroneDimensionsMeters(widthM: meters.x, lengthM: meters.y, heightM: meters.z)
    }

    var maxVerticalSpeedMps: Float {
        max(maxAscentSpeedMps, maxDescentSpeedMps)
    }

    var supportedLaunchModes: [LaunchMode] {
        let implemented = (fixedWingParameters?.supportedLaunchModes ?? [.standard])
            .filter(\.isRuntimeImplemented)
        return implemented.isEmpty ? [.standard] : implemented
    }

    var preferredLaunchMode: LaunchMode {
        let preferred = fixedWingParameters?.preferredLaunchMode ?? .standard
        return supportedLaunchModes.contains(preferred)
            ? preferred
            : supportedLaunchModes.first ?? .standard
    }
}

struct DroneDimensionsMeters: Hashable {
    let widthM: Float
    let lengthM: Float
    let heightM: Float
}

protocol DroneModelRepository {
    var allProfiles: [DroneModelProfile] { get }
    var defaultProfile: DroneModelProfile { get }
}

struct LIPODroneModelRepository: DroneModelRepository {
    // Keep legacy saved model IDs loadable after the branding rename.
    static let legacyModelIDMap: [String: String] = [
        "dji-mini-4-pro": "dji-matrice-350-rtk",
        "dji-air-3s": "dji-matrice-350-rtk",
        "dji-mavic-3-pro": "freefly-alta-x",
        "lipo-scout-4": "dji-matrice-350-rtk",
        "lipo-vector-3s": "dji-matrice-350-rtk",
        "lipo-atlas-3-pro": "freefly-alta-x",
        "fixedwing-rectangular": "quantum-systems-trinity-pro",
        "fixedwing-delta": "wingtraone-gen-ii",
        "fixedwing-swept": "quantum-systems-trinity-pro",
        "ebeeClass": "wingtraone-gen-ii",
        "delairUX11Class": "quantum-systems-trinity-pro",
        "wingtraClass": "wingtraone-gen-ii",
        "trinityClass": "quantum-systems-trinity-pro"
    ]

    static func canonicalModelID(_ id: String) -> String {
        legacyModelIDMap[id] ?? id
    }

    let allProfiles: [DroneModelProfile]

    init(abstractParameters: AbstractDroneParameters = .default) {
        allProfiles = UAVReferenceCatalog.realProfiles.map(Self.runtimeProfile(from:)) + [Self.abstractProfile(from: abstractParameters)]
    }

    var defaultProfile: DroneModelProfile {
        allProfiles.first(where: { $0.id == UAVReferenceCatalog.defaultProfileID }) ?? allProfiles[0]
    }

    static func runtimeProfile(from uavProfile: UAVProfile) -> DroneModelProfile {
        let tuning = runtimeTuning(for: uavProfile)
        let catalogDimensionsUnfolded = uavProfile.dimensions.resolvedUnfoldedMillimeters(fallback: tuning.fallbackDimensions)
        let dimensionsUnfolded = tuning.runtimeSceneDimensionsOverride ?? catalogDimensionsUnfolded
        let defaultFoldedFallback = DroneDimensionsMM(
            x: dimensionsUnfolded.x * 0.60,
            y: dimensionsUnfolded.y * 0.46,
            z: dimensionsUnfolded.z * 0.88
        )
        let dimensionsFolded = tuning.runtimeSceneDimensionsOverride.map {
            DroneDimensionsMM(
                x: $0.x * 0.60,
                y: $0.y * 0.46,
                z: $0.z * 0.88
            )
        } ?? uavProfile.dimensions.resolvedFoldedMillimeters(fallback: defaultFoldedFallback)
        let runtimeMass = uavProfile.maxTakeoffMass ?? uavProfile.baseMass ?? tuning.fallbackTakeoffMass

        var profile = DroneModelProfile(
            id: uavProfile.id,
            displayName: uavProfile.displayName,
            displayNameKey: uavProfile.displayName,
            manufacturer: uavProfile.manufacturer,
            takeoffMassKg: runtimeMass,
            dimensionsFoldedMm: dimensionsFolded,
            dimensionsUnfoldedMm: dimensionsUnfolded,
            maxHorizontalSpeedMps: tuning.maxHorizontalSpeedMps,
            maxAscentSpeedMps: tuning.maxAscentSpeedMps,
            maxDescentSpeedMps: tuning.maxDescentSpeedMps,
            maxFlightTimeMin: tuning.maxFlightTimeMin,
            maxHoverTimeMin: tuning.maxHoverTimeMin,
            maxWindResistanceMps: tuning.maxWindResistanceMps,
            batteryCapacitymAh: max(1000.0, tuning.batteryEnergyWh * 22.0),
            batteryEnergyWh: tuning.batteryEnergyWh,
            cameraLayoutKey: tuning.cameraLayoutKey,
            visualClass: tuning.visualClass,
            operationalCategory: tuning.operationalCategory,
            airframeClass: tuning.airframeClass,
            airframeStyle: tuning.airframeStyle,
            fixedWingParameters: tuning.fixedWingParameters,
            launchMethod: tuning.launchMethod,
            landingMethod: tuning.landingMethod,
            controlResponsiveness: tuning.controlResponsiveness,
            hoverThrottle: tuning.hoverThrottle,
            cameraPreset: tuning.cameraPreset,
            collisionRadiusMeters: tuning.collisionRadiusMeters,
            propulsionUnitTemplate: tuning.propulsionUnitTemplate,
            notes: uavProfile.notes,
            sourceURL: UAVReferenceCatalog.sourceURL(for: uavProfile.id),
            uavProfileID: uavProfile.id,
            structuralQualityFactor: tuning.structuralQualityFactor
        )
        profile.skinMaterial = tuning.skinMaterial
        return profile
    }

    private static func runtimeTuning(for uavProfile: UAVProfile) -> RuntimeTuning {
        if let override = runtimeTuningOverride(for: uavProfile) {
            return override
        }

        switch uavProfile.visualPreset {
        case .abstractCustom:
            return RuntimeTuning(
                fallbackTakeoffMass: 1.0,
                fallbackDimensions: DroneDimensionsMM(x: 340, y: 320, z: 120),
                maxHorizontalSpeedMps: 18.0,
                maxAscentSpeedMps: 7.0,
                maxDescentSpeedMps: 6.0,
                maxFlightTimeMin: 34.0,
                maxHoverTimeMin: 30.0,
                maxWindResistanceMps: 11.0,
                batteryEnergyWh: 58.0,
                cameraLayoutKey: "drone.camera.custom",
                visualClass: .abstract,
                operationalCategory: .multirotor,
                airframeClass: .multirotor,
                airframeStyle: .multirotorQuad,
                fixedWingParameters: nil,
                launchMethod: .vertical,
                landingMethod: .vertical,
                controlResponsiveness: 0.80,
                hoverThrottle: 0.56,
                cameraPreset: DroneCameraPreset(fpvFov: 82.0, followDistance: 8.0, followHeight: 2.8),
                collisionRadiusMeters: 0.29
            )
        case .djiMatrice350RTK:
            return RuntimeTuning(
                fallbackTakeoffMass: 9.2,
                fallbackDimensions: DroneDimensionsMM(x: 810, y: 670, z: 430),
                maxHorizontalSpeedMps: 23.0,
                maxAscentSpeedMps: 6.0,
                maxDescentSpeedMps: 5.0,
                maxFlightTimeMin: 50.0,
                maxHoverTimeMin: 44.0,
                maxWindResistanceMps: 12.0,
                batteryEnergyWh: 526.0,
                cameraLayoutKey: "drone.camera.single_compact",
                visualClass: .vectorMidDual,
                operationalCategory: .multirotor,
                airframeClass: .multirotor,
                airframeStyle: .multirotorQuad,
                fixedWingParameters: nil,
                launchMethod: .vertical,
                landingMethod: .vertical,
                controlResponsiveness: 0.74,
                hoverThrottle: 0.57,
                cameraPreset: DroneCameraPreset(fpvFov: 82.0, followDistance: 11.2, followHeight: 4.0),
                collisionRadiusMeters: 0.38,
                structuralQualityFactor: 1.15
            )
        case .djiMavic4Pro:
            return RuntimeTuning(
                fallbackTakeoffMass: 1.063,
                fallbackDimensions: DroneDimensionsMM(x: 390, y: 330, z: 135),
                maxHorizontalSpeedMps: 18.0,
                maxAscentSpeedMps: 6.0,
                maxDescentSpeedMps: 6.0,
                maxFlightTimeMin: 51.0,
                maxHoverTimeMin: 45.0,
                maxWindResistanceMps: 12.0,
                batteryEnergyWh: 95.0,
                cameraLayoutKey: "drone.camera.multi_lens",
                visualClass: .miniCompact,
                operationalCategory: .multirotor,
                airframeClass: .multirotor,
                airframeStyle: .multirotorQuad,
                fixedWingParameters: nil,
                launchMethod: .vertical,
                landingMethod: .vertical,
                controlResponsiveness: 0.84,
                hoverThrottle: 0.53,
                cameraPreset: DroneCameraPreset(fpvFov: 84.0, followDistance: 8.8, followHeight: 3.0),
                collisionRadiusMeters: 0.24,
                structuralQualityFactor: 0.95
            )
        case .djiNeo:
            return RuntimeTuning(
                fallbackTakeoffMass: 0.135,
                fallbackDimensions: DroneDimensionsMM(x: 157, y: 130, z: 48.5),
                maxHorizontalSpeedMps: 10.0,
                maxAscentSpeedMps: 3.0,
                maxDescentSpeedMps: 2.5,
                maxFlightTimeMin: 18.0,
                maxHoverTimeMin: 15.0,
                maxWindResistanceMps: 8.0,
                batteryEnergyWh: 10.0,
                cameraLayoutKey: "drone.camera.single_compact",
                visualClass: .miniCompact,
                operationalCategory: .multirotor,
                airframeClass: .multirotor,
                airframeStyle: .multirotorQuad,
                fixedWingParameters: nil,
                launchMethod: .vertical,
                landingMethod: .vertical,
                controlResponsiveness: 0.92,
                hoverThrottle: 0.50,
                cameraPreset: DroneCameraPreset(fpvFov: 92.0, followDistance: 4.8, followHeight: 1.5),
                collisionRadiusMeters: 0.12,
                structuralQualityFactor: 0.65
            )
        case .fpvRacingQuad:
            // The five-inch open racer, which is what the airframe is modelled at; the other six
            // classes override this per aircraft below.
            return RuntimeTuning(
                fallbackTakeoffMass: 0.680,
                fallbackDimensions: DroneDimensionsMM(x: 250, y: 250, z: 62),
                maxHorizontalSpeedMps: 38.0,
                maxAscentSpeedMps: 16.0,
                maxDescentSpeedMps: 14.0,
                maxFlightTimeMin: 4.6,
                maxHoverTimeMin: 5.5,
                maxWindResistanceMps: 12.0,
                batteryEnergyWh: 28.9,
                cameraLayoutKey: "drone.camera.fpv",
                visualClass: .miniCompact,
                operationalCategory: .multirotor,
                airframeClass: .multirotor,
                airframeStyle: .multirotorQuad,
                fixedWingParameters: nil,
                launchMethod: .vertical,
                landingMethod: .vertical,
                // Racing quads are flown on rate, not on assistance: full stick is a demand for
                // angular rate and the airframe delivers it almost immediately. There is nothing
                // to soften here.
                controlResponsiveness: 1.0,
                hoverThrottle: 0.22,
                cameraPreset: DroneCameraPreset(fpvFov: 108.0, followDistance: 3.4, followHeight: 1.0),
                collisionRadiusMeters: 0.16,
                // Carbon plates and exposed props: light, stiff, and entirely willing to break.
                structuralQualityFactor: 0.55
            )
        case .djiPhantom3Standard:
            return RuntimeTuning(
                fallbackTakeoffMass: 1.216,
                fallbackDimensions: DroneDimensionsMM(x: 350, y: 350, z: 230),
                maxHorizontalSpeedMps: 16.0,
                maxAscentSpeedMps: 5.0,
                maxDescentSpeedMps: 3.0,
                maxFlightTimeMin: 25.0,
                maxHoverTimeMin: 22.0,
                maxWindResistanceMps: 10.0,
                batteryEnergyWh: 68.0,
                cameraLayoutKey: "drone.camera.single_compact",
                visualClass: .vectorMidDual,
                operationalCategory: .multirotor,
                airframeClass: .multirotor,
                airframeStyle: .multirotorQuad,
                fixedWingParameters: nil,
                launchMethod: .vertical,
                landingMethod: .vertical,
                controlResponsiveness: 0.70,
                hoverThrottle: 0.54,
                cameraPreset: DroneCameraPreset(fpvFov: 80.0, followDistance: 9.5, followHeight: 3.1),
                collisionRadiusMeters: 0.28,
                structuralQualityFactor: 0.85
            )
        case .freeflyAltaX:
            return RuntimeTuning(
                fallbackTakeoffMass: 34.86,
                fallbackDimensions: DroneDimensionsMM(x: 2273, y: 2273, z: 387),
                maxHorizontalSpeedMps: 20.0,
                maxAscentSpeedMps: 4.5,
                maxDescentSpeedMps: 3.6,
                maxFlightTimeMin: 30.0,
                maxHoverTimeMin: 25.0,
                maxWindResistanceMps: 14.0,
                batteryEnergyWh: 950.0,
                cameraLayoutKey: "drone.camera.single_compact",
                visualClass: .atlasProTriple,
                operationalCategory: .multirotor,
                airframeClass: .multirotor,
                airframeStyle: .multirotorQuad,
                fixedWingParameters: nil,
                launchMethod: .vertical,
                landingMethod: .vertical,
                controlResponsiveness: 0.62,
                hoverThrottle: 0.60,
                cameraPreset: DroneCameraPreset(fpvFov: 80.0, followDistance: 16.0, followHeight: 5.8),
                collisionRadiusMeters: 0.62,
                structuralQualityFactor: 1.25
            )
        case .wingtraOneGenII:
            return RuntimeTuning(
                fallbackTakeoffMass: 4.5,
                fallbackDimensions: DroneDimensionsMM(x: 1250, y: 940, z: 300),
                maxHorizontalSpeedMps: 26.0,
                maxAscentSpeedMps: 5.8,
                maxDescentSpeedMps: 7.0,
                maxFlightTimeMin: 59.0,
                maxHoverTimeMin: 0.0,
                maxWindResistanceMps: 14.0,
                batteryEnergyWh: 160.0,
                cameraLayoutKey: "drone.camera.fixed_front",
                visualClass: .wingtraClass,
                operationalCategory: .fixedWingVTOL,
                airframeClass: .hybridVTOL,
                airframeStyle: .tailsitterVTOL,
                fixedWingParameters: FixedWingParameters(
                    family: .tailsitterVTOL,
                    minSustainableSpeedMps: 11.8,
                    cruiseSpeedMps: 16.0,
                    climbSpeedMps: 14.2,
                    stallWarningSpeedMps: 10.8,
                    waypointAcceptanceRadiusMeters: 11.0,
                    nominalTurnRateDegPerSec: 12.5,
                    bankResponseGain: 0.86,
                    climbResponseGain: 0.72,
                    descentResponseGain: 0.62,
                    dragFactor: 0.98,
                    throttleResponseGain: 0.68,
                    turnAuthority: 0.68,
                    maxBankAngleDeg: 40.0,
                    preferredLaunchMode: .vtol,
                    initialClimbPitchDeg: 11.0,
                    initialClimbTargetAltitude: 16.0
                ),
                launchMethod: .vertical,
                landingMethod: .tailsitterVerticalLanding,
                controlResponsiveness: 0.62,
                hoverThrottle: 0.0,
                cameraPreset: DroneCameraPreset(fpvFov: 72.0, followDistance: 8.2, followHeight: 2.6),
                collisionRadiusMeters: 0.34,
                // Real tailsitter: props never tilt relative to the airframe
                // (buildWingtraOneGenII's leftMotor/rightMotor, both fixed
                // forward-facing) — the whole body pitches instead. Fixed
                // .cruiseProp units, mount offsets match the visual rig.
                propulsionUnitTemplate: [
                    .cruiseProp(id: "wingtra_prop_left", mountOffset: SIMD3<Float>(-0.29, 0.060, 0.14)),
                    .cruiseProp(id: "wingtra_prop_right", mountOffset: SIMD3<Float>(0.29, 0.060, 0.14))
                ],
                structuralQualityFactor: 1.1
            )
        case .quantumSystemsTrinityPro:
            return RuntimeTuning(
                fallbackTakeoffMass: 5.75,
                fallbackDimensions: DroneDimensionsMM(x: 2394, y: 1491, z: 320),
                maxHorizontalSpeedMps: 28.0,
                maxAscentSpeedMps: 5.4,
                maxDescentSpeedMps: 6.6,
                maxFlightTimeMin: 90.0,
                maxHoverTimeMin: 0.0,
                maxWindResistanceMps: 15.5,
                batteryEnergyWh: 198.0,
                cameraLayoutKey: "drone.camera.fixed_front",
                visualClass: .trinityClass,
                operationalCategory: .fixedWingVTOL,
                airframeClass: .hybridVTOL,
                airframeStyle: .surveyEVTOL,
                fixedWingParameters: FixedWingParameters(
                    family: .surveyEVTOL,
                    minSustainableSpeedMps: 12.5,
                    cruiseSpeedMps: 17.0,
                    climbSpeedMps: 15.0,
                    stallWarningSpeedMps: 11.4,
                    waypointAcceptanceRadiusMeters: 12.0,
                    nominalTurnRateDegPerSec: 11.8,
                    bankResponseGain: 0.82,
                    climbResponseGain: 0.68,
                    descentResponseGain: 0.60,
                    dragFactor: 1.00,
                    throttleResponseGain: 0.64,
                    turnAuthority: 0.60,
                    maxBankAngleDeg: 38.0,
                    preferredLaunchMode: .vtol,
                    initialClimbPitchDeg: 10.5,
                    initialClimbTargetAltitude: 18.0
                ),
                launchMethod: .vertical,
                landingMethod: .vertical,
                controlResponsiveness: 0.58,
                hoverThrottle: 0.0,
                cameraPreset: DroneCameraPreset(fpvFov: 70.0, followDistance: 9.4, followHeight: 3.0),
                collisionRadiusMeters: 0.44,
                // Trinity Pro renders through the same UAVVisualFactory rig as
                // Wingcopter 198 (buildQuantumSystemsTrinityPro, shared 4-pod
                // tiltPivot layout) — mirror its mount offsets exactly.
                propulsionUnitTemplate: [
                    .tiltRotor(id: "trinitypro_tilt_fl_upper", mountOffset: SIMD3<Float>(-0.52, 0.11, 0.12)),
                    .tiltRotor(id: "trinitypro_tilt_fl_lower", mountOffset: SIMD3<Float>(-0.52, 0.08, 0.12)),
                    .tiltRotor(id: "trinitypro_tilt_fr_upper", mountOffset: SIMD3<Float>(0.52, 0.11, 0.12)),
                    .tiltRotor(id: "trinitypro_tilt_fr_lower", mountOffset: SIMD3<Float>(0.52, 0.08, 0.12)),
                    .tiltRotor(id: "trinitypro_tilt_rl_upper", mountOffset: SIMD3<Float>(-0.52, 0.11, -0.14)),
                    .tiltRotor(id: "trinitypro_tilt_rl_lower", mountOffset: SIMD3<Float>(-0.52, 0.08, -0.14)),
                    .tiltRotor(id: "trinitypro_tilt_rr_upper", mountOffset: SIMD3<Float>(0.52, 0.11, -0.14)),
                    .tiltRotor(id: "trinitypro_tilt_rr_lower", mountOffset: SIMD3<Float>(0.52, 0.08, -0.14))
                ],
                structuralQualityFactor: 1.1
            )
        case .djiFlyCart30:
            return RuntimeTuning(
                fallbackTakeoffMass: 95.0,
                fallbackDimensions: DroneDimensionsMM(x: 2800, y: 3085, z: 947),
                maxHorizontalSpeedMps: 20.0,
                maxAscentSpeedMps: 4.0,
                maxDescentSpeedMps: 3.2,
                maxFlightTimeMin: 18.0,
                maxHoverTimeMin: 16.0,
                maxWindResistanceMps: 12.0,
                batteryEnergyWh: 7600.0,
                cameraLayoutKey: "drone.camera.single_compact",
                visualClass: .atlasProTriple,
                operationalCategory: .multirotor,
                airframeClass: .multirotor,
                airframeStyle: .multirotorQuad,
                fixedWingParameters: nil,
                launchMethod: .vertical,
                landingMethod: .vertical,
                controlResponsiveness: 0.52,
                hoverThrottle: 0.63,
                cameraPreset: DroneCameraPreset(fpvFov: 78.0, followDistance: 18.5, followHeight: 6.2),
                collisionRadiusMeters: 0.82,
                structuralQualityFactor: 1.2
            )
        case .griff30:
            return RuntimeTuning(
                fallbackTakeoffMass: 45.0,
                fallbackDimensions: DroneDimensionsMM(x: 2400, y: 2400, z: 900),
                maxHorizontalSpeedMps: 18.0,
                maxAscentSpeedMps: 4.0,
                maxDescentSpeedMps: 3.0,
                maxFlightTimeMin: 20.0,
                maxHoverTimeMin: 18.0,
                maxWindResistanceMps: 11.0,
                batteryEnergyWh: 5200.0,
                cameraLayoutKey: "drone.camera.single_compact",
                visualClass: .atlasProTriple,
                operationalCategory: .multirotor,
                airframeClass: .multirotor,
                airframeStyle: .multirotorQuad,
                fixedWingParameters: nil,
                launchMethod: .vertical,
                landingMethod: .vertical,
                controlResponsiveness: 0.54,
                hoverThrottle: 0.62,
                cameraPreset: DroneCameraPreset(fpvFov: 78.0, followDistance: 17.0, followHeight: 6.0),
                collisionRadiusMeters: 0.78,
                structuralQualityFactor: 1.2
            )
        case .griff60:
            return RuntimeTuning(
                fallbackTakeoffMass: 90.0,
                fallbackDimensions: DroneDimensionsMM(x: 3200, y: 3200, z: 1100),
                maxHorizontalSpeedMps: 16.0,
                maxAscentSpeedMps: 3.4,
                maxDescentSpeedMps: 2.8,
                maxFlightTimeMin: 14.0,
                maxHoverTimeMin: 12.0,
                maxWindResistanceMps: 10.0,
                batteryEnergyWh: 8200.0,
                cameraLayoutKey: "drone.camera.single_compact",
                visualClass: .atlasProTriple,
                operationalCategory: .multirotor,
                airframeClass: .multirotor,
                airframeStyle: .multirotorQuad,
                fixedWingParameters: nil,
                launchMethod: .vertical,
                landingMethod: .vertical,
                controlResponsiveness: 0.46,
                hoverThrottle: 0.66,
                cameraPreset: DroneCameraPreset(fpvFov: 76.0, followDistance: 21.0, followHeight: 7.4),
                collisionRadiusMeters: 0.96,
                structuralQualityFactor: 1.25
            )
        case .wildfireEmber40:
            return RuntimeTuning(
                fallbackTakeoffMass: 48.5,
                fallbackDimensions: DroneDimensionsMM(x: 2600, y: 2600, z: 950),
                maxHorizontalSpeedMps: 19.0,
                maxAscentSpeedMps: 4.2,
                maxDescentSpeedMps: 3.4,
                maxFlightTimeMin: 22.0,
                maxHoverTimeMin: 19.0,
                maxWindResistanceMps: 11.0,
                batteryEnergyWh: 3800.0,
                cameraLayoutKey: "drone.camera.single_compact",
                visualClass: .atlasProTriple,
                operationalCategory: .multirotor,
                airframeClass: .multirotor,
                airframeStyle: .multirotorQuad,
                fixedWingParameters: nil,
                launchMethod: .vertical,
                landingMethod: .vertical,
                controlResponsiveness: 0.58,
                hoverThrottle: 0.60,
                cameraPreset: DroneCameraPreset(fpvFov: 78.0, followDistance: 17.5, followHeight: 6.1),
                collisionRadiusMeters: 0.66,
                structuralQualityFactor: 1.2
            )
        case .pyroliftTalon60:
            return RuntimeTuning(
                fallbackTakeoffMass: 100.0,
                fallbackDimensions: DroneDimensionsMM(x: 3000, y: 3000, z: 1050),
                maxHorizontalSpeedMps: 19.0,
                maxAscentSpeedMps: 3.8,
                maxDescentSpeedMps: 3.0,
                maxFlightTimeMin: 16.0,
                maxHoverTimeMin: 14.0,
                maxWindResistanceMps: 12.0,
                batteryEnergyWh: 8000.0,
                cameraLayoutKey: "drone.camera.single_compact",
                visualClass: .atlasProTriple,
                operationalCategory: .multirotor,
                airframeClass: .multirotor,
                airframeStyle: .multirotorQuad,
                fixedWingParameters: nil,
                launchMethod: .vertical,
                landingMethod: .vertical,
                controlResponsiveness: 0.50,
                hoverThrottle: 0.64,
                cameraPreset: DroneCameraPreset(fpvFov: 77.0, followDistance: 19.5, followHeight: 6.8),
                collisionRadiusMeters: 0.86,
                structuralQualityFactor: 1.25
            )
        case .colossusCA8Vulcan:
            return RuntimeTuning(
                fallbackTakeoffMass: 325.0,
                fallbackDimensions: DroneDimensionsMM(x: 3600, y: 3600, z: 1300),
                maxHorizontalSpeedMps: 15.0,
                maxAscentSpeedMps: 3.0,
                maxDescentSpeedMps: 2.4,
                maxFlightTimeMin: 12.0,
                maxHoverTimeMin: 10.0,
                maxWindResistanceMps: 13.0,
                batteryEnergyWh: 14000.0,
                cameraLayoutKey: "drone.camera.single_compact",
                visualClass: .atlasProTriple,
                operationalCategory: .multirotor,
                airframeClass: .multirotor,
                airframeStyle: .multirotorQuad,
                fixedWingParameters: nil,
                launchMethod: .vertical,
                landingMethod: .vertical,
                controlResponsiveness: 0.42,
                hoverThrottle: 0.69,
                cameraPreset: DroneCameraPreset(fpvFov: 74.0, followDistance: 24.0, followHeight: 8.2),
                collisionRadiusMeters: 1.15,
                structuralQualityFactor: 1.3
            )
        case .colossusCA12Atlas:
            return RuntimeTuning(
                fallbackTakeoffMass: 445.0,
                fallbackDimensions: DroneDimensionsMM(x: 4200, y: 4200, z: 1500),
                maxHorizontalSpeedMps: 13.0,
                maxAscentSpeedMps: 2.6,
                maxDescentSpeedMps: 2.0,
                maxFlightTimeMin: 10.0,
                maxHoverTimeMin: 8.0,
                maxWindResistanceMps: 15.0,
                batteryEnergyWh: 19000.0,
                cameraLayoutKey: "drone.camera.single_compact",
                visualClass: .atlasProTriple,
                operationalCategory: .multirotor,
                airframeClass: .multirotor,
                airframeStyle: .multirotorQuad,
                fixedWingParameters: nil,
                launchMethod: .vertical,
                landingMethod: .vertical,
                controlResponsiveness: 0.36,
                hoverThrottle: 0.73,
                cameraPreset: DroneCameraPreset(fpvFov: 72.0, followDistance: 28.0, followHeight: 9.4),
                collisionRadiusMeters: 1.40,
                structuralQualityFactor: 1.35
            )
        case .agroWingTitanAT40:
            return RuntimeTuning(
                fallbackTakeoffMass: 150.0,
                fallbackDimensions: DroneDimensionsMM(x: 3400, y: 3400, z: 1150),
                maxHorizontalSpeedMps: 14.0,
                maxAscentSpeedMps: 3.2,
                maxDescentSpeedMps: 2.6,
                maxFlightTimeMin: 15.0,
                maxHoverTimeMin: 12.0,
                maxWindResistanceMps: 12.0,
                batteryEnergyWh: 15000.0,
                cameraLayoutKey: "drone.camera.single_compact",
                visualClass: .atlasProTriple,
                operationalCategory: .multirotor,
                airframeClass: .multirotor,
                airframeStyle: .multirotorQuad,
                fixedWingParameters: nil,
                launchMethod: .vertical,
                landingMethod: .vertical,
                controlResponsiveness: 0.44,
                hoverThrottle: 0.68,
                cameraPreset: DroneCameraPreset(fpvFov: 75.0, followDistance: 22.0, followHeight: 7.5),
                collisionRadiusMeters: 1.05,
                structuralQualityFactor: 1.1
            )
        case .avidrone490TL:
            return RuntimeTuning(
                fallbackTakeoffMass: 57.0,
                fallbackDimensions: DroneDimensionsMM(x: 1900, y: 900, z: 800),
                maxHorizontalSpeedMps: 19.0,
                maxAscentSpeedMps: 4.2,
                maxDescentSpeedMps: 3.5,
                maxFlightTimeMin: 28.0,
                maxHoverTimeMin: 24.0,
                maxWindResistanceMps: 10.0,
                batteryEnergyWh: 4200.0,
                cameraLayoutKey: "drone.camera.single_compact",
                visualClass: .atlasProTriple,
                operationalCategory: .multirotor,
                airframeClass: .multirotor,
                airframeStyle: .multirotorQuad,
                fixedWingParameters: nil,
                launchMethod: .vertical,
                landingMethod: .vertical,
                controlResponsiveness: 0.48,
                hoverThrottle: 0.60,
                cameraPreset: DroneCameraPreset(fpvFov: 76.0, followDistance: 15.5, followHeight: 5.6),
                collisionRadiusMeters: 0.70,
                structuralQualityFactor: 1.15
            )
        case .mq9bSkyGuardian:
            return RuntimeTuning(
                fallbackTakeoffMass: 5670.0,
                fallbackDimensions: DroneDimensionsMM(x: 24000, y: 11700, z: 3900),
                runtimeSceneDimensionsOverride: DroneDimensionsMM(x: 3200, y: 1900, z: 900),
                maxHorizontalSpeedMps: 108.0,
                maxAscentSpeedMps: 4.2,
                maxDescentSpeedMps: 5.5,
                maxFlightTimeMin: 2400.0,
                maxHoverTimeMin: 0.0,
                maxWindResistanceMps: 24.0,
                batteryEnergyWh: 45000.0,
                cameraLayoutKey: "drone.camera.fixed_front",
                visualClass: .fixedWingSwept,
                operationalCategory: .fixedWing,
                airframeClass: .fixedWing,
                airframeStyle: .conventionalFixedWing,
                fixedWingParameters: FixedWingParameters(
                    family: .swept,
                    minSustainableSpeedMps: 44.0,
                    cruiseSpeedMps: 90.0,
                    climbSpeedMps: 65.0,
                    stallWarningSpeedMps: 38.0,
                    waypointAcceptanceRadiusMeters: 28.0,
                    nominalTurnRateDegPerSec: 7.8,
                    bankResponseGain: 0.58,
                    climbResponseGain: 0.48,
                    descentResponseGain: 0.42,
                    dragFactor: 1.08,
                    throttleResponseGain: 0.52,
                    turnAuthority: 0.32,
                    maxBankAngleDeg: 28.0,
                    supportedLaunchModes: [.standard, .runway],
                    preferredLaunchMode: .runway,
                    takeoffRotationSpeed: 53.0,
                    initialClimbPitchDeg: 8.0,
                    maxInitialBankDeg: 10.0,
                    // Published ground roll, not a placeholder. This value now
                    // sizes the drafted strip, the preflight corridor and the
                    // runway sequence's own abort, so a figure the aircraft cannot
                    // achieve would abort every takeoff. Measured need: 656 m,
                    // which is the same over-delivery gap as this airframe's
                    // 72 %-of-declared climb — its thrust sizing, not the runway.
                    runwayTakeoffDistance: 520.0,
                    initialClimbTargetAltitude: 55.0
                ),
                launchMethod: .handLaunch,
                landingMethod: .bellyLanding,
                controlResponsiveness: 0.20,
                hoverThrottle: 0.0,
                cameraPreset: DroneCameraPreset(fpvFov: 54.0, followDistance: 10.8, followHeight: 3.6),
                collisionRadiusMeters: 0.58,
                structuralQualityFactor: 1.35
            )
        case .hermes900:
            return RuntimeTuning(
                fallbackTakeoffMass: 1180.0,
                fallbackDimensions: DroneDimensionsMM(x: 15000, y: 8500, z: 2600),
                runtimeSceneDimensionsOverride: DroneDimensionsMM(x: 2600, y: 1600, z: 820),
                maxHorizontalSpeedMps: 61.0,
                maxAscentSpeedMps: 4.0,
                maxDescentSpeedMps: 4.8,
                maxFlightTimeMin: 2160.0,
                maxHoverTimeMin: 0.0,
                maxWindResistanceMps: 20.0,
                batteryEnergyWh: 16000.0,
                cameraLayoutKey: "drone.camera.fixed_front",
                visualClass: .fixedWingRectangular,
                operationalCategory: .fixedWing,
                airframeClass: .fixedWing,
                airframeStyle: .conventionalFixedWing,
                fixedWingParameters: FixedWingParameters(
                    family: .conventionalSurvey,
                    minSustainableSpeedMps: 30.0,
                    cruiseSpeedMps: 50.0,
                    climbSpeedMps: 38.0,
                    stallWarningSpeedMps: 26.0,
                    waypointAcceptanceRadiusMeters: 18.0,
                    nominalTurnRateDegPerSec: 9.2,
                    bankResponseGain: 0.64,
                    climbResponseGain: 0.54,
                    descentResponseGain: 0.48,
                    dragFactor: 1.04,
                    throttleResponseGain: 0.58,
                    turnAuthority: 0.36,
                    maxBankAngleDeg: 30.0,
                    supportedLaunchModes: [.standard, .runway],
                    preferredLaunchMode: .runway,
                    takeoffRotationSpeed: 35.0,
                    initialClimbPitchDeg: 8.5,
                    maxInitialBankDeg: 11.0,
                    // Elbit quote a take-off run near this; measured need 317 m.
                    runwayTakeoffDistance: 350.0,
                    initialClimbTargetAltitude: 40.0
                ),
                launchMethod: .handLaunch,
                landingMethod: .bellyLanding,
                controlResponsiveness: 0.24,
                hoverThrottle: 0.0,
                cameraPreset: DroneCameraPreset(fpvFov: 56.0, followDistance: 9.4, followHeight: 3.0),
                collisionRadiusMeters: 0.52,
                structuralQualityFactor: 1.3
            )
        case .ft5Los:
            return RuntimeTuning(
                fallbackTakeoffMass: 85.0,
                fallbackDimensions: DroneDimensionsMM(x: 6400, y: 3100, z: 820),
                maxHorizontalSpeedMps: 50.0,
                maxAscentSpeedMps: 4.5,
                maxDescentSpeedMps: 5.0,
                maxFlightTimeMin: 600.0,
                maxHoverTimeMin: 0.0,
                maxWindResistanceMps: 16.0,
                batteryEnergyWh: 2200.0,
                cameraLayoutKey: "drone.camera.fixed_front",
                visualClass: .fixedWingRectangular,
                operationalCategory: .fixedWing,
                airframeClass: .fixedWing,
                airframeStyle: .conventionalFixedWing,
                fixedWingParameters: FixedWingParameters(
                    family: .conventionalSurvey,
                    minSustainableSpeedMps: 22.0,
                    cruiseSpeedMps: 38.0,
                    climbSpeedMps: 29.0,
                    stallWarningSpeedMps: 19.0,
                    waypointAcceptanceRadiusMeters: 15.0,
                    nominalTurnRateDegPerSec: 10.4,
                    bankResponseGain: 0.70,
                    climbResponseGain: 0.60,
                    descentResponseGain: 0.52,
                    dragFactor: 1.02,
                    throttleResponseGain: 0.62,
                    turnAuthority: 0.48,
                    maxBankAngleDeg: 34.0,
                    supportedLaunchModes: [.catapult],
                    preferredLaunchMode: .catapult,
                    initialClimbPitchDeg: 10.0,
                    maxInitialBankDeg: 13.0,
                    catapultExitSpeed: 29.0,
                    initialClimbTargetAltitude: 24.0
                ),
                launchMethod: .handLaunch,
                landingMethod: .linearBellyLanding,
                controlResponsiveness: 0.40,
                hoverThrottle: 0.0,
                cameraPreset: DroneCameraPreset(fpvFov: 64.0, followDistance: 8.0, followHeight: 2.5),
                collisionRadiusMeters: 0.42,
                structuralQualityFactor: 1.05
            )
        case .lightFixedWingSurvey:
            return RuntimeTuning(
                fallbackTakeoffMass: 12.0,
                fallbackDimensions: DroneDimensionsMM(x: 3600, y: 1800, z: 420),
                maxHorizontalSpeedMps: 44.0,
                maxAscentSpeedMps: 4.5,
                maxDescentSpeedMps: 4.2,
                maxFlightTimeMin: 240.0,
                maxHoverTimeMin: 0.0,
                maxWindResistanceMps: 14.0,
                batteryEnergyWh: 680.0,
                cameraLayoutKey: "drone.camera.fixed_front",
                visualClass: .fixedWingRectangular,
                operationalCategory: .fixedWing,
                airframeClass: .fixedWing,
                airframeStyle: .conventionalFixedWing,
                fixedWingParameters: FixedWingParameters(
                    family: .conventionalSurvey,
                    minSustainableSpeedMps: 18.0,
                    cruiseSpeedMps: 30.0,
                    climbSpeedMps: 24.0,
                    stallWarningSpeedMps: 15.5,
                    waypointAcceptanceRadiusMeters: 13.0,
                    nominalTurnRateDegPerSec: 11.0,
                    bankResponseGain: 0.76,
                    climbResponseGain: 0.66,
                    descentResponseGain: 0.56,
                    dragFactor: 1.00,
                    throttleResponseGain: 0.64,
                    turnAuthority: 0.56,
                    maxBankAngleDeg: 36.0,
                    supportedLaunchModes: [.handLaunch],
                    preferredLaunchMode: .handLaunch,
                    initialClimbPitchDeg: 11.0,
                    maxInitialBankDeg: 15.0,
                    handThrowSpeed: 22.0,
                    initialClimbTargetAltitude: 18.0
                ),
                launchMethod: .handLaunch,
                landingMethod: .bellyLanding,
                controlResponsiveness: 0.52,
                hoverThrottle: 0.0,
                cameraPreset: DroneCameraPreset(fpvFov: 68.0, followDistance: 6.2, followHeight: 1.9),
                collisionRadiusMeters: 0.28,
                structuralQualityFactor: 0.85
            )
        // MARK: Fuel-burning and research airframes
        //
        // `batteryEnergyWh` on these is the same runtime energy-store analogue
        // the existing MQ-9B and Hermes 900 entries already use — it is NOT the
        // aircraft's fuel energy, which is orders of magnitude larger and lives
        // on `UAVPowerplantSpec.fuel` in the catalogue instead. Endurance is
        // driven by `maxFlightTimeMin` (see BatteryThermalSimulationService,
        // where the Wh figure cancels out of the drain rate), so these values
        // are scaled to stay consistent with the rest of the fleet's displayed
        // power draw rather than being invented independently.
        case .aerosondeMk47:
            return fixedWingRuntimeTuning(
                fallbackTakeoffMass: 36.3,
                fallbackDimensions: DroneDimensionsMM(x: 3600, y: 1900, z: 500),
                maxHorizontalSpeedMps: 41.0,
                maxAscentSpeedMps: 3.0,
                maxDescentSpeedMps: 4.0,
                maxFlightTimeMin: 840.0,
                maxWindResistanceMps: 12.0,
                batteryEnergyWh: 1600.0,
                visualClass: .fixedWingRectangular,
                controlResponsiveness: 0.46,
                cameraPreset: DroneCameraPreset(fpvFov: 66.0, followDistance: 7.0, followHeight: 2.2),
                collisionRadiusMeters: 0.34,
                fixedWingParameters: FixedWingParameters(
                    family: .conventionalSurvey,
                    minSustainableSpeedMps: 18.0,
                    cruiseSpeedMps: 28.0,
                    climbSpeedMps: 22.0,
                    stallWarningSpeedMps: 15.5,
                    waypointAcceptanceRadiusMeters: 14.0,
                    nominalTurnRateDegPerSec: 11.0,
                    bankResponseGain: 0.74,
                    climbResponseGain: 0.62,
                    descentResponseGain: 0.54,
                    dragFactor: 1.00,
                    throttleResponseGain: 0.60,
                    turnAuthority: 0.52,
                    maxBankAngleDeg: 35.0,
                    supportedLaunchModes: [.catapult],
                    preferredLaunchMode: .catapult,
                    maxAirspeed: 41.0,
                    nominalClimbRateMps: 2.6,
                    initialClimbPitchDeg: 10.0,
                    maxInitialBankDeg: 13.0,
                    catapultExitSpeed: 25.0,
                    initialClimbTargetAltitude: 22.0
                ),
                structuralQualityFactor: 0.95
            )
        case .rq7bShadow:
            return fixedWingRuntimeTuning(
                fallbackTakeoffMass: 170.0,
                fallbackDimensions: DroneDimensionsMM(x: 4270, y: 3410, z: 1000),
                maxHorizontalSpeedMps: 54.0,
                maxAscentSpeedMps: 3.5,
                maxDescentSpeedMps: 4.2,
                maxFlightTimeMin: 420.0,
                maxWindResistanceMps: 14.0,
                batteryEnergyWh: 3000.0,
                visualClass: .fixedWingRectangular,
                landingMethod: .linearBellyLanding,
                controlResponsiveness: 0.42,
                cameraPreset: DroneCameraPreset(fpvFov: 62.0, followDistance: 8.5, followHeight: 2.7),
                collisionRadiusMeters: 0.42,
                fixedWingParameters: FixedWingParameters(
                    family: .conventionalSurvey,
                    minSustainableSpeedMps: 25.0,
                    cruiseSpeedMps: 31.0,
                    climbSpeedMps: 27.0,
                    stallWarningSpeedMps: 21.5,
                    waypointAcceptanceRadiusMeters: 16.0,
                    nominalTurnRateDegPerSec: 10.0,
                    bankResponseGain: 0.70,
                    climbResponseGain: 0.58,
                    descentResponseGain: 0.50,
                    dragFactor: 1.02,
                    throttleResponseGain: 0.58,
                    turnAuthority: 0.46,
                    maxBankAngleDeg: 33.0,
                    supportedLaunchModes: [.catapult],
                    preferredLaunchMode: .catapult,
                    maxAirspeed: 54.0,
                    nominalClimbRateMps: 3.0,
                    initialClimbPitchDeg: 10.0,
                    maxInitialBankDeg: 12.0,
                    catapultExitSpeed: 32.0,
                    initialClimbTargetAltitude: 26.0
                ),
                structuralQualityFactor: 1.05
            )
        // Harpy: tailless delta, no canard. Small span on a heavy body gives a
        // markedly higher stall and cruise than the survey wings above.
        case .deltaLoiteringMunition:
            return fixedWingRuntimeTuning(
                fallbackTakeoffMass: 135.0,
                fallbackDimensions: DroneDimensionsMM(x: 2100, y: 2700, z: 550),
                maxHorizontalSpeedMps: 51.0,
                maxAscentSpeedMps: 4.0,
                maxDescentSpeedMps: 5.5,
                maxFlightTimeMin: 150.0,
                maxWindResistanceMps: 16.0,
                batteryEnergyWh: 950.0,
                visualClass: .fixedWingDelta,
                airframeStyle: .flyingWing,
                landingMethod: .bellyLanding,
                controlResponsiveness: 0.44,
                cameraPreset: DroneCameraPreset(fpvFov: 60.0, followDistance: 7.6, followHeight: 2.4),
                collisionRadiusMeters: 0.36,
                fixedWingParameters: FixedWingParameters(
                    family: .delta,
                    minSustainableSpeedMps: 30.0,
                    cruiseSpeedMps: 40.0,
                    climbSpeedMps: 35.0,
                    stallWarningSpeedMps: 26.0,
                    waypointAcceptanceRadiusMeters: 18.0,
                    nominalTurnRateDegPerSec: 12.0,
                    bankResponseGain: 0.68,
                    climbResponseGain: 0.56,
                    descentResponseGain: 0.52,
                    dragFactor: 1.04,
                    throttleResponseGain: 0.62,
                    turnAuthority: 0.44,
                    maxBankAngleDeg: 38.0,
                    supportedLaunchModes: [.canister],
                    preferredLaunchMode: .canister,
                    maxAirspeed: 51.0,
                    nominalClimbRateMps: 3.4,
                    initialClimbPitchDeg: 11.0,
                    maxInitialBankDeg: 14.0,
                    initialClimbTargetAltitude: 28.0
                ),
                structuralQualityFactor: 1.00
            )
        // Harop / Harpy NG: same delta with forward canards, a longer-endurance
        // installation and a higher dash speed.
        case .canardDeltaLoiteringMunition:
            return fixedWingRuntimeTuning(
                fallbackTakeoffMass: 135.0,
                fallbackDimensions: DroneDimensionsMM(x: 3000, y: 2500, z: 600),
                maxHorizontalSpeedMps: 116.0,
                maxAscentSpeedMps: 4.5,
                maxDescentSpeedMps: 6.0,
                maxFlightTimeMin: 360.0,
                maxWindResistanceMps: 16.0,
                batteryEnergyWh: 2200.0,
                visualClass: .fixedWingDelta,
                airframeStyle: .flyingWing,
                landingMethod: .bellyLanding,
                controlResponsiveness: 0.46,
                cameraPreset: DroneCameraPreset(fpvFov: 60.0, followDistance: 7.8, followHeight: 2.4),
                collisionRadiusMeters: 0.36,
                fixedWingParameters: FixedWingParameters(
                    family: .delta,
                    minSustainableSpeedMps: 27.0,
                    cruiseSpeedMps: 42.0,
                    climbSpeedMps: 36.0,
                    stallWarningSpeedMps: 23.5,
                    waypointAcceptanceRadiusMeters: 18.0,
                    nominalTurnRateDegPerSec: 13.0,
                    bankResponseGain: 0.72,
                    climbResponseGain: 0.60,
                    descentResponseGain: 0.54,
                    dragFactor: 1.02,
                    throttleResponseGain: 0.64,
                    turnAuthority: 0.50,
                    maxBankAngleDeg: 40.0,
                    supportedLaunchModes: [.canister],
                    preferredLaunchMode: .canister,
                    maxAirspeed: 116.0,
                    nominalClimbRateMps: 4.0,
                    initialClimbPitchDeg: 12.0,
                    maxInitialBankDeg: 15.0,
                    initialClimbTargetAltitude: 30.0
                ),
                structuralQualityFactor: 1.00
            )
        case .researchDeltaWing:
            return fixedWingRuntimeTuning(
                fallbackTakeoffMass: 2.6,
                fallbackDimensions: DroneDimensionsMM(x: 1245, y: 780, z: 220),
                maxHorizontalSpeedMps: 26.0,
                maxAscentSpeedMps: 4.0,
                maxDescentSpeedMps: 3.8,
                maxFlightTimeMin: 40.0,
                maxWindResistanceMps: 10.0,
                batteryEnergyWh: 96.0,
                visualClass: .fixedWingDelta,
                airframeStyle: .flyingWing,
                controlResponsiveness: 0.62,
                cameraPreset: DroneCameraPreset(fpvFov: 74.0, followDistance: 4.6, followHeight: 1.5),
                collisionRadiusMeters: 0.20,
                fixedWingParameters: FixedWingParameters(
                    family: .delta,
                    minSustainableSpeedMps: 12.0,
                    cruiseSpeedMps: 18.0,
                    climbSpeedMps: 15.0,
                    stallWarningSpeedMps: 10.5,
                    waypointAcceptanceRadiusMeters: 8.0,
                    nominalTurnRateDegPerSec: 16.0,
                    bankResponseGain: 0.82,
                    climbResponseGain: 0.70,
                    descentResponseGain: 0.60,
                    dragFactor: 0.98,
                    throttleResponseGain: 0.70,
                    turnAuthority: 0.66,
                    maxBankAngleDeg: 42.0,
                    supportedLaunchModes: [.handLaunch],
                    preferredLaunchMode: .handLaunch,
                    maxAirspeed: 26.0,
                    nominalClimbRateMps: 2.6,
                    initialClimbPitchDeg: 12.0,
                    maxInitialBankDeg: 16.0,
                    handThrowSpeed: 15.0,
                    initialClimbTargetAltitude: 16.0
                ),
                structuralQualityFactor: 0.70
            )
        // NC State / NASA BWB DELTA: dolly-launched, skid-recovered mini-turbojet
        // testbed. No landing gear on the real aircraft, hence belly landing.
        case .blendedWingBodyTestbed:
            return fixedWingRuntimeTuning(
                fallbackTakeoffMass: 19.05,
                fallbackDimensions: DroneDimensionsMM(x: 2859, y: 1473, z: 450),
                maxHorizontalSpeedMps: 48.0,
                maxAscentSpeedMps: 5.5,
                maxDescentSpeedMps: 5.0,
                maxFlightTimeMin: 12.0,
                maxWindResistanceMps: 11.0,
                batteryEnergyWh: 500.0,
                visualClass: .fixedWingDelta,
                airframeStyle: .flyingWing,
                controlResponsiveness: 0.58,
                cameraPreset: DroneCameraPreset(fpvFov: 70.0, followDistance: 6.4, followHeight: 2.0),
                collisionRadiusMeters: 0.30,
                fixedWingParameters: FixedWingParameters(
                    family: .flyingWing,
                    minSustainableSpeedMps: 13.4,
                    cruiseSpeedMps: 35.7,
                    climbSpeedMps: 24.0,
                    stallWarningSpeedMps: 11.5,
                    waypointAcceptanceRadiusMeters: 12.0,
                    nominalTurnRateDegPerSec: 14.0,
                    bankResponseGain: 0.78,
                    climbResponseGain: 0.66,
                    descentResponseGain: 0.58,
                    dragFactor: 0.96,
                    throttleResponseGain: 0.72,
                    turnAuthority: 0.60,
                    maxBankAngleDeg: 40.0,
                    supportedLaunchModes: [.standard, .runway],
                    preferredLaunchMode: .runway,
                    maxAirspeed: 48.0,
                    nominalClimbRateMps: 5.0,
                    takeoffRotationSpeed: 15.0,
                    initialClimbPitchDeg: 12.0,
                    maxInitialBankDeg: 15.0,
                    runwayTakeoffDistance: 60.0,
                    initialClimbTargetAltitude: 20.0
                ),
                structuralQualityFactor: 0.80
            )
        // HESA Karrar: turbojet cropped delta, launched off an inclined rail on a
        // trailer by a solid booster and recovered by parachute. It has no
        // undercarriage and never rolls, so it is not a runway aircraft — the
        // `.runway` support it used to declare was a stand-in from before the rail
        // could be flown, and it made the flight model give a rocket-launched
        // target drone tyres.
        case .jetTargetDrone:
            return fixedWingRuntimeTuning(
                fallbackTakeoffMass: 700.0,
                fallbackDimensions: DroneDimensionsMM(x: 2500, y: 4000, z: 950),
                maxHorizontalSpeedMps: 250.0,
                maxAscentSpeedMps: 18.0,
                maxDescentSpeedMps: 16.0,
                maxFlightTimeMin: 60.0,
                maxWindResistanceMps: 24.0,
                batteryEnergyWh: 5200.0,
                visualClass: .fixedWingDelta,
                landingMethod: .bellyLanding,
                controlResponsiveness: 0.34,
                cameraPreset: DroneCameraPreset(fpvFov: 56.0, followDistance: 11.0, followHeight: 3.4),
                collisionRadiusMeters: 0.50,
                fixedWingParameters: FixedWingParameters(
                    family: .delta,
                    minSustainableSpeedMps: 63.0,
                    cruiseSpeedMps: 170.0,
                    climbSpeedMps: 110.0,
                    stallWarningSpeedMps: 55.0,
                    waypointAcceptanceRadiusMeters: 40.0,
                    nominalTurnRateDegPerSec: 9.0,
                    bankResponseGain: 0.62,
                    climbResponseGain: 0.54,
                    descentResponseGain: 0.50,
                    dragFactor: 1.10,
                    throttleResponseGain: 0.46,
                    turnAuthority: 0.36,
                    maxBankAngleDeg: 45.0,
                    supportedLaunchModes: [.catapult],
                    preferredLaunchMode: .catapult,
                    maxAirspeed: 250.0,
                    nominalClimbRateMps: 18.0,
                    initialClimbPitchDeg: 12.0,
                    maxInitialBankDeg: 14.0,
                    // Nine metres of rail and a booster that pulls it to flying
                    // speed on the way up it — the published launchers for this
                    // class are short, steep and violent.
                    catapultRailAngleDegrees: 15.0,
                    catapultRailLengthMeters: 9.0,
                    // 14 g. The rail only has to get it moving — the bottle goes on
                    // burning in the air until the aircraft has flying speed, the
                    // same way a canister booster does.
                    maxCatapultAccelerationG: 14.0,
                    catapultUsesRocketBooster: true,
                    runwayTakeoffDistance: 420.0,
                    initialClimbTargetAltitude: 90.0
                ),
                structuralQualityFactor: 1.20
            )

        // MARK: Supersonic reference aircraft
        //
        // Stall speeds here are doing more work than they look like they are. The
        // aerodynamic model calibrates each airframe's wing *area* from its stall speed
        // and mass rather than from a guessed aspect ratio, so `minSustainableSpeedMps`
        // is where the wing comes from. Every one below was chosen by working backwards
        // from the planform: the Firebee II's 75 m/s yields 2.6 m² against a 2.94 m span,
        // and the X-10's 63 m/s yields 39.5 m² — which is its *published* wing area, and
        // therefore a genuine cross-check rather than a fit.

        case .bqm34fFirebeeII:
            return fixedWingRuntimeTuning(
                fallbackTakeoffMass: 951.0,
                fallbackDimensions: DroneDimensionsMM(x: 2940, y: 8890, z: 1710),
                maxHorizontalSpeedMps: 525.0,
                maxAscentSpeedMps: 55.0,
                maxDescentSpeedMps: 40.0,
                maxFlightTimeMin: 73.0,
                maxWindResistanceMps: 30.0,
                batteryEnergyWh: 6400.0,
                visualClass: .fixedWingDelta,
                landingMethod: .bellyLanding,
                controlResponsiveness: 0.42,
                cameraPreset: DroneCameraPreset(fpvFov: 58.0, followDistance: 22.0, followHeight: 5.5),
                collisionRadiusMeters: 0.70,
                fixedWingParameters: FixedWingParameters(
                    family: .supersonicCruciform,
                    minSustainableSpeedMps: 75.0,
                    cruiseSpeedMps: 240.0,
                    climbSpeedMps: 200.0,
                    stallWarningSpeedMps: 68.0,
                    waypointAcceptanceRadiusMeters: 120.0,
                    nominalTurnRateDegPerSec: 6.0,
                    bankResponseGain: 0.68,
                    climbResponseGain: 0.58,
                    descentResponseGain: 0.54,
                    dragFactor: 1.04,
                    throttleResponseGain: 0.42,
                    turnAuthority: 0.42,
                    maxBankAngleDeg: 60.0,
                    // Both real launch methods. The rail is the RATO ground launch, which
                    // is a rocket bottle rather than a catapult shuttle — the same
                    // distinction the Karrar already draws.
                    supportedLaunchModes: [.airLaunch, .catapult],
                    preferredLaunchMode: .airLaunch,
                    maxAirspeed: 525.0,
                    nominalClimbRateMps: 45.0,
                    initialClimbPitchDeg: 14.0,
                    maxInitialBankDeg: 16.0,
                    catapultRailAngleDegrees: 15.0,
                    catapultRailLengthMeters: 12.0,
                    maxCatapultAccelerationG: 16.0,
                    catapultUsesRocketBooster: true,
                    runwayTakeoffDistance: 900.0,
                    initialClimbTargetAltitude: 400.0,
                    // A DC-130 carries it at around 10 km and 150 m/s.
                    airLaunchReleaseAltitude: 10_000.0,
                    airLaunchReleaseSpeed: 150.0
                ),
                structuralQualityFactor: 1.45,
                skinMaterial: .aluminium
            )

        case .aqm35TargetDrone:
            return fixedWingRuntimeTuning(
                fallbackTakeoffMass: 900.0,
                fallbackDimensions: DroneDimensionsMM(x: 3380, y: 10060, z: 1690),
                maxHorizontalSpeedMps: 457.0,
                maxAscentSpeedMps: 60.0,
                maxDescentSpeedMps: 45.0,
                maxFlightTimeMin: 30.0,
                maxWindResistanceMps: 30.0,
                batteryEnergyWh: 5600.0,
                visualClass: .fixedWingDelta,
                landingMethod: .bellyLanding,
                controlResponsiveness: 0.40,
                cameraPreset: DroneCameraPreset(fpvFov: 58.0, followDistance: 24.0, followHeight: 6.0),
                collisionRadiusMeters: 0.72,
                fixedWingParameters: FixedWingParameters(
                    family: .supersonicCruciform,
                    minSustainableSpeedMps: 72.0,
                    cruiseSpeedMps: 230.0,
                    climbSpeedMps: 195.0,
                    stallWarningSpeedMps: 65.0,
                    waypointAcceptanceRadiusMeters: 120.0,
                    nominalTurnRateDegPerSec: 5.5,
                    bankResponseGain: 0.66,
                    climbResponseGain: 0.56,
                    descentResponseGain: 0.52,
                    dragFactor: 1.05,
                    throttleResponseGain: 0.40,
                    turnAuthority: 0.40,
                    maxBankAngleDeg: 58.0,
                    // Ground launch was designed and never tested, so it is not offered.
                    supportedLaunchModes: [.airLaunch],
                    preferredLaunchMode: .airLaunch,
                    maxAirspeed: 457.0,
                    nominalClimbRateMps: 48.0,
                    initialClimbPitchDeg: 14.0,
                    maxInitialBankDeg: 15.0,
                    initialClimbTargetAltitude: 400.0,
                    airLaunchReleaseAltitude: 10_500.0,
                    airLaunchReleaseSpeed: 145.0
                ),
                structuralQualityFactor: 1.40,
                skinMaterial: .aluminium
            )

        case .rockwellHiMAT:
            return fixedWingRuntimeTuning(
                fallbackTakeoffMass: 1588.0,
                fallbackDimensions: DroneDimensionsMM(x: 4750, y: 6860, z: 1310),
                maxHorizontalSpeedMps: 413.0,
                maxAscentSpeedMps: 90.0,
                maxDescentSpeedMps: 60.0,
                maxFlightTimeMin: 30.0,
                maxWindResistanceMps: 28.0,
                batteryEnergyWh: 7200.0,
                visualClass: .fixedWingDelta,
                landingMethod: .bellyLanding,
                controlResponsiveness: 0.62,
                cameraPreset: DroneCameraPreset(fpvFov: 62.0, followDistance: 18.0, followHeight: 4.6),
                collisionRadiusMeters: 0.62,
                fixedWingParameters: FixedWingParameters(
                    family: .canardDelta,
                    minSustainableSpeedMps: 50.0,
                    cruiseSpeedMps: 260.0,
                    climbSpeedMps: 210.0,
                    stallWarningSpeedMps: 45.0,
                    waypointAcceptanceRadiusMeters: 90.0,
                    nominalTurnRateDegPerSec: 14.0,
                    bankResponseGain: 0.92,
                    climbResponseGain: 0.82,
                    descentResponseGain: 0.74,
                    dragFactor: 0.98,
                    throttleResponseGain: 0.62,
                    turnAuthority: 0.88,
                    // Built to hold 8 g. A 60° bank limit would make that unreachable and
                    // would quietly delete the aircraft's entire reason for existing.
                    maxBankAngleDeg: 80.0,
                    supportedLaunchModes: [.airLaunch],
                    preferredLaunchMode: .airLaunch,
                    maxAirspeed: 413.0,
                    nominalClimbRateMps: 75.0,
                    initialClimbPitchDeg: 16.0,
                    maxInitialBankDeg: 25.0,
                    initialClimbTargetAltitude: 300.0,
                    // The NB-52B drop point: 13,700 m at Mach 0.68.
                    airLaunchReleaseAltitude: 13_700.0,
                    airLaunchReleaseSpeed: 201.0
                ),
                structuralQualityFactor: 1.75,
                // Graphite and fibreglass wings with aeroelastic tailoring — one of the
                // technologies the programme existed to demonstrate.
                skinMaterial: .composite
            )

        case .hermeusQuarterhorse:
            return fixedWingRuntimeTuning(
                fallbackTakeoffMass: 11000.0,
                fallbackDimensions: DroneDimensionsMM(x: 8400, y: 15200, z: 3600),
                maxHorizontalSpeedMps: 738.0,
                maxAscentSpeedMps: 130.0,
                maxDescentSpeedMps: 80.0,
                maxFlightTimeMin: 45.0,
                maxWindResistanceMps: 32.0,
                batteryEnergyWh: 24000.0,
                visualClass: .fixedWingDelta,
                launchMethod: .runway,
                landingMethod: .bellyLanding,
                controlResponsiveness: 0.55,
                cameraPreset: DroneCameraPreset(fpvFov: 60.0, followDistance: 34.0, followHeight: 8.5),
                collisionRadiusMeters: 1.10,
                fixedWingParameters: FixedWingParameters(
                    family: .supersonicDelta,
                    minSustainableSpeedMps: 75.0,
                    cruiseSpeedMps: 420.0,
                    climbSpeedMps: 300.0,
                    stallWarningSpeedMps: 68.0,
                    waypointAcceptanceRadiusMeters: 200.0,
                    nominalTurnRateDegPerSec: 8.0,
                    bankResponseGain: 0.80,
                    climbResponseGain: 0.72,
                    descentResponseGain: 0.64,
                    dragFactor: 0.96,
                    throttleResponseGain: 0.58,
                    turnAuthority: 0.62,
                    maxBankAngleDeg: 70.0,
                    supportedLaunchModes: [.standard, .runway],
                    preferredLaunchMode: .runway,
                    // The Mach 2.5 the Mk 2 series is built for, not the Mach 1.21 the
                    // aircraft has flown so far. This is a limit, and a limit describes
                    // the airframe rather than the test programme's progress through it.
                    maxAirspeed: 738.0,
                    // 80 m/s, not the 110 first written. Nobody publishes this aircraft's
                    // climb rate, so the first figure was an aspiration; the climb probe
                    // measured 79 m/s from its published thrust against its own drag, and
                    // a declared figure the airframe cannot deliver is worse than no
                    // figure at all — every consumer of it would be planning on fiction.
                    nominalClimbRateMps: 80.0,
                    takeoffRotationSpeed: 82.0,
                    initialClimbPitchDeg: 14.0,
                    maxInitialBankDeg: 12.0,
                    runwayTakeoffDistance: 1400.0,
                    initialClimbTargetAltitude: 300.0
                ),
                structuralQualityFactor: 1.85,
                skinMaterial: .titanium
            )

        case .northAmericanX10:
            return fixedWingRuntimeTuning(
                fallbackTakeoffMass: 15876.0,
                fallbackDimensions: DroneDimensionsMM(x: 8590, y: 20170, z: 4400),
                maxHorizontalSpeedMps: 580.0,
                maxAscentSpeedMps: 26.5,
                maxDescentSpeedMps: 50.0,
                maxFlightTimeMin: 30.0,
                maxWindResistanceMps: 32.0,
                batteryEnergyWh: 30000.0,
                visualClass: .fixedWingDelta,
                launchMethod: .runway,
                landingMethod: .bellyLanding,
                controlResponsiveness: 0.36,
                cameraPreset: DroneCameraPreset(fpvFov: 58.0, followDistance: 42.0, followHeight: 10.0),
                collisionRadiusMeters: 1.30,
                fixedWingParameters: FixedWingParameters(
                    family: .canardDelta,
                    // 69 m/s is not a guess: it is the stall speed at which the model's
                    // calibrated wing area comes out at the X-10's published 39.5 m².
                    //
                    // It was 63 first, derived against the 15,876 kg *gross* weight — and
                    // the acceptance probe reported 47.7 m², twenty per cent out. The
                    // runtime flies the aircraft at its 19,187 kg *maximum*, which is the
                    // mass the calibration actually sees. Reading the wrong one of two
                    // published weights is a quiet error and it took a published wing area
                    // to catch it.
                    minSustainableSpeedMps: 69.0,
                    cruiseSpeedMps: 420.0,
                    climbSpeedMps: 260.0,
                    stallWarningSpeedMps: 57.0,
                    waypointAcceptanceRadiusMeters: 220.0,
                    nominalTurnRateDegPerSec: 5.0,
                    bankResponseGain: 0.58,
                    climbResponseGain: 0.50,
                    descentResponseGain: 0.46,
                    dragFactor: 1.02,
                    throttleResponseGain: 0.40,
                    turnAuthority: 0.38,
                    maxBankAngleDeg: 60.0,
                    supportedLaunchModes: [.standard, .runway],
                    preferredLaunchMode: .runway,
                    maxAirspeed: 580.0,
                    // The published 5,224 ft/min.
                    nominalClimbRateMps: 26.5,
                    takeoffRotationSpeed: 78.0,
                    initialClimbPitchDeg: 10.0,
                    maxInitialBankDeg: 10.0,
                    runwayTakeoffDistance: 1300.0,
                    initialClimbTargetAltitude: 250.0
                ),
                structuralQualityFactor: 1.60,
                skinMaterial: .aluminium
            )
        }
    }

    private static func runtimeTuningOverride(
        for uavProfile: UAVProfile
    ) -> RuntimeTuning? {
        switch uavProfile.id {
        // The FPV class shares one airframe model; everything that separates a whoop from an
        // open-class machine is here rather than in the geometry.
        case "fpv-tiny-whoop-65":
            return fpvClassTuning(
                takeoffMass: 0.035,
                dimensions: DroneDimensionsMM(x: 98, y: 98, z: 42),
                maxHorizontalSpeedMps: 13.0,
                maxAscentSpeedMps: 6.0,
                maxDescentSpeedMps: 5.0,
                maxFlightTimeMin: 3.6,
                maxWindResistanceMps: 4.0,
                batteryEnergyWh: 1.7,
                controlResponsiveness: 1.0,
                hoverThrottle: 0.30,
                fpvFov: 100.0,
                collisionRadiusMeters: 0.055,
                structuralQualityFactor: 0.45
            )
        case "fpv-micro-racer-25":
            return fpvClassTuning(
                takeoffMass: 0.145,
                dimensions: DroneDimensionsMM(x: 145, y: 145, z: 46),
                maxHorizontalSpeedMps: 26.0,
                maxAscentSpeedMps: 12.0,
                maxDescentSpeedMps: 10.0,
                maxFlightTimeMin: 4.4,
                maxWindResistanceMps: 7.0,
                batteryEnergyWh: 8.4,
                controlResponsiveness: 1.0,
                hoverThrottle: 0.25,
                fpvFov: 104.0,
                collisionRadiusMeters: 0.09,
                structuralQualityFactor: 0.50
            )
        case "fpv-spec-5":
            return fpvClassTuning(
                takeoffMass: 0.740,
                dimensions: DroneDimensionsMM(x: 250, y: 250, z: 62),
                // Spec class exists to cap exactly this number: same airframe, rule-limited motor
                // and prop, so the racing is decided by the pilot.
                maxHorizontalSpeedMps: 32.0,
                maxAscentSpeedMps: 13.0,
                maxDescentSpeedMps: 12.0,
                maxFlightTimeMin: 4.2,
                maxWindResistanceMps: 12.0,
                batteryEnergyWh: 24.4,
                controlResponsiveness: 0.98,
                hoverThrottle: 0.26,
                fpvFov: 106.0,
                collisionRadiusMeters: 0.16,
                structuralQualityFactor: 0.58
            )
        case "fpv-long-range-7":
            return fpvClassTuning(
                takeoffMass: 1.150,
                dimensions: DroneDimensionsMM(x: 340, y: 340, z: 78),
                maxHorizontalSpeedMps: 30.0,
                maxAscentSpeedMps: 10.0,
                maxDescentSpeedMps: 9.0,
                maxFlightTimeMin: 17.0,
                maxWindResistanceMps: 13.0,
                batteryEnergyWh: 88.8,
                controlResponsiveness: 0.94,
                hoverThrottle: 0.30,
                fpvFov: 100.0,
                collisionRadiusMeters: 0.21,
                structuralQualityFactor: 0.62
            )
        case "fpv-open-class":
            return fpvClassTuning(
                takeoffMass: 2.600,
                dimensions: DroneDimensionsMM(x: 480, y: 480, z: 115),
                maxHorizontalSpeedMps: 48.0,
                maxAscentSpeedMps: 18.0,
                maxDescentSpeedMps: 15.0,
                maxFlightTimeMin: 6.0,
                maxWindResistanceMps: 15.0,
                batteryEnergyWh: 178.0,
                // Still a rate machine, but four times the mass of a five-inch has to be turned.
                controlResponsiveness: 0.92,
                hoverThrottle: 0.30,
                fpvFov: 104.0,
                collisionRadiusMeters: 0.30,
                structuralQualityFactor: 0.72
            )
        case "fpv-cinewhoop-3":
            return fpvClassTuning(
                takeoffMass: 0.550,
                dimensions: DroneDimensionsMM(x: 195, y: 195, z: 72),
                maxHorizontalSpeedMps: 19.0,
                maxAscentSpeedMps: 8.0,
                maxDescentSpeedMps: 7.0,
                maxFlightTimeMin: 4.5,
                // Ducts are sail area. A cinewhoop is heavier than a racer and still gets pushed
                // around more, which is exactly the trade its pilots make for flying indoors.
                maxWindResistanceMps: 8.0,
                batteryEnergyWh: 28.9,
                controlResponsiveness: 0.88,
                hoverThrottle: 0.34,
                fpvFov: 96.0,
                collisionRadiusMeters: 0.13,
                structuralQualityFactor: 0.60
            )
        // MQ-9A shares MQ-9B's visual preset (same airframe lineage) but is a
        // lighter, shorter-winged and faster aircraft, so it cannot inherit the
        // MQ-9B tuning wholesale.
        // The AQM-35B shares the A's visual preset because it is the same airframe —
        // stretched, strengthened and re-engined — but it is half a ton heavier with more
        // than twice the thrust, so it cannot inherit the A's tuning.
        case "northrop-aqm-35b":
            return fixedWingRuntimeTuning(
                fallbackTakeoffMass: 1540.0,
                fallbackDimensions: DroneDimensionsMM(x: 3860, y: 10770, z: 1880),
                maxHorizontalSpeedMps: 592.0,
                maxAscentSpeedMps: 85.0,
                maxDescentSpeedMps: 55.0,
                maxFlightTimeMin: 25.0,
                maxWindResistanceMps: 30.0,
                batteryEnergyWh: 9600.0,
                visualClass: .fixedWingDelta,
                landingMethod: .bellyLanding,
                controlResponsiveness: 0.38,
                cameraPreset: DroneCameraPreset(fpvFov: 58.0, followDistance: 26.0, followHeight: 6.4),
                collisionRadiusMeters: 0.78,
                fixedWingParameters: FixedWingParameters(
                    family: .supersonicCruciform,
                    minSustainableSpeedMps: 85.0,
                    cruiseSpeedMps: 300.0,
                    climbSpeedMps: 240.0,
                    stallWarningSpeedMps: 77.0,
                    waypointAcceptanceRadiusMeters: 150.0,
                    nominalTurnRateDegPerSec: 5.0,
                    bankResponseGain: 0.64,
                    climbResponseGain: 0.56,
                    descentResponseGain: 0.52,
                    dragFactor: 1.03,
                    throttleResponseGain: 0.44,
                    turnAuthority: 0.40,
                    maxBankAngleDeg: 58.0,
                    supportedLaunchModes: [.airLaunch],
                    preferredLaunchMode: .airLaunch,
                    maxAirspeed: 592.0,
                    nominalClimbRateMps: 70.0,
                    initialClimbPitchDeg: 14.0,
                    maxInitialBankDeg: 15.0,
                    initialClimbTargetAltitude: 450.0,
                    airLaunchReleaseAltitude: 11_000.0,
                    airLaunchReleaseSpeed: 150.0
                ),
                structuralQualityFactor: 1.55,
                skinMaterial: .aluminium
            )
        case "mq-9a-reaper":
            return fixedWingRuntimeTuning(
                fallbackTakeoffMass: 4763.0,
                fallbackDimensions: DroneDimensionsMM(x: 20100, y: 11000, z: 3810),
                runtimeSceneDimensionsOverride: DroneDimensionsMM(x: 2750, y: 1630, z: 775),
                maxHorizontalSpeedMps: 134.0,
                maxAscentSpeedMps: 4.4,
                maxDescentSpeedMps: 5.6,
                maxFlightTimeMin: 1620.0,
                maxWindResistanceMps: 24.0,
                batteryEnergyWh: 26000.0,
                visualClass: .fixedWingSwept,
                controlResponsiveness: 0.22,
                cameraPreset: DroneCameraPreset(fpvFov: 54.0, followDistance: 10.2, followHeight: 3.4),
                collisionRadiusMeters: 0.54,
                fixedWingParameters: FixedWingParameters(
                    family: .swept,
                    minSustainableSpeedMps: 40.0,
                    cruiseSpeedMps: 87.0,
                    climbSpeedMps: 62.0,
                    stallWarningSpeedMps: 35.0,
                    waypointAcceptanceRadiusMeters: 26.0,
                    nominalTurnRateDegPerSec: 8.2,
                    bankResponseGain: 0.60,
                    climbResponseGain: 0.50,
                    descentResponseGain: 0.44,
                    dragFactor: 1.06,
                    throttleResponseGain: 0.54,
                    turnAuthority: 0.34,
                    maxBankAngleDeg: 29.0,
                    supportedLaunchModes: [.standard, .runway],
                    preferredLaunchMode: .runway,
                    maxAirspeed: 134.0,
                    nominalClimbRateMps: 4.2,
                    takeoffRotationSpeed: 48.0,
                    initialClimbPitchDeg: 8.0,
                    maxInitialBankDeg: 10.0,
                    // ~1,600 ft of ground roll at weight, the published figure.
                    // The model needs 530 m, an eight per cent spread.
                    runwayTakeoffDistance: 490.0,
                    initialClimbTargetAltitude: 50.0
                ),
                structuralQualityFactor: 1.35
            )
        // Harpy NG flies the Harop airframe with a heavier installation and a
        // longer loiter, so it overrides that preset's mass and endurance.
        case "iai-harpy-ng":
            return fixedWingRuntimeTuning(
                fallbackTakeoffMass: 160.0,
                fallbackDimensions: DroneDimensionsMM(x: 3000, y: 2500, z: 600),
                maxHorizontalSpeedMps: 116.0,
                maxAscentSpeedMps: 4.2,
                maxDescentSpeedMps: 5.8,
                maxFlightTimeMin: 540.0,
                maxWindResistanceMps: 16.0,
                batteryEnergyWh: 3800.0,
                visualClass: .fixedWingDelta,
                airframeStyle: .flyingWing,
                landingMethod: .bellyLanding,
                controlResponsiveness: 0.44,
                cameraPreset: DroneCameraPreset(fpvFov: 60.0, followDistance: 7.8, followHeight: 2.4),
                collisionRadiusMeters: 0.37,
                fixedWingParameters: FixedWingParameters(
                    family: .delta,
                    minSustainableSpeedMps: 29.0,
                    cruiseSpeedMps: 43.0,
                    climbSpeedMps: 37.0,
                    stallWarningSpeedMps: 25.0,
                    waypointAcceptanceRadiusMeters: 18.0,
                    nominalTurnRateDegPerSec: 12.5,
                    bankResponseGain: 0.70,
                    climbResponseGain: 0.58,
                    descentResponseGain: 0.53,
                    dragFactor: 1.03,
                    throttleResponseGain: 0.62,
                    turnAuthority: 0.48,
                    maxBankAngleDeg: 39.0,
                    supportedLaunchModes: [.canister],
                    preferredLaunchMode: .canister,
                    maxAirspeed: 116.0,
                    nominalClimbRateMps: 3.8,
                    initialClimbPitchDeg: 12.0,
                    maxInitialBankDeg: 15.0,
                    initialClimbTargetAltitude: 30.0
                ),
                structuralQualityFactor: 1.00
            )
        case "dji-mavic-3t":
            return multirotorRuntimeTuning(
                fallbackTakeoffMass: 1.05,
                fallbackDimensions: DroneDimensionsMM(x: 347.5, y: 283.0, z: 107.7),
                maxHorizontalSpeedMps: 21.0,
                maxAscentSpeedMps: 8.0,
                maxDescentSpeedMps: 6.0,
                maxFlightTimeMin: 45.0,
                maxHoverTimeMin: 38.0,
                maxWindResistanceMps: 12.0,
                batteryEnergyWh: 77.0,
                cameraLayoutKey: "drone.camera.multi_lens",
                visualClass: .miniCompact,
                controlResponsiveness: 0.84,
                hoverThrottle: 0.53,
                cameraPreset: DroneCameraPreset(fpvFov: 84.0, followDistance: 8.8, followHeight: 3.0),
                collisionRadiusMeters: 0.24,
                structuralQualityFactor: 0.95
            )
        case "dji-matrice-4t":
            return multirotorRuntimeTuning(
                fallbackTakeoffMass: 1.42,
                fallbackDimensions: DroneDimensionsMM(x: 307.0, y: 387.5, z: 149.5),
                maxHorizontalSpeedMps: 21.0,
                maxAscentSpeedMps: 10.0,
                maxDescentSpeedMps: 8.0,
                maxFlightTimeMin: 49.0,
                maxHoverTimeMin: 42.0,
                maxWindResistanceMps: 12.0,
                batteryEnergyWh: 99.5,
                cameraLayoutKey: "drone.camera.multi_lens",
                visualClass: .miniCompact,
                controlResponsiveness: 0.82,
                hoverThrottle: 0.52,
                cameraPreset: DroneCameraPreset(fpvFov: 84.0, followDistance: 8.8, followHeight: 3.0),
                collisionRadiusMeters: 0.26,
                structuralQualityFactor: 1.1
            )
        case "dji-matrice-30t":
            return multirotorRuntimeTuning(
                fallbackTakeoffMass: 4.069,
                fallbackDimensions: DroneDimensionsMM(x: 470.0, y: 585.0, z: 215.0),
                maxHorizontalSpeedMps: 23.0,
                maxAscentSpeedMps: 6.0,
                maxDescentSpeedMps: 5.0,
                maxFlightTimeMin: 41.0,
                maxHoverTimeMin: 36.0,
                maxWindResistanceMps: 12.0,
                batteryEnergyWh: 263.2,
                cameraLayoutKey: "drone.camera.multi_lens",
                visualClass: .vectorMidDual,
                controlResponsiveness: 0.72,
                hoverThrottle: 0.57,
                cameraPreset: DroneCameraPreset(fpvFov: 82.0, followDistance: 10.8, followHeight: 3.8),
                collisionRadiusMeters: 0.35,
                structuralQualityFactor: 1.15
            )
        case "dji-matrice-400":
            return multirotorRuntimeTuning(
                fallbackTakeoffMass: 15.8,
                fallbackDimensions: DroneDimensionsMM(x: 980.0, y: 760.0, z: 480.0),
                maxHorizontalSpeedMps: 25.0,
                maxAscentSpeedMps: 10.0,
                maxDescentSpeedMps: 8.0,
                maxFlightTimeMin: 59.0,
                maxHoverTimeMin: 53.0,
                maxWindResistanceMps: 12.0,
                batteryEnergyWh: 977.0,
                cameraLayoutKey: "drone.camera.multi_lens",
                visualClass: .atlasProTriple,
                controlResponsiveness: 0.62,
                hoverThrottle: 0.59,
                cameraPreset: DroneCameraPreset(fpvFov: 78.0, followDistance: 14.8, followHeight: 5.4),
                collisionRadiusMeters: 0.58,
                structuralQualityFactor: 1.2
            )
        case "fotokite-sigma":
            return multirotorRuntimeTuning(
                fallbackTakeoffMass: 1.30,
                fallbackDimensions: DroneDimensionsMM(x: 520.0, y: 520.0, z: 180.0),
                maxHorizontalSpeedMps: 2.0,
                maxAscentSpeedMps: 1.2,
                maxDescentSpeedMps: 1.2,
                maxFlightTimeMin: 1440.0,
                maxHoverTimeMin: 1440.0,
                maxWindResistanceMps: 8.0,
                batteryEnergyWh: 0.0,
                cameraLayoutKey: "drone.camera.multi_lens",
                visualClass: .abstract,
                controlResponsiveness: 0.58,
                hoverThrottle: 0.50,
                cameraPreset: DroneCameraPreset(fpvFov: 76.0, followDistance: 8.0, followHeight: 2.8),
                collisionRadiusMeters: 0.26,
                structuralQualityFactor: 1.1
            )
        case "everdrone-first-on-scene":
            return multirotorRuntimeTuning(
                fallbackTakeoffMass: 7.0,
                fallbackDimensions: DroneDimensionsMM(x: 780.0, y: 780.0, z: 300.0),
                maxHorizontalSpeedMps: 15.0,
                maxAscentSpeedMps: 5.0,
                maxDescentSpeedMps: 4.0,
                maxFlightTimeMin: 24.0,
                maxHoverTimeMin: 20.0,
                maxWindResistanceMps: 10.0,
                batteryEnergyWh: 240.0,
                cameraLayoutKey: "drone.camera.single_compact",
                visualClass: .vectorMidDual,
                controlResponsiveness: 0.66,
                hoverThrottle: 0.58,
                cameraPreset: DroneCameraPreset(fpvFov: 80.0, followDistance: 10.5, followHeight: 3.6),
                collisionRadiusMeters: 0.36,
                structuralQualityFactor: 1.15
            )
        case "zipline-platform-1":
            return fixedWingRuntimeTuning(
                fallbackTakeoffMass: 20.0,
                fallbackDimensions: DroneDimensionsMM(x: 3350.0, y: 1800.0, z: 420.0),
                maxHorizontalSpeedMps: 31.3,
                maxAscentSpeedMps: 4.5,
                maxDescentSpeedMps: 4.0,
                maxFlightTimeMin: 132.5,
                maxWindResistanceMps: 14.0,
                batteryEnergyWh: 1200.0,
                visualClass: .fixedWingRectangular,
                controlResponsiveness: 0.46,
                cameraPreset: DroneCameraPreset(fpvFov: 66.0, followDistance: 6.8, followHeight: 2.1),
                collisionRadiusMeters: 0.32,
                fixedWingParameters: FixedWingParameters(
                    family: .conventionalSurvey,
                    minSustainableSpeedMps: 17.0,
                    cruiseSpeedMps: 29.0,
                    climbSpeedMps: 23.0,
                    stallWarningSpeedMps: 15.0,
                    waypointAcceptanceRadiusMeters: 13.0,
                    nominalTurnRateDegPerSec: 10.0,
                    bankResponseGain: 0.70,
                    climbResponseGain: 0.60,
                    descentResponseGain: 0.52,
                    dragFactor: 1.00,
                    throttleResponseGain: 0.62,
                    turnAuthority: 0.50,
                    maxBankAngleDeg: 34.0,
                    supportedLaunchModes: [.catapult],
                    preferredLaunchMode: .catapult,
                    initialClimbPitchDeg: 10.0,
                    maxInitialBankDeg: 13.0,
                    catapultExitSpeed: 23.0,
                    initialClimbTargetAltitude: 24.0
                ),
                structuralQualityFactor: 1.15
            )
        case "wingcopter-198":
            return hybridVTOLRuntimeTuning(
                fallbackTakeoffMass: 25.0,
                fallbackDimensions: DroneDimensionsMM(x: 1980.0, y: 1520.0, z: 650.0),
                maxHorizontalSpeedMps: 25.0,
                maxAscentSpeedMps: 5.5,
                maxDescentSpeedMps: 5.5,
                maxFlightTimeMin: 62.7,
                maxWindResistanceMps: 14.0,
                batteryEnergyWh: 1000.0,
                visualClass: .trinityClass,
                controlResponsiveness: 0.56,
                cameraPreset: DroneCameraPreset(fpvFov: 70.0, followDistance: 9.4, followHeight: 3.0),
                collisionRadiusMeters: 0.38,
                fixedWingParameters: FixedWingParameters(
                    family: .surveyEVTOL,
                    minSustainableSpeedMps: 12.5,
                    cruiseSpeedMps: 22.0,
                    climbSpeedMps: 15.0,
                    stallWarningSpeedMps: 11.4,
                    waypointAcceptanceRadiusMeters: 12.0,
                    nominalTurnRateDegPerSec: 11.0,
                    bankResponseGain: 0.76,
                    climbResponseGain: 0.64,
                    descentResponseGain: 0.56,
                    dragFactor: 1.00,
                    throttleResponseGain: 0.62,
                    turnAuthority: 0.58,
                    maxBankAngleDeg: 36.0,
                    preferredLaunchMode: .vtol,
                    initialClimbPitchDeg: 10.5,
                    initialClimbTargetAltitude: 18.0
                ),
                // Real Wingcopter 198: 8 motors on 4 tilting rotor arms (2
                // coaxial per arm), sweeping 0 (vertical/hover) -> pi/2
                // (forward/cruise). Mount offsets mirror Trinity's 4-pod
                // layout (DroneModelBuilder.buildTrinityClass) since the
                // visual rig doesn't yet model a tilting nacelle (Phase C).
                propulsionUnitTemplate: [
                    .tiltRotor(id: "wingcopter198_tilt_fl_upper", mountOffset: SIMD3<Float>(-0.52, 0.11, 0.12)),
                    .tiltRotor(id: "wingcopter198_tilt_fl_lower", mountOffset: SIMD3<Float>(-0.52, 0.08, 0.12)),
                    .tiltRotor(id: "wingcopter198_tilt_fr_upper", mountOffset: SIMD3<Float>(0.52, 0.11, 0.12)),
                    .tiltRotor(id: "wingcopter198_tilt_fr_lower", mountOffset: SIMD3<Float>(0.52, 0.08, 0.12)),
                    .tiltRotor(id: "wingcopter198_tilt_rl_upper", mountOffset: SIMD3<Float>(-0.52, 0.11, -0.14)),
                    .tiltRotor(id: "wingcopter198_tilt_rl_lower", mountOffset: SIMD3<Float>(-0.52, 0.08, -0.14)),
                    .tiltRotor(id: "wingcopter198_tilt_rr_upper", mountOffset: SIMD3<Float>(0.52, 0.11, -0.14)),
                    .tiltRotor(id: "wingcopter198_tilt_rr_lower", mountOffset: SIMD3<Float>(0.52, 0.08, -0.14))
                ],
                structuralQualityFactor: 1.1
            )
        case "matternet-m2":
            return multirotorRuntimeTuning(
                fallbackTakeoffMass: 12.0,
                fallbackDimensions: DroneDimensionsMM(x: 720.0, y: 720.0, z: 320.0),
                maxHorizontalSpeedMps: 14.0,
                maxAscentSpeedMps: 4.5,
                maxDescentSpeedMps: 3.5,
                maxFlightTimeMin: 35.0,
                maxHoverTimeMin: 30.0,
                maxWindResistanceMps: 10.0,
                batteryEnergyWh: 240.0,
                cameraLayoutKey: "drone.camera.single_compact",
                visualClass: .abstract,
                controlResponsiveness: 0.64,
                hoverThrottle: 0.58,
                cameraPreset: DroneCameraPreset(fpvFov: 80.0, followDistance: 9.5, followHeight: 3.2),
                collisionRadiusMeters: 0.34,
                structuralQualityFactor: 1.1
            )
        case "skydio-x10":
            return multirotorRuntimeTuning(
                fallbackTakeoffMass: 2.13,
                fallbackDimensions: DroneDimensionsMM(x: 351.0, y: 351.0, z: 160.0),
                maxHorizontalSpeedMps: 20.1,
                maxAscentSpeedMps: 8.0,
                maxDescentSpeedMps: 6.0,
                maxFlightTimeMin: 40.0,
                maxHoverTimeMin: 35.0,
                maxWindResistanceMps: 12.8,
                batteryEnergyWh: 70.0,
                cameraLayoutKey: "drone.camera.multi_lens",
                visualClass: .miniCompact,
                controlResponsiveness: 0.84,
                hoverThrottle: 0.53,
                cameraPreset: DroneCameraPreset(fpvFov: 84.0, followDistance: 8.8, followHeight: 3.0),
                collisionRadiusMeters: 0.27,
                structuralQualityFactor: 1.15
            )
        case "dji-matrice-4td-dock-3":
            return multirotorRuntimeTuning(
                fallbackTakeoffMass: 2.09,
                fallbackDimensions: DroneDimensionsMM(x: 377.7, y: 416.2, z: 212.5),
                maxHorizontalSpeedMps: 15.0,
                maxAscentSpeedMps: 6.0,
                maxDescentSpeedMps: 6.0,
                maxFlightTimeMin: 54.0,
                maxHoverTimeMin: 47.0,
                maxWindResistanceMps: 12.0,
                batteryEnergyWh: 149.9,
                cameraLayoutKey: "drone.camera.multi_lens",
                visualClass: .miniCompact,
                controlResponsiveness: 0.78,
                hoverThrottle: 0.54,
                cameraPreset: DroneCameraPreset(fpvFov: 84.0, followDistance: 9.0, followHeight: 3.2),
                collisionRadiusMeters: 0.29,
                structuralQualityFactor: 1.1
            )
        case "brinc-lemur-2":
            // BRINC publishes weight, endurance, dimensions, and sensors, but not a numeric max speed.
            return multirotorRuntimeTuning(
                fallbackTakeoffMass: 1.50,
                fallbackDimensions: DroneDimensionsMM(x: 406.4, y: 330.2, z: 101.6),
                maxHorizontalSpeedMps: 10.0,
                maxAscentSpeedMps: 3.0,
                maxDescentSpeedMps: 3.0,
                maxFlightTimeMin: 20.0,
                maxHoverTimeMin: 20.0,
                maxWindResistanceMps: 5.0,
                batteryEnergyWh: 44.0,
                cameraLayoutKey: "drone.camera.multi_lens",
                visualClass: .miniCompact,
                controlResponsiveness: 0.90,
                hoverThrottle: 0.52,
                cameraPreset: DroneCameraPreset(fpvFov: 92.0, followDistance: 5.2, followHeight: 1.6),
                collisionRadiusMeters: 0.14,
                structuralQualityFactor: 1.2
            )
        case "dji-neo":
            return multirotorRuntimeTuning(
                fallbackTakeoffMass: 0.135,
                fallbackDimensions: DroneDimensionsMM(x: 130.0, y: 157.0, z: 48.5),
                maxHorizontalSpeedMps: 16.0,
                maxAscentSpeedMps: 3.0,
                maxDescentSpeedMps: 2.0,
                maxFlightTimeMin: 18.0,
                maxHoverTimeMin: 18.0,
                maxWindResistanceMps: 8.0,
                batteryEnergyWh: 10.5,
                cameraLayoutKey: "drone.camera.single_compact",
                visualClass: .miniCompact,
                controlResponsiveness: 0.92,
                hoverThrottle: 0.50,
                cameraPreset: DroneCameraPreset(fpvFov: 92.0, followDistance: 4.8, followHeight: 1.5),
                collisionRadiusMeters: 0.12,
                structuralQualityFactor: 0.65
            )
        case "sensefly-ebee-tac":
            return fixedWingRuntimeTuning(
                fallbackTakeoffMass: 1.7,
                fallbackDimensions: DroneDimensionsMM(x: 1160, y: 700, z: 180),
                maxHorizontalSpeedMps: 30.0,
                maxAscentSpeedMps: 4.5,
                maxDescentSpeedMps: 4.0,
                maxFlightTimeMin: 90.0,
                maxWindResistanceMps: 12.0,
                batteryEnergyWh: 82.0,
                visualClass: .ebeeClass,
                airframeStyle: .flyingWing,
                controlResponsiveness: 0.56,
                cameraPreset: DroneCameraPreset(fpvFov: 70.0, followDistance: 5.8, followHeight: 1.7),
                collisionRadiusMeters: 0.24,
                fixedWingParameters: FixedWingParameters(
                    family: .flyingWing,
                    minSustainableSpeedMps: 13.4,
                    cruiseSpeedMps: 19.5,
                    climbSpeedMps: 15.8,
                    stallWarningSpeedMps: 12.0,
                    waypointAcceptanceRadiusMeters: 9.0,
                    nominalTurnRateDegPerSec: 14.0,
                    bankResponseGain: 0.80,
                    climbResponseGain: 0.68,
                    descentResponseGain: 0.58,
                    dragFactor: 0.97,
                    throttleResponseGain: 0.66,
                    turnAuthority: 0.64,
                    maxBankAngleDeg: 40.0,
                    supportedLaunchModes: [.handLaunch],
                    preferredLaunchMode: .handLaunch,
                    initialClimbPitchDeg: 11.0,
                    maxInitialBankDeg: 15.0,
                    handThrowSpeed: 16.4,
                    initialClimbTargetAltitude: 16.0
                ),
                structuralQualityFactor: 0.7
            )
        case "rq-21-integrator":
            return fixedWingRuntimeTuning(
                fallbackTakeoffMass: 61.0,
                fallbackDimensions: DroneDimensionsMM(x: 4900, y: 2800, z: 620),
                maxHorizontalSpeedMps: 42.0,
                maxAscentSpeedMps: 4.8,
                maxDescentSpeedMps: 4.5,
                maxFlightTimeMin: 960.0,
                maxWindResistanceMps: 18.0,
                batteryEnergyWh: 4200.0,
                visualClass: .fixedWingRectangular,
                controlResponsiveness: 0.36,
                cameraPreset: DroneCameraPreset(fpvFov: 62.0, followDistance: 7.8, followHeight: 2.3),
                collisionRadiusMeters: 0.40,
                fixedWingParameters: FixedWingParameters(
                    family: .conventionalSurvey,
                    minSustainableSpeedMps: 18.5,
                    cruiseSpeedMps: 29.0,
                    climbSpeedMps: 23.0,
                    stallWarningSpeedMps: 16.5,
                    waypointAcceptanceRadiusMeters: 12.0,
                    nominalTurnRateDegPerSec: 10.6,
                    bankResponseGain: 0.70,
                    climbResponseGain: 0.60,
                    descentResponseGain: 0.52,
                    dragFactor: 1.02,
                    throttleResponseGain: 0.60,
                    turnAuthority: 0.52,
                    maxBankAngleDeg: 34.0,
                    supportedLaunchModes: [.catapult],
                    preferredLaunchMode: .catapult,
                    initialClimbPitchDeg: 9.5,
                    maxInitialBankDeg: 12.0,
                    catapultExitSpeed: 24.0,
                    initialClimbTargetAltitude: 24.0
                ),
                structuralQualityFactor: 1.25
            )
        default:
            return nil
        }
    }

    private static func multirotorRuntimeTuning(
        fallbackTakeoffMass: Float,
        fallbackDimensions: DroneDimensionsMM,
        maxHorizontalSpeedMps: Float,
        maxAscentSpeedMps: Float,
        maxDescentSpeedMps: Float,
        maxFlightTimeMin: Float,
        maxHoverTimeMin: Float,
        maxWindResistanceMps: Float,
        batteryEnergyWh: Float,
        cameraLayoutKey: String = "drone.camera.single_compact",
        visualClass: DroneVisualClass,
        airframeStyle: AirframeStyle = .multirotorQuad,
        controlResponsiveness: Float,
        hoverThrottle: Float,
        cameraPreset: DroneCameraPreset,
        collisionRadiusMeters: Float,
        structuralQualityFactor: Float = 1.0
    ) -> RuntimeTuning {
        RuntimeTuning(
            fallbackTakeoffMass: fallbackTakeoffMass,
            fallbackDimensions: fallbackDimensions,
            maxHorizontalSpeedMps: maxHorizontalSpeedMps,
            maxAscentSpeedMps: maxAscentSpeedMps,
            maxDescentSpeedMps: maxDescentSpeedMps,
            maxFlightTimeMin: maxFlightTimeMin,
            maxHoverTimeMin: maxHoverTimeMin,
            maxWindResistanceMps: maxWindResistanceMps,
            batteryEnergyWh: batteryEnergyWh,
            cameraLayoutKey: cameraLayoutKey,
            visualClass: visualClass,
            operationalCategory: .multirotor,
            airframeClass: .multirotor,
            airframeStyle: airframeStyle,
            fixedWingParameters: nil,
            launchMethod: .vertical,
            landingMethod: .vertical,
            controlResponsiveness: controlResponsiveness,
            hoverThrottle: hoverThrottle,
            cameraPreset: cameraPreset,
            collisionRadiusMeters: collisionRadiusMeters,
            structuralQualityFactor: structuralQualityFactor
        )
    }

    private static func fixedWingRuntimeTuning(
        fallbackTakeoffMass: Float,
        fallbackDimensions: DroneDimensionsMM,
        runtimeSceneDimensionsOverride: DroneDimensionsMM? = nil,
        maxHorizontalSpeedMps: Float,
        maxAscentSpeedMps: Float,
        maxDescentSpeedMps: Float,
        maxFlightTimeMin: Float,
        maxWindResistanceMps: Float,
        batteryEnergyWh: Float,
        visualClass: DroneVisualClass,
        operationalCategory: DroneOperationalCategory = .fixedWing,
        airframeStyle: AirframeStyle = .conventionalFixedWing,
        launchMethod: LaunchMethod = .handLaunch,
        landingMethod: LandingMethod = .bellyLanding,
        controlResponsiveness: Float,
        cameraPreset: DroneCameraPreset,
        collisionRadiusMeters: Float,
        fixedWingParameters: FixedWingParameters,
        structuralQualityFactor: Float = 1.0,
        skinMaterial: UAVSkinMaterial = .aluminium
    ) -> RuntimeTuning {
        RuntimeTuning(
            fallbackTakeoffMass: fallbackTakeoffMass,
            fallbackDimensions: fallbackDimensions,
            runtimeSceneDimensionsOverride: runtimeSceneDimensionsOverride,
            maxHorizontalSpeedMps: maxHorizontalSpeedMps,
            maxAscentSpeedMps: maxAscentSpeedMps,
            maxDescentSpeedMps: maxDescentSpeedMps,
            maxFlightTimeMin: maxFlightTimeMin,
            maxHoverTimeMin: 0.0,
            maxWindResistanceMps: maxWindResistanceMps,
            batteryEnergyWh: batteryEnergyWh,
            cameraLayoutKey: "drone.camera.fixed_front",
            visualClass: visualClass,
            operationalCategory: operationalCategory,
            airframeClass: .fixedWing,
            airframeStyle: airframeStyle,
            fixedWingParameters: fixedWingParameters,
            launchMethod: launchMethod,
            landingMethod: landingMethod,
            controlResponsiveness: controlResponsiveness,
            hoverThrottle: 0.0,
            cameraPreset: cameraPreset,
            collisionRadiusMeters: collisionRadiusMeters,
            structuralQualityFactor: structuralQualityFactor,
            skinMaterial: skinMaterial
        )
    }

    private static func hybridVTOLRuntimeTuning(
        fallbackTakeoffMass: Float,
        fallbackDimensions: DroneDimensionsMM,
        runtimeSceneDimensionsOverride: DroneDimensionsMM? = nil,
        maxHorizontalSpeedMps: Float,
        maxAscentSpeedMps: Float,
        maxDescentSpeedMps: Float,
        maxFlightTimeMin: Float,
        maxWindResistanceMps: Float,
        batteryEnergyWh: Float,
        visualClass: DroneVisualClass,
        operationalCategory: DroneOperationalCategory = .fixedWingVTOL,
        airframeStyle: AirframeStyle = .surveyEVTOL,
        launchMethod: LaunchMethod = .vertical,
        landingMethod: LandingMethod = .vertical,
        controlResponsiveness: Float,
        cameraPreset: DroneCameraPreset,
        collisionRadiusMeters: Float,
        fixedWingParameters: FixedWingParameters,
        propulsionUnitTemplate: [PropulsionUnit],
        structuralQualityFactor: Float = 1.0
    ) -> RuntimeTuning {
        RuntimeTuning(
            fallbackTakeoffMass: fallbackTakeoffMass,
            fallbackDimensions: fallbackDimensions,
            runtimeSceneDimensionsOverride: runtimeSceneDimensionsOverride,
            maxHorizontalSpeedMps: maxHorizontalSpeedMps,
            maxAscentSpeedMps: maxAscentSpeedMps,
            maxDescentSpeedMps: maxDescentSpeedMps,
            maxFlightTimeMin: maxFlightTimeMin,
            maxHoverTimeMin: 0.0,
            maxWindResistanceMps: maxWindResistanceMps,
            batteryEnergyWh: batteryEnergyWh,
            cameraLayoutKey: "drone.camera.fixed_front",
            visualClass: visualClass,
            operationalCategory: operationalCategory,
            airframeClass: .hybridVTOL,
            airframeStyle: airframeStyle,
            fixedWingParameters: fixedWingParameters,
            launchMethod: launchMethod,
            landingMethod: landingMethod,
            controlResponsiveness: controlResponsiveness,
            hoverThrottle: 0.0,
            cameraPreset: cameraPreset,
            collisionRadiusMeters: collisionRadiusMeters,
            propulsionUnitTemplate: propulsionUnitTemplate,
            structuralQualityFactor: structuralQualityFactor
        )
    }

    static func abstractProfile(from parameters: AbstractDroneParameters) -> DroneModelProfile {
        DroneModelProfile(
            id: "abstract-uav",
            displayName: "Abstract UAV",
            displayNameKey: "drone.model.abstract",
            manufacturer: "Custom",
            takeoffMassKg: parameters.massKg,
            dimensionsFoldedMm: DroneDimensionsMM(x: parameters.unfoldedMm.x * 0.68, y: parameters.unfoldedMm.y * 0.52, z: parameters.unfoldedMm.z * 0.8),
            dimensionsUnfoldedMm: parameters.unfoldedMm,
            maxHorizontalSpeedMps: parameters.maxHorizontalSpeedMps,
            maxAscentSpeedMps: parameters.maxAscentSpeedMps,
            maxDescentSpeedMps: parameters.maxDescentSpeedMps,
            maxFlightTimeMin: 34.0,
            maxHoverTimeMin: 30.0,
            maxWindResistanceMps: parameters.maxWindResistanceMps,
            batteryCapacitymAh: max(1000.0, parameters.batteryEnergyWh * 52.0),
            batteryEnergyWh: parameters.batteryEnergyWh,
            cameraLayoutKey: "drone.camera.custom",
            visualClass: .abstract,
            operationalCategory: .multirotor,
            airframeClass: .multirotor,
            airframeStyle: .multirotorQuad,
            fixedWingParameters: nil,
            launchMethod: .vertical,
            landingMethod: .vertical,
            controlResponsiveness: parameters.controlResponsiveness,
            hoverThrottle: 0.56,
            cameraPreset: DroneCameraPreset(fpvFov: 82.0, followDistance: 8.0, followHeight: 2.8),
            collisionRadiusMeters: parameters.collisionRadiusMeters,
            notes: "User editable abstract profile",
            sourceURL: nil
        )
    }
}

/// One shape for every FPV class entry: they differ in mass, size, speed and how hard they hit,
/// never in what kind of aircraft they are.
private func fpvClassTuning(
    takeoffMass: Float,
    dimensions: DroneDimensionsMM,
    maxHorizontalSpeedMps: Float,
    maxAscentSpeedMps: Float,
    maxDescentSpeedMps: Float,
    maxFlightTimeMin: Float,
    maxWindResistanceMps: Float,
    batteryEnergyWh: Float,
    controlResponsiveness: Float,
    hoverThrottle: Float,
    fpvFov: Float,
    collisionRadiusMeters: Float,
    structuralQualityFactor: Float
) -> RuntimeTuning {
    RuntimeTuning(
        fallbackTakeoffMass: takeoffMass,
        fallbackDimensions: dimensions,
        maxHorizontalSpeedMps: maxHorizontalSpeedMps,
        maxAscentSpeedMps: maxAscentSpeedMps,
        maxDescentSpeedMps: maxDescentSpeedMps,
        maxFlightTimeMin: maxFlightTimeMin,
        // Hovering is the cheapest thing a racing quad ever does, and nobody buys one to do it.
        maxHoverTimeMin: maxFlightTimeMin * 1.2,
        maxWindResistanceMps: maxWindResistanceMps,
        batteryEnergyWh: batteryEnergyWh,
        cameraLayoutKey: "drone.camera.fpv",
        visualClass: .miniCompact,
        operationalCategory: .multirotor,
        airframeClass: .multirotor,
        airframeStyle: .multirotorQuad,
        fixedWingParameters: nil,
        launchMethod: .vertical,
        landingMethod: .vertical,
        controlResponsiveness: controlResponsiveness,
        hoverThrottle: hoverThrottle,
        cameraPreset: DroneCameraPreset(
            fpvFov: fpvFov,
            followDistance: max(2.2, dimensions.x / 1000.0 * 12.0),
            followHeight: max(0.7, dimensions.x / 1000.0 * 3.4)
        ),
        collisionRadiusMeters: collisionRadiusMeters,
        structuralQualityFactor: structuralQualityFactor
    )
}

private struct RuntimeTuning {
    let fallbackTakeoffMass: Float
    let fallbackDimensions: DroneDimensionsMM
    let runtimeSceneDimensionsOverride: DroneDimensionsMM?
    let maxHorizontalSpeedMps: Float
    let maxAscentSpeedMps: Float
    let maxDescentSpeedMps: Float
    let maxFlightTimeMin: Float
    let maxHoverTimeMin: Float
    let maxWindResistanceMps: Float
    let batteryEnergyWh: Float
    let cameraLayoutKey: String
    let visualClass: DroneVisualClass
    let operationalCategory: DroneOperationalCategory
    let airframeClass: AirframeClass
    let airframeStyle: AirframeStyle
    let fixedWingParameters: FixedWingParameters?
    let launchMethod: LaunchMethod
    let landingMethod: LandingMethod
    let controlResponsiveness: Float
    let hoverThrottle: Float
    let cameraPreset: DroneCameraPreset
    let collisionRadiusMeters: Float
    let propulsionUnitTemplate: [PropulsionUnit]
    /// Structural build-quality multiplier on top of the component-kind strength table
    /// (`VehicleComponentGraphBuilder.strengthJPerKg`) — a flimsier toy-grade shell and a
    /// reinforced industrial/military airframe of the same mass do not fail at the same impact
    /// energy. 1.0 = today's unmodified strength table; hand-calibrated per airframe below, not
    /// derived from any other field, so it defaults to neutral for every profile not explicitly
    /// tuned.
    let structuralQualityFactor: Float
    /// Skin material. Only matters above about Mach 2, which is why it defaults to
    /// aluminium and why no subsonic entry sets it.
    let skinMaterial: UAVSkinMaterial

    init(
        fallbackTakeoffMass: Float,
        fallbackDimensions: DroneDimensionsMM,
        runtimeSceneDimensionsOverride: DroneDimensionsMM? = nil,
        maxHorizontalSpeedMps: Float,
        maxAscentSpeedMps: Float,
        maxDescentSpeedMps: Float,
        maxFlightTimeMin: Float,
        maxHoverTimeMin: Float,
        maxWindResistanceMps: Float,
        batteryEnergyWh: Float,
        cameraLayoutKey: String,
        visualClass: DroneVisualClass,
        operationalCategory: DroneOperationalCategory,
        airframeClass: AirframeClass,
        airframeStyle: AirframeStyle,
        fixedWingParameters: FixedWingParameters?,
        launchMethod: LaunchMethod,
        landingMethod: LandingMethod,
        controlResponsiveness: Float,
        hoverThrottle: Float,
        cameraPreset: DroneCameraPreset,
        collisionRadiusMeters: Float,
        propulsionUnitTemplate: [PropulsionUnit] = [],
        structuralQualityFactor: Float = 1.0,
        skinMaterial: UAVSkinMaterial = .aluminium
    ) {
        self.fallbackTakeoffMass = fallbackTakeoffMass
        self.fallbackDimensions = fallbackDimensions
        self.runtimeSceneDimensionsOverride = runtimeSceneDimensionsOverride
        self.maxHorizontalSpeedMps = maxHorizontalSpeedMps
        self.maxAscentSpeedMps = maxAscentSpeedMps
        self.maxDescentSpeedMps = maxDescentSpeedMps
        self.maxFlightTimeMin = maxFlightTimeMin
        self.maxHoverTimeMin = maxHoverTimeMin
        self.maxWindResistanceMps = maxWindResistanceMps
        self.batteryEnergyWh = batteryEnergyWh
        self.cameraLayoutKey = cameraLayoutKey
        self.visualClass = visualClass
        self.operationalCategory = operationalCategory
        self.airframeClass = airframeClass
        self.airframeStyle = airframeStyle
        self.fixedWingParameters = fixedWingParameters
        self.launchMethod = launchMethod
        self.landingMethod = landingMethod
        self.controlResponsiveness = controlResponsiveness
        self.hoverThrottle = hoverThrottle
        self.cameraPreset = cameraPreset
        self.collisionRadiusMeters = collisionRadiusMeters
        self.propulsionUnitTemplate = propulsionUnitTemplate
        self.structuralQualityFactor = structuralQualityFactor
        self.skinMaterial = skinMaterial
    }
}

// Equipment/autonomy properties of the airframe itself — orthogonal to `UAVControlLinkType`
// (which is a *dynamic* runtime state: radio vs. fiberOptic, depending on whether a spool is
// attached right now). These describe what the aircraft can *do* about losing whichever link is
// currently active, independent of which link that is — "losing the comms channel" and "losing
// the ability to fly" are different events, and the reaction should depend on equipment, not on
// which link type failed.
enum NavigationCapability: String, Hashable {
    /// No GPS/IMU-based hold or navigation — the operator's own visual line-of-sight is the only
    /// stabilization/positioning reference (a simple acro/FPV racer).
    case visualLineOfSight
    /// GPS position/altitude hold, no autonomous mission-following or return-to-home logic.
    case gpsAssisted
    /// Full GPS autopilot — waypoint/mission following, return-to-home, loiter.
    case gpsAutopilot
}

enum AutonomyLevel: String, Hashable {
    /// Flies only under direct operator input (manual/stabilized/GPS-hold).
    case operatorControlled
    /// Can fly a pre-planned mission/route unattended, but has no dedicated link-loss failsafe
    /// behavior beyond what the mission logic already does.
    case missionControlled
    /// Can autonomously execute a dedicated failsafe sequence (hold/RTH/land) independent of the
    /// operator link, on top of mission-following.
    case failsafeCapable
}

enum LinkLossPolicy: String, Hashable {
    /// No autopilot to fall back on — losing the link also means losing the ability to fly.
    /// Matches reality for a simple visual-line-of-sight aircraft with no GPS.
    case strandedWithoutInput
    /// Multirotor-style reaction: brake, hold position, then land in place.
    case holdAndLand
    /// Fixed-wing-style reaction: wings-level stabilize, loiter/glide, then a controlled descent.
    case stabilizeAndGlideDown
    /// Autonomous/mission-bound reaction: fly itself home via the existing return-to-home logic.
    case returnHome
}

struct UAVOperationalProfile: Hashable {
    let nominalFlightTimeSec: Float
    let nominalCruiseSpeedMps: Float
    let nominalMaxRangeM: Float
    let nominalLinkRangeM: Float
    let batteryReserveFraction: Float
    let payloadRangePenaltyPerKg: Float
    let climbConsumptionMultiplier: Float
    let hoverConsumptionMultiplier: Float
    let turnConsumptionMultiplier: Float
    let loiterConsumptionMultiplier: Float
    let minSafeAirspeedMps: Float
    let preferredMapScaleMin: MapScale
    let preferredMapScaleMax: MapScale
    let estimatedDataQuality: UAVEstimatedDataQuality
    let navigationCapability: NavigationCapability
    let autonomyLevel: AutonomyLevel
    let linkLossPolicy: LinkLossPolicy
}

enum MapScaleSuitability: String, CaseIterable, Hashable {
    case optimal
    case acceptable
    case tight
    case unsuitable

    var title: String {
        rawValue.uppercased()
    }
}

struct UAVMapScaleRecommendation: Hashable {
    let recommendedMapScaleMin: MapScale
    let recommendedMapScaleMax: MapScale
    let recommendedOperationalMapScale: MapScale
    let unsuitableMapScales: [MapScale]
    let minimumTurnRadiusM: Float
    let waypointAnticipationDistanceM: Float
    let currentSuitability: MapScaleSuitability
}

extension DroneModelProfile {
    var operationalProfile: UAVOperationalProfile {
        UAVOperationalProfileResolver.resolve(
            runtimeProfile: self,
            uavProfile: resolvedUAVProfile
        )
    }

    func mapScaleRecommendation(
        currentScale: MapScale,
        payloadMassKg: Float,
        batteryFraction: Float,
        weatherPenalty: Float
    ) -> UAVMapScaleRecommendation {
        UAVMapScaleRecommendationResolver.resolve(
            runtimeProfile: self,
            operationalProfile: operationalProfile,
            currentScale: currentScale,
            payloadMassKg: payloadMassKg,
            batteryFraction: batteryFraction,
            weatherPenalty: weatherPenalty
        )
    }
}

private enum UAVOperationalProfileResolver {
    static func resolve(
        runtimeProfile: DroneModelProfile,
        uavProfile: UAVProfile?
    ) -> UAVOperationalProfile {
        let analog = AnalogCluster(runtimeProfile: runtimeProfile, uavProfile: uavProfile)
        let quality = resolvedQuality(for: uavProfile)

        let nominalFlightTimeSec = max(
            360.0,
            uavProfile?.nominalFlightTimeSec ?? runtimeProfile.maxFlightTimeMin * 60.0
        )
        let nominalCruiseSpeedMps = max(
            2.0,
            uavProfile?.nominalCruiseSpeedMps ?? defaultCruiseSpeed(
                runtimeProfile: runtimeProfile
            )
        )
        let nominalMaxRangeM = max(
            120.0,
            uavProfile?.nominalMaxRangeM ?? analogRangeEstimate(
                analog: analog,
                flightTimeSec: nominalFlightTimeSec,
                cruiseSpeedMps: nominalCruiseSpeedMps,
                quality: quality
            )
        )
        let nominalLinkRangeM = max(
            90.0,
            uavProfile?.nominalLinkRangeM ?? analogLinkEstimate(
                analog: analog,
                nominalMaxRangeM: nominalMaxRangeM,
                quality: quality
            )
        )
        let batteryReserveFraction = (
            uavProfile?.batteryReserveFraction ??
            analogReserveFraction(for: analog)
        ).clamped(to: 0.18...0.42)
        let payloadRangePenaltyPerKg = max(
            0.008,
            uavProfile?.payloadRangePenaltyPerKg ?? analogPayloadPenalty(
                analog: analog,
                runtimeProfile: runtimeProfile,
                uavProfile: uavProfile
            )
        )
        let climbConsumptionMultiplier = max(
            1.02,
            uavProfile?.climbConsumptionMultiplier ?? analogClimbMultiplier(for: analog)
        )
        let hoverConsumptionMultiplier = max(
            1.0,
            uavProfile?.hoverConsumptionMultiplier ?? analogHoverMultiplier(for: analog)
        )
        let turnConsumptionMultiplier = max(
            1.0,
            uavProfile?.turnConsumptionMultiplier ?? analogTurnMultiplier(for: analog)
        )
        let loiterConsumptionMultiplier = max(
            1.0,
            uavProfile?.loiterConsumptionMultiplier ?? analogLoiterMultiplier(for: analog)
        )
        let minSafeAirspeedMps = max(
            0.0,
            uavProfile?.minSafeAirspeedMps ??
                runtimeProfile.fixedWingParameters?.minSustainableSpeedMps ??
                runtimeProfile.fixedWingParameters?.stallWarningSpeedMps ??
                0.0
        )
        let navigationCapability = uavProfile?.navigationCapability ??
            analogNavigationCapability(runtimeProfile: runtimeProfile, analog: analog)
        let autonomyLevel = uavProfile?.autonomyLevel ??
            analogAutonomyLevel(runtimeProfile: runtimeProfile, analog: analog, navigationCapability: navigationCapability)
        let linkLossPolicy = uavProfile?.linkLossPolicy ??
            analogLinkLossPolicy(runtimeProfile: runtimeProfile, navigationCapability: navigationCapability)

        let baseProfile = UAVOperationalProfile(
            nominalFlightTimeSec: nominalFlightTimeSec,
            nominalCruiseSpeedMps: nominalCruiseSpeedMps,
            nominalMaxRangeM: nominalMaxRangeM,
            nominalLinkRangeM: nominalLinkRangeM,
            batteryReserveFraction: batteryReserveFraction,
            payloadRangePenaltyPerKg: payloadRangePenaltyPerKg,
            climbConsumptionMultiplier: climbConsumptionMultiplier,
            hoverConsumptionMultiplier: hoverConsumptionMultiplier,
            turnConsumptionMultiplier: turnConsumptionMultiplier,
            loiterConsumptionMultiplier: loiterConsumptionMultiplier,
            minSafeAirspeedMps: minSafeAirspeedMps,
            preferredMapScaleMin: .x16,
            preferredMapScaleMax: .x64,
            estimatedDataQuality: quality,
            navigationCapability: navigationCapability,
            autonomyLevel: autonomyLevel,
            linkLossPolicy: linkLossPolicy
        )

        let recommendation = UAVMapScaleRecommendationResolver.resolve(
            runtimeProfile: runtimeProfile,
            operationalProfile: baseProfile,
            currentScale: .x32,
            payloadMassKg: 0.0,
            batteryFraction: 1.0,
            weatherPenalty: 1.0
        )

        return UAVOperationalProfile(
            nominalFlightTimeSec: nominalFlightTimeSec,
            nominalCruiseSpeedMps: nominalCruiseSpeedMps,
            nominalMaxRangeM: nominalMaxRangeM,
            nominalLinkRangeM: nominalLinkRangeM,
            batteryReserveFraction: batteryReserveFraction,
            payloadRangePenaltyPerKg: payloadRangePenaltyPerKg,
            climbConsumptionMultiplier: climbConsumptionMultiplier,
            hoverConsumptionMultiplier: hoverConsumptionMultiplier,
            turnConsumptionMultiplier: turnConsumptionMultiplier,
            loiterConsumptionMultiplier: loiterConsumptionMultiplier,
            minSafeAirspeedMps: minSafeAirspeedMps,
            preferredMapScaleMin: uavProfile?.preferredMapScaleMin ?? recommendation.recommendedMapScaleMin,
            preferredMapScaleMax: uavProfile?.preferredMapScaleMax ?? recommendation.recommendedMapScaleMax,
            estimatedDataQuality: quality,
            navigationCapability: navigationCapability,
            autonomyLevel: autonomyLevel,
            linkLossPolicy: linkLossPolicy
        )
    }

    // Equipment fit is inferred the same way every other unspecified operational number already
    // is in this resolver: from the airframe class, mass category, and mission role, falling back
    // to the most common real-world fit for this catalog (which is entirely professional/
    // commercial/military hardware — a bare visual-line-of-sight racer with no GPS at all isn't
    // represented here yet, but the category exists for custom/user-added airframes).
    private static func analogNavigationCapability(
        runtimeProfile: DroneModelProfile,
        analog: AnalogCluster
    ) -> NavigationCapability {
        if analog.massCategory == .nano {
            // Toy/nano-class multirotors (e.g. DJI Neo) typically hold altitude/position via
            // vision+IMU rather than a full GPS autopilot with mission/RTH logic.
            return .gpsAssisted
        }
        return .gpsAutopilot
    }

    private static func analogAutonomyLevel(
        runtimeProfile: DroneModelProfile,
        analog: AnalogCluster,
        navigationCapability: NavigationCapability
    ) -> AutonomyLevel {
        guard navigationCapability != .visualLineOfSight else {
            return .operatorControlled
        }
        let tacticalRole = analog.missionRole.contains("istar") ||
            analog.missionRole.contains("isr") ||
            analog.missionRole.contains("reconnaissance") ||
            analog.missionRole.contains("strike") ||
            analog.missionRole.contains("surveillance") ||
            analog.missionRole.contains("patrol")
        if tacticalRole && (runtimeProfile.airframeClass == .fixedWing || runtimeProfile.airframeClass == .hybridVTOL) {
            return .failsafeCapable
        }
        return .missionControlled
    }

    private static func analogLinkLossPolicy(
        runtimeProfile: DroneModelProfile,
        navigationCapability: NavigationCapability
    ) -> LinkLossPolicy {
        guard navigationCapability != .visualLineOfSight else {
            return .strandedWithoutInput
        }
        switch runtimeProfile.airframeClass {
        case .fixedWing, .hybridVTOL:
            return .returnHome
        case .multirotor:
            return navigationCapability == .gpsAutopilot ? .returnHome : .holdAndLand
        }
    }

    private static func resolvedQuality(for uavProfile: UAVProfile?) -> UAVEstimatedDataQuality {
        guard let uavProfile else {
            return .estimated
        }

        if hasExplicitOperationalFields(uavProfile) {
            return uavProfile.estimatedDataQuality
        }

        switch uavProfile.specConfidence {
        case .verified, .partial:
            return .derived
        case .custom:
            return .estimated
        }
    }

    private static func hasExplicitOperationalFields(_ uavProfile: UAVProfile) -> Bool {
        uavProfile.nominalFlightTimeSec != nil ||
        uavProfile.nominalCruiseSpeedMps != nil ||
        uavProfile.nominalMaxRangeM != nil ||
        uavProfile.nominalLinkRangeM != nil ||
        uavProfile.batteryReserveFraction != nil ||
        uavProfile.payloadRangePenaltyPerKg != nil ||
        uavProfile.climbConsumptionMultiplier != nil ||
        uavProfile.hoverConsumptionMultiplier != nil ||
        uavProfile.turnConsumptionMultiplier != nil ||
        uavProfile.loiterConsumptionMultiplier != nil ||
        uavProfile.minSafeAirspeedMps != nil ||
        uavProfile.preferredMapScaleMin != nil ||
        uavProfile.preferredMapScaleMax != nil
    }

    private static func defaultCruiseSpeed(
        runtimeProfile: DroneModelProfile
    ) -> Float {
        switch runtimeProfile.airframeClass {
        case .fixedWing, .hybridVTOL:
            return runtimeProfile.fixedWingParameters?.cruiseSpeedMps ??
                max(8.0, runtimeProfile.maxHorizontalSpeedMps * 0.55)
        case .multirotor:
            return max(3.0, runtimeProfile.maxHorizontalSpeedMps * 0.56)
        }
    }

    private static func analogRangeEstimate(
        analog: AnalogCluster,
        flightTimeSec: Float,
        cruiseSpeedMps: Float,
        quality: UAVEstimatedDataQuality
    ) -> Float {
        let efficiency: Float
        switch analog.operationalCategory {
        case .multirotor:
            efficiency = 0.56
        case .fixedWing:
            efficiency = 0.82
        case .fixedWingVTOL:
            efficiency = 0.74
        }

        let missionFactor: Float = analog.missionRole.contains("cargo") ? 0.84 : 1.0
        let safetyFactor: Float = quality == .estimated ? 0.82 : 0.92
        return flightTimeSec * cruiseSpeedMps * efficiency * missionFactor * safetyFactor
    }

    private static func analogLinkEstimate(
        analog: AnalogCluster,
        nominalMaxRangeM: Float,
        quality: UAVEstimatedDataQuality
    ) -> Float {
        let linkFactor: Float
        switch analog.operationalCategory {
        case .multirotor:
            linkFactor = analog.massCategory == .nano || analog.massCategory == .micro ? 1.28 : 1.52
        case .fixedWing:
            linkFactor = analog.massCategory == .heavy ? 2.10 : 1.82
        case .fixedWingVTOL:
            linkFactor = 1.66
        }
        let safetyFactor: Float = quality == .estimated ? 0.84 : 0.94
        return nominalMaxRangeM * linkFactor * safetyFactor
    }

    private static func analogReserveFraction(for analog: AnalogCluster) -> Float {
        switch analog.operationalCategory {
        case .multirotor:
            return analog.missionRole.contains("cargo") ? 0.32 : 0.28
        case .fixedWing:
            return analog.massCategory == .heavy ? 0.34 : 0.30
        case .fixedWingVTOL:
            return 0.31
        }
    }

    private static func analogPayloadPenalty(
        analog: AnalogCluster,
        runtimeProfile: DroneModelProfile,
        uavProfile: UAVProfile?
    ) -> Float {
        if let maxPayloadMass = uavProfile?.maxPayloadMass ?? uavProfile?.estimatedMaxPayloadMass,
           maxPayloadMass > 0.01 {
            let nominalPenalty = 0.18 / max(maxPayloadMass, 0.25)
            switch analog.operationalCategory {
            case .multirotor:
                return nominalPenalty.clamped(to: 0.018...0.16)
            case .fixedWing:
                return (nominalPenalty * 0.72).clamped(to: 0.010...0.09)
            case .fixedWingVTOL:
                return (nominalPenalty * 0.84).clamped(to: 0.012...0.10)
            }
        }

        let massPenalty = 0.22 / max(runtimeProfile.takeoffMassKg, 0.35)
        return massPenalty.clamped(to: 0.010...0.18)
    }

    private static func analogClimbMultiplier(for analog: AnalogCluster) -> Float {
        switch analog.operationalCategory {
        case .multirotor:
            return 1.18
        case .fixedWing:
            return 1.12
        case .fixedWingVTOL:
            return 1.16
        }
    }

    private static func analogHoverMultiplier(for analog: AnalogCluster) -> Float {
        switch analog.operationalCategory {
        case .multirotor:
            return analog.missionRole.contains("cargo") ? 1.14 : 1.08
        case .fixedWing:
            return 1.0
        case .fixedWingVTOL:
            return 1.28
        }
    }

    private static func analogTurnMultiplier(for analog: AnalogCluster) -> Float {
        switch analog.operationalCategory {
        case .multirotor:
            return 1.04
        case .fixedWing:
            return analog.massCategory == .heavy ? 1.10 : 1.08
        case .fixedWingVTOL:
            return 1.07
        }
    }

    private static func analogLoiterMultiplier(for analog: AnalogCluster) -> Float {
        switch analog.operationalCategory {
        case .multirotor:
            return 1.06
        case .fixedWing:
            return 1.04
        case .fixedWingVTOL:
            return 1.05
        }
    }

    private struct AnalogCluster {
        let operationalCategory: DroneOperationalCategory
        let massCategory: UAVMassCategory
        let missionRole: String

        init(runtimeProfile: DroneModelProfile, uavProfile: UAVProfile?) {
            self.operationalCategory = runtimeProfile.operationalCategory
            self.massCategory = uavProfile?.massCategory ?? Self.derivedMassCategory(for: runtimeProfile.takeoffMassKg)
            self.missionRole = uavProfile?.missionRole?.lowercased() ?? "general"
        }

        private static func derivedMassCategory(for takeoffMassKg: Float) -> UAVMassCategory {
            switch takeoffMassKg {
            case ..<0.25:
                return .nano
            case ..<2.5:
                return .micro
            case ..<15.0:
                return .light
            case ..<120.0:
                return .medium
            case ..<250.0:
                return .heavy
            default:
                return .superheavy
            }
        }
    }
}

private enum UAVMapScaleRecommendationResolver {
    static func resolve(
        runtimeProfile: DroneModelProfile,
        operationalProfile: UAVOperationalProfile,
        currentScale: MapScale,
        payloadMassKg: Float,
        batteryFraction: Float,
        weatherPenalty: Float
    ) -> UAVMapScaleRecommendation {
        let effectiveBattery = batteryFraction.clamped(to: 0.22...1.0)
        let payloadFactor = max(
            0.42,
            1.0 - payloadMassKg * operationalProfile.payloadRangePenaltyPerKg
        )
        let weatherFactor = max(1.0, weatherPenalty)
        let dynamicOperationalRadius = max(
            36.0,
            operationalProfile.nominalMaxRangeM *
                (1.0 - operationalProfile.batteryReserveFraction) *
                effectiveBattery *
                payloadFactor /
                weatherFactor
        )

        let minimumTurnRadiusM: Float = {
            guard runtimeProfile.airframeClass == .fixedWing else {
                return max(4.0, runtimeProfile.collisionRadius * 7.5)
            }

            if let wing = runtimeProfile.fixedWingParameters {
                return max(8.0, wing.minimumTurnRadius(airspeed: wing.cruiseSpeedMps))
            }

            return max(8.0, operationalProfile.nominalCruiseSpeedMps * 2.2)
        }()

        let waypointAnticipationDistanceM: Float = {
            if let wing = runtimeProfile.fixedWingParameters {
                return max(
                    wing.waypointAcceptanceRadiusMeters * 1.75,
                    minimumTurnRadiusM * 0.85,
                    wing.cruiseSpeedMps * 1.4
                )
            }
            return max(2.0, runtimeProfile.maxHorizontalSpeedMps * 0.38)
        }()

        let maneuverFloor = max(
            18.0,
            runtimeProfile.airframeClass == .fixedWing
                ? max(minimumTurnRadiusM * 2.2, waypointAnticipationDistanceM * 1.35)
                : waypointAnticipationDistanceM * 1.05
        )
        let maneuverComfort = max(
            maneuverFloor * 1.28,
            runtimeProfile.airframeClass == .fixedWing
                ? minimumTurnRadiusM * 3.1
                : maneuverFloor * 1.20
        )
        let targetHalfExtent = max(
            maneuverComfort,
            min(dynamicOperationalRadius * 0.88, dynamicOperationalRadius)
        )
        let preferredUpperExtent = max(
            targetHalfExtent,
            min(dynamicOperationalRadius * 1.30, targetHalfExtent * 1.45)
        )

        var recommendedMin: MapScale = operationalProfile.preferredMapScaleMin
        var recommendedMax: MapScale = operationalProfile.preferredMapScaleMax
        var recommendedOperational: MapScale = operationalProfile.preferredMapScaleMax
        var unsuitable: [MapScale] = []

        // The adviser searches only the ordinary map sizes.
        //
        // Its "largest map that is not tight" rule has no upper bound of its own, so
        // before the extended ranges existed it always landed on the biggest scale
        // there was — harmless while that was 25.6 km, and nonsense the moment an
        // 819 km range joined the list, because every aircraft in the catalogue down
        // to a DJI Neo would have been advised to fly on it. Extended ranges are
        // chosen deliberately for high-altitude work, not recommended by area
        // arithmetic. `advisedCases` is `conventionalCases`, so behaviour for every
        // existing aircraft is exactly what it was.
        let advisedCases = MapScale.conventionalCases

        for scale in advisedCases {
            let extent = scale.worldHalfExtentMeters
            let suitability = resolveSuitability(
                extent: extent,
                maneuverFloor: maneuverFloor,
                maneuverComfort: maneuverComfort,
                targetHalfExtent: targetHalfExtent,
                preferredUpperExtent: preferredUpperExtent
            )

            if suitability == .unsuitable {
                unsuitable.append(scale)
            }

            if scale == currentScale {
                recommendedOperational = recommendedOperationalScale(
                    targetHalfExtent: targetHalfExtent
                )
            }
        }

        if let firstPreferred = advisedCases.first(where: {
            resolveSuitability(
                extent: $0.worldHalfExtentMeters,
                maneuverFloor: maneuverFloor,
                maneuverComfort: maneuverComfort,
                targetHalfExtent: targetHalfExtent,
                preferredUpperExtent: preferredUpperExtent
            ) != .unsuitable
        }) {
            recommendedMin = firstPreferred
        }

        if let lastPreferred = advisedCases.last(where: {
            resolveSuitability(
                extent: $0.worldHalfExtentMeters,
                maneuverFloor: maneuverFloor,
                maneuverComfort: maneuverComfort,
                targetHalfExtent: targetHalfExtent,
                preferredUpperExtent: preferredUpperExtent
            ) != .tight
        }) {
            let minIndex = advisedCases.firstIndex(of: recommendedMin) ?? 0
            let lastIndex = advisedCases.firstIndex(of: lastPreferred) ?? minIndex
            recommendedMax = advisedCases[max(minIndex, lastIndex)]
        } else {
            recommendedMax = recommendedOperationalScale(targetHalfExtent: targetHalfExtent)
        }

        recommendedOperational = recommendedOperationalScale(targetHalfExtent: targetHalfExtent)

        return UAVMapScaleRecommendation(
            recommendedMapScaleMin: recommendedMin,
            recommendedMapScaleMax: recommendedMax,
            recommendedOperationalMapScale: recommendedOperational,
            unsuitableMapScales: unsuitable,
            minimumTurnRadiusM: minimumTurnRadiusM,
            waypointAnticipationDistanceM: waypointAnticipationDistanceM,
            currentSuitability: resolveSuitability(
                extent: currentScale.worldHalfExtentMeters,
                maneuverFloor: maneuverFloor,
                maneuverComfort: maneuverComfort,
                targetHalfExtent: targetHalfExtent,
                preferredUpperExtent: preferredUpperExtent
            )
        )
    }

    private static func recommendedOperationalScale(targetHalfExtent: Float) -> MapScale {
        MapScale.conventionalCases.min { lhs, rhs in
            abs(lhs.worldHalfExtentMeters - targetHalfExtent) <
                abs(rhs.worldHalfExtentMeters - targetHalfExtent)
        } ?? .x32
    }

    private static func resolveSuitability(
        extent: Float,
        maneuverFloor: Float,
        maneuverComfort: Float,
        targetHalfExtent: Float,
        preferredUpperExtent: Float
    ) -> MapScaleSuitability {
        if extent < maneuverFloor {
            return .unsuitable
        }
        if extent < maneuverComfort {
            return .tight
        }
        if extent >= targetHalfExtent * 0.82 && extent <= preferredUpperExtent {
            return .optimal
        }
        if extent >= maneuverComfort {
            return .acceptable
        }
        return .tight
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
