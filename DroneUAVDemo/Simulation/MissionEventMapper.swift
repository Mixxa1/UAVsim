import Foundation

final class MissionEventMapper {
    func simpleEvent(
        missionID: UUID?,
        category: MissionEventCategory,
        severity: MissionEventSeverity,
        code: MissionEventCode,
        detailKey: String? = nil,
        projectID: String,
        projectName: String,
        plan: MissionPlan?,
        statusSnapshot: MissionStatusSnapshot,
        batteryState: BatteryState,
        activeTarget: MissionTarget? = nil,
        payloadState: PayloadState? = nil
    ) -> MissionEvent {
        makeEvent(
            missionID: missionID,
            category: category,
            severity: severity,
            code: code,
            detailKey: detailKey,
            projectID: projectID,
            projectName: projectName,
            plan: plan,
            statusSnapshot: statusSnapshot,
            batteryState: batteryState,
            activeTarget: activeTarget,
            payloadState: payloadState
        )
    }

    func preparedEvents(
        plan: MissionPlan,
        projectID: String,
        projectName: String,
        statusSnapshot: MissionStatusSnapshot,
        batteryState: BatteryState
    ) -> [MissionEvent] {
        var events: [MissionEvent] = [
            makeEvent(
                missionID: plan.id,
                category: .planning,
                severity: .info,
                code: .missionDraftPrepared,
                projectID: projectID,
                projectName: projectName,
                plan: plan,
                statusSnapshot: statusSnapshot,
                batteryState: batteryState
            )
        ]

        if plan.isReadyForExecution {
            events.append(
                makeEvent(
                    missionID: plan.id,
                    category: .planning,
                    severity: .info,
                    code: .missionValidated,
                    projectID: projectID,
                    projectName: projectName,
                    plan: plan,
                    statusSnapshot: statusSnapshot,
                    batteryState: batteryState
                )
            )
        } else if let explanation = plan.explanations.first(where: \.isBlocking) ?? statusSnapshot.primaryExplanation {
            events.append(
                makeEvent(
                    missionID: plan.id,
                    category: .planning,
                    severity: explanation.severity == .critical ? .critical : .warning,
                    code: .missionBlocked,
                    detailKey: explanation.detailKey,
                    projectID: projectID,
                    projectName: projectName,
                    plan: plan,
                    statusSnapshot: statusSnapshot,
                    batteryState: batteryState
                )
            )
        }

        return events
    }

    func missionStartRequestedEvent(
        plan: MissionPlan?,
        projectID: String,
        projectName: String,
        statusSnapshot: MissionStatusSnapshot,
        batteryState: BatteryState
    ) -> MissionEvent {
        makeEvent(
            missionID: plan?.id,
            category: .operatorAction,
            severity: .info,
            code: .missionStartRequested,
            projectID: projectID,
            projectName: projectName,
            plan: plan,
            statusSnapshot: statusSnapshot,
            batteryState: batteryState
        )
    }

