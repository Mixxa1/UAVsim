import Foundation

final class MissionExecutionCoordinator {
    func prepare(
        plan: MissionPlan,
        binding: MissionExecutionBindingResult
    ) -> MissionExecutionState {
        guard plan.isReadyForExecution,
              binding.bindingState == .bound,
              let firstTarget = binding.activeTarget else {
            return MissionExecutionState(
                mode: .none,
                status: .blocked,
                bindingState: binding.bindingState,
                planID: plan.id,
                activeWaypointIndex: binding.activeWaypointIndex,
                activeTarget: binding.activeTarget,
                waypointProgress: binding.waypointProgress,
                distanceToActiveTarget: binding.distanceToActiveTarget,
                hasBoundAutopilotTarget: false,
                failureReason: binding.failureReason ?? .executionBindingFailed,
                abortReason: nil,
                explanations: binding.explanations.isEmpty ? plan.explanations : binding.explanations,
                lastUpdatedAt: Date()
            )
        }

        return MissionExecutionState(
            mode: .autopilotTarget,
            status: .ready,
            bindingState: binding.bindingState,
            planID: plan.id,
            activeWaypointIndex: binding.activeWaypointIndex,
            activeTarget: firstTarget,
            waypointProgress: binding.waypointProgress,
            distanceToActiveTarget: binding.distanceToActiveTarget,
            hasBoundAutopilotTarget: false,
            failureReason: nil,
            abortReason: nil,
            explanations: binding.explanations,
            lastUpdatedAt: Date()
        )
    }

    func start(state: MissionExecutionState) -> MissionExecutionState {
        guard state.canStart else {
            return blocked(
                from: state,
                reason: .planNotReady,
                detailKey: "mission.status.reason.plan_not_ready"
            )
        }

        var nextState = state
        nextState.status = .running
        nextState.bindingState = .bound
        nextState.explanations = []
        nextState.failureReason = nil
        nextState.abortReason = nil
        nextState.lastUpdatedAt = Date()
        return nextState
    }

    func pause(
        state: MissionExecutionState,
        reason: MissionFailureReason = .missionPausedByOperator,
        detailKey: String = "mission.status.reason.mission_paused_by_operator"
    ) -> MissionExecutionState {
        guard state.canPause else {
            return state
        }

        var nextState = state
        nextState.status = .paused
        nextState.bindingState = .bound
        nextState.hasBoundAutopilotTarget = false
        nextState.failureReason = reason
        nextState.explanations = [
            MissionStatusExplanation(
                reason: reason,
                severity: .warning,
                detailKey: detailKey,
                isBlocking: false
            )
        ]
        nextState.lastUpdatedAt = Date()
        return nextState
    }

    func resume(state: MissionExecutionState) -> MissionExecutionState {
        guard state.canResume else {
            return state
        }

        var nextState = state
        nextState.status = .running
        nextState.bindingState = .bound
        nextState.explanations = []
        nextState.failureReason = nil
        nextState.abortReason = nil
        nextState.lastUpdatedAt = Date()
        return nextState
    }

    func abort(
        state: MissionExecutionState,
        reason: MissionFailureReason = .missionAborted,
        abortReason: MissionAbortReason = .operatorRequested,
        detailKey: String = "mission.status.reason.mission_aborted"
    ) -> MissionExecutionState {
        guard state.canAbort else {
            return state
        }

        var nextState = state
        nextState.status = .aborted
        nextState.mode = .none
        nextState.bindingState = .unbound
        nextState.activeWaypointIndex = nil
        nextState.activeTarget = nil
        nextState.distanceToActiveTarget = nil
        nextState.hasBoundAutopilotTarget = false
        nextState.failureReason = reason
        nextState.abortReason = abortReason
        nextState.explanations = [
            MissionStatusExplanation(
                reason: reason,
                severity: .critical,
                detailKey: detailKey
            )
        ]
        nextState.lastUpdatedAt = Date()
        return nextState
    }

    func update(
        state: MissionExecutionState,
        plan: MissionPlan,
        progress: MissionProgressUpdate
    ) -> MissionExecutionState {
        guard state.planID == plan.id else {
            return blocked(
                from: state,
                reason: .planNotReady,
                detailKey: "mission.status.reason.plan_not_ready"
            )
        }

        var nextState = state
        nextState.distanceToActiveTarget = progress.distanceToActiveTarget
        nextState.hasBoundAutopilotTarget = progress.hasBoundTarget
        nextState.bindingState = .bound
        nextState.lastUpdatedAt = Date()

        guard state.status == .running else {
            return nextState
        }

        if progress.hasReachedActiveTarget,
           let activeWaypointIndex = state.activeWaypointIndex {
            nextState = completeExecutionTarget(
                state: nextState,
                reachedIndex: activeWaypointIndex,
                plan: plan
            )
            return nextState
        }

        return nextState
    }

