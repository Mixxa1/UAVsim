import Foundation
import simd

enum AirframeClass: String, CaseIterable {
    case multirotor
    case fixedWing
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
    let turnAuthority: Float
    let maxBankAngleDeg: Float
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
        self.launchMethod = launchMethod
        self.landingMethod = landingMethod
        self.controlResponsiveness = controlResponsiveness
        self.hoverThrottle = hoverThrottle
        self.cameraPreset = cameraPreset
        self.collisionRadiusMeters = collisionRadiusMeters
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

    private static func runtimeProfile(from uavProfile: UAVProfile) -> DroneModelProfile {
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
            notes: uavProfile.notes,
            sourceURL: UAVReferenceCatalog.sourceURL(for: uavProfile.id),
            uavProfileID: uavProfile.id
        )
    }

    private static func runtimeTuning(for uavProfile: UAVProfile) -> RuntimeTuning {
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
                airframeClass: .fixedWing,
                airframeStyle: .tailsitterVTOL,
                fixedWingParameters: FixedWingParameters(
                    family: .tailsitterVTOL,
                    minSustainableSpeedMps: 11.8,
                    cruiseSpeedMps: 16.0,
                    turnAuthority: 0.68,
                    maxBankAngleDeg: 40.0
                ),
                launchMethod: .vertical,
                landingMethod: .tailsitterVerticalLanding,
                controlResponsiveness: 0.62,
                hoverThrottle: 0.0,
                cameraPreset: DroneCameraPreset(fpvFov: 72.0, followDistance: 8.2, followHeight: 2.6),
                collisionRadiusMeters: 0.34
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
                airframeClass: .fixedWing,
                airframeStyle: .surveyEVTOL,
                fixedWingParameters: FixedWingParameters(
                    family: .surveyEVTOL,
                    minSustainableSpeedMps: 12.5,
                    cruiseSpeedMps: 17.0,
                    turnAuthority: 0.60,
                    maxBankAngleDeg: 38.0
                ),
                launchMethod: .vertical,
                landingMethod: .vertical,
                controlResponsiveness: 0.58,
                hoverThrottle: 0.0,
                cameraPreset: DroneCameraPreset(fpvFov: 70.0, followDistance: 9.4, followHeight: 3.0),
                collisionRadiusMeters: 0.44
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
                    turnAuthority: 0.32,
                    maxBankAngleDeg: 28.0
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
                    turnAuthority: 0.36,
                    maxBankAngleDeg: 30.0
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
                    turnAuthority: 0.48,
                    maxBankAngleDeg: 34.0
                ),
                launchMethod: .handLaunch,
                landingMethod: .linearBellyLanding,
                controlResponsiveness: 0.40,
                hoverThrottle: 0.0,
                cameraPreset: DroneCameraPreset(fpvFov: 64.0, followDistance: 8.0, followHeight: 2.5),
                collisionRadiusMeters: 0.42
            )
        case .flyEye:
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
                    turnAuthority: 0.56,
                    maxBankAngleDeg: 36.0
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
        collisionRadiusMeters: Float
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
    }
}
