import Foundation

enum FixedWingMissionBatteryLevel: String, Equatable {
    case nominal
    case advisory
    case caution
    case critical
}

struct FixedWingMissionArbiterDecision: Equatable {
    var batteryLevel: FixedWingMissionBatteryLevel
    var conserveEnergy: Bool
    var shouldOverrideMission: Bool
    var prefersReturnHome: Bool
    var abortReason: MissionAbortReason?
    var diagnosticReason: String?

    static let nominal = FixedWingMissionArbiterDecision(
        batteryLevel: .nominal,
        conserveEnergy: false,
        shouldOverrideMission: false,
        prefersReturnHome: false,
        abortReason: nil,
        diagnosticReason: nil
    )
}

final class FixedWingMissionStateArbiter {
    private var previousLevel: FixedWingMissionBatteryLevel = .nominal

    func reset() {
        previousLevel = .nominal
    }

    func evaluate(
        batteryState: BatteryState,
        operationalStatus: MissionOperationalStatus,
        wing: FixedWingParameters
    ) -> FixedWingMissionArbiterDecision {
        let rawLevel = rawBatteryLevel(
            batteryState: batteryState,
            operationalStatus: operationalStatus,
            wing: wing
        )
        let batteryLevel = applyHysteresis(
            rawLevel: rawLevel,
            batteryState: batteryState,
            operationalStatus: operationalStatus,
            wing: wing
        )
        previousLevel = batteryLevel

        switch batteryLevel {
        case .nominal:
            return .nominal
        case .advisory:
            return FixedWingMissionArbiterDecision(
                batteryLevel: .advisory,
                conserveEnergy: false,
                shouldOverrideMission: false,
                prefersReturnHome: false,
                abortReason: nil,
                diagnosticReason: "battery_advisory_margin"
            )
        case .caution:
            return FixedWingMissionArbiterDecision(
                batteryLevel: .caution,
                conserveEnergy: true,
                shouldOverrideMission: false,
                prefersReturnHome: false,
                abortReason: nil,
                diagnosticReason: "battery_caution_margin"
            )
        case .critical:
            let canReturnSafely = operationalStatus.canReachHomeSafely
            return FixedWingMissionArbiterDecision(
                batteryLevel: .critical,
                conserveEnergy: true,
                shouldOverrideMission: true,
                prefersReturnHome: canReturnSafely,
                abortReason: .batteryUnsafe,
                diagnosticReason: canReturnSafely
                    ? "battery_critical_return_home"
                    : "battery_critical_abort"
            )
        }
    }

    private func rawBatteryLevel(
        batteryState: BatteryState,
        operationalStatus: MissionOperationalStatus,
        wing: FixedWingParameters
    ) -> FixedWingMissionBatteryLevel {
        let cruiseSpeed = max(wing.cruiseAirspeed, 1.0)
        let returnMargin = operationalStatus.estimatedSafeReturnRangeM - operationalStatus.distanceToHomeM
        let missionMargin = operationalStatus.estimatedSafeReturnRangeM - operationalStatus.missionDistanceBudgetM
        let advisoryRangeMargin = max(wing.waypointAcceptanceRadiusMeters * 5.0, cruiseSpeed * 75.0)
        let cautionRangeMargin = max(wing.waypointAcceptanceRadiusMeters * 3.5, cruiseSpeed * 45.0)
        let criticalRangeMargin = max(wing.waypointAcceptanceRadiusMeters * 2.0, cruiseSpeed * 20.0)

        if batteryState.isDepleted ||
            batteryState.chargePercent <= 8.0 ||
            (batteryState.remainingTimeSec > 0.0 && batteryState.remainingTimeSec < 35.0) ||
            !operationalStatus.canReachHomeSafely ||
            returnMargin <= -criticalRangeMargin {
            return .critical
        }

        if batteryState.chargePercent <= 16.0 ||
            (batteryState.remainingTimeSec > 0.0 && batteryState.remainingTimeSec < 75.0) ||
            !operationalStatus.canCompleteMissionSafely ||
            missionMargin <= cautionRangeMargin {
            return .caution
        }

        if batteryState.chargePercent <= 28.0 ||
            (batteryState.remainingTimeSec > 0.0 && batteryState.remainingTimeSec < 150.0) ||
            missionMargin <= advisoryRangeMargin ||
            returnMargin <= advisoryRangeMargin {
            return .advisory
        }

        return .nominal
    }

