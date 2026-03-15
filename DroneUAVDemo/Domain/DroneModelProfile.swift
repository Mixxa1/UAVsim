import Foundation
import simd

enum AirframeClass: String, CaseIterable {
    case multirotor
    case fixedWing
}

enum FixedWingFamily: String, CaseIterable {
    case rectangular
    case delta
    case swept
}

enum DroneVisualClass: String, CaseIterable {
    case miniCompact
    case airMidDual
    case mavicProTriple
    case abstract
    case fixedWingRectangular
    case fixedWingDelta
    case fixedWingSwept

    var titleKey: String {
        switch self {
        case .miniCompact:
            return "drone.visual.mini"
        case .airMidDual:
            return "drone.visual.air"
        case .mavicProTriple:
            return "drone.visual.mavic"
        case .abstract:
            return "drone.visual.abstract"
        case .fixedWingRectangular:
            return "drone.visual.fixed_rect"
        case .fixedWingDelta:
            return "drone.visual.fixed_delta"
        case .fixedWingSwept:
            return "drone.visual.fixed_swept"
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
    let airframeClass: AirframeClass
    let fixedWingParameters: FixedWingParameters?

    let controlResponsiveness: Float
    let hoverThrottle: Float
    let cameraPreset: DroneCameraPreset
    let collisionRadiusMeters: Float

    let notes: String
    let sourceURL: URL?

    var isAbstract: Bool {
        id == "abstract-uav"
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

struct DJIDroneModelRepository: DroneModelRepository {
    let allProfiles: [DroneModelProfile]

    init(abstractParameters: AbstractDroneParameters = .default) {
        allProfiles = [
            DroneModelProfile(
                id: "dji-mini-4-pro",
                displayName: "DJI Mini 4 Pro",
                displayNameKey: "drone.model.mini4pro",
                manufacturer: "DJI",
                takeoffMassKg: 0.249,
                dimensionsFoldedMm: DroneDimensionsMM(x: 148, y: 94, z: 64),
                dimensionsUnfoldedMm: DroneDimensionsMM(x: 298, y: 373, z: 101),
                maxHorizontalSpeedMps: 16.0,
                maxAscentSpeedMps: 5.0,
                maxDescentSpeedMps: 5.0,
                maxFlightTimeMin: 34.0,
                maxHoverTimeMin: 30.0,
                maxWindResistanceMps: 10.7,
                batteryCapacitymAh: 2590,
                batteryEnergyWh: 18.96,
                cameraLayoutKey: "drone.camera.single_compact",
                visualClass: .miniCompact,
                airframeClass: .multirotor,
                fixedWingParameters: nil,
                controlResponsiveness: 0.92,
                hoverThrottle: 0.54,
                cameraPreset: DroneCameraPreset(fpvFov: 84.0, followDistance: 7.4, followHeight: 2.6),
                collisionRadiusMeters: 0.22,
                notes: "Light compact quadcopter",
                sourceURL: URL(string: "https://www.dji.com/mini-4-pro/specs")
            ),
            DroneModelProfile(
                id: "dji-air-3s",
                displayName: "DJI Air 3S",
                displayNameKey: "drone.model.air3s",
                manufacturer: "DJI",
                takeoffMassKg: 0.724,
                dimensionsFoldedMm: DroneDimensionsMM(x: 214.19, y: 100.63, z: 89.17),
                dimensionsUnfoldedMm: DroneDimensionsMM(x: 266.11, y: 325.47, z: 106.0),
                maxHorizontalSpeedMps: 21.0,
                maxAscentSpeedMps: 10.0,
                maxDescentSpeedMps: 10.0,
                maxFlightTimeMin: 45.0,
                maxHoverTimeMin: 41.0,
                maxWindResistanceMps: 12.0,
                batteryCapacitymAh: 4276,
                batteryEnergyWh: 62.5,
                cameraLayoutKey: "drone.camera.dual_front",
                visualClass: .airMidDual,
                airframeClass: .multirotor,
                fixedWingParameters: nil,
                controlResponsiveness: 0.86,
                hoverThrottle: 0.56,
                cameraPreset: DroneCameraPreset(fpvFov: 82.0, followDistance: 8.8, followHeight: 3.1),
                collisionRadiusMeters: 0.28,
                notes: "Mid-size dual-camera quadcopter",
                sourceURL: URL(string: "https://www.dji.com/air-3s/specs")
            ),
            DroneModelProfile(
                id: "dji-mavic-3-pro",
                displayName: "DJI Mavic 3 Pro",
                displayNameKey: "drone.model.mavic3pro",
                manufacturer: "DJI",
                takeoffMassKg: 0.958,
                dimensionsFoldedMm: DroneDimensionsMM(x: 231.1, y: 98.0, z: 95.4),
                dimensionsUnfoldedMm: DroneDimensionsMM(x: 347.5, y: 290.8, z: 107.7),
                maxHorizontalSpeedMps: 21.0,
                maxAscentSpeedMps: 8.0,
                maxDescentSpeedMps: 6.0,
                maxFlightTimeMin: 43.0,
                maxHoverTimeMin: 37.0,
                maxWindResistanceMps: 12.0,
                batteryCapacitymAh: 5000,
                batteryEnergyWh: 77.0,
                cameraLayoutKey: "drone.camera.triple_front",
                visualClass: .mavicProTriple,
                airframeClass: .multirotor,
                fixedWingParameters: nil,
                controlResponsiveness: 0.77,
                hoverThrottle: 0.58,
                cameraPreset: DroneCameraPreset(fpvFov: 80.0, followDistance: 9.4, followHeight: 3.3),
                collisionRadiusMeters: 0.32,
                notes: "Larger professional quadcopter",
                sourceURL: URL(string: "https://www.dji.com/mavic-3-pro/specs")
            ),
            DroneModelProfile(
                id: "fixedwing-rectangular",
                displayName: "Rectangular Wing UAV",
                displayNameKey: "drone.model.fixed_rect",
                manufacturer: "AeroLab",
                takeoffMassKg: 1.45,
                dimensionsFoldedMm: DroneDimensionsMM(x: 530, y: 220, z: 120),
                dimensionsUnfoldedMm: DroneDimensionsMM(x: 1250, y: 760, z: 180),
                maxHorizontalSpeedMps: 32.0,
                maxAscentSpeedMps: 5.5,
                maxDescentSpeedMps: 6.5,
                maxFlightTimeMin: 52.0,
                maxHoverTimeMin: 0.0,
                maxWindResistanceMps: 14.0,
                batteryCapacitymAh: 6800,
                batteryEnergyWh: 102.0,
                cameraLayoutKey: "drone.camera.fixed_front",
                visualClass: .fixedWingRectangular,
                airframeClass: .fixedWing,
                fixedWingParameters: FixedWingParameters(
                    family: .rectangular,
                    minSustainableSpeedMps: 11.0,
                    cruiseSpeedMps: 18.0,
                    turnAuthority: 0.75,
                    maxBankAngleDeg: 48.0
                ),
                controlResponsiveness: 0.68,
                hoverThrottle: 0.0,
                cameraPreset: DroneCameraPreset(fpvFov: 74.0, followDistance: 12.0, followHeight: 4.2),
                collisionRadiusMeters: 0.44,
                notes: "Straight rectangular wing, front propulsion",
                sourceURL: nil
            ),
            DroneModelProfile(
                id: "fixedwing-delta",
                displayName: "Delta Wing UAV",
                displayNameKey: "drone.model.fixed_delta",
                manufacturer: "AeroLab",
                takeoffMassKg: 1.10,
                dimensionsFoldedMm: DroneDimensionsMM(x: 420, y: 200, z: 95),
                dimensionsUnfoldedMm: DroneDimensionsMM(x: 980, y: 820, z: 120),
                maxHorizontalSpeedMps: 42.0,
                maxAscentSpeedMps: 7.2,
                maxDescentSpeedMps: 8.0,
                maxFlightTimeMin: 40.0,
                maxHoverTimeMin: 0.0,
                maxWindResistanceMps: 16.0,
                batteryCapacitymAh: 5600,
                batteryEnergyWh: 86.0,
                cameraLayoutKey: "drone.camera.fixed_front",
                visualClass: .fixedWingDelta,
                airframeClass: .fixedWing,
                fixedWingParameters: FixedWingParameters(
                    family: .delta,
                    minSustainableSpeedMps: 13.5,
                    cruiseSpeedMps: 24.0,
                    turnAuthority: 1.0,
                    maxBankAngleDeg: 62.0
                ),
                controlResponsiveness: 0.82,
                hoverThrottle: 0.0,
                cameraPreset: DroneCameraPreset(fpvFov: 78.0, followDistance: 13.0, followHeight: 4.5),
                collisionRadiusMeters: 0.38,
                notes: "Delta wing high-speed profile",
                sourceURL: nil
            ),
            DroneModelProfile(
                id: "fixedwing-swept",
                displayName: "Swept Wing UAV",
                displayNameKey: "drone.model.fixed_swept",
                manufacturer: "AeroLab",
                takeoffMassKg: 1.70,
                dimensionsFoldedMm: DroneDimensionsMM(x: 610, y: 260, z: 150),
                dimensionsUnfoldedMm: DroneDimensionsMM(x: 1520, y: 900, z: 210),
                maxHorizontalSpeedMps: 36.0,
                maxAscentSpeedMps: 6.0,
                maxDescentSpeedMps: 6.8,
                maxFlightTimeMin: 60.0,
                maxHoverTimeMin: 0.0,
                maxWindResistanceMps: 15.0,
                batteryCapacitymAh: 7800,
                batteryEnergyWh: 118.0,
                cameraLayoutKey: "drone.camera.fixed_front",
                visualClass: .fixedWingSwept,
                airframeClass: .fixedWing,
                fixedWingParameters: FixedWingParameters(
                    family: .swept,
                    minSustainableSpeedMps: 12.0,
                    cruiseSpeedMps: 20.0,
                    turnAuthority: 0.70,
                    maxBankAngleDeg: 52.0
                ),
                controlResponsiveness: 0.64,
                hoverThrottle: 0.0,
                cameraPreset: DroneCameraPreset(fpvFov: 72.0, followDistance: 14.5, followHeight: 5.0),
                collisionRadiusMeters: 0.50,
                notes: "Swept/curved wing long-endurance profile",
                sourceURL: nil
            ),
            Self.abstractProfile(from: abstractParameters)
        ]
    }

    var defaultProfile: DroneModelProfile {
        allProfiles[1]
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
            airframeClass: .multirotor,
            fixedWingParameters: nil,
            controlResponsiveness: parameters.controlResponsiveness,
            hoverThrottle: 0.56,
            cameraPreset: DroneCameraPreset(fpvFov: 82.0, followDistance: 8.0, followHeight: 2.8),
            collisionRadiusMeters: parameters.collisionRadiusMeters,
            notes: "User editable abstract profile",
            sourceURL: nil
        )
    }
}
