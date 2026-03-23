import Foundation

struct ResolvedFlightBaseline: Hashable {
    let vehicleType: UAVVehicleType
    let tuningSource: UAVFlightTuningSource
    let massSourceQuality: PayloadDataQualitySource
    let referenceMass: Float
    let totalMass: Float
    let normalizedLoadFactor: Float
    let payloadRatio: Float

    let effectiveHoverThrottle: Float
    let effectiveStabilizationThrust: Float
    let effectiveCruiseThrottle: Float
    let effectiveMinimumSafeFlightThrottle: Float
    let effectiveClimbThrottle: Float
    let effectiveTransitionThrottle: Float

    let effectiveVerticalResponseFactor: Float
    let effectiveTransitionResponseFactor: Float
    let effectiveThrottleAuthority: Float
    let maneuverAuthorityMultiplier: Float
    let liftPenaltyMultiplier: Float
    let stallProtectionBias: Float
    let glideThrottleFactor: Float
    let payloadCruisePenaltyMultiplier: Float

    var hoverCapable: Bool {
        switch vehicleType {
        case .multicopter, .helicopter, .hybridVTOL, .custom:
            return true
        case .fixedWing:
            return false
        }
    }

    var hoverLockThrottle: Float {
        switch vehicleType {
        case .fixedWing:
            return effectiveMinimumSafeFlightThrottle
        case .hybridVTOL:
            return max(effectiveHoverThrottle, effectiveTransitionThrottle)
        case .multicopter, .helicopter, .custom:
            return effectiveHoverThrottle
        }
    }

    var cruiseReferenceThrottle: Float {
        switch vehicleType {
        case .multicopter, .helicopter:
            return effectiveHoverThrottle
        case .fixedWing, .hybridVTOL, .custom:
            return max(effectiveCruiseThrottle, effectiveMinimumSafeFlightThrottle)
        }
    }

    var takeoffThrottleReference: Float {
        switch vehicleType {
        case .fixedWing:
            return effectiveClimbThrottle
        case .hybridVTOL:
            return max(effectiveHoverThrottle + 0.04, effectiveTransitionThrottle).clamped(to: 0.30...0.90)
        case .multicopter, .helicopter, .custom:
            return (effectiveHoverThrottle + 0.10).clamped(to: 0.30...0.86)
        }
    }

    var landingThrottleReference: Float {
        switch vehicleType {
        case .fixedWing:
            return (effectiveMinimumSafeFlightThrottle * glideThrottleFactor).clamped(to: 0.18...0.70)
        case .hybridVTOL:
            return (effectiveTransitionThrottle * 0.92).clamped(to: 0.22...0.78)
        case .multicopter, .helicopter, .custom:
            return (effectiveHoverThrottle - 0.16).clamped(to: 0.20...0.68)
        }
    }

    var groundedTakeoffThreshold: Float {
        hoverCapable
            ? max(0.22, hoverLockThrottle * 0.72)
            : max(0.24, takeoffThrottleReference * 0.70)
    }

    var groundedIdleThreshold: Float {
        hoverCapable
            ? max(0.16, hoverLockThrottle * 0.55)
            : max(0.18, effectiveMinimumSafeFlightThrottle * 0.55)
    }
}