    func executionTransitionEvents(
        previous: MissionExecutionState,
        current: MissionExecutionState,
        plan: MissionPlan?,
        projectID: String,
        projectName: String,
        statusSnapshot: MissionStatusSnapshot,
        batteryState: BatteryState
    ) -> [MissionEvent] {
        var events: [MissionEvent] = []

        let previousCompleted = Set(previous.waypointProgress.filter { $0.state == .completed }.map(\.target.id))
        let newlyCompleted = current.waypointProgress.filter {
            $0.state == .completed && !previousCompleted.contains($0.target.id)
        }

        for progress in newlyCompleted {
            events.append(
                makeEvent(
                    missionID: plan?.id,
                    category: .execution,
                    severity: .info,
                    code: .waypointReached,
                    projectID: projectID,
                    projectName: projectName,
                    plan: plan,
                    statusSnapshot: statusSnapshot,
                    batteryState: batteryState,
                    activeTarget: progress.target
                )
            )

            events.append(
                makeEvent(
                    missionID: plan?.id,
                    category: .execution,
                    severity: .info,
                    code: .segmentCompleted,
                    projectID: projectID,
                    projectName: projectName,
                    plan: plan,
                    statusSnapshot: statusSnapshot,
                    batteryState: batteryState,
                    activeTarget: progress.target
                )
            )
        }

        if previous.activeTarget?.id != current.activeTarget?.id,
           let activeTarget = current.activeTarget {
            events.append(
                makeEvent(
                    missionID: plan?.id,
                    category: .execution,
                    severity: .info,
                    code: .waypointActivated,
                    projectID: projectID,
                    projectName: projectName,
                    plan: plan,
                    statusSnapshot: statusSnapshot,
                    batteryState: batteryState,
                    activeTarget: activeTarget
                )
            )
        }

        guard previous.status != current.status else {
            return events
        }

        switch current.status {
        case .running:
            let code: MissionEventCode = previous.status == .paused ? .missionResumed : .missionStarted
            events.append(
                makeEvent(
                    missionID: plan?.id,
                    category: .execution,
                    severity: .info,
                    code: code,
                    projectID: projectID,
                    projectName: projectName,
                    plan: plan,
                    statusSnapshot: statusSnapshot,
                    batteryState: batteryState,
                    activeTarget: current.activeTarget
                )
            )
        case .paused:
            events.append(
                makeEvent(
                    missionID: plan?.id,
                    category: .execution,
                    severity: .warning,
                    code: .missionPaused,
                    detailKey: current.explanations.first?.detailKey,
                    projectID: projectID,
                    projectName: projectName,
                    plan: plan,
                    statusSnapshot: statusSnapshot,
                    batteryState: batteryState,
                    activeTarget: current.activeTarget
                )
            )
        case .blocked:
            events.append(
                makeEvent(
                    missionID: plan?.id,
                    category: .execution,
                    severity: .warning,
                    code: .missionBlocked,
                    detailKey: current.explanations.first?.detailKey ?? statusSnapshot.primaryExplanation?.detailKey,
                    projectID: projectID,
                    projectName: projectName,
                    plan: plan,
                    statusSnapshot: statusSnapshot,
                    batteryState: batteryState,
                    activeTarget: current.activeTarget
                )
            )
        case .aborted:
            let severity: MissionEventSeverity = current.abortReason == .operatorRequested ? .warning : .critical
            events.append(
                makeEvent(
                    missionID: plan?.id,
                    category: .execution,
                    severity: severity,
                    code: .missionAborted,
                    detailKey: current.explanations.first?.detailKey ?? current.abortReason?.detailKey,
                    projectID: projectID,
                    projectName: projectName,
                    plan: plan,
                    statusSnapshot: statusSnapshot,
                    batteryState: batteryState,
                    activeTarget: current.activeTarget
                )
            )
        case .completed:
            events.append(
                makeEvent(
                    missionID: plan?.id,
                    category: .execution,
                    severity: .info,
                    code: .missionCompleted,
                    projectID: projectID,
                    projectName: projectName,
                    plan: plan,
                    statusSnapshot: statusSnapshot,
                    batteryState: batteryState
                )
            )
        case .failed:
            events.append(
                makeEvent(
                    missionID: plan?.id,
                    category: .execution,
                    severity: .critical,
                    code: .missionAborted,
                    detailKey: current.explanations.first?.detailKey ?? "mission.status.reason.unknown_runtime_mismatch",
                    projectID: projectID,
                    projectName: projectName,
                    plan: plan,
                    statusSnapshot: statusSnapshot,
                    batteryState: batteryState
                )
            )
        case .idle, .ready:
            break
        }

        return events
    }

