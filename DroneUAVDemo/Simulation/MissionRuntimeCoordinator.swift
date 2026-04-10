import Foundation
import simd

final class MissionExecutionCoordinator {
    private let routeBuilder = MissionRouteBuilder()
    private let routeValidator = MissionRouteValidator()
    private let follower = MissionRouteFollower()

    private(set) var state: MissionExecutionState = .idle
    private(set) var currentValidatedRoute: MissionValidatedRoute?

    func currentTrackingState(
        position: SIMD3<Float>,
        airframeClass: AirframeClass
    ) -> MissionLineTrackingState? {
        guard state.executionStatus == .running || state.executionStatus == .failedsafe else {
            return state.lineTrackingState
        }

        guard let route = currentValidatedRoute,
              let activeSegmentIndex = state.activeSegmentIndex else {
            return nil
        }

        return follower.track(
            route: route,
            activeSegmentIndex: activeSegmentIndex,
            currentPosition: position,
            configuration: configuration(for: airframeClass)
        )
    }

    func reset() {
        state = .idle
        currentValidatedRoute = nil
    }

    func prepare(plan: MissionPlan) -> MissionExecutionState {
        let runtimeRoute = routeBuilder.build(from: plan)
        let routeValidation = routeValidator.validate(route: runtimeRoute, for: plan)
        currentValidatedRoute = routeValidation.isValid ? runtimeRoute : nil

        let progress = MissionWaypointProgress(
            currentIndex: 0,
            reachedCount: 0,
            totalCount: plan.waypoints.count,
            distanceToCurrent: runtimeRoute?.totalLengthMeters ?? plan.route.metrics.lengthMeters,
            lastReachedWaypointID: nil
        )

        state = MissionExecutionState(
            missionPlan: plan,
            currentPhase: routeValidation.isValid ? .ready : .aborted,
            executionStatus: routeValidation.isValid ? .ready : .aborted,
            waypointProgress: progress,
            progressSnapshot: MissionProgressSnapshot(
                currentPhase: routeValidation.isValid ? .ready : .aborted,
                status: routeValidation.isValid ? .ready : .aborted,
                activeWaypointIndex: plan.waypoints.isEmpty ? nil : 0,
                routeProgress: progress,
                distanceRemaining: runtimeRoute?.totalLengthMeters ?? 0.0,
                estimatedTimeRemaining: plan.route.metrics.estimatedFlightTimeSec,
                isPayloadActionPending: false,
                isReturnLegActive: false
            ),
            abortReason: routeValidation.isValid ? nil : .routeUnavailable,
            activeFailsafe: nil,
            controlAuthority: .none,
            activeSegmentIndex: routeValidation.isValid ? 0 : nil,
            activeSegment: nil,
            lineTrackingState: nil,
            isMissionControlActive: false,
            lastCommand: .prepareMission
        )

        return state
    }

