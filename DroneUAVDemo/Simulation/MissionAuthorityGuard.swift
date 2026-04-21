import Foundation

final class MissionAuthorityGuard {
    private let lossConfirmationDelay: TimeInterval
    private var pendingLossStartedAt: Date?
    private var pendingLossReason: MissionFailureReason?

    init(lossConfirmationDelay: TimeInterval = 0.8) {
        self.lossConfirmationDelay = max(0.15, lossConfirmationDelay)
    }

    func evaluate(
        executionState: MissionExecutionState,
        controlAuthority: FlightControlAuthority,
        missionOwnsTargetSource: Bool,
        airframeClass: AirframeClass,
        fixedWingDebugState: FixedWingAutopilotDebugState?,
        currentMarker: TargetMarkerState?,
        adapter: MissionAutopilotAdapter
    ) -> MissionControlAuthorityState {
        let now = Date()
        let requiresMissionAuthority = executionState.status == .running
        let fixedWingRouteActive = airframeClass == .fixedWing &&
            isFixedWingMissionRouteActive(debugState: fixedWingDebugState)
        let hasBoundMissionTarget = fixedWingRouteActive || adapter.isBound(
            activeTarget: executionState.activeTarget,
            currentMarker: currentMarker
        )

        guard requiresMissionAuthority else {
            resetPendingLoss()
            return MissionControlAuthorityState(
                expectedAuthority: .none,
                actualAuthority: controlAuthority,
                sourceOwnsTarget: missionOwnsTargetSource,
                hasBoundMissionTarget: hasBoundMissionTarget,
                requiresMissionAuthority: false,
                isAuthorityConfirmed: true,
                lossState: .stable,
                lossDuration: 0.0,
                didRecoverTransientLoss: false,
                failureReason: nil
            )
        }

        let failureReason: MissionFailureReason? = {
            if executionState.activeTarget == nil || !missionOwnsTargetSource || !hasBoundMissionTarget {
                return .noMissionTarget
            }
            if fixedWingRouteActive {
                return nil
            }
            if controlAuthority != .markerGuidance {
                return .noControlAuthority
            }
            return nil
        }()

        if let failureReason {
            if pendingLossReason != failureReason || pendingLossStartedAt == nil {
                pendingLossReason = failureReason
                pendingLossStartedAt = now
            }

            let duration = max(0.0, now.timeIntervalSince(pendingLossStartedAt ?? now))
            let lossState: MissionAuthorityLossState = duration >= lossConfirmationDelay
                ? .confirmedLost
                : .transientLost

            return MissionControlAuthorityState(
                expectedAuthority: fixedWingRouteActive ? .none : .markerGuidance,
                actualAuthority: controlAuthority,
                sourceOwnsTarget: missionOwnsTargetSource,
                hasBoundMissionTarget: hasBoundMissionTarget,
                requiresMissionAuthority: true,
                isAuthorityConfirmed: false,
                lossState: lossState,
                lossDuration: duration,
                didRecoverTransientLoss: false,
                failureReason: failureReason
            )
        }

        let transientLossDuration: TimeInterval = {
            guard let pendingLossStartedAt else {
                return 0.0
            }
            return max(0.0, now.timeIntervalSince(pendingLossStartedAt))
        }()
        let didRecoverTransientLoss = transientLossDuration > 0.0 &&
            transientLossDuration < lossConfirmationDelay
        resetPendingLoss()

        return MissionControlAuthorityState(
            expectedAuthority: fixedWingRouteActive ? .none : .markerGuidance,
            actualAuthority: controlAuthority,
            sourceOwnsTarget: missionOwnsTargetSource,
            hasBoundMissionTarget: hasBoundMissionTarget,
            requiresMissionAuthority: true,
            isAuthorityConfirmed: true,
            lossState: .stable,
            lossDuration: 0.0,
            didRecoverTransientLoss: didRecoverTransientLoss,
            failureReason: nil
        )
    }

    private func isFixedWingMissionRouteActive(
        debugState: FixedWingAutopilotDebugState?
    ) -> Bool {
        guard let debugState,
              let routeIdentifier = debugState.routeIdentifier,
              routeIdentifier.hasPrefix("mission:") else {
            return false
        }

        switch debugState.missionState {
        case .idle, .failed:
            return false
        case .aligningToLaunch,
             .climbout,
             .capturingLeg,
             .trackingLeg,
             .flyByTurn,
             .loitering,
             .completed,
             .recoveringSpeed:
            return true
        }
    }

    private func resetPendingLoss() {
        pendingLossStartedAt = nil
        pendingLossReason = nil
    }
}