enum FlightBaselineResolver {
    static func resolve(
        runtimeProfile: DroneModelProfile,
        activeUAVProfile: UAVProfile?,
        vehicleMassModel: VehicleMassModel,
        flightMode: DroneFlightMode
    ) -> ResolvedFlightBaseline {
        let tuning = activeUAVProfile?.flightTuningProfile ?? UAVFlightTuningProfile.runtimeFallback(for: runtimeProfile)
        let totalMass = max(0.20, vehicleMassModel.resolvedCurrentTotalMass)
        let referenceMass = max(0.20, tuning.referenceMass)
        let normalizedLoadFactor = (totalMass / referenceMass).clamped(to: 0.70...1.85)
        let payloadRatio = vehicleMassModel.payloadLoadRatio.clamped(to: 0.0...1.0)

        switch tuning.vehicleType {
        case .multicopter:
            guard let multirotor = tuning.multicopter else {
                return fallbackResolvedBaseline(tuning: tuning, totalMass: totalMass, normalizedLoadFactor: normalizedLoadFactor, payloadRatio: payloadRatio, massSourceQuality: vehicleMassModel.massSourceQuality)
            }

            return resolveVerticalHoldBaseline(
                vehicleType: .multicopter,
                source: tuning.source,
                massSourceQuality: vehicleMassModel.massSourceQuality,
                referenceMass: referenceMass,
                totalMass: totalMass,
                normalizedLoadFactor: normalizedLoadFactor,
                payloadRatio: payloadRatio,
                hoverThrottleBaseline: multirotor.hoverThrottleBaseline,
                stabilizationThrustBaseline: multirotor.stabilizationThrustBaseline,
                verticalResponseFactor: multirotor.verticalResponseFactor,
                throttleAuthority: multirotor.throttleAuthority,
                maneuverPenaltyFactor: multirotor.maneuverPenaltyFactor,
                payloadThrustCompensationFactor: multirotor.payloadThrustCompensationFactor
            )
        case .helicopter:
            guard let helicopter = tuning.helicopter else {
                return fallbackResolvedBaseline(tuning: tuning, totalMass: totalMass, normalizedLoadFactor: normalizedLoadFactor, payloadRatio: payloadRatio, massSourceQuality: vehicleMassModel.massSourceQuality)
            }

            return resolveVerticalHoldBaseline(
                vehicleType: .helicopter,
                source: tuning.source,
                massSourceQuality: vehicleMassModel.massSourceQuality,
                referenceMass: referenceMass,
                totalMass: totalMass,
                normalizedLoadFactor: normalizedLoadFactor,
                payloadRatio: payloadRatio,
                hoverThrottleBaseline: helicopter.hoverThrottleBaseline,
                stabilizationThrustBaseline: helicopter.stabilizationThrustBaseline,
                verticalResponseFactor: helicopter.verticalResponseFactor,
                throttleAuthority: helicopter.throttleAuthority,
                maneuverPenaltyFactor: helicopter.maneuverPenaltyFactor,
                payloadThrustCompensationFactor: helicopter.payloadThrustCompensationFactor
            )
        case .fixedWing:
            guard let fixedWing = tuning.fixedWing else {
                return fallbackResolvedBaseline(tuning: tuning, totalMass: totalMass, normalizedLoadFactor: normalizedLoadFactor, payloadRatio: payloadRatio, massSourceQuality: vehicleMassModel.massSourceQuality)
            }

            let loadDelta = max(0.0, normalizedLoadFactor - 1.0)
            let payloadPenalty = payloadRatio * fixedWing.payloadCruisePenaltyFactor
            let effectiveCruiseThrottle = (fixedWing.cruiseThrottleBaseline * (1.0 + loadDelta * 0.28 + payloadPenalty * 0.22)).clamped(to: 0.28...0.86)
            let effectiveMinimumSafeFlightThrottle = (fixedWing.minimumSafeFlightThrottle * (1.0 + loadDelta * 0.24 + payloadPenalty * 0.18)).clamped(to: 0.24...0.80)
            let effectiveClimbThrottle = (fixedWing.climbThrottleBaseline * (1.0 + loadDelta * 0.32 + payloadPenalty * 0.26)).clamped(to: 0.35...0.92)
            let stallProtectionBias = (fixedWing.stallProtectionBias + loadDelta * 0.14 + payloadPenalty * 0.12).clamped(to: 0.10...0.55)
            let glideThrottleFactor = fixedWing.glideThrottleFactor.clamped(to: 0.48...0.82)
            let payloadCruisePenaltyMultiplier = (1.0 - payloadPenalty * 0.24).clamped(to: 0.72...1.00)

            return ResolvedFlightBaseline(
                vehicleType: .fixedWing,
                tuningSource: tuning.source,
                massSourceQuality: vehicleMassModel.massSourceQuality,
                referenceMass: referenceMass,
                totalMass: totalMass,
                normalizedLoadFactor: normalizedLoadFactor,
                payloadRatio: payloadRatio,
                effectiveHoverThrottle: 0.0,
                effectiveStabilizationThrust: 1.0,
                effectiveCruiseThrottle: effectiveCruiseThrottle,
                effectiveMinimumSafeFlightThrottle: effectiveMinimumSafeFlightThrottle,
                effectiveClimbThrottle: effectiveClimbThrottle,
                effectiveTransitionThrottle: 0.0,
                effectiveVerticalResponseFactor: 0.70,
                effectiveTransitionResponseFactor: 0.70,
                effectiveThrottleAuthority: (0.78 - loadDelta * 0.12).clamped(to: 0.55...0.92),
                maneuverAuthorityMultiplier: (1.0 - payloadPenalty * 0.16).clamped(to: 0.62...1.00),
                liftPenaltyMultiplier: 1.0,
                stallProtectionBias: stallProtectionBias,
                glideThrottleFactor: glideThrottleFactor,
                payloadCruisePenaltyMultiplier: payloadCruisePenaltyMultiplier
            )
        case .hybridVTOL:
            guard let hybrid = tuning.hybridVTOL else {
                return fallbackResolvedBaseline(tuning: tuning, totalMass: totalMass, normalizedLoadFactor: normalizedLoadFactor, payloadRatio: payloadRatio, massSourceQuality: vehicleMassModel.massSourceQuality)
            }

            let loadDelta = max(0.0, normalizedLoadFactor - 1.0)
            let payloadBoost = payloadRatio * hybrid.payloadThrustCompensationFactor
            let hoverModeBias: Float = flightMode == .hover || flightMode == .takeoff || flightMode == .landing ? 1.02 : 1.0
            let effectiveHoverThrottle = (hybrid.hoverThrottleBaseline * (1.0 + loadDelta * 0.48 + payloadBoost * 0.18) * hoverModeBias).clamped(to: 0.24...0.88)
            let effectiveTransitionThrottle = (hybrid.transitionThrottleBaseline * (1.0 + loadDelta * 0.30 + payloadBoost * 0.14) * hoverModeBias).clamped(to: 0.26...0.84)
            let effectiveCruiseThrottle = (hybrid.cruiseThrottleBaseline * (1.0 + loadDelta * 0.22 + payloadBoost * 0.10)).clamped(to: 0.24...0.80)
            let effectiveVerticalResponseFactor = (hybrid.verticalResponseFactor / (0.96 + loadDelta * 0.55)).clamped(to: 0.58...1.18)
            let effectiveTransitionResponseFactor = (hybrid.transitionResponseFactor / (0.96 + loadDelta * 0.45)).clamped(to: 0.58...1.18)
            let effectiveMinimumSafeFlightThrottle = max(effectiveCruiseThrottle * 0.92, 0.28)
            let effectiveClimbThrottle = max(effectiveTransitionThrottle, effectiveHoverThrottle * 0.96).clamped(to: 0.30...0.88)

            return ResolvedFlightBaseline(
                vehicleType: .hybridVTOL,
                tuningSource: tuning.source,
                massSourceQuality: vehicleMassModel.massSourceQuality,
                referenceMass: referenceMass,
                totalMass: totalMass,
                normalizedLoadFactor: normalizedLoadFactor,
                payloadRatio: payloadRatio,
                effectiveHoverThrottle: effectiveHoverThrottle,
                effectiveStabilizationThrust: (1.70 + payloadBoost * 0.06 + loadDelta * 0.08).clamped(to: 1.46...2.00),
                effectiveCruiseThrottle: effectiveCruiseThrottle,
                effectiveMinimumSafeFlightThrottle: effectiveMinimumSafeFlightThrottle,
                effectiveClimbThrottle: effectiveClimbThrottle,
                effectiveTransitionThrottle: effectiveTransitionThrottle,
                effectiveVerticalResponseFactor: effectiveVerticalResponseFactor,
                effectiveTransitionResponseFactor: effectiveTransitionResponseFactor,
                effectiveThrottleAuthority: (0.76 + hybrid.transitionResponseFactor * 0.18 - payloadBoost * 0.08).clamped(to: 0.58...1.04),
                maneuverAuthorityMultiplier: (1.0 - payloadBoost * 0.18).clamped(to: 0.60...1.00),
                liftPenaltyMultiplier: (1.0 - payloadBoost * 0.05).clamped(to: 0.80...1.02),
                stallProtectionBias: (0.22 + loadDelta * 0.08 + payloadBoost * 0.06).clamped(to: 0.16...0.40),
                glideThrottleFactor: 0.68,
                payloadCruisePenaltyMultiplier: (1.0 - payloadBoost * 0.12).clamped(to: 0.78...1.00)
            )
        case .custom:
            guard let custom = tuning.custom else {
                return fallbackResolvedBaseline(tuning: tuning, totalMass: totalMass, normalizedLoadFactor: normalizedLoadFactor, payloadRatio: payloadRatio, massSourceQuality: vehicleMassModel.massSourceQuality)
            }

            let loadDelta = max(0.0, normalizedLoadFactor - 1.0)
            let effectiveHoverThrottle = (custom.configurableHoverThrottleBaseline * (1.0 + loadDelta * 0.44 + payloadRatio * 0.14)).clamped(to: 0.22...0.84)
            let effectiveCruiseThrottle = (custom.configurableCruiseThrottleBaseline * (1.0 + loadDelta * 0.20 + payloadRatio * 0.10)).clamped(to: 0.22...0.80)
            let effectiveVerticalResponseFactor = (custom.configurableVerticalResponseFactor / (0.96 + loadDelta * 0.50)).clamped(to: 0.60...1.20)
            let effectiveThrottleAuthority = (custom.configurableThrottleAuthority * (1.0 - payloadRatio * 0.10)).clamped(to: 0.58...1.08)

            return ResolvedFlightBaseline(
                vehicleType: .custom,
                tuningSource: tuning.source,
                massSourceQuality: vehicleMassModel.massSourceQuality,
                referenceMass: referenceMass,
                totalMass: totalMass,
                normalizedLoadFactor: normalizedLoadFactor,
                payloadRatio: payloadRatio,
                effectiveHoverThrottle: effectiveHoverThrottle,
                effectiveStabilizationThrust: (1.0 / max(0.36, effectiveHoverThrottle)).clamped(to: 1.46...2.04),
                effectiveCruiseThrottle: effectiveCruiseThrottle,
                effectiveMinimumSafeFlightThrottle: max(effectiveCruiseThrottle * 0.88, 0.24),
                effectiveClimbThrottle: max(effectiveHoverThrottle, effectiveCruiseThrottle + 0.06).clamped(to: 0.28...0.88),
                effectiveTransitionThrottle: effectiveHoverThrottle,
                effectiveVerticalResponseFactor: effectiveVerticalResponseFactor,
                effectiveTransitionResponseFactor: effectiveVerticalResponseFactor,
                effectiveThrottleAuthority: effectiveThrottleAuthority,
                maneuverAuthorityMultiplier: (1.0 - loadDelta * 0.16).clamped(to: 0.62...1.00),
                liftPenaltyMultiplier: (1.0 - payloadRatio * 0.04).clamped(to: 0.82...1.02),
                stallProtectionBias: 0.20,
                glideThrottleFactor: 0.70,
                payloadCruisePenaltyMultiplier: (1.0 - payloadRatio * 0.10).clamped(to: 0.80...1.00)
            )
        }
    }