    func safetyTransitionEvents(
        previous: MissionSafetyState,
        current: MissionSafetyState,
        plan: MissionPlan?,
        projectID: String,
        projectName: String,
        statusSnapshot: MissionStatusSnapshot,
        batteryState: BatteryState
    ) -> [MissionEvent] {
        var events: [MissionEvent] = []

        let previousWarningIDs = Set(previous.warnings.map(\.id))
        for warning in current.warnings where !previousWarningIDs.contains(warning.id) {
            guard warning.reason != .authorityFlapDetected else {
                continue
            }
            events.append(
                makeEvent(
                    missionID: plan?.id,
                    category: .safety,
                    severity: eventSeverity(for: warning.severity),
                    code: .missionWarningRaised,
                    detailKey: warning.detailKey,
                    projectID: projectID,
                    projectName: projectName,
                    plan: plan,
                    statusSnapshot: statusSnapshot,
                    batteryState: batteryState
                )
            )
        }

        if previous.authorityState.lossState == .transientLost && current.authorityState.didRecoverTransientLoss {
            events.append(
                makeEvent(
                    missionID: plan?.id,
                    category: .safety,
                    severity: .warning,
                    code: .controlAuthorityFlap,
                    detailKey: "mission.event.detail.controlAuthorityFlap",
                    projectID: projectID,
                    projectName: projectName,
                    plan: plan,
                    statusSnapshot: statusSnapshot,
                    batteryState: batteryState
                )
            )
            events.append(
                makeEvent(
                    missionID: plan?.id,
                    category: .safety,
                    severity: .info,
                    code: .controlAuthorityGranted,
                    projectID: projectID,
                    projectName: projectName,
                    plan: plan,
                    statusSnapshot: statusSnapshot,
                    batteryState: batteryState
                )
            )
        } else if previous.authorityState.lossState != .confirmedLost &&
            current.authorityState.lossState == .confirmedLost {
            events.append(
                makeEvent(
                    missionID: plan?.id,
                    category: .safety,
                    severity: .critical,
                    code: .controlAuthorityLost,
                    detailKey: current.authorityState.failureReason == .noMissionTarget
                        ? "mission.status.reason.no_mission_target"
                        : "mission.status.reason.no_control_authority",
                    projectID: projectID,
                    projectName: projectName,
                    plan: plan,
                    statusSnapshot: statusSnapshot,
                    batteryState: batteryState
                )
            )
        } else if previous.authorityState.lossState == .confirmedLost && current.authorityState.isAuthorityConfirmed {
            events.append(
                makeEvent(
                    missionID: plan?.id,
                    category: .safety,
                    severity: .info,
                    code: .controlAuthorityGranted,
                    projectID: projectID,
                    projectName: projectName,
                    plan: plan,
                    statusSnapshot: statusSnapshot,
                    batteryState: batteryState
                )
            )
        }

        if previous.blockReason != current.blockReason,
           let blockReason = current.blockReason,
           blockReason == .runtimeUnsafe || blockReason == .runtimeStallDetected || blockReason == .batteryUnsafe {
            events.append(
                makeEvent(
                    missionID: plan?.id,
                    category: .safety,
                    severity: blockReason == .batteryUnsafe ? .warning : .critical,
                    code: .runtimeUnsafeDetected,
                    detailKey: blockReason.detailKey,
                    projectID: projectID,
                    projectName: projectName,
                    plan: plan,
                    statusSnapshot: statusSnapshot,
                    batteryState: batteryState
                )
            )
        }

        if previous.failsafeMode != current.failsafeMode,
           current.failsafeMode != .none {
            events.append(
                makeEvent(
                    missionID: plan?.id,
                    category: .failsafe,
                    severity: current.failsafeMode == .hold || current.failsafeMode == .pauseMission ? .warning : .critical,
                    code: .failsafeTriggered,
                    detailKey: current.failsafeMode.titleKey,
                    projectID: projectID,
                    projectName: projectName,
                    plan: plan,
                    statusSnapshot: statusSnapshot,
                    batteryState: batteryState
                )
            )

            if current.failsafeMode == .returnHome {
                events.append(
                    makeEvent(
                        missionID: plan?.id,
                        category: .failsafe,
                        severity: .warning,
                        code: .returnHomeTriggered,
                        detailKey: "mission.status.reason.return_home_triggered",
                        projectID: projectID,
                        projectName: projectName,
                        plan: plan,
                        statusSnapshot: statusSnapshot,
                        batteryState: batteryState
                    )
                )
            }
        }

        return events
    }

