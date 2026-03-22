import Foundation

struct VehicleMassModel: Hashable {
    let baseMass: Float?
    let batteryMass: Float?
    let payloadMass: Float
    let currentTotalMass: Float?
    let effectiveMass: Float
    let verticalLoadPenalty: Float
    let maneuverPenalty: Float
    let hoverThrottleAdjustment: Float

    static func baseline(for runtimeProfile: DroneModelProfile, uavProfile: UAVProfile?) -> VehicleMassModel {
        let resolution = uavProfile?.payloadDataResolution
        let baseMass = resolution?.baseMass
        let batteryMass = resolution?.batteryMass
        let currentTotalMass: Float?
        if let baseMass, let batteryMass {
            currentTotalMass = baseMass + batteryMass
        } else {
            currentTotalMass = nil
        }

        return VehicleMassModel(
            baseMass: baseMass,
            batteryMass: batteryMass,
            payloadMass: 0.0,
            currentTotalMass: currentTotalMass,
            effectiveMass: runtimeProfile.takeoffMassKg,
            verticalLoadPenalty: 0.0,
            maneuverPenalty: 0.0,
            hoverThrottleAdjustment: 0.0
        )
    }
}