    func command(
        _ command: MissionCommand,
        using input: MissionExecutionInput
    ) -> MissionExecutionResult {
        var resolvedState = resolvedState(from: input)
        guard let missionPlan = resolvedState.missionPlan else {
            reset()
            return MissionExecutionResult(
                state: .idle,
                requestedCommand: nil,
                requestedFailsafe: nil,
                warningKeys: ["mission.warning.invalid_plan_runtime"]
            )
        }

        switch command {
        case .prepareMission:
            return MissionExecutionResult(
                state: prepare(plan: missionPlan),
                requestedCommand: nil,
                requestedFailsafe: nil,
                warningKeys: []
            )

        case .armForMission:
            resolvedState.lastCommand = .armForMission
            state = resolvedState
            return MissionExecutionResult(
                state: resolvedState,
                requestedCommand: .armForMission,
                requestedFailsafe: nil,
                warningKeys: []
            )

        case .startMission:
            guard missionPlan.isReadyForExecution,
                  let route = currentValidatedRoute else {
                let aborted = abortedState(
                    from: resolvedState,
                    reason: .routeUnavailable,
                    command: .startMission
                )
                state = aborted
                return MissionExecutionResult(
                    state: aborted,
                    requestedCommand: nil,
                    requestedFailsafe: .abort,
                    warningKeys: ["mission.warning.route_unavailable"]
                )
            }

            let phase: MissionPhase = {
                if input.physicalState.isGroundRestState || !input.isArmed || input.flightMode == .takeoff {
                    return .takeoff
                }
                return phaseForSegmentIndex(
                    resolvedState.activeSegmentIndex ?? 0,
                    route: route
                )
            }()

            let next = refreshedState(
                from: resolvedState,
                phase: phase,
                status: .running,
                command: .startMission,
                controlAuthority: .mission,
                activeFailsafe: nil,
                abortReason: nil,
                trackingState: nil
            )
            state = next
            return MissionExecutionResult(
                state: next,
                requestedCommand: .startMission,
                requestedFailsafe: nil,
                warningKeys: []
            )

        case .pauseMission, .holdPosition:
            let paused = refreshedState(
                from: resolvedState,
                phase: .paused,
                status: .paused,
                command: command,
                controlAuthority: .mission,
                activeFailsafe: resolvedState.activeFailsafe,
                abortReason: resolvedState.abortReason,
                trackingState: nil
            )
            state = paused
            return MissionExecutionResult(
                state: paused,
                requestedCommand: .holdPosition,
                requestedFailsafe: nil,
                warningKeys: []
            )

        case .resumeMission:
            let resumed = refreshedState(
                from: resolvedState,
                phase: resumedPhase(from: resolvedState),
                status: .running,
                command: .resumeMission,
                controlAuthority: .mission,
                activeFailsafe: resolvedState.activeFailsafe,
                abortReason: resolvedState.abortReason,
                trackingState: nil
            )
            state = resumed
            return MissionExecutionResult(
                state: resumed,
                requestedCommand: .resumeMission,
                requestedFailsafe: nil,
                warningKeys: []
            )

        case .returnHome:
            guard let route = currentValidatedRoute else {
                return MissionExecutionResult(
                    state: resolvedState,
                    requestedCommand: nil,
                    requestedFailsafe: nil,
                    warningKeys: ["mission.warning.route_unavailable"]
                )
            }
            let rerouted = jumpToReturnLeg(
                from: resolvedState,
                route: route,
                command: .returnHome,
                failsafe: nil
            )
            state = rerouted
            return MissionExecutionResult(
                state: rerouted,
                requestedCommand: .returnHome,
                requestedFailsafe: nil,
                warningKeys: []
            )

        case .abortMission:
            let aborted = abortedState(
                from: resolvedState,
                reason: .userAbort,
                command: .abortMission
            )
            state = aborted
            return MissionExecutionResult(
                state: aborted,
                requestedCommand: .abortMission,
                requestedFailsafe: .abort,
                warningKeys: []
            )

        case .triggerPayloadDelivery:
            let payloadState = refreshedState(
                from: resolvedState,
                phase: .payloadDelivery,
                status: .running,
                command: .triggerPayloadDelivery,
                controlAuthority: .mission,
                activeFailsafe: resolvedState.activeFailsafe,
                abortReason: nil,
                trackingState: nil
            )
            state = payloadState
            return MissionExecutionResult(
                state: payloadState,
                requestedCommand: .triggerPayloadDelivery,
                requestedFailsafe: nil,
                warningKeys: []
            )
        }
    }

