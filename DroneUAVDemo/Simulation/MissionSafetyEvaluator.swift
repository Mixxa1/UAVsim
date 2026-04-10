import Foundation

final class MissionSafetyEvaluator {
    func evaluate(
        draftStatus: MissionDraftStatus,
        currentPlan: MissionPlan?,
        executionState: MissionExecutionState,
        authorityState: MissionControlAuthorityState,
        runtimeMonitor: MissionRuntimeMonitorReport,
        canStartMissionAutopilot: Bool,
        batteryState: BatteryState,
        collisionAnalysis: CollisionAnalysisSnapshot,
        thermalState: ThermalState,
        signalState: UAVSignalState
    ) -> MissionSafetyState {
        let maxTemperature = DamageComponent.allCases
            .map { thermalState.temperature(for: $0) }
            .max() ?? 33.0
        let hasValidatedPlan = currentPlan?.isReadyForExecution == true
        let hasExecutionContour = executionState.hasExecutionContour
        let hasMissionTarget = executionState.activeTarget != nil
        let hasRuntimeDistance = executionState.hasRuntimeDistance
        let batterySafeToStart = !batteryState.isDepleted &&
            batteryState.chargePercent >= 18.0 &&
            (batteryState.remainingTimeSec <= 0.0 || batteryState.remainingTimeSec >= 90.0)
        let batterySafeToContinue = !batteryState.isDepleted &&
            batteryState.chargePercent >= 12.0 &&
            (batteryState.remainingTimeSec <= 0.0 || batteryState.remainingTimeSec >= 45.0)
        let collisionSafe = collisionAnalysis.emergencyAction != .emergencyStop &&
            collisionAnalysis.riskScore < 0.92
        let thermalSafe = maxTemperature < 86.0
        let signalSafe = !signalState.isInteractionBlocking
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
            collisionSafe: collisionSafe,
            thermalSafe: thermalSafe,
            signalSafe: signalSafe,
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
        if !signalSafe {
            warnings.append(
                MissionWarning(
                    reason: .runtimeUnsafe,
                    severity: .critical,
                    detailKey: "mission.status.reason.runtime_unsafe"
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
                    if !batterySafeToContinue {
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
                if !batterySafeToStart {
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
