import Foundation

enum UAVFlightTuningSource: String, Hashable {
    case estimated
    case custom
}

struct UAVFlightTuningProfile: Hashable {
    struct MulticopterTuning: Hashable {
        let hoverThrottleBaseline: Float
        let stabilizationThrustBaseline: Float
        let verticalResponseFactor: Float
        let throttleAuthority: Float
        let maneuverPenaltyFactor: Float
        let payloadThrustCompensationFactor: Float
    }

    struct HelicopterTuning: Hashable {
        let hoverThrottleBaseline: Float
        let stabilizationThrustBaseline: Float
        let verticalResponseFactor: Float
        let throttleAuthority: Float
        let maneuverPenaltyFactor: Float
        let payloadThrustCompensationFactor: Float
    }

    struct FixedWingTuning: Hashable {
        let cruiseThrottleBaseline: Float
        let minimumSafeFlightThrottle: Float
        let climbThrottleBaseline: Float
        let glideThrottleFactor: Float
        let stallProtectionBias: Float
        let payloadCruisePenaltyFactor: Float
    }

    struct HybridVTOLTuning: Hashable {
        let hoverThrottleBaseline: Float
        let transitionThrottleBaseline: Float
        let cruiseThrottleBaseline: Float
        let verticalResponseFactor: Float
        let transitionResponseFactor: Float
        let payloadThrustCompensationFactor: Float
    }

    struct CustomTuning: Hashable {
        let configurableHoverThrottleBaseline: Float
        let configurableCruiseThrottleBaseline: Float
        let configurableThrottleAuthority: Float
        let configurableVerticalResponseFactor: Float
    }

    let vehicleType: UAVVehicleType
    let source: UAVFlightTuningSource
    let referenceMass: Float
    let multicopter: MulticopterTuning?
    let helicopter: HelicopterTuning?
    let fixedWing: FixedWingTuning?
    let hybridVTOL: HybridVTOLTuning?
    let custom: CustomTuning?