    private func applyHysteresis(
        rawLevel: FixedWingMissionBatteryLevel,
        batteryState: BatteryState,
        operationalStatus: MissionOperationalStatus,
        wing: FixedWingParameters
    ) -> FixedWingMissionBatteryLevel {
        let cruiseSpeed = max(wing.cruiseAirspeed, 1.0)
        let missionMargin = operationalStatus.estimatedSafeReturnRangeM - operationalStatus.missionDistanceBudgetM
        let cautionRecoveryMargin = max(wing.waypointAcceptanceRadiusMeters * 4.0, cruiseSpeed * 55.0)
        let advisoryRecoveryMargin = max(wing.waypointAcceptanceRadiusMeters * 5.5, cruiseSpeed * 90.0)

        switch previousLevel {
        case .critical:
            let canRecover = batteryState.chargePercent >= 12.0 &&
                (batteryState.remainingTimeSec <= 0.0 || batteryState.remainingTimeSec >= 60.0) &&
                operationalStatus.canReachHomeSafely
            return canRecover ? rawLevel : .critical
        case .caution:
            let canRecover = batteryState.chargePercent >= 22.0 &&
                missionMargin >= cautionRecoveryMargin
            if rawLevel == .nominal || rawLevel == .advisory {
                return canRecover ? rawLevel : .caution
            }
            return rawLevel
        case .advisory:
            let canRecover = batteryState.chargePercent >= 32.0 &&
                missionMargin >= advisoryRecoveryMargin
            return rawLevel == .nominal && !canRecover ? .advisory : rawLevel
        case .nominal:
            return rawLevel
        }
    }
}

