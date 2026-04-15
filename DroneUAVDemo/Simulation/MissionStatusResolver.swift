import Foundation

final class MissionStatusResolver {
    func resolve(
        draftStatus: MissionDraftStatus,
        currentPlan: MissionPlan?,
        executionState: MissionExecutionState,
        safetyState: MissionSafetyState,
        operationalStatus: MissionOperationalStatus,
        controlAuthority: FlightControlAuthority,
        flightMode: DroneFlightMode
    ) -> MissionStatusSnapshot {
        let planStatus = resolvedPlanStatus(
            draftStatus: draftStatus,
            currentPlan: currentPlan
        )
        let hasValidatedPlan = currentPlan?.status == .validated
        let executionReadiness = resolvedExecutionReadiness(
            currentPlan: currentPlan,
            executionState: executionState
        )
        let hasExecutionContour = executionState.hasExecutionContour
        let hasActiveExecutionTarget = executionState.activeTarget != nil
        let hasRuntimeDistance = executionState.hasRuntimeDistance
        let startPermissionGranted = safetyState.readiness == .ready &&
            safetyState.failsafeMode == .none
        var explanations = currentPlan?.explanations ?? []

        explanations.append(contentsOf: draftExplanations(for: draftStatus, currentPlan: currentPlan))
        explanations.append(contentsOf: executionState.explanations)
        explanations.append(contentsOf: safetyState.warnings.map(makeExplanation(from:)))

        if let blockReason = safetyState.blockReason {
            explanations.append(
                MissionStatusExplanation(
                    reason: blockReason.failureReason,
                    severity: blockReason == .missionStartBlocked ? .warning : .critical,
                    detailKey: blockReason.detailKey
                )
            )
        }

        if safetyState.failsafeMode == .returnHome {
            explanations.append(
                MissionStatusExplanation(
                    reason: .returnHomeTriggered,
                    severity: .warning,
                    detailKey: "mission.status.reason.return_home_triggered",
                    isBlocking: false
                )
            )
        }

        explanations = unique(explanations)

        let truthStatus = resolveTruthStatus(
            draftStatus: draftStatus,
            currentPlan: currentPlan,
            planStatus: planStatus,
            executionReadiness: executionReadiness,
            executionState: executionState,
            safetyState: safetyState,
            flightMode: flightMode
        )

        let completedWaypointCount = executionState.waypointProgress.filter { $0.state == .completed }.count
        let totalWaypointCount = currentPlan?.waypoints.count ?? executionState.waypointProgress.count
        let canPrepare = draftStatus.canSave &&
            executionState.status != .running &&
            executionState.status != .paused
        let canStart = hasValidatedPlan &&
            executionReadiness == .ready &&
            executionState.canStart &&
            startPermissionGranted
        let canPause = executionState.canPause &&
            safetyState.failsafeMode == .none
        let canResume = executionState.canResume &&
            startPermissionGranted
        let canAbort = executionState.canAbort

        return MissionStatusSnapshot(
            truthStatus: truthStatus,
            draftStatus: draftStatus,
            planStatus: planStatus,
            executionReadiness: executionReadiness,
            executionStatus: executionState.status,
            executionBindingState: executionState.bindingState,
            controlAuthority: controlAuthority,
            safetyState: safetyState,
            activeTargetLabel: executionState.activeTarget?.label,
            distanceToActiveTarget: executionState.distanceToActiveTarget,
            completedWaypointCount: completedWaypointCount,
            totalWaypointCount: totalWaypointCount,
            hasValidatedPlan: hasValidatedPlan,
            hasExecutionContour: hasExecutionContour,
            hasActiveExecutionTarget: hasActiveExecutionTarget,
            hasRuntimeDistance: hasRuntimeDistance,
            hasBoundAutopilotTarget: executionState.hasBoundAutopilotTarget,
            startPermissionGranted: startPermissionGranted,
            canPrepare: canPrepare,
            canStart: canStart,
            canPause: canPause,
            canResume: canResume,
            canAbort: canAbort,
            operationalStatus: operationalStatus,
            explanations: explanations
        )
    }

    private func resolvedPlanStatus(
        draftStatus: MissionDraftStatus,
        currentPlan: MissionPlan?
    ) -> MissionPlanStatus {
        if let currentPlan {
            return currentPlan.status
        }

        switch draftStatus.kind {
        case .invalid:
            return .invalid
        case .empty, .editing, .previewUnavailable, .ready:
            return .draft
        }
    }

    private func resolvedExecutionReadiness(
        currentPlan: MissionPlan?,
        executionState: MissionExecutionState
    ) -> MissionExecutionReadiness {
        guard let currentPlan else {
            return .draft
        }

        guard currentPlan.status == .validated else {
            return .draft
        }

        guard executionState.planID == currentPlan.id else {
            return .validated
        }

        if executionState.bindingState == .failed {
            return .failedBinding
        }

        if !executionState.hasExecutionContour ||
            executionState.activeTarget == nil ||
            !executionState.hasRuntimeDistance {
            return .executionUnbound
        }

        return .ready
    }