    private static func resolveVerticalHoldBaseline(
        vehicleType: UAVVehicleType,
        source: UAVFlightTuningSource,
        massSourceQuality: PayloadDataQualitySource,
        referenceMass: Float,
        totalMass: Float,
        normalizedLoadFactor: Float,
        payloadRatio: Float,
        hoverThrottleBaseline: Float,
        stabilizationThrustBaseline: Float,
        verticalResponseFactor: Float,
        throttleAuthority: Float,
        maneuverPenaltyFactor: Float,
        payloadThrustCompensationFactor: Float
    ) -> ResolvedFlightBaseline {
        let loadDelta = max(0.0, normalizedLoadFactor - 1.0)
        let payloadBoost = payloadRatio * payloadThrustCompensationFactor
        let effectiveHoverThrottle = (hoverThrottleBaseline * (1.0 + loadDelta * 0.52 + payloadBoost * 0.20)).clamped(to: 0.20...0.88)
        let effectiveStabilizationThrust = (stabilizationThrustBaseline * (1.0 + loadDelta * 0.18 + payloadBoost * 0.08)).clamped(to: 1.45...2.25)
        let effectiveVerticalResponseFactor = (verticalResponseFactor / (0.92 + loadDelta * 0.70)).clamped(to: 0.55...1.40)
        let effectiveThrottleAuthority = (throttleAuthority * (1.0 - payloadRatio * maneuverPenaltyFactor * 0.18)).clamped(to: 0.45...1.20)
        let maneuverAuthorityMultiplier = (1.0 - loadDelta * maneuverPenaltyFactor * 0.35).clamped(to: 0.48...1.00)
        let liftPenaltyMultiplier = (1.0 - payloadBoost * 0.05).clamped(to: 0.80...1.02)

        return ResolvedFlightBaseline(
            vehicleType: vehicleType,
            tuningSource: source,
            massSourceQuality: massSourceQuality,
            referenceMass: referenceMass,
            totalMass: totalMass,
            normalizedLoadFactor: normalizedLoadFactor,
            payloadRatio: payloadRatio,
            effectiveHoverThrottle: effectiveHoverThrottle,
            effectiveStabilizationThrust: effectiveStabilizationThrust,
            effectiveCruiseThrottle: effectiveHoverThrottle,
            effectiveMinimumSafeFlightThrottle: max(effectiveHoverThrottle * 0.72, 0.20),
            effectiveClimbThrottle: (effectiveHoverThrottle + 0.08).clamped(to: 0.28...0.88),
            effectiveTransitionThrottle: effectiveHoverThrottle,
            effectiveVerticalResponseFactor: effectiveVerticalResponseFactor,
            effectiveTransitionResponseFactor: effectiveVerticalResponseFactor,
            effectiveThrottleAuthority: effectiveThrottleAuthority,
            maneuverAuthorityMultiplier: maneuverAuthorityMultiplier,
            liftPenaltyMultiplier: liftPenaltyMultiplier,
            stallProtectionBias: 0.0,
            glideThrottleFactor: 0.70,
            payloadCruisePenaltyMultiplier: 1.0
        )
    }

