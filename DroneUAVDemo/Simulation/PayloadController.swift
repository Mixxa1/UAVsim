import Foundation

enum PayloadController {
    static func defaultConfiguration() -> PayloadConfiguration {
        PayloadConfiguration()
    }

    static func capabilityCheck(
        for configuration: PayloadConfiguration,
        profile: UAVProfile?
    ) -> PayloadCapabilityCheck {
        let payloadMass = max(0.0, configuration.payloadMass)
        guard payloadMass > 0.001 else {
            return PayloadCapabilityCheck(
                isPayloadMassAllowed: false,
                isTakeoffMassAllowed: false,
                resultingTotalMass: nil,
                rejectReason: .invalidPayloadMass
            )
        }

        guard let profile else {
            return PayloadCapabilityCheck(
                isPayloadMassAllowed: false,
                isTakeoffMassAllowed: false,
                resultingTotalMass: nil,
                rejectReason: .selectUAVFirst
            )
        }

        let resolution = profile.payloadDataResolution

        guard let maxPayloadMass = resolution.maxPayloadMass,
              let maxTakeoffMass = resolution.maxTakeoffMass,
              let baseMass = resolution.baseMass,
              let batteryMass = resolution.batteryMass else {
            return .unavailable
        }

        let resultingTotalMass = baseMass + batteryMass + payloadMass
        let isPayloadMassAllowed = payloadMass <= maxPayloadMass + 0.0001
        let isTakeoffMassAllowed = resultingTotalMass <= maxTakeoffMass + 0.0001

        let rejectReason: PayloadCapabilityRejectReason?
        if !isPayloadMassAllowed {
            rejectReason = .payloadMassExceeded
        } else if !isTakeoffMassAllowed {
            rejectReason = .totalMassExceeded
        } else {
            rejectReason = nil
        }

        return PayloadCapabilityCheck(
            isPayloadMassAllowed: isPayloadMassAllowed,
            isTakeoffMassAllowed: isTakeoffMassAllowed,
            resultingTotalMass: resultingTotalMass,
            rejectReason: rejectReason
        )
    }

    static func massModel(
        for runtimeProfile: DroneModelProfile,
        uavProfile: UAVProfile?,
        installedPayload: PayloadConfiguration?,
        payloadState: PayloadState
    ) -> VehicleMassModel {
        let payloadMass: Float
        if payloadState == .attached, let installedPayload {
            payloadMass = max(0.0, installedPayload.payloadMass)
        } else {
            payloadMass = 0.0
        }

        return VehicleMassModel.resolve(
            for: runtimeProfile,
            uavProfile: uavProfile,
            payloadMass: payloadMass
        )
    }
}