    private func draftExplanations(
        for draftStatus: MissionDraftStatus,
        currentPlan: MissionPlan?
    ) -> [MissionStatusExplanation] {
        var explanations: [MissionStatusExplanation] = []

        if currentPlan == nil {
            switch draftStatus.kind {
            case .empty:
                explanations.append(
                    MissionStatusExplanation(
                        reason: .draftEmpty,
                        severity: .info,
                        detailKey: "mission.status.reason.draft_empty",
                        isBlocking: false
                    )
                )
            case .previewUnavailable:
                explanations.append(
                    MissionStatusExplanation(
                        reason: .previewUnavailable,
                        severity: .warning,
                        detailKey: "mission.status.reason.preview_unavailable",
                        isBlocking: false
                    )
                )
            case .invalid:
                break
            case .editing, .ready:
                explanations.append(
                    MissionStatusExplanation(
                        reason: .planNotPrepared,
                        severity: .info,
                        detailKey: "mission.status.reason.plan_not_prepared",
                        isBlocking: false
                    )
                )
            }
        }

        for issue in draftStatus.issues {
            let severity: MissionStatusExplanationSeverity = {
                switch issue.severity {
                case .info:
                    return .info
                case .warning:
                    return .warning
                case .error:
                    return .critical
                }
            }()

            explanations.append(
                MissionStatusExplanation(
                    reason: issue.reason,
                    severity: severity,
                    detailKey: issue.messageKey,
                    isBlocking: issue.severity == .error
                )
            )
        }

        return explanations
    }

    private func resolveTruthStatus(
        draftStatus: MissionDraftStatus,
        currentPlan: MissionPlan?,
        planStatus: MissionPlanStatus,
        executionReadiness: MissionExecutionReadiness,
        executionState: MissionExecutionState,
        safetyState: MissionSafetyState,
        flightMode: DroneFlightMode
    ) -> MissionTruthStatus {
        if safetyState.failsafeMode == .returnHome && flightMode == .returnHome {
            return .returningHome
        }

        switch executionState.status {
        case .running:
            return activeTruthStatus(safetyState: safetyState, fallback: .running)
        case .paused:
            return activeTruthStatus(safetyState: safetyState, fallback: .paused)
        case .completed:
            return .completed
        case .aborted:
            return .aborted
        case .failed:
            return .failed
        case .blocked:
            return blockedTruthStatus(
                for: safetyState.blockReason,
                executionReadiness: executionReadiness
            )
        case .ready:
            if safetyState.readiness == .ready && executionReadiness == .ready {
                return .ready
            }
            return blockedTruthStatus(
                for: safetyState.blockReason,
                executionReadiness: executionReadiness
            )
        case .idle:
            if currentPlan != nil {
                switch planStatus {
                case .invalid:
                    return .invalid
                case .validated:
                    return truthStatus(for: executionReadiness)
                case .draft:
                    break
                }
            }

            switch planStatus {
            case .invalid:
                return .invalid
            case .validated:
                return truthStatus(for: executionReadiness)
            case .draft:
                switch draftStatus.kind {
                case .invalid:
                    return .invalid
                case .empty, .editing, .previewUnavailable, .ready:
                    return .draft
                }
            }
        }
    }

    private func activeTruthStatus(
        safetyState: MissionSafetyState,
        fallback: MissionTruthStatus
    ) -> MissionTruthStatus {
        guard let blockReason = safetyState.blockReason else {
            return fallback
        }
        return blockedTruthStatus(for: blockReason)
    }

    private func blockedTruthStatus(
        for blockReason: MissionBlockReason?,
        executionReadiness: MissionExecutionReadiness? = nil
    ) -> MissionTruthStatus {
        switch blockReason {
        case .executionContourMissing:
            return .executionUnbound
        case .executionBindingFailed:
            return .failedBinding
        case .runtimeDistanceUnavailable:
            return .runtimeDistanceUnavailable
        case .noControlAuthority:
            return .noAuthority
        case .noMissionTarget:
            return .noTarget
        case .routeInvalid, .noValidatedPlan:
            return .routeInvalid
        case .runtimeStallDetected, .batteryUnsafe, .runtimeUnsafe:
            return .runtimeUnsafe
        case .missionStartBlocked:
            return truthStatus(for: executionReadiness) == .ready
                ? .blocked
                : truthStatus(for: executionReadiness)
        case .none:
            switch executionReadiness {
            case .failedBinding:
                return .failedBinding
            case .executionUnbound:
                return .executionUnbound
            case .validated:
                return .validated
            case .ready:
                return .ready
            case .draft, .none:
                break
            }
            return .blocked
        }
    }

    private func truthStatus(for executionReadiness: MissionExecutionReadiness?) -> MissionTruthStatus {
        switch executionReadiness {
        case .validated:
            return .validated
        case .executionUnbound:
            return .executionUnbound
        case .ready:
            return .ready
        case .failedBinding:
            return .failedBinding
        case .draft, .none:
            return .draft
        }
    }

    private func makeExplanation(from warning: MissionWarning) -> MissionStatusExplanation {
        let severity: MissionStatusExplanationSeverity = {
            switch warning.severity {
            case .info:
                return .info
            case .warning:
                return .warning
            case .critical:
                return .critical
            }
        }()

        return MissionStatusExplanation(
            reason: warning.reason,
            severity: severity,
            detailKey: warning.detailKey,
            isBlocking: warning.severity == .critical
        )
    }

    private func unique(_ explanations: [MissionStatusExplanation]) -> [MissionStatusExplanation] {
        var seen = Set<String>()
        return explanations.filter { explanation in
            seen.insert(explanation.id).inserted
        }
    }
}
