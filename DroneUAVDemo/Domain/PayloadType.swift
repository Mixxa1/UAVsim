import Foundation

enum PayloadType: String, CaseIterable, Identifiable, Hashable {
    case cargoBox
    case cameraGimbal
    case thermalCamera
    case lidarModule
    case laserRangefinder
    case fireHose
    case fireCapsuleLauncher
    case agriculturalSprayer
    case rescuePack
    case sensorModule
    case radioRelay
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cargoBox:
            return L10n.s("payload.type.cargo_box")
        case .cameraGimbal:
            return L10n.s("payload.type.camera_gimbal")
        case .thermalCamera:
            return L10n.s("payload.type.thermal_camera")
        case .lidarModule:
            return L10n.s("payload.type.lidar_module")
        case .laserRangefinder:
            return L10n.s("payload.type.laser_rangefinder")
        case .fireHose:
            return L10n.s("payload.type.fire_hose")
        case .fireCapsuleLauncher:
            return L10n.s("payload.type.fire_capsule_launcher")
        case .agriculturalSprayer:
            return L10n.s("payload.type.agricultural_sprayer")
        case .rescuePack:
            return L10n.s("payload.type.rescue_pack")
        case .sensorModule:
            return L10n.s("payload.type.sensor_module")
        case .radioRelay:
            return L10n.s("payload.type.radio_relay")
        case .custom:
            return L10n.s("payload.type.custom")
        }
    }

    var defaultMass: Float {
        switch self {
        case .cargoBox:
            return 3.0
        case .cameraGimbal:
            return 0.65
        case .thermalCamera:
            return 0.80
        case .lidarModule:
            return 1.40
        case .laserRangefinder:
            return 0.55
        case .fireHose:
            // Reference/baseline mass used for UI display and mass-scaling factors elsewhere —
            // matches a 30m standard-diameter rig (FireHoseDiameterClass.standard.massForLength(30)).
            // The actual configured mass varies with the rigged hose length/diameter class.
            return 59.0
        case .fireCapsuleLauncher:
            // Reference/baseline mass — matches a 2-capsule medium rig
            // (FireCapsuleTuning.totalMass(size: .medium, count: 2)). The actual configured mass
            // varies with the rigged capsule size/count.
            return 6.0
        case .agriculturalSprayer:
            // Reference/baseline mass for a full flagship-size tank
            // (AgriculturalSprayerTuning.massForFullTank()). Drains toward the empty hardware-only
            // mass at runtime as the tank sprays out.
            return 47.0
        case .rescuePack:
            return 2.20
        case .sensorModule:
            return 0.90
        case .radioRelay:
            return 1.10
        case .custom:
            return 1.00
        }
    }

    var defaultVisualPreset: PayloadVisualPreset {
        switch self {
        case .cargoBox:
            return .cargoBox
        case .cameraGimbal:
            return .cameraGimbal
        case .thermalCamera:
            return .thermalCamera
        case .lidarModule:
            return .lidarModule
        case .laserRangefinder:
            return .laserRangefinder
        case .fireHose:
            return .fireHose
        case .fireCapsuleLauncher:
            return .fireCapsuleLauncher
        case .agriculturalSprayer:
            return .agriculturalSprayer
        case .rescuePack:
            return .rescuePack
        case .sensorModule:
            return .sensorModule
        case .radioRelay:
            return .radioRelay
        case .custom:
            return .customModule
        }
    }
}
