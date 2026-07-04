import Foundation

enum PayloadType: String, CaseIterable, Identifiable, Hashable {
    case cargoBox
    case cameraGimbal
    case thermalCamera
    case lidarModule
    case laserRangefinder
    case fireHose
    case fireCapsuleLauncher
    case rescuePack
    case sensorModule
    case radioRelay
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cargoBox:
            return NSLocalizedString("payload.type.cargo_box", comment: "")
        case .cameraGimbal:
            return NSLocalizedString("payload.type.camera_gimbal", comment: "")
        case .thermalCamera:
            return NSLocalizedString("payload.type.thermal_camera", comment: "")
        case .lidarModule:
            return NSLocalizedString("payload.type.lidar_module", comment: "")
        case .laserRangefinder:
            return NSLocalizedString("payload.type.laser_rangefinder", comment: "")
        case .fireHose:
            return NSLocalizedString("payload.type.fire_hose", comment: "")
        case .fireCapsuleLauncher:
            return NSLocalizedString("payload.type.fire_capsule_launcher", comment: "")
        case .rescuePack:
            return NSLocalizedString("payload.type.rescue_pack", comment: "")
        case .sensorModule:
            return NSLocalizedString("payload.type.sensor_module", comment: "")
        case .radioRelay:
            return NSLocalizedString("payload.type.radio_relay", comment: "")
        case .custom:
            return NSLocalizedString("payload.type.custom", comment: "")
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
