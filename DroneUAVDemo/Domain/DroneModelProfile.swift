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
        }
    }

    var titleKey: String {
        "tactical.map.launch.mode.\(rawValue)"
    }

    /// Runway and mission-placed VTOL starts remain separate future features.
    /// Do not expose them through the assisted fixed-wing launch workflow until
    /// they have their own ground-roll/transition dynamics.
    var isRuntimeImplemented: Bool {
        switch self {
        case .standard, .handLaunch, .catapult:
            return true
        case .runway, .vtol:
            return false
        }
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

enum FixedWingFamily: String, CaseIterable {
    case rectangular
    case delta
    case swept
    case flyingWing
    case conventionalSurvey
    case tailsitterVTOL
    case surveyEVTOL
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
    let launchPreSpoolSeconds: Float
    let runwayTakeoffDistance: Float
    let initialClimbTargetAltitude: Float

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
        launchPreSpoolSeconds: Float = 0.45,
        runwayTakeoffDistance: Float = 45.0,
        initialClimbTargetAltitude: Float = 18.0
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
        self.catapultExitSpeed = max(
            catapultExitSpeed ?? 0.0,
            max(self.minSafeAirspeed * 1.28, self.climbAirspeed)
        )
        self.handLaunchAngleDegrees = handLaunchAngleDegrees.clamped(
            to: FixedWingHandLaunchTuning.minimumLaunchAngleDegrees...20.0
        )
        self.handReleaseHeightMeters = handReleaseHeightMeters.clamped(to: 0.8...2.2)
        self.catapultRailAngleDegrees = catapultRailAngleDegrees.clamped(to: 4.0...22.0)
        self.maxCatapultAccelerationG = maxCatapultAccelerationG.clamped(to: 2.0...12.0)
        let minimumRailLength = (self.catapultExitSpeed * self.catapultExitSpeed) /
            (2.0 * self.maxCatapultAccelerationG * 9.81)
        self.catapultRailLengthMeters = max(
            minimumRailLength,
            catapultRailLengthMeters ?? max(4.2, minimumRailLength)
        )
        self.launchPreSpoolSeconds = launchPreSpoolSeconds.clamped(to: 0.15...2.0)
        self.runwayTakeoffDistance = runwayTakeoffDistance
        self.initialClimbTargetAltitude = initialClimbTargetAltitude
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
        }
    }
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

    let notes: String
    let sourceURL: URL?
    let uavProfileID: String?

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
        uavProfileID: String? = nil
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
    }

    var isAbstract: Bool {
        id == "abstract-uav"
    }

    var resolvedUAVProfile: UAVProfile? {
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

        return DroneModelProfile(
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
            uavProfileID: uavProfile.id
        )
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
                collisionRadiusMeters: 0.38
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
                collisionRadiusMeters: 0.24
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
                collisionRadiusMeters: 0.12
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
                collisionRadiusMeters: 0.28
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
                collisionRadiusMeters: 0.62
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
                ]
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
                ]
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
                collisionRadiusMeters: 0.82
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
                collisionRadiusMeters: 0.78
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
                collisionRadiusMeters: 0.96
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
                collisionRadiusMeters: 0.66
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
                collisionRadiusMeters: 0.86
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
                collisionRadiusMeters: 1.15
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
                collisionRadiusMeters: 1.40
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
                collisionRadiusMeters: 0.70
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
                    runwayTakeoffDistance: 260.0,
                    initialClimbTargetAltitude: 55.0
                ),
                launchMethod: .handLaunch,
                landingMethod: .bellyLanding,
                controlResponsiveness: 0.20,
                hoverThrottle: 0.0,
                cameraPreset: DroneCameraPreset(fpvFov: 54.0, followDistance: 10.8, followHeight: 3.6),
                collisionRadiusMeters: 0.58
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
                    runwayTakeoffDistance: 180.0,
                    initialClimbTargetAltitude: 40.0
                ),
                launchMethod: .handLaunch,
                landingMethod: .bellyLanding,
                controlResponsiveness: 0.24,
                hoverThrottle: 0.0,
                cameraPreset: DroneCameraPreset(fpvFov: 56.0, followDistance: 9.4, followHeight: 3.0),
                collisionRadiusMeters: 0.52
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
                collisionRadiusMeters: 0.42
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
                collisionRadiusMeters: 0.28
            )
        }
    }

    private static func runtimeTuningOverride(
        for uavProfile: UAVProfile
    ) -> RuntimeTuning? {
        switch uavProfile.id {
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
                collisionRadiusMeters: 0.24
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
                collisionRadiusMeters: 0.26
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
                collisionRadiusMeters: 0.35
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
                collisionRadiusMeters: 0.58
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
                collisionRadiusMeters: 0.26
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
                collisionRadiusMeters: 0.36
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
                )
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
                ]
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
                collisionRadiusMeters: 0.34
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
                collisionRadiusMeters: 0.27
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
                collisionRadiusMeters: 0.29
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
                collisionRadiusMeters: 0.14
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
                collisionRadiusMeters: 0.12
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
                )
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
                )
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
        collisionRadiusMeters: Float
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
            collisionRadiusMeters: collisionRadiusMeters
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
        fixedWingParameters: FixedWingParameters
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
            collisionRadiusMeters: collisionRadiusMeters
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
        propulsionUnitTemplate: [PropulsionUnit]
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
            propulsionUnitTemplate: propulsionUnitTemplate
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
        propulsionUnitTemplate: [PropulsionUnit] = []
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
    }
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
            estimatedDataQuality: quality
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
            estimatedDataQuality: quality
        )
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

        for scale in MapScale.allCases {
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

        if let firstPreferred = MapScale.allCases.first(where: {
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

        if let lastPreferred = MapScale.allCases.last(where: {
            resolveSuitability(
                extent: $0.worldHalfExtentMeters,
                maneuverFloor: maneuverFloor,
                maneuverComfort: maneuverComfort,
                targetHalfExtent: targetHalfExtent,
                preferredUpperExtent: preferredUpperExtent
            ) != .tight
        }) {
            let minIndex = MapScale.allCases.firstIndex(of: recommendedMin) ?? 0
            let lastIndex = MapScale.allCases.firstIndex(of: lastPreferred) ?? minIndex
            recommendedMax = MapScale.allCases[max(minIndex, lastIndex)]
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
        MapScale.allCases.min { lhs, rhs in
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