    private func completeExecutionTarget(
        state: MissionExecutionState,
        reachedIndex: Int,
        plan: MissionPlan
    ) -> MissionExecutionState {
        var nextState = state
        guard reachedIndex >= 0,
              reachedIndex < plan.executionTargets.count else {
            return blocked(
                from: nextState,
                reason: .executionBlocked,
                detailKey: "mission.status.reason.execution_blocked"
            )
        }
        let reachedAt = Date()
        let reachedTarget = plan.executionTargets[reachedIndex]
        let nextPendingExecutionIndex = reachedIndex + 1 < plan.executionTargets.count
            ? reachedIndex + 1
            : nil

        nextState.waypointProgress = nextState.waypointProgress.map { progress in
            guard reachedTarget.countsTowardMissionProgress,
                  progress.target.waypointID == reachedTarget.waypointID else {
                return progress
            }
            var nextProgress = progress
            nextProgress.state = .completed
            nextProgress.reachedAt = reachedAt
            return nextProgress
        }

        if let nextExecutionIndex = nextPendingExecutionIndex {
            let nextExecutionTarget = plan.executionTargets[nextExecutionIndex]
            nextState.waypointProgress = nextState.waypointProgress.map { progress in
                guard progress.state != .completed else {
                    return progress
                }
                var nextProgress = progress
                nextProgress.state = progress.target.waypointID == nextExecutionTarget.waypointID
                    ? .active
                    : .pending
                return nextProgress
            }

            nextState.activeWaypointIndex = nextExecutionIndex
            nextState.activeTarget = nextExecutionTarget
            nextState.distanceToActiveTarget = nil
            nextState.bindingState = .bound
            nextState.hasBoundAutopilotTarget = false
            nextState.failureReason = nil
            nextState.abortReason = nil
            nextState.explanations = [
                MissionStatusExplanation(
                    reason: .waypointReached,
                    severity: .info,
                    detailKey: "mission.status.reason.waypoint_reached",
                    isBlocking: false
                )
            ]
            nextState.lastUpdatedAt = reachedAt
            return nextState
        }

        let completedWaypointCount = nextState.waypointProgress.filter { $0.state == .completed }.count
        let totalWaypointCount = max(plan.waypoints.count, nextState.waypointProgress.count)
        let reachedFinalExecutionTarget = reachedIndex >= plan.executionTargets.count - 1
        guard totalWaypointCount > 0,
              reachedFinalExecutionTarget,
              completedWaypointCount >= totalWaypointCount else {
            return blocked(
                from: nextState,
                reason: .executionBlocked,
                detailKey: "mission.status.reason.execution_blocked"
            )
        }

        nextState.status = .completed
        nextState.mode = .none
        nextState.bindingState = .unbound
        nextState.activeWaypointIndex = nil
        nextState.activeTarget = nil
        nextState.distanceToActiveTarget = nil
        nextState.hasBoundAutopilotTarget = false
        nextState.failureReason = nil
        nextState.abortReason = nil
        nextState.explanations = [
            MissionStatusExplanation(
                reason: .missionCompleted,
                severity: .info,
                detailKey: "mission.status.reason.mission_completed",
                isBlocking: false
            )
        ]
        nextState.lastUpdatedAt = reachedAt
        return nextState
    }

    func blocked(
        from state: MissionExecutionState,
        reason: MissionFailureReason,
        detailKey: String
    ) -> MissionExecutionState {
        var nextState = state
        nextState.status = .blocked
        nextState.bindingState = .failed
        nextState.hasBoundAutopilotTarget = false
        nextState.failureReason = reason
        nextState.abortReason = nil
        nextState.explanations = [
            MissionStatusExplanation(
                reason: reason,
                severity: .critical,
                detailKey: detailKey
            )
        ]
        nextState.lastUpdatedAt = Date()
        return nextState
    }

    func failed(
        from state: MissionExecutionState,
        reason: MissionFailureReason,
        detailKey: String
    ) -> MissionExecutionState {
        var nextState = state
        nextState.status = .failed
        nextState.mode = .none
        nextState.bindingState = .failed
        nextState.activeWaypointIndex = nil
        nextState.activeTarget = nil
        nextState.distanceToActiveTarget = nil
        nextState.hasBoundAutopilotTarget = false
        nextState.failureReason = reason
        nextState.abortReason = .unknownRuntimeMismatch
        nextState.explanations = [
            MissionStatusExplanation(
                reason: reason,
                severity: .critical,
                detailKey: detailKey
            )
        ]
        nextState.lastUpdatedAt = Date()
        return nextState
    }
}