final class MissionSafetyEvaluator {
    func evaluate(
        draftStatus: MissionDraftStatus,
        currentPlan: MissionPlan?,
        executionState: MissionExecutionState,
        authorityState: MissionControlAuthorityState,
        runtimeMonitor: MissionRuntimeMonitorReport,
        canStartMissionAutopilot: Bool,
        batteryState: BatteryState,
        airframeClass: AirframeClass,
        collisionAnalysis: CollisionAnalysisSnapshot,
        thermalState: ThermalState,
        signalState: UAVSignalState,
        operationalStatus: MissionOperationalStatus,
        missionGeofenceState: MissionGeofenceState = .inactive
    ) -> MissionSafetyState {
        let maxTemperature = DamageComponent.allCases
            .map { thermalState.temperature(for: $0) }
            .max() ?? 33.0
        let hasValidatedPlan = currentPlan?.isReadyForExecution == true
        let hasExecutionContour = executionState.hasExecutionContour
        let hasMissionTarget = executionState.activeTarget != nil
        let hasRuntimeDistance = executionState.hasRuntimeDistance
        let usesCruiseRangeForBatteryTime = airframeClass == .hybridVTOL
        let remainingTimeSafeToStart = usesCruiseRangeForBatteryTime ||
            batteryState.remainingTimeSec <= 0.0 ||
            batteryState.remainingTimeSec >= 90.0
        let remainingTimeSafeToContinue = usesCruiseRangeForBatteryTime ||
            batteryState.remainingTimeSec <= 0.0 ||
            batteryState.remainingTimeSec >= 45.0
        let batterySafeToStart = !batteryState.isDepleted &&
            batteryState.chargePercent >= 18.0 &&
            remainingTimeSafeToStart
        let batterySafeToContinue = !batteryState.isDepleted &&
            batteryState.chargePercent >= 12.0 &&
            remainingTimeSafeToContinue
        let returnSafe = operationalStatus.canReachHomeSafely
        let missionSafe = operationalStatus.canCompleteMissionSafely
        let collisionSafe = collisionAnalysis.emergencyAction != .emergencyStop &&
            collisionAnalysis.riskScore < 0.92
        let thermalSafe = maxTemperature < 86.0
        let signalSafe = !signalState.isInteractionBlocking && !operationalStatus.isLinkLost
        let mapScaleSuitable = operationalStatus.mapScaleSuitability != .unsuitable
        let routeHealthy = currentPlan?.status == .validated
        let adapterHealthy = executionState.status != .running || canStartMissionAutopilot

        let runtimeConstraints = MissionRuntimeConstraintState(
            hasValidatedPlan: hasValidatedPlan,
            hasExecutionContour: hasExecutionContour,
            hasMissionTarget: hasMissionTarget,
            hasRuntimeDistance: hasRuntimeDistance,
            targetBindingAvailable: canStartMissionAutopilot,
            batterySafeToStart: batterySafeToStart,
            batterySafeToContinue: batterySafeToContinue,
            returnSafe: returnSafe,
            missionSafe: missionSafe,
            collisionSafe: collisionSafe,
            thermalSafe: thermalSafe,
            signalSafe: signalSafe,
            mapScaleSuitable: mapScaleSuitable,
            routeHealthy: routeHealthy,
            progressHealthy: runtimeMonitor.progressHealthy,
            adapterHealthy: adapterHealthy
        )

        var warnings = runtimeMonitor.warnings.filter { warning in
            !(authorityState.isAuthorityTransientLoss && warning.reason == .noMissionTarget)
        }
        if batteryState.chargePercent <= 20.0 {
            warnings.append(
                MissionWarning(
                    reason: .batteryUnsafe,
                    severity: batterySafeToContinue ? .warning : .critical,
                    detailKey: "mission.status.reason.battery_unsafe"
                )
            )
        }
        if !returnSafe || !missionSafe {
            warnings.append(
                MissionWarning(
                    reason: .batteryUnsafe,
                    severity: returnSafe && !missionSafe ? .warning : .critical,
                    detailKey: !missionSafe
                        ? "mission.status.reason.route_exceeds_safe_return"
                        : "mission.status.reason.battery_unsafe"
                )
            )
        }
        if !signalSafe {
            warnings.append(
                MissionWarning(
                    reason: .runtimeUnsafe,
                    severity: .critical,
                    detailKey: "mission.status.reason.runtime_unsafe"
                )
            )
        }
        if operationalStatus.isInCriticalLinkZone {
            warnings.append(
                MissionWarning(
                    reason: .runtimeUnsafe,
                    severity: .warning,
                    detailKey: "mission.status.reason.link_degraded"
                )
            )
        }
        if missionGeofenceState == .warning || missionGeofenceState == .breach {
            warnings.append(
                MissionWarning(
                    reason: .runtimeUnsafe,
                    severity: missionGeofenceState == .breach ? .critical : .warning,
                    detailKey: missionGeofenceState == .breach
                        ? "mission.status.reason.geofence_breach"
                        : "mission.status.reason.geofence_warning"
                )
            )
        }
        if operationalStatus.mapScaleSuitability == .tight || operationalStatus.mapScaleSuitability == .unsuitable {
            warnings.append(
                MissionWarning(
                    reason: .routeInvalid,
                    severity: operationalStatus.mapScaleSuitability == .unsuitable ? .critical : .warning,
                    detailKey: operationalStatus.mapScaleSuitability == .unsuitable
                        ? "mission.status.reason.map_unsuitable"
                        : "mission.status.reason.map_tight"
                )
            )
        }
        if !collisionSafe || collisionAnalysis.riskScore >= 0.65 {
            warnings.append(
                MissionWarning(
                    reason: .runtimeUnsafe,
                    severity: collisionSafe ? .warning : .critical,
                    detailKey: "mission.status.reason.runtime_unsafe"
                )
            )
        }
        if !thermalSafe || maxTemperature >= 78.0 {
            warnings.append(
                MissionWarning(
                    reason: .runtimeUnsafe,
                    severity: thermalSafe ? .warning : .critical,
                    detailKey: "mission.status.reason.runtime_unsafe"
                )
            )
        }
        if authorityState.isAuthorityTransientLoss || authorityState.didRecoverTransientLoss {
            warnings.append(
                MissionWarning(
                    reason: .authorityFlapDetected,
                    severity: .warning,
                    detailKey: "mission.status.reason.authority_flap_detected"
                )
            )
        } else if authorityState.isAuthorityLost {
            warnings.append(
                MissionWarning(
                    reason: authorityState.failureReason ?? .noControlAuthority,
                    severity: .critical,
                    detailKey: authorityState.failureReason == .noMissionTarget
                        ? "mission.status.reason.no_mission_target"
                        : "mission.status.reason.no_control_authority"
                )
            )
        }

        let blockReason: MissionBlockReason? = {
            if currentPlan == nil {
                switch draftStatus.kind {
                case .invalid:
                    return .routeInvalid
                case .empty, .editing, .previewUnavailable, .ready:
                    return nil
                }
            }
            if !hasValidatedPlan || !routeHealthy {
                return .routeInvalid
            }
            if executionState.status == .ready ||
                executionState.status == .paused ||
                executionState.status == .blocked {
                if executionState.bindingState == .failed {
                    return .executionBindingFailed
                }
                if !hasExecutionContour {
                    return .executionContourMissing
                }
                if !hasMissionTarget {
                    return .noMissionTarget
                }
                if !hasRuntimeDistance {
                    return .runtimeDistanceUnavailable
                }
            }
            if executionState.status == .running {
                if authorityState.isAuthorityLost {
                    return authorityState.failureReason == .noMissionTarget
                        ? .noMissionTarget
                        : .noControlAuthority
                }
                if runtimeMonitor.isTargetMissing && !authorityState.isAuthorityTransientLoss {
                    return .noMissionTarget
                }
                if runtimeMonitor.isStalled {
                    return .runtimeStallDetected
                }
                if !runtimeConstraints.isSafeToContinue {
                    if !batterySafeToContinue || !returnSafe || !missionSafe {
                        return .batteryUnsafe
                    }
                    return .runtimeUnsafe
                }
                return nil
            }
            if executionState.status == .ready || executionState.status == .paused {
                if !canStartMissionAutopilot {
                    return .missionStartBlocked
                }
                if !batterySafeToStart || !returnSafe || !missionSafe {
                    return .batteryUnsafe
                }
                if !runtimeConstraints.isSafeToStart {
                    return .runtimeUnsafe
                }
            }
            return nil
        }()

        let readiness: MissionRunReadiness = {
            if currentPlan == nil {
                switch draftStatus.kind {
                case .invalid:
                    return .invalid
                case .empty, .editing, .previewUnavailable, .ready:
                    return .draft
                }
            }
            if !hasValidatedPlan {
                return .invalid
            }
            if blockReason != nil {
                return .blocked
            }
            return .ready
        }()

        return MissionSafetyState(
            readiness: readiness,
            blockReason: blockReason,
            warnings: unique(warnings),
            authorityState: authorityState,
            runtimeConstraints: runtimeConstraints,
            failsafeMode: .none,
            abortReason: nil
        )
    }

    private func unique(_ warnings: [MissionWarning]) -> [MissionWarning] {
        var seen = Set<String>()
        return warnings.filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.severity.priority != rhs.severity.priority {
                    return lhs.severity.priority < rhs.severity.priority
                }
                return lhs.detailKey < rhs.detailKey
            }
    }
}