    func payloadTriggeredEvent(
        missionID: UUID?,
        projectID: String,
        projectName: String,
        payloadState: PayloadState,
        statusSnapshot: MissionStatusSnapshot,
        batteryState: BatteryState,
        detailKey: String?
    ) -> MissionEvent {
        makeEvent(
            missionID: missionID,
            category: .payload,
            severity: .info,
            code: .payloadActionTriggered,
            detailKey: detailKey,
            projectID: projectID,
            projectName: projectName,
            plan: nil,
            statusSnapshot: statusSnapshot,
            batteryState: batteryState,
            payloadState: payloadState
        )
    }

    func payloadCompletedEvent(
        missionID: UUID?,
        projectID: String,
        projectName: String,
        payloadState: PayloadState,
        statusSnapshot: MissionStatusSnapshot,
        batteryState: BatteryState,
        detailKey: String?
    ) -> MissionEvent {
        makeEvent(
            missionID: missionID,
            category: .payload,
            severity: .info,
            code: .payloadActionCompleted,
            detailKey: detailKey,
            projectID: projectID,
            projectName: projectName,
            plan: nil,
            statusSnapshot: statusSnapshot,
            batteryState: batteryState,
            payloadState: payloadState
        )
    }

    func debriefGeneratedEvent(
        debrief: MissionDebrief,
        projectID: String,
        projectName: String
    ) -> MissionEvent {
        MissionEvent(
            missionID: debrief.timelineID,
            category: .diagnostics,
            severity: .info,
            code: .debriefGenerated,
            context: MissionEventContext(
                projectID: projectID,
                projectName: projectName,
                missionPlanID: nil,
                waypointIndex: nil,
                waypointLabel: nil,
                truthStatusRaw: debrief.execution.finalTruthStatusRaw,
                executionStatusRaw: debrief.execution.finalExecutionStatusRaw,
                planStatusRaw: nil,
                controlAuthorityRaw: nil,
                failsafeModeRaw: debrief.execution.finalFailsafeModeRaw,
                distanceToTargetMeters: nil,
                batteryPercent: debrief.energy.endBatteryPercent,
                payloadStateRaw: debrief.payload.finalPayloadStateRaw,
                warningReasonRaw: nil,
                noteKey: debrief.summary.verdictKey
            )
        )
    }

    private func makeEvent(
        missionID: UUID?,
        category: MissionEventCategory,
        severity: MissionEventSeverity,
        code: MissionEventCode,
        detailKey: String? = nil,
        projectID: String,
        projectName: String,
        plan: MissionPlan?,
        statusSnapshot: MissionStatusSnapshot,
        batteryState: BatteryState,
        activeTarget: MissionTarget? = nil,
        payloadState: PayloadState? = nil
    ) -> MissionEvent {
        let target = activeTarget ?? statusSnapshot.activeTargetLabel.flatMap { label in
            guard let plan,
                  let target = plan.waypoints.first(where: { $0.label == label }) else {
                return nil
            }
            return target
        }

        return MissionEvent(
            missionID: missionID,
            category: category,
            severity: severity,
            code: code,
            detailKey: detailKey,
            context: MissionEventContext(
                projectID: projectID,
                projectName: projectName,
                missionPlanID: plan?.id,
                waypointIndex: target?.index,
                waypointLabel: target?.label,
                truthStatusRaw: statusSnapshot.truthStatus.rawValue,
                executionStatusRaw: statusSnapshot.executionStatus.rawValue,
                planStatusRaw: statusSnapshot.planStatus.rawValue,
                controlAuthorityRaw: statusSnapshot.controlAuthority.rawValue,
                failsafeModeRaw: statusSnapshot.safetyState.failsafeMode.rawValue,
                distanceToTargetMeters: statusSnapshot.distanceToActiveTarget,
                batteryPercent: batteryState.chargePercent,
                payloadStateRaw: payloadState?.rawValue,
                warningReasonRaw: statusSnapshot.primaryExplanation?.reason.rawValue,
                noteKey: nil
            )
        )
    }

    private func eventSeverity(for warningSeverity: MissionWarningSeverity) -> MissionEventSeverity {
        switch warningSeverity {
        case .info:
            return .info
        case .warning:
            return .warning
        case .critical:
            return .critical
        }
    }
}