    static func catalogDefault(
        vehicleType: UAVVehicleType,
        specConfidence: UAVSpecConfidence,
        baseMass: Float?,
        batteryMass: Float?,
        estimatedBatteryMass: Float?,
        maxPayloadMass: Float?,
        estimatedMaxPayloadMass: Float?,
        maxTakeoffMass: Float?,
        estimatedMaxTakeoffMass: Float?,
        visualPreset: UAVVisualPreset
    ) -> UAVFlightTuningProfile {
        let resolvedBatteryMass = batteryMass ?? estimatedBatteryMass
        let resolvedPayloadMass = maxPayloadMass ?? estimatedMaxPayloadMass
        let resolvedTakeoffMass = maxTakeoffMass ?? estimatedMaxTakeoffMass
        let referenceMass = resolvedReferenceMass(
            baseMass: baseMass,
            batteryMass: resolvedBatteryMass,
            maxPayloadMass: resolvedPayloadMass,
            maxTakeoffMass: resolvedTakeoffMass
        )
        let source: UAVFlightTuningSource = specConfidence == .custom ? .custom : .estimated

        switch visualPreset {
        case .djiNeo:
            return multicopter(
                referenceMass: referenceMass,
                hoverThrottleBaseline: 0.46,
                stabilizationThrustBaseline: 1.96,
                verticalResponseFactor: 1.20,
                throttleAuthority: 1.08,
                maneuverPenaltyFactor: 0.20,
                payloadThrustCompensationFactor: 0.42,
                source: source
            )
        case .djiMavic4Pro:
            return multicopter(
                referenceMass: referenceMass,
                hoverThrottleBaseline: 0.50,
                stabilizationThrustBaseline: 1.90,
                verticalResponseFactor: 1.10,
                throttleAuthority: 1.00,
                maneuverPenaltyFactor: 0.24,
                payloadThrustCompensationFactor: 0.38,
                source: source
            )
        case .djiPhantom3Standard:
            return multicopter(
                referenceMass: referenceMass,
                hoverThrottleBaseline: 0.54,
                stabilizationThrustBaseline: 1.84,
                verticalResponseFactor: 0.96,
                throttleAuthority: 0.90,
                maneuverPenaltyFactor: 0.30,
                payloadThrustCompensationFactor: 0.34,
                source: source
            )
        case .djiMatrice350RTK:
            return multicopter(
                referenceMass: referenceMass,
                hoverThrottleBaseline: 0.58,
                stabilizationThrustBaseline: 1.78,
                verticalResponseFactor: 0.88,
                throttleAuthority: 0.82,
                maneuverPenaltyFactor: 0.34,
                payloadThrustCompensationFactor: 0.48,
                source: source
            )
        case .djiFlyCart30:
            return multicopter(
                referenceMass: referenceMass,
                hoverThrottleBaseline: 0.64,
                stabilizationThrustBaseline: 1.62,
                verticalResponseFactor: 0.72,
                throttleAuthority: 0.64,
                maneuverPenaltyFactor: 0.46,
                payloadThrustCompensationFactor: 0.58,
                source: source
            )
        case .freeflyAltaX:
            return multicopter(
                referenceMass: referenceMass,
                hoverThrottleBaseline: 0.61,
                stabilizationThrustBaseline: 1.68,
                verticalResponseFactor: 0.78,
                throttleAuthority: 0.70,
                maneuverPenaltyFactor: 0.42,
                payloadThrustCompensationFactor: 0.54,
                source: source
            )
        case .griff30:
            return multicopter(
                referenceMass: referenceMass,
                hoverThrottleBaseline: 0.62,
                stabilizationThrustBaseline: 1.65,
                verticalResponseFactor: 0.76,
                throttleAuthority: 0.68,
                maneuverPenaltyFactor: 0.44,
                payloadThrustCompensationFactor: 0.56,
                source: source
            )
        case .griff60:
            return multicopter(
                referenceMass: referenceMass,
                hoverThrottleBaseline: 0.67,
                stabilizationThrustBaseline: 1.58,
                verticalResponseFactor: 0.70,
                throttleAuthority: 0.60,
                maneuverPenaltyFactor: 0.50,
                payloadThrustCompensationFactor: 0.62,
                source: source
            )
        case .avidrone490TL:
            return helicopter(
                referenceMass: referenceMass,
                hoverThrottleBaseline: 0.59,
                stabilizationThrustBaseline: 1.72,
                verticalResponseFactor: 0.82,
                throttleAuthority: 0.72,
                maneuverPenaltyFactor: 0.38,
                payloadThrustCompensationFactor: 0.50,
                source: source
            )
        case .wingtraOneGenII:
            return hybridVTOL(
                referenceMass: referenceMass,
                hoverThrottleBaseline: 0.60,
                transitionThrottleBaseline: 0.55,
                cruiseThrottleBaseline: 0.43,
                verticalResponseFactor: 0.82,
                transitionResponseFactor: 0.76,
                payloadThrustCompensationFactor: 0.34,
                source: source
            )
        case .quantumSystemsTrinityPro:
            return hybridVTOL(
                referenceMass: referenceMass,
                hoverThrottleBaseline: 0.58,
                transitionThrottleBaseline: 0.53,
                cruiseThrottleBaseline: 0.41,
                verticalResponseFactor: 0.80,
                transitionResponseFactor: 0.74,
                payloadThrustCompensationFactor: 0.32,
                source: source
            )
        case .mq9bSkyGuardian:
            return fixedWing(
                referenceMass: referenceMass,
                cruiseThrottleBaseline: 0.54,
                minimumSafeFlightThrottle: 0.46,
                climbThrottleBaseline: 0.68,
                glideThrottleFactor: 0.66,
                stallProtectionBias: 0.22,
                payloadCruisePenaltyFactor: 0.18,
                source: source
            )
        case .hermes900:
            return fixedWing(
                referenceMass: referenceMass,
                cruiseThrottleBaseline: 0.51,
                minimumSafeFlightThrottle: 0.44,
                climbThrottleBaseline: 0.64,
                glideThrottleFactor: 0.67,
                stallProtectionBias: 0.24,
                payloadCruisePenaltyFactor: 0.16,
                source: source
            )
        case .ft5Los:
            return fixedWing(
                referenceMass: referenceMass,
                cruiseThrottleBaseline: 0.49,
                minimumSafeFlightThrottle: 0.41,
                climbThrottleBaseline: 0.61,
                glideThrottleFactor: 0.70,
                stallProtectionBias: 0.28,
                payloadCruisePenaltyFactor: 0.18,
                source: source
            )
        case .flyEye:
            return fixedWing(
                referenceMass: referenceMass,
                cruiseThrottleBaseline: 0.45,
                minimumSafeFlightThrottle: 0.38,
                climbThrottleBaseline: 0.57,
                glideThrottleFactor: 0.74,
                stallProtectionBias: 0.32,
                payloadCruisePenaltyFactor: 0.20,
                source: source
            )
        case .abstractCustom:
            return custom(
                referenceMass: max(0.35, referenceMass),
                configurableHoverThrottleBaseline: dynamicCustomHoverBaseline(referenceMass: referenceMass),
                configurableCruiseThrottleBaseline: 0.50,
                configurableThrottleAuthority: dynamicCustomAuthority(referenceMass: referenceMass),
                configurableVerticalResponseFactor: dynamicCustomVerticalResponse(referenceMass: referenceMass)
            )
        }
    }