    func update(_ input: MissionExecutionInput) -> MissionExecutionResult {
        var resolvedState = resolvedState(from: input)
        guard let missionPlan = resolvedState.missionPlan else {
            reset()
            return MissionExecutionResult(
                state: .idle,
                requestedCommand: nil,
                requestedFailsafe: nil,
                warningKeys: []
            )
        }

        guard let route = currentValidatedRoute else {
            let failed = abortedState(
                from: resolvedState,
                reason: .routeUnavailable,
                command: resolvedState.lastCommand
            )
            state = failed
            return MissionExecutionResult(
                state: failed,
                requestedCommand: nil,
                requestedFailsafe: .abort,
                warningKeys: ["mission.warning.route_unavailable"]
            )
        }

        if resolvedState.executionStatus == .idle ||
            resolvedState.executionStatus == .ready ||
            resolvedState.executionStatus == .completed ||
            resolvedState.executionStatus == .aborted {
            state = resolvedState
            return MissionExecutionResult(
                state: resolvedState,
                requestedCommand: nil,
                requestedFailsafe: nil,
                warningKeys: []
            )
        }

        if input.linkState == .lost {
            let redirected = jumpToReturnLeg(
                from: resolvedState,
                route: route,
                command: resolvedState.lastCommand,
                failsafe: .returnHome
            )
            state = redirected
            return MissionExecutionResult(
                state: redirected,
                requestedCommand: .returnHome,
                requestedFailsafe: nil,
                warningKeys: ["mission.warning.link_lost"]
            )
        }

        let criticalBatteryThreshold: Float = 8.0
        let reserveThreshold = max(
            missionPlan.validationResult.energyEstimate.reserveRequiredPercent,
            missionPlan.constraints.reservePercent
        )

        if input.batteryState.chargePercent <= criticalBatteryThreshold {
            let failed = refreshedState(
                from: resolvedState,
                phase: .landing,
                status: .failedsafe,
                command: resolvedState.lastCommand,
                controlAuthority: .failsafe,
                activeFailsafe: .forcedLanding,
                abortReason: .lowBattery,
                trackingState: nil
            )
            state = failed
            return MissionExecutionResult(
                state: failed,
                requestedCommand: nil,
                requestedFailsafe: .forcedLanding,
                warningKeys: ["mission.warning.energy_critical"]
            )
        }

        if input.batteryState.chargePercent <= reserveThreshold || input.isOutsideOperationalBounds {
            let redirected = jumpToReturnLeg(
                from: resolvedState,
                route: route,
                command: resolvedState.lastCommand,
                failsafe: .returnHome,
                abortReason: input.isOutsideOperationalBounds ? .boundaryViolation : .lowBattery
            )
            state = redirected
            return MissionExecutionResult(
                state: redirected,
                requestedCommand: .returnHome,
                requestedFailsafe: nil,
                warningKeys: [input.isOutsideOperationalBounds ? "mission.warning.boundary_violation" : "mission.warning.energy_low"]
            )
        }

        if resolvedState.executionStatus == .paused {
            resolvedState.lineTrackingState = nil
            resolvedState.activeSegment = nil
            state = resolvedState
            return MissionExecutionResult(
                state: resolvedState,
                requestedCommand: nil,
                requestedFailsafe: nil,
                warningKeys: []
            )
        }

        if resolvedState.currentPhase == .payloadDelivery {
            if input.payloadState != .attached {
                let next = afterPayloadDelivery(
                    from: resolvedState,
                    route: route
                )
                state = next
                return MissionExecutionResult(
                    state: next,
                    requestedCommand: next.currentPhase == .returnHome ? .returnHome : nil,
                    requestedFailsafe: nil,
                    warningKeys: []
                )
            }

            state = resolvedState
            return MissionExecutionResult(
                state: resolvedState,
                requestedCommand: nil,
                requestedFailsafe: nil,
                warningKeys: []
            )
        }

        if resolvedState.currentPhase == .takeoff {
            let airborne = !input.physicalState.isGroundRestState && input.position.y >= missionPlan.cruiseAltitudeMeters - 0.6
            if !airborne {
                let holding = refreshedState(
                    from: resolvedState,
                    phase: .takeoff,
                    status: .running,
                    command: resolvedState.lastCommand,
                    controlAuthority: .mission,
                    activeFailsafe: resolvedState.activeFailsafe,
                    abortReason: resolvedState.abortReason,
                    trackingState: nil
                )
                state = holding
                return MissionExecutionResult(
                    state: holding,
                    requestedCommand: nil,
                    requestedFailsafe: nil,
                    warningKeys: []
                )
            }
            resolvedState = refreshedState(
                from: resolvedState,
                phase: phaseForSegmentIndex(resolvedState.activeSegmentIndex ?? 0, route: route),
                status: .running,
                command: resolvedState.lastCommand,
                controlAuthority: .mission,
                activeFailsafe: resolvedState.activeFailsafe,
                abortReason: resolvedState.abortReason,
                trackingState: nil
            )
        }

        guard let activeSegmentIndex = resolvedState.activeSegmentIndex else {
            let completed = completedState(from: resolvedState)
            state = completed
            return MissionExecutionResult(
                state: completed,
                requestedCommand: nil,
                requestedFailsafe: nil,
                warningKeys: []
            )
        }

        guard let tracking = follower.track(
            route: route,
            activeSegmentIndex: activeSegmentIndex,
            currentPosition: input.position,
            configuration: configuration(for: input.airframeClass)
        ) else {
            let failed = abortedState(
                from: resolvedState,
                reason: .routeUnavailable,
                command: resolvedState.lastCommand
            )
            state = failed
            return MissionExecutionResult(
                state: failed,
                requestedCommand: nil,
                requestedFailsafe: .abort,
                warningKeys: ["mission.warning.route_unavailable"]
            )
        }

        var nextState = resolvedState
        var nextTracking = tracking
        var completedSegmentIndex = activeSegmentIndex - 1

        if tracking.shouldAdvanceSegment {
            completedSegmentIndex = tracking.activeSegment.index
            let nextSegmentIndex = tracking.activeSegment.index + 1

            if tracking.isRouteComplete {
                let completed = completedState(
                    from: nextState,
                    reachedCount: route.reachedWaypointCount(afterCompletedSegmentIndex: completedSegmentIndex),
                    lastReachedWaypointID: missionPlan.waypoints.last?.id
                )
                state = completed
                return MissionExecutionResult(
                    state: completed,
                    requestedCommand: nil,
                    requestedFailsafe: nil,
                    warningKeys: []
                )
            }

            if route.isReturnLeg(segmentIndex: nextSegmentIndex),
               missionPlan.missionType == .delivery,
               input.payloadState == .attached {
                nextState.activeSegmentIndex = nextSegmentIndex
                nextState.currentPhase = .payloadDelivery
                nextState.executionStatus = .running
                nextState.progressSnapshot.isPayloadActionPending = true
                nextState.progressSnapshot.isReturnLegActive = false
                nextState.lineTrackingState = nil
                nextState.activeSegment = nil
                nextState.controlAuthority = .mission
                nextState.isMissionControlActive = true
                state = synchronizeProgress(
                    state: nextState,
                    route: route,
                    tracking: nil,
                    completedSegmentIndex: completedSegmentIndex,
                    missionPlan: missionPlan
                )
                return MissionExecutionResult(
                    state: state,
                    requestedCommand: .holdPosition,
                    requestedFailsafe: nil,
                    warningKeys: []
                )
            }

            nextState.activeSegmentIndex = nextSegmentIndex
            if let refreshedTracking = follower.track(
                route: route,
                activeSegmentIndex: nextSegmentIndex,
                currentPosition: input.position,
                configuration: configuration(for: input.airframeClass)
            ) {
                nextTracking = refreshedTracking
            }
        }

        nextState = synchronizeProgress(
            state: nextState,
            route: route,
            tracking: nextTracking,
            completedSegmentIndex: completedSegmentIndex,
            missionPlan: missionPlan
        )
        state = nextState

        return MissionExecutionResult(
            state: nextState,
            requestedCommand: nil,
            requestedFailsafe: nil,
            warningKeys: []
        )
    }