    private static func fallbackResolvedBaseline(
        tuning: UAVFlightTuningProfile,
        totalMass: Float,
        normalizedLoadFactor: Float,
        payloadRatio: Float,
        massSourceQuality: PayloadDataQualitySource
    ) -> ResolvedFlightBaseline {
        ResolvedFlightBaseline(
            vehicleType: tuning.vehicleType,
            tuningSource: tuning.source,
            massSourceQuality: massSourceQuality,
            referenceMass: max(0.20, tuning.referenceMass),
            totalMass: totalMass,
            normalizedLoadFactor: normalizedLoadFactor,
            payloadRatio: payloadRatio,
            effectiveHoverThrottle: 0.54,
            effectiveStabilizationThrust: 1.80,
            effectiveCruiseThrottle: 0.48,
            effectiveMinimumSafeFlightThrottle: 0.36,
            effectiveClimbThrottle: 0.60,
            effectiveTransitionThrottle: 0.52,
            effectiveVerticalResponseFactor: 0.90,
            effectiveTransitionResponseFactor: 0.78,
            effectiveThrottleAuthority: 0.82,
            maneuverAuthorityMultiplier: 0.86,
            liftPenaltyMultiplier: 0.92,
            stallProtectionBias: 0.24,
            glideThrottleFactor: 0.70,
            payloadCruisePenaltyMultiplier: 0.92
        )
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