    static func runtimeFallback(for runtimeProfile: DroneModelProfile) -> UAVFlightTuningProfile {
        let referenceMass = max(0.35, runtimeProfile.takeoffMassKg)

        switch runtimeProfile.operationalCategory {
        case .fixedWingVTOL:
            return hybridVTOL(
                referenceMass: referenceMass,
                hoverThrottleBaseline: 0.58,
                transitionThrottleBaseline: 0.53,
                cruiseThrottleBaseline: 0.42,
                verticalResponseFactor: 0.80,
                transitionResponseFactor: 0.74,
                payloadThrustCompensationFactor: 0.32,
                source: .estimated
            )
        case .fixedWing:
            return fixedWing(
                referenceMass: referenceMass,
                cruiseThrottleBaseline: 0.48,
                minimumSafeFlightThrottle: 0.40,
                climbThrottleBaseline: 0.60,
                glideThrottleFactor: 0.70,
                stallProtectionBias: 0.28,
                payloadCruisePenaltyFactor: 0.18,
                source: .estimated
            )
        case .multirotor:
            return multicopter(
                referenceMass: referenceMass,
                hoverThrottleBaseline: runtimeProfile.hoverThrottle.clamped(to: 0.42...0.68),
                stabilizationThrustBaseline: 1.80,
                verticalResponseFactor: 0.92,
                throttleAuthority: 0.84,
                maneuverPenaltyFactor: 0.32,
                payloadThrustCompensationFactor: 0.40,
                source: .estimated
            )
        }
    }

    static func multicopter(
        referenceMass: Float,
        hoverThrottleBaseline: Float,
        stabilizationThrustBaseline: Float,
        verticalResponseFactor: Float,
        throttleAuthority: Float,
        maneuverPenaltyFactor: Float,
        payloadThrustCompensationFactor: Float,
        source: UAVFlightTuningSource
    ) -> UAVFlightTuningProfile {
        UAVFlightTuningProfile(
            vehicleType: .multicopter,
            source: source,
            referenceMass: max(0.20, referenceMass),
            multicopter: MulticopterTuning(
                hoverThrottleBaseline: hoverThrottleBaseline,
                stabilizationThrustBaseline: stabilizationThrustBaseline,
                verticalResponseFactor: verticalResponseFactor,
                throttleAuthority: throttleAuthority,
                maneuverPenaltyFactor: maneuverPenaltyFactor,
                payloadThrustCompensationFactor: payloadThrustCompensationFactor
            ),
            helicopter: nil,
            fixedWing: nil,
            hybridVTOL: nil,
            custom: nil
        )
    }

    static func helicopter(
        referenceMass: Float,
        hoverThrottleBaseline: Float,
        stabilizationThrustBaseline: Float,
        verticalResponseFactor: Float,
        throttleAuthority: Float,
        maneuverPenaltyFactor: Float,
        payloadThrustCompensationFactor: Float,
        source: UAVFlightTuningSource
    ) -> UAVFlightTuningProfile {
        UAVFlightTuningProfile(
            vehicleType: .helicopter,
            source: source,
            referenceMass: max(0.20, referenceMass),
            multicopter: nil,
            helicopter: HelicopterTuning(
                hoverThrottleBaseline: hoverThrottleBaseline,
                stabilizationThrustBaseline: stabilizationThrustBaseline,
                verticalResponseFactor: verticalResponseFactor,
                throttleAuthority: throttleAuthority,
                maneuverPenaltyFactor: maneuverPenaltyFactor,
                payloadThrustCompensationFactor: payloadThrustCompensationFactor
            ),
            fixedWing: nil,
            hybridVTOL: nil,
            custom: nil
        )
    }