    private func afterPayloadDelivery(
        from state: MissionExecutionState,
        route: MissionValidatedRoute
    ) -> MissionExecutionState {
        let nextPhase: MissionPhase
        if let activeSegmentIndex = state.activeSegmentIndex,
           route.isReturnLeg(segmentIndex: activeSegmentIndex) {
            nextPhase = .returnHome
        } else {
            nextPhase = .completed
        }

        return refreshedState(
            from: state,
            phase: nextPhase,
            status: .running,
            command: state.lastCommand,
            controlAuthority: .mission,
            activeFailsafe: state.activeFailsafe,
            abortReason: state.abortReason,
            trackingState: nil
        )
    }

    private func synchronizeProgress(
        state: MissionExecutionState,
        route: MissionValidatedRoute,
        tracking: MissionLineTrackingState?,
        completedSegmentIndex: Int,
        missionPlan: MissionPlan
    ) -> MissionExecutionState {
        let reachedCount = max(0, route.reachedWaypointCount(afterCompletedSegmentIndex: completedSegmentIndex))
        let activeWaypointIndex = tracking?.activeSegment.activeWaypointIndex
        let lastReachedWaypointID = reachedCount > 0 ? missionPlan.waypoints[reachedCount - 1].id : nil
        let phase = tracking.map { phaseForTracking($0, route: route, missionPlan: missionPlan) } ?? state.currentPhase
        let distanceToCurrent = tracking?.waypointDistance ?? state.waypointProgress.distanceToCurrent
        let distanceRemaining = tracking?.distanceRemaining ?? state.progressSnapshot.distanceRemaining

        var next = state
        next.currentPhase = phase
        next.executionStatus = state.executionStatus == .failedsafe ? .failedsafe : .running
        next.controlAuthority = state.controlAuthority == .failsafe ? .failsafe : .mission
        next.activeSegment = tracking?.activeSegment
        next.lineTrackingState = tracking
        next.isMissionControlActive = true
        next.waypointProgress = MissionWaypointProgress(
            currentIndex: activeWaypointIndex ?? missionPlan.waypoints.count,
            reachedCount: reachedCount,
            totalCount: missionPlan.waypoints.count,
            distanceToCurrent: distanceToCurrent,
            lastReachedWaypointID: lastReachedWaypointID
        )
        next.progressSnapshot = MissionProgressSnapshot(
            currentPhase: phase,
            status: next.executionStatus,
            activeWaypointIndex: activeWaypointIndex,
            routeProgress: next.waypointProgress,
            distanceRemaining: distanceRemaining,
            estimatedTimeRemaining: missionPlan.route.metrics.estimatedFlightTimeSec,
            isPayloadActionPending: phase == .payloadDelivery,
            isReturnLegActive: tracking.map { route.isReturnLeg(segmentIndex: $0.activeSegment.index) } ?? state.progressSnapshot.isReturnLegActive
        )
        return next
    }

