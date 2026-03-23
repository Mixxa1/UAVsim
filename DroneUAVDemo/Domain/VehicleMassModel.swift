import Foundation

struct VehicleMassModel: Hashable {
    let baseMass: Float?
    let batteryMass: Float?
    let payloadMass: Float
    let currentTotalMass: Float?
    let effectiveMass: Float
    let payloadLoadRatio: Float
    let massSourceQuality: PayloadDataQualitySource
    let usesEstimatedValues: Bool

    static func baseline(for runtimeProfile: DroneModelProfile, uavProfile: UAVProfile?) -> VehicleMassModel {
        resolve(for: runtimeProfile, uavProfile: uavProfile, payloadMass: 0.0)
    }

    static func resolve(
        for runtimeProfile: DroneModelProfile,
        uavProfile: UAVProfile?,
        payloadMass: Float
    ) -> VehicleMassModel {
        let resolution = uavProfile?.payloadDataResolution
        let baseMass = resolution?.baseMass
        let batteryMass = resolution?.batteryMass
        let currentTotalMass = totalMass(baseMass: baseMass, batteryMass: batteryMass, payloadMass: payloadMass)
        let fallbackBaselineMass = baselineMassEstimate(
            runtimeProfile: runtimeProfile,
            resolution: resolution
        )
        let effectiveMass = max(0.20, currentTotalMass ?? (fallbackBaselineMass + payloadMass))
        let payloadReference = max(
            0.25,
            resolution?.maxPayloadMass ?? max(0.35, fallbackBaselineMass * 0.18)
        )
        let massSourceQuality = resolution?.sourceQuality ?? (uavProfile?.specConfidence == .custom ? .custom : .estimated)
        let usesEstimatedValues = resolution?.usesEstimatedValues ?? (uavProfile?.specConfidence != .custom)

        return VehicleMassModel(
            baseMass: baseMass,
            batteryMass: batteryMass,
            payloadMass: payloadMass,
            currentTotalMass: currentTotalMass,
            effectiveMass: effectiveMass,
            payloadLoadRatio: payloadMass <= 0.0001 ? 0.0 : min(1.0, max(0.0, payloadMass / payloadReference)),
            massSourceQuality: massSourceQuality,
            usesEstimatedValues: usesEstimatedValues
        )
    }

    var resolvedCurrentTotalMass: Float {
        currentTotalMass ?? effectiveMass
    }

    private static func totalMass(
        baseMass: Float?,
        batteryMass: Float?,
        payloadMass: Float
    ) -> Float? {
        guard let baseMass, let batteryMass else {
            return nil
        }
        return baseMass + batteryMass + payloadMass
    }

    private static func baselineMassEstimate(
        runtimeProfile: DroneModelProfile,
        resolution: PayloadDataResolution?
    ) -> Float {
        if let baseMass = resolution?.baseMass,
           let batteryMass = resolution?.batteryMass {
            return max(0.20, baseMass + batteryMass)
        }

        if let maxTakeoffMass = resolution?.maxTakeoffMass,
           let maxPayloadMass = resolution?.maxPayloadMass {
            return max(0.20, maxTakeoffMass - maxPayloadMass)
        }

        if let maxTakeoffMass = resolution?.maxTakeoffMass {
            return max(0.20, maxTakeoffMass)
        }

        return max(0.20, runtimeProfile.takeoffMassKg)
    }
}