    static func fixedWing(
        referenceMass: Float,
        cruiseThrottleBaseline: Float,
        minimumSafeFlightThrottle: Float,
        climbThrottleBaseline: Float,
        glideThrottleFactor: Float,
        stallProtectionBias: Float,
        payloadCruisePenaltyFactor: Float,
        source: UAVFlightTuningSource
    ) -> UAVFlightTuningProfile {
        UAVFlightTuningProfile(
            vehicleType: .fixedWing,
            source: source,
            referenceMass: max(0.20, referenceMass),
            multicopter: nil,
            helicopter: nil,
            fixedWing: FixedWingTuning(
                cruiseThrottleBaseline: cruiseThrottleBaseline,
                minimumSafeFlightThrottle: minimumSafeFlightThrottle,
                climbThrottleBaseline: climbThrottleBaseline,
                glideThrottleFactor: glideThrottleFactor,
                stallProtectionBias: stallProtectionBias,
                payloadCruisePenaltyFactor: payloadCruisePenaltyFactor
            ),
            hybridVTOL: nil,
            custom: nil
        )
    }

    static func hybridVTOL(
        referenceMass: Float,
        hoverThrottleBaseline: Float,
        transitionThrottleBaseline: Float,
        cruiseThrottleBaseline: Float,
        verticalResponseFactor: Float,
        transitionResponseFactor: Float,
        payloadThrustCompensationFactor: Float,
        source: UAVFlightTuningSource
    ) -> UAVFlightTuningProfile {
        UAVFlightTuningProfile(
            vehicleType: .hybridVTOL,
            source: source,
            referenceMass: max(0.20, referenceMass),
            multicopter: nil,
            helicopter: nil,
            fixedWing: nil,
            hybridVTOL: HybridVTOLTuning(
                hoverThrottleBaseline: hoverThrottleBaseline,
                transitionThrottleBaseline: transitionThrottleBaseline,
                cruiseThrottleBaseline: cruiseThrottleBaseline,
                verticalResponseFactor: verticalResponseFactor,
                transitionResponseFactor: transitionResponseFactor,
                payloadThrustCompensationFactor: payloadThrustCompensationFactor
            ),
            custom: nil
        )
    }

    static func custom(
        referenceMass: Float,
        configurableHoverThrottleBaseline: Float,
        configurableCruiseThrottleBaseline: Float,
        configurableThrottleAuthority: Float,
        configurableVerticalResponseFactor: Float
    ) -> UAVFlightTuningProfile {
        UAVFlightTuningProfile(
            vehicleType: .custom,
            source: .custom,
            referenceMass: max(0.20, referenceMass),
            multicopter: nil,
            helicopter: nil,
            fixedWing: nil,
            hybridVTOL: nil,
            custom: CustomTuning(
                configurableHoverThrottleBaseline: configurableHoverThrottleBaseline,
                configurableCruiseThrottleBaseline: configurableCruiseThrottleBaseline,
                configurableThrottleAuthority: configurableThrottleAuthority,
                configurableVerticalResponseFactor: configurableVerticalResponseFactor
            )
        )
    }

    private static func resolvedReferenceMass(
        baseMass: Float?,
        batteryMass: Float?,
        maxPayloadMass: Float?,
        maxTakeoffMass: Float?
    ) -> Float {
        if let baseMass, let batteryMass {
            return max(0.20, baseMass + batteryMass)
        }
        if let maxTakeoffMass, let maxPayloadMass {
            return max(0.20, maxTakeoffMass - maxPayloadMass)
        }
        if let baseMass {
            return max(0.20, baseMass + (batteryMass ?? 0.0))
        }
        if let maxTakeoffMass {
            return max(0.20, maxTakeoffMass)
        }
        return 1.0
    }

    private static func dynamicCustomHoverBaseline(referenceMass: Float) -> Float {
        let massBias = Float(log2(max(1.0, Double(referenceMass)))) * 0.025
        return (0.50 + min(0.12, max(0.0, massBias))).clamped(to: 0.46...0.66)
    }

    private static func dynamicCustomAuthority(referenceMass: Float) -> Float {
        (0.94 - min(0.26, referenceMass * 0.015)).clamped(to: 0.62...1.02)
    }

    private static func dynamicCustomVerticalResponse(referenceMass: Float) -> Float {
        (0.98 - min(0.30, referenceMass * 0.018)).clamped(to: 0.66...1.08)
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