    private func phaseForTracking(
        _ tracking: MissionLineTrackingState,
        route: MissionValidatedRoute,
        missionPlan: MissionPlan
    ) -> MissionPhase {
        if route.isReturnLeg(segmentIndex: tracking.activeSegment.index) {
            return .returnHome
        }
        if let activeWaypointIndex = tracking.activeSegment.activeWaypointIndex,
           activeWaypointIndex >= max(0, missionPlan.waypoints.count - 1) {
            return .approach
        }
        return .transit
    }

    private func phaseForSegmentIndex(
        _ activeSegmentIndex: Int,
        route: MissionValidatedRoute
    ) -> MissionPhase {
        route.isReturnLeg(segmentIndex: activeSegmentIndex) ? .returnHome : .transit
    }

    private func resumedPhase(from state: MissionExecutionState) -> MissionPhase {
        if state.progressSnapshot.isPayloadActionPending {
            return .payloadDelivery
        }
        if state.progressSnapshot.isReturnLegActive {
            return .returnHome
        }
        return state.activeSegment?.segment.role == .returnHome ? .returnHome : .transit
    }

    private func jumpToReturnLeg(
        from state: MissionExecutionState,
        route: MissionValidatedRoute,
        command: MissionCommand?,
        failsafe: MissionFailsafeAction?,
        abortReason: MissionAbortReason? = nil
    ) -> MissionExecutionState {
        guard let returnLegStartSegmentIndex = route.returnLegStartSegmentIndex else {
            return refreshedState(
                from: state,
                phase: .paused,
                status: failsafe == nil ? .paused : .failedsafe,
                command: command,
                controlAuthority: failsafe == nil ? .mission : .failsafe,
                activeFailsafe: failsafe,
                abortReason: abortReason,
                trackingState: nil
            )
        }

        var next = refreshedState(
            from: state,
            phase: .returnHome,
            status: failsafe == nil ? .running : .failedsafe,
            command: command,
            controlAuthority: failsafe == nil ? .mission : .failsafe,
            activeFailsafe: failsafe,
            abortReason: abortReason,
            trackingState: nil
        )
        next.activeSegmentIndex = max(returnLegStartSegmentIndex, state.activeSegmentIndex ?? 0)
        next.progressSnapshot.isReturnLegActive = true
        next.progressSnapshot.isPayloadActionPending = false
        return next
    }

