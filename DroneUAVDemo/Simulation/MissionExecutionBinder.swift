import Foundation
import simd

struct MissionExecutionBindingResult: Equatable {
    var bindingState: MissionExecutionBindingState
    var activeWaypointIndex: Int?
    var activeTarget: MissionTarget?
    var waypointProgress: [MissionWaypointProgress]
    var distanceToActiveTarget: Float?
    var failureReason: MissionFailureReason?
    var explanations: [MissionStatusExplanation]

    var hasExecutionContour: Bool {
        bindingState == .bound && !waypointProgress.isEmpty
    }
}

final class MissionExecutionBinder {
    func bind(
        plan: MissionPlan,
        currentPosition: SIMD2<Float>
    ) -> MissionExecutionBindingResult {
        guard plan.isReadyForExecution else {
            return MissionExecutionBindingResult(
                bindingState: .failed,
                activeWaypointIndex: nil,
                activeTarget: nil,
                waypointProgress: [],
                distanceToActiveTarget: nil,
                failureReason: .executionBindingFailed,
                explanations: plan.explanations
            )
        }

        guard plan.routePoints.count >= 2 else {
            return failure(
                reason: .executionContourMissing,
                detailKey: "mission.status.reason.execution_contour_missing"
            )
        }

        guard let firstTarget = plan.executionTargets.first else {
            return failure(
                reason: .noMissionTarget,
                detailKey: "mission.status.reason.no_active_execution_target"
            )
        }

        let distance = simd_distance(currentPosition, firstTarget.position)
        guard distance.isFinite else {
            return failure(
                reason: .runtimeDistanceUnavailable,
                detailKey: "mission.status.reason.runtime_distance_unavailable"
            )
        }

        let progress = plan.waypoints.enumerated().map { index, target in
            MissionWaypointProgress(
                target: target,
                state: index == 0 ? .active : .pending,
                reachedAt: nil
            )
        }

        return MissionExecutionBindingResult(
            bindingState: .bound,
            activeWaypointIndex: 0,
            activeTarget: firstTarget,
            waypointProgress: progress,
            distanceToActiveTarget: distance,
            failureReason: nil,
            explanations: [
                MissionStatusExplanation(
                    reason: .executionNotStarted,
                    severity: .info,
                    detailKey: "mission.status.reason.execution_not_started",
                    isBlocking: false
                )
            ]
        )
    }

    private func failure(
        reason: MissionFailureReason,
        detailKey: String
    ) -> MissionExecutionBindingResult {
        MissionExecutionBindingResult(
            bindingState: .failed,
            activeWaypointIndex: nil,
            activeTarget: nil,
            waypointProgress: [],
            distanceToActiveTarget: nil,
            failureReason: reason,
            explanations: [
                MissionStatusExplanation(
                    reason: reason,
                    severity: .critical,
                    detailKey: detailKey
                )
            ]
        )
    }
}
