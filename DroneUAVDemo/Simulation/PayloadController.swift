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
        guard payloadState == .attached,
              let installedPayload else {
            return VehicleMassModel.baseline(for: runtimeProfile, uavProfile: uavProfile)
        }

        let payloadMass = max(0.0, installedPayload.payloadMass)
        let baselineMass = max(0.30, runtimeProfile.takeoffMassKg)
        let resolution = uavProfile?.payloadDataResolution
        let payloadReference = max(
            0.25,
            max(resolution?.maxPayloadMass ?? payloadMass, payloadMass > 0.0 ? payloadMass : 0.25)
        )
        let normalizedLoad = min(1.0, max(0.0, payloadMass / payloadReference))
        let verticalLoadPenalty = min(0.18, max(0.0, 0.04 + normalizedLoad * 0.12))
        let maneuverPenalty = min(0.16, max(0.0, 0.03 + normalizedLoad * 0.11))
        let hoverThrottleAdjustment = runtimeProfile.airframeClass == .multirotor
            ? min(0.14, max(0.0, 0.015 + normalizedLoad * 0.11))
            : 0.0

        let currentTotalMass: Float?
        if let baseMass = resolution?.baseMass, let batteryMass = resolution?.batteryMass {
            currentTotalMass = baseMass + batteryMass + payloadMass
        } else {
            currentTotalMass = nil
        }

        return VehicleMassModel(
            baseMass: resolution?.baseMass,
            batteryMass: resolution?.batteryMass,
            payloadMass: payloadMass,
            currentTotalMass: currentTotalMass,
            effectiveMass: baselineMass + payloadMass,
            verticalLoadPenalty: verticalLoadPenalty,
            maneuverPenalty: maneuverPenalty,
            hoverThrottleAdjustment: hoverThrottleAdjustment
        )
    }
}