    private func completedState(
        from state: MissionExecutionState,
        reachedCount: Int? = nil,
        lastReachedWaypointID: UUID? = nil
    ) -> MissionExecutionState {
        var next = state
        next.currentPhase = .completed
        next.executionStatus = .completed
        next.controlAuthority = .none
        next.activeSegmentIndex = nil
        next.activeSegment = nil
        next.lineTrackingState = nil
        next.isMissionControlActive = false
        next.activeFailsafe = nil
        next.waypointProgress = MissionWaypointProgress(
            currentIndex: state.missionPlan?.waypoints.count ?? state.waypointProgress.currentIndex,
            reachedCount: reachedCount ?? state.waypointProgress.reachedCount,
            totalCount: state.missionPlan?.waypoints.count ?? state.waypointProgress.totalCount,
            distanceToCurrent: 0.0,
            lastReachedWaypointID: lastReachedWaypointID ?? state.waypointProgress.lastReachedWaypointID
        )
        next.progressSnapshot = MissionProgressSnapshot(
            currentPhase: .completed,
            status: .completed,
            activeWaypointIndex: nil,
            routeProgress: next.waypointProgress,
            distanceRemaining: 0.0,
            estimatedTimeRemaining: 0.0,
            isPayloadActionPending: false,
            isReturnLegActive: false
        )
        return next
    }

    private func abortedState(
        from state: MissionExecutionState,
        reason: MissionAbortReason,
        command: MissionCommand?
    ) -> MissionExecutionState {
        var next = state
        next.currentPhase = .aborted
        next.executionStatus = .aborted
        next.abortReason = reason
        next.activeFailsafe = .abort
        next.controlAuthority = .none
        next.activeSegmentIndex = nil
        next.activeSegment = nil
        next.lineTrackingState = nil
        next.isMissionControlActive = false
        next.lastCommand = command
        next.progressSnapshot = MissionProgressSnapshot(
            currentPhase: .aborted,
            status: .aborted,
            activeWaypointIndex: nil,
            routeProgress: next.waypointProgress,
            distanceRemaining: 0.0,
            estimatedTimeRemaining: 0.0,
            isPayloadActionPending: false,
            isReturnLegActive: false
        )
        return next
    }

    private func refreshedState(
        from state: MissionExecutionState,
        phase: MissionPhase,
        status: MissionExecutionStatus,
        command: MissionCommand?,
        controlAuthority: MissionControlAuthority,
        activeFailsafe: MissionFailsafeAction?,
        abortReason: MissionAbortReason?,
        trackingState: MissionLineTrackingState?
    ) -> MissionExecutionState {
        var next = state
        next.currentPhase = phase
        next.executionStatus = status
        next.controlAuthority = controlAuthority
        next.activeFailsafe = activeFailsafe
        next.abortReason = abortReason
        next.lineTrackingState = trackingState
        next.activeSegment = trackingState?.activeSegment
        next.isMissionControlActive = controlAuthority == .mission || controlAuthority == .failsafe
        next.lastCommand = command
        return next
    }

    private func resolvedState(from input: MissionExecutionInput) -> MissionExecutionState {
        var resolved = state
        if resolved.missionPlan == nil {
            resolved.missionPlan = input.missionPlan
        } else if let inputPlan = input.missionPlan {
            resolved.missionPlan = inputPlan
        }
        return resolved
    }

    private func configuration(for airframeClass: AirframeClass) -> MissionRouteFollower.Configuration {
        switch airframeClass {
        case .multirotor:
            return .multirotor
        case .fixedWing:
            return .fixedWing
        }
    }
}

typealias MissionRuntimeCoordinator = MissionExecutionCoordinator
