import Foundation
import simd

struct FixedWingAssistOutput {
    let state: FixedWingAssistState
    let rollDegrees: Float
    let pitchDegrees: Float
    let yawDegrees: Float
    let throttle: Float
    let transitionReason: String?
}

struct FixedWingAssistInterceptDebugContext {
    let activeTargetSource: String
    let segmentCountAfterValidation: Int
    let activeRouteIncludesHome: Bool
    let selectedWaypointID: UUID?
    let guidanceTargetType: String
    let guidanceTargetPoint: SIMD2<Float>?
    let currentLegStart: SIMD2<Float>?
    let currentLegEnd: SIMD2<Float>?
}

struct FixedWingAssistGeometryAssessment {
    let feasibilityState: FixedWingAssistInterceptFeasibilityState
    let distanceToWaypoint: Float
    let headingErrorRadians: Float
    let availableTurnInDistance: Float
    let estimatedTurnRadius: Float
    let targetBearing: Float
    let limitedHeading: Float
    let turnCommand: Float
    let commandedBankDegrees: Float
    let commandedTurnDirection: FixedWingAssistTurnDirection
}

final class FixedWingAssistController {
    private struct TerminalCaptureTracker {
        var waypointID: UUID?
        var targetPosition: SIMD2<Float>
        var captureOrigin: SIMD2<Float>
        var approachDirection: SIMD2<Float>
        var alongTrackToWaypointAtStart: Float
        var previousPlaneDistance: Float
        var previousDistanceToWaypoint: Float
        var closestDistanceToWaypoint: Float
        var enteredCaptureRadius: Bool
        var crossedAcceptancePlane: Bool
    }

    private struct TerminalCaptureAssessment {
        let distanceToWaypoint: Float
        let captureRadius: Float
        let enteredCaptureRadius: Bool
        let crossedAcceptancePlane: Bool
        let interceptCompletedReason: String

        var completedReason: String? {
            interceptCompletedReason == "pending" ? nil : interceptCompletedReason
        }
    }

    private enum Tuning {
        static let headingBankGain: Float = 0.82
        static let neutralBlend: Float = 0.12
        static let pitchBlend: Float = 0.14
        static let throttleBlend: Float = 0.10
        static let altitudePitchGain: Float = 0.92
        static let altitudePitchDamping: Float = 1.95
        static let altitudeThrottleGain: Float = 0.012
        static let altitudeThrottleDamping: Float = 0.040
        static let interceptLeadLimitDeg: Float = 58.0
        static let headingBankFraction: Float = 0.72
        static let maxAssistBankDeg: Float = 30.0
        static let maxAltitudePitchDeg: Float = 10.0
        static let minAltitudePitchDeg: Float = -9.0
        static let interceptDebugInterval: TimeInterval = 0.25
        static let waypointRetargetToleranceMeters: Float = 0.05
        static let acceptancePlaneHysteresisMeters: Float = 0.10
        static let nearPassRadiusMultiplier: Float = 1.35
        static let nearPassOpeningDistanceMeters: Float = 0.15
        static let tightTurnLeadLimitDeg: Float = 52.0
        static let poorGeometryLeadLimitDeg: Float = 64.0
    }

    private var turnOverrideWasActive = false
    private var altitudeOverrideWasActive = false
    private var terminalCaptureTracker: TerminalCaptureTracker?
    private var lastInterceptDebugTimestamp = Date.distantPast
    func reset() {
        turnOverrideWasActive = false
        altitudeOverrideWasActive = false
        terminalCaptureTracker = nil
        lastInterceptDebugTimestamp = .distantPast
    }

    func engage(
        _ mode: FixedWingAssistMode,
        from aircraftState: DroneState,
        selectedWaypointID: UUID?,
        currentState: FixedWingAssistState
    ) -> FixedWingAssistState {
        reset()

        var nextState = currentState
        nextState.mode = mode
        nextState.selectedWaypointID = selectedWaypointID ?? currentState.selectedWaypointID
        nextState.targetHeadingRadians = nil
        nextState.targetAltitudeMeters = nil
        nextState.interceptCompleted = false
        nextState.captureCompletedReason = nil
        nextState.autoAdvanceSuppressed = false
        nextState.autoAdvanceSuppressedReason = nil
        nextState.commandedTurnDirection = .none
        nextState.activeGuidanceTargetType = "none"
        nextState.activeGuidanceMode = "none"
        nextState.usingObsoleteFixedWingMode = false

        switch mode {
        case .manual:
            nextState.interceptState = .manual
        case .headingHold:
            nextState.interceptState = .headingHold
            nextState.targetHeadingRadians = aircraftState.orientation.z
            nextState.targetAltitudeMeters = max(0.0, aircraftState.position.y)
        case .altitudeHold:
            nextState.interceptState = .altitudeHold
            nextState.targetHeadingRadians = aircraftState.orientation.z
            nextState.targetAltitudeMeters = max(0.0, aircraftState.position.y)
        case .waypointIntercept:
            nextState.interceptState = .singlePointIntercept
            nextState.targetHeadingRadians = aircraftState.orientation.z
            nextState.targetAltitudeMeters = max(0.0, aircraftState.position.y)
            nextState.activeGuidanceTargetType = "singlePointIntercept"
            nextState.activeGuidanceMode = "singlePointIntercept"
        }

        return nextState
    }

    func update(
        assistState: FixedWingAssistState,
        aircraftState: DroneState,
        wing: FixedWingParameters,
        baseline: ResolvedFlightBaseline,
        currentControls: DroneControlValues,
        interceptTarget: SIMD2<Float>?,
        captureTarget: SIMD2<Float>?,
        interceptDebugContext: FixedWingAssistInterceptDebugContext,
        turnOverrideActive: Bool,
        altitudeOverrideActive: Bool
    ) -> FixedWingAssistOutput? {
        guard assistState.mode != .manual else {
            reset()
            return nil
        }

        var nextState = assistState

        if turnOverrideActive {
            turnOverrideWasActive = true
        } else if turnOverrideWasActive {
            nextState.targetHeadingRadians = aircraftState.orientation.z
            turnOverrideWasActive = false
        }

        if altitudeOverrideActive {
            altitudeOverrideWasActive = true
        } else if altitudeOverrideWasActive {
            nextState.targetAltitudeMeters = max(0.0, aircraftState.position.y)
            altitudeOverrideWasActive = false
        }

        let cruiseThrottle = baseline.cruiseReferenceThrottle
        let minThrottle = baseline.effectiveMinimumSafeFlightThrottle
        let maxThrottle = max(minThrottle + 0.18, baseline.effectiveClimbThrottle)

        var yawTargetRadians = nextState.targetHeadingRadians ?? aircraftState.orientation.z
        var rollTargetDegrees = smoothed(
            current: Float(currentControls.roll),
            target: 0.0,
            blend: Tuning.neutralBlend
        )
        var pitchTargetDegrees = smoothed(
            current: Float(currentControls.pitch),
            target: 0.0,
            blend: Tuning.neutralBlend
        )
        var throttleTarget = smoothed(
            current: Float(currentControls.throttle),
            target: cruiseThrottle,
            blend: Tuning.throttleBlend
        )
        var transitionReason: String?

        switch nextState.mode {
        case .manual:
            break
        case .headingHold:
            terminalCaptureTracker = nil
            applyGeometryDiagnostics(
                evaluateInterceptGeometry(
                    aircraftState: aircraftState,
                    wing: wing,
                    interceptTarget: interceptTarget
                ),
                to: &nextState
            )
            yawTargetRadians = nextState.targetHeadingRadians ?? aircraftState.orientation.z
            rollTargetDegrees = headingRollTarget(
                currentHeading: aircraftState.orientation.z,
                targetHeading: yawTargetRadians,
                maxBankDegrees: min(Float(wing.maxBankAngleDeg) * Tuning.headingBankFraction, Tuning.maxAssistBankDeg)
            )
        case .altitudeHold:
            terminalCaptureTracker = nil
            applyGeometryDiagnostics(
                evaluateInterceptGeometry(
                    aircraftState: aircraftState,
                    wing: wing,
                    interceptTarget: interceptTarget
                ),
                to: &nextState
            )
            nextState.targetHeadingRadians = aircraftState.orientation.z
            yawTargetRadians = aircraftState.orientation.z
            let altitudeTargets = altitudeTargetsForHold(
                aircraftState: aircraftState,
                targetAltitude: nextState.targetAltitudeMeters ?? aircraftState.position.y,
                currentControls: currentControls,
                cruiseThrottle: cruiseThrottle,
                minThrottle: minThrottle,
                maxThrottle: maxThrottle
            )
            pitchTargetDegrees = altitudeTargets.pitchDegrees
            throttleTarget = altitudeTargets.throttle
        case .waypointIntercept:
            let planarPosition = SIMD2<Float>(aircraftState.position.x, aircraftState.position.z)
            guard let interceptTarget else {
                terminalCaptureTracker = nil
                nextState = engage(
                    .headingHold,
                    from: aircraftState,
                    selectedWaypointID: nextState.selectedWaypointID,
                    currentState: nextState
                )
                transitionReason = "fixed_wing_assist_intercept_target_lost"
                yawTargetRadians = nextState.targetHeadingRadians ?? aircraftState.orientation.z
                applyGeometryDiagnostics(nil, to: &nextState)
                break
            }

            guard let geometryAssessment = evaluateInterceptGeometry(
                aircraftState: aircraftState,
                wing: wing,
                interceptTarget: interceptTarget
            ) else {
                applyGeometryDiagnostics(nil, to: &nextState)
                break
            }
            applyGeometryDiagnostics(geometryAssessment, to: &nextState)

            let capturePoint = captureTarget ?? interceptTarget
            let currentHeading = aircraftState.orientation.z
            let currentAirspeed = max(aircraftState.forwardAirspeed, wing.minSustainableSpeedMps)
            let captureRadius = max(
                wing.waypointAcceptanceRadiusMeters,
                wing.minimumTurnRadius(airspeed: currentAirspeed) * 0.35
            )
            let captureAssessment = assessTerminalCapture(
                waypointID: nextState.selectedWaypointID,
                targetPosition: capturePoint,
                currentPosition: planarPosition,
                currentHeading: currentHeading,
                captureRadius: captureRadius,
                wing: wing
            )

            nextState.distanceToActiveWaypointMeters = captureAssessment.distanceToWaypoint

            if let completedReason = captureAssessment.completedReason {
                terminalCaptureTracker = nil
                nextState = engage(
                    .headingHold,
                    from: aircraftState,
                    selectedWaypointID: nextState.selectedWaypointID,
                    currentState: nextState
                )
                nextState.interceptCompleted = true
                nextState.captureCompletedReason = completedReason
                nextState.interceptState = .terminalCapture
                nextState.activeGuidanceMode = "terminalCapture"
                nextState.activeGuidanceTargetType = "terminalCapture"
                nextState.distanceToActiveWaypointMeters = captureAssessment.distanceToWaypoint
                transitionReason = "fixed_wing_assist_terminal_capture_\(completedReason)"

                emitInterceptDebugIfNeeded(
                    context: interceptDebugContext,
                    currentWorldPosition: aircraftState.position,
                    targetWorldPosition: SIMD3<Float>(
                        capturePoint.x,
                        nextState.targetAltitudeMeters ?? aircraftState.position.y,
                        capturePoint.y
                    ),
                    currentHeading: currentHeading,
                    geometry: geometryAssessment,
                    guidanceMode: "terminalCapture",
                    distanceToWaypoint: captureAssessment.distanceToWaypoint,
                    captureRadius: captureAssessment.captureRadius,
                    interceptCompletedReason: completedReason,
                    stateTransitionReason: transitionReason,
                    force: true
                )
            } else {
                let guidanceMode = resolvedGuidanceMode(from: interceptDebugContext.guidanceTargetType)
                nextState.interceptCompleted = false
                nextState.interceptState = guidanceMode.interceptState
                nextState.activeGuidanceMode = guidanceMode.rawValue
                nextState.activeGuidanceTargetType = guidanceMode.rawValue
                nextState.targetHeadingRadians = geometryAssessment.limitedHeading
                nextState.headingErrorDegrees = geometryAssessment.turnCommand.radiansToDegrees
                nextState.commandedBankDegrees = geometryAssessment.commandedBankDegrees
                nextState.filteredBankCommandDegrees = geometryAssessment.commandedBankDegrees
                nextState.commandedTurnDirection = geometryAssessment.commandedTurnDirection

                yawTargetRadians = geometryAssessment.limitedHeading
                rollTargetDegrees = geometryAssessment.commandedBankDegrees

                let altitudeTargets = altitudeTargetsForHold(
                    aircraftState: aircraftState,
                    targetAltitude: nextState.targetAltitudeMeters ?? aircraftState.position.y,
                    currentControls: currentControls,
                    cruiseThrottle: cruiseThrottle,
                    minThrottle: minThrottle,
                    maxThrottle: maxThrottle
                )
                pitchTargetDegrees = altitudeTargets.pitchDegrees
                throttleTarget = altitudeTargets.throttle

                emitInterceptDebugIfNeeded(
                    context: interceptDebugContext,
                    currentWorldPosition: aircraftState.position,
                    targetWorldPosition: SIMD3<Float>(
                        interceptTarget.x,
                        nextState.targetAltitudeMeters ?? aircraftState.position.y,
                        interceptTarget.y
                    ),
                    currentHeading: currentHeading,
                    geometry: geometryAssessment,
                    guidanceMode: guidanceMode.rawValue,
                    distanceToWaypoint: captureAssessment.distanceToWaypoint,
                    captureRadius: captureAssessment.captureRadius,
                    interceptCompletedReason: captureAssessment.interceptCompletedReason,
                    stateTransitionReason: transitionReason
                )
            }
        }

        nextState.stateTransitionReason = transitionReason ?? nextState.stateTransitionReason
        nextState.usingObsoleteFixedWingMode = false

        return FixedWingAssistOutput(
            state: nextState,
            rollDegrees: rollTargetDegrees,
            pitchDegrees: pitchTargetDegrees,
            yawDegrees: yawTargetRadians.radiansToDegrees,
            throttle: throttleTarget.clamped(to: 0.0...1.0),
            transitionReason: transitionReason
        )
    }

    func evaluateInterceptGeometry(
        aircraftState: DroneState,
        wing: FixedWingParameters,
        interceptTarget: SIMD2<Float>?
    ) -> FixedWingAssistGeometryAssessment? {
        guard let interceptTarget else {
            return nil
        }

        let planarPosition = SIMD2<Float>(aircraftState.position.x, aircraftState.position.z)
        let currentHeading = aircraftState.orientation.z
        let targetBearing = bearingToTarget(
            from: planarPosition,
            to: interceptTarget,
            fallback: currentHeading
        )
        let headingError = shortestAngleRadians(targetBearing - currentHeading)
        let distanceToWaypoint = simd_distance(planarPosition, interceptTarget)
        let currentAirspeed = max(aircraftState.forwardAirspeed, wing.minSustainableSpeedMps)
        let normalBankLimitDegrees = min(Float(wing.maxBankAngleDeg) * 0.76, Tuning.maxAssistBankDeg)
        let normalTurnRadius = effectiveTurnRadius(
            airspeed: currentAirspeed,
            bankLimitDegrees: normalBankLimitDegrees,
            wing: wing
        )
        let forwardUnit = SIMD2<Float>(sin(currentHeading), -cos(currentHeading))
        let deltaToTarget = interceptTarget - planarPosition
        let availableTurnInDistance = max(0.0, simd_dot(deltaToTarget, forwardUnit))
        let headingErrorDegrees = abs(headingError.radiansToDegrees)
        let feasibilityState = assessFeasibilityState(
            headingErrorDegrees: headingErrorDegrees,
            distanceToWaypoint: distanceToWaypoint,
            availableTurnInDistance: availableTurnInDistance,
            estimatedTurnRadius: normalTurnRadius
        )

        let headingLeadLimitDegrees: Float
        let bankLimitDegrees: Float
        switch feasibilityState {
        case .feasible:
            headingLeadLimitDegrees = Tuning.interceptLeadLimitDeg
            bankLimitDegrees = normalBankLimitDegrees
        case .tightTurn:
            headingLeadLimitDegrees = Tuning.tightTurnLeadLimitDeg
            bankLimitDegrees = normalBankLimitDegrees
        case .poorGeometry:
            headingLeadLimitDegrees = Tuning.poorGeometryLeadLimitDeg
            bankLimitDegrees = normalBankLimitDegrees
        }

        let turnCommand = headingError.clamped(
            to: -headingLeadLimitDegrees.degreesToRadians...headingLeadLimitDegrees.degreesToRadians
        )
        let commandedBankDegrees = bankCommandDegrees(
            forHeadingError: turnCommand,
            maxBankDegrees: max(6.0, bankLimitDegrees)
        )

        return FixedWingAssistGeometryAssessment(
            feasibilityState: feasibilityState,
            distanceToWaypoint: distanceToWaypoint,
            headingErrorRadians: headingError,
            availableTurnInDistance: availableTurnInDistance,
            estimatedTurnRadius: effectiveTurnRadius(
                airspeed: currentAirspeed,
                bankLimitDegrees: max(6.0, bankLimitDegrees),
                wing: wing
            ),
            targetBearing: targetBearing,
            limitedHeading: limitedInterceptHeading(
                currentHeading: currentHeading,
                targetBearing: targetBearing,
                leadLimitDegrees: headingLeadLimitDegrees
            ),
            turnCommand: turnCommand,
            commandedBankDegrees: commandedBankDegrees,
            commandedTurnDirection: turnDirection(forBankDegrees: commandedBankDegrees)
        )
    }

    private func resolvedGuidanceMode(from rawValue: String) -> FixedWingGuidanceMode {
        FixedWingGuidanceMode(rawValue: rawValue) ?? .singlePointIntercept
    }

    private func limitedInterceptHeading(
        currentHeading: Float,
        targetBearing: Float,
        leadLimitDegrees: Float = Tuning.interceptLeadLimitDeg
    ) -> Float {
        let headingError = shortestAngleRadians(targetBearing - currentHeading)
        let limitedError = headingError.clamped(
            to: -leadLimitDegrees.degreesToRadians...leadLimitDegrees.degreesToRadians
        )
        return wrap(currentHeading + limitedError)
    }

    private func headingRollTarget(
        currentHeading: Float,
        targetHeading: Float,
        maxBankDegrees: Float
    ) -> Float {
        let headingError = shortestAngleRadians(targetHeading - currentHeading)
        return bankCommandDegrees(forHeadingError: headingError, maxBankDegrees: maxBankDegrees)
    }

    private func assessFeasibilityState(
        headingErrorDegrees: Float,
        distanceToWaypoint: Float,
        availableTurnInDistance: Float,
        estimatedTurnRadius: Float
    ) -> FixedWingAssistInterceptFeasibilityState {
        if headingErrorDegrees >= 120.0 ||
            (headingErrorDegrees >= 100.0 && availableTurnInDistance < estimatedTurnRadius * 0.45) ||
            (headingErrorDegrees >= 90.0 && distanceToWaypoint < estimatedTurnRadius * 1.05) {
            return .poorGeometry
        }

        if headingErrorDegrees >= 60.0 ||
            (headingErrorDegrees >= 45.0 && availableTurnInDistance < estimatedTurnRadius) ||
            (headingErrorDegrees >= 70.0 && distanceToWaypoint < estimatedTurnRadius * 1.60) {
            return .tightTurn
        }

        return .feasible
    }

    private func bankCommandDegrees(
        forHeadingError headingError: Float,
        maxBankDegrees: Float
    ) -> Float {
        let targetRoll = headingError.radiansToDegrees * Tuning.headingBankGain
        return targetRoll.clamped(to: -maxBankDegrees...maxBankDegrees)
    }

    private func applyGeometryDiagnostics(
        _ assessment: FixedWingAssistGeometryAssessment?,
        to state: inout FixedWingAssistState
    ) {
        guard let assessment else {
            state.interceptFeasibilityState = nil
            state.headingErrorDegrees = nil
            state.rawHeadingErrorDegrees = nil
            state.estimatedTurnRadiusMeters = nil
            state.commandedBankDegrees = nil
            state.filteredBankCommandDegrees = nil
            state.commandedTurnDirection = .none
            state.usingObsoleteFixedWingMode = false
            return
        }

        state.interceptFeasibilityState = assessment.feasibilityState
        state.distanceToActiveWaypointMeters = assessment.distanceToWaypoint
        state.headingErrorDegrees = assessment.headingErrorRadians.radiansToDegrees
        state.rawHeadingErrorDegrees = assessment.headingErrorRadians.radiansToDegrees
        state.estimatedTurnRadiusMeters = assessment.estimatedTurnRadius
        state.commandedBankDegrees = assessment.commandedBankDegrees
        state.filteredBankCommandDegrees = assessment.commandedBankDegrees
        state.commandedTurnDirection = assessment.commandedTurnDirection
        state.usingObsoleteFixedWingMode = false
    }

    private func effectiveTurnRadius(
        airspeed: Float,
        bankLimitDegrees: Float,
        wing: FixedWingParameters
    ) -> Float {
        let referenceSpeed = max(airspeed, wing.minSafeAirspeed)
        let bankRadians = max(6.0, bankLimitDegrees).degreesToRadians
        let gravity: Float = 9.81
        let kinematicRadius = referenceSpeed * referenceSpeed / max(0.4, gravity * tan(bankRadians))
        return max(
            wing.waypointAcceptanceRadiusMeters * 1.1,
            kinematicRadius / max(0.65, wing.turnAuthority)
        )
    }

    private func turnDirection(forBankDegrees bankDegrees: Float) -> FixedWingAssistTurnDirection {
        if bankDegrees > 0.25 {
            return .right
        }
        if bankDegrees < -0.25 {
            return .left
        }
        return .none
    }

    private func bearingToTarget(
        from currentPosition: SIMD2<Float>,
        to targetPosition: SIMD2<Float>,
        fallback: Float
    ) -> Float {
        let delta = targetPosition - currentPosition
        guard simd_length_squared(delta) > 0.0001 else {
            return fallback
        }

        return wrap(atan2(-delta.x, -delta.y))
    }

    private func assessTerminalCapture(
        waypointID: UUID?,
        targetPosition: SIMD2<Float>,
        currentPosition: SIMD2<Float>,
        currentHeading: Float,
        captureRadius: Float,
        wing: FixedWingParameters
    ) -> TerminalCaptureAssessment {
        refreshTerminalCaptureTracker(
            waypointID: waypointID,
            targetPosition: targetPosition,
            currentPosition: currentPosition,
            currentHeading: currentHeading
        )

        guard var tracker = terminalCaptureTracker else {
            return TerminalCaptureAssessment(
                distanceToWaypoint: simd_distance(targetPosition, currentPosition),
                captureRadius: captureRadius,
                enteredCaptureRadius: false,
                crossedAcceptancePlane: false,
                interceptCompletedReason: "pending"
            )
        }

        let distanceToWaypoint = simd_distance(targetPosition, currentPosition)
        let planeDistance = simd_dot(targetPosition - currentPosition, tracker.approachDirection)
        let enteredCaptureRadius = tracker.enteredCaptureRadius || distanceToWaypoint <= captureRadius
        let crossedAcceptancePlane = tracker.crossedAcceptancePlane || (
            tracker.previousPlaneDistance > Tuning.acceptancePlaneHysteresisMeters &&
            planeDistance <= Tuning.acceptancePlaneHysteresisMeters
        )
        let nearPassRadius = max(
            captureRadius,
            wing.waypointAcceptanceRadiusMeters * Tuning.nearPassRadiusMultiplier
        )
        let openingDistance = distanceToWaypoint - tracker.previousDistanceToWaypoint
        let forwardProgress = simd_dot(currentPosition - tracker.captureOrigin, tracker.approachDirection)
        let passedCloseEnoughWithForwardProgress =
            tracker.closestDistanceToWaypoint <= nearPassRadius &&
            forwardProgress >= tracker.alongTrackToWaypointAtStart - nearPassRadius &&
            openingDistance >= max(Tuning.nearPassOpeningDistanceMeters, captureRadius * 0.02)

        let interceptCompletedReason: String
        if enteredCaptureRadius {
            interceptCompletedReason = "entered_capture_radius"
        } else if crossedAcceptancePlane {
            interceptCompletedReason = "crossed_acceptance_plane"
        } else if passedCloseEnoughWithForwardProgress {
            interceptCompletedReason = "near_pass_forward_progress"
        } else {
            interceptCompletedReason = "pending"
        }

        tracker.targetPosition = targetPosition
        tracker.previousPlaneDistance = planeDistance
        tracker.previousDistanceToWaypoint = distanceToWaypoint
        tracker.closestDistanceToWaypoint = min(tracker.closestDistanceToWaypoint, distanceToWaypoint)
        tracker.enteredCaptureRadius = enteredCaptureRadius
        tracker.crossedAcceptancePlane = crossedAcceptancePlane
        terminalCaptureTracker = tracker

        return TerminalCaptureAssessment(
            distanceToWaypoint: distanceToWaypoint,
            captureRadius: captureRadius,
            enteredCaptureRadius: enteredCaptureRadius,
            crossedAcceptancePlane: crossedAcceptancePlane,
            interceptCompletedReason: interceptCompletedReason
        )
    }

    private func refreshTerminalCaptureTracker(
        waypointID: UUID?,
        targetPosition: SIMD2<Float>,
        currentPosition: SIMD2<Float>,
        currentHeading: Float
    ) {
        let toleranceSquared = Tuning.waypointRetargetToleranceMeters * Tuning.waypointRetargetToleranceMeters
        if let tracker = terminalCaptureTracker,
           tracker.waypointID == waypointID,
           simd_length_squared(tracker.targetPosition - targetPosition) <= toleranceSquared {
            return
        }

        let approachVector = targetPosition - currentPosition
        let approachDirection: SIMD2<Float>
        if simd_length_squared(approachVector) > 0.0001 {
            approachDirection = simd_normalize(approachVector)
        } else {
            approachDirection = SIMD2<Float>(sin(currentHeading), -cos(currentHeading))
        }

        let distanceToWaypoint = simd_length(approachVector)
        terminalCaptureTracker = TerminalCaptureTracker(
            waypointID: waypointID,
            targetPosition: targetPosition,
            captureOrigin: currentPosition,
            approachDirection: approachDirection,
            alongTrackToWaypointAtStart: max(0.0, simd_dot(targetPosition - currentPosition, approachDirection)),
            previousPlaneDistance: max(0.0, simd_dot(targetPosition - currentPosition, approachDirection)),
            previousDistanceToWaypoint: distanceToWaypoint,
            closestDistanceToWaypoint: distanceToWaypoint,
            enteredCaptureRadius: false,
            crossedAcceptancePlane: false
        )
    }

    private func emitInterceptDebugIfNeeded(
        context: FixedWingAssistInterceptDebugContext,
        currentWorldPosition: SIMD3<Float>,
        targetWorldPosition: SIMD3<Float>,
        currentHeading: Float,
        geometry: FixedWingAssistGeometryAssessment,
        guidanceMode: String,
        distanceToWaypoint: Float,
        captureRadius: Float,
        interceptCompletedReason: String,
        stateTransitionReason: String?,
        force: Bool = false
    ) {
        let now = Date()
        guard force || now.timeIntervalSince(lastInterceptDebugTimestamp) >= Tuning.interceptDebugInterval else {
            return
        }

        lastInterceptDebugTimestamp = now
        print(
            String(
                format: "[FixedWingAssist] selectedWaypointID=%@ guidanceMode=%@ guidanceTargetType=%@ guidanceTargetPoint=%@ currentLegStart=%@ currentLegEnd=%@ currentWorldPos=(%.2f, %.2f, %.2f) targetWorldPos=(%.2f, %.2f, %.2f) currentHeadingDeg=%.2f targetBearingDeg=%.2f headingErrorDeg=%.2f distanceToWaypoint=%.2f availableTurnInDistance=%.2f estimatedTurnRadius=%.2f feasibilityState=%@ captureRadius=%.2f interceptCompletedReason=%@ transitionReason=%@ activeTargetSource=%@ activeRouteIncludesHome=%@ segmentCountAfterValidation=%d usingObsoleteFixedWingMode=false",
                formatWaypointIdentifier(context.selectedWaypointID),
                guidanceMode,
                context.guidanceTargetType,
                formatPlanarPoint(context.guidanceTargetPoint),
                formatPlanarPoint(context.currentLegStart),
                formatPlanarPoint(context.currentLegEnd),
                currentWorldPosition.x,
                currentWorldPosition.y,
                currentWorldPosition.z,
                targetWorldPosition.x,
                targetWorldPosition.y,
                targetWorldPosition.z,
                bodyHeadingDegrees(fromYawRadians: currentHeading),
                bodyHeadingDegrees(fromYawRadians: geometry.targetBearing),
                geometry.headingErrorRadians.radiansToDegrees,
                distanceToWaypoint,
                geometry.availableTurnInDistance,
                geometry.estimatedTurnRadius,
                geometry.feasibilityState.rawValue,
                captureRadius,
                interceptCompletedReason,
                stateTransitionReason ?? "nil",
                context.activeTargetSource,
                context.activeRouteIncludesHome ? "true" : "false",
                context.segmentCountAfterValidation
            )
        )
    }

    private func formatWaypointIdentifier(_ waypointID: UUID?) -> String {
        waypointID?.uuidString ?? "nil"
    }

    private func formatPlanarPoint(_ point: SIMD2<Float>?) -> String {
        guard let point else {
            return "nil"
        }
        return String(format: "(%.2f, %.2f)", point.x, point.y)
    }

    private func altitudeTargetsForHold(
        aircraftState: DroneState,
        targetAltitude: Float,
        currentControls: DroneControlValues,
        cruiseThrottle: Float,
        minThrottle: Float,
        maxThrottle: Float
    ) -> (pitchDegrees: Float, throttle: Float) {
        let altitudeError = targetAltitude - aircraftState.position.y
        let verticalSpeed = aircraftState.velocity.y
        let rawPitch = (
            altitudeError * Tuning.altitudePitchGain -
            verticalSpeed * Tuning.altitudePitchDamping
        ).clamped(to: Tuning.minAltitudePitchDeg...Tuning.maxAltitudePitchDeg)
        let rawThrottle = (
            cruiseThrottle +
            altitudeError * Tuning.altitudeThrottleGain -
            verticalSpeed * Tuning.altitudeThrottleDamping
        ).clamped(to: minThrottle...maxThrottle)

        return (
            pitchDegrees: smoothed(
                current: Float(currentControls.pitch),
                target: rawPitch,
                blend: Tuning.pitchBlend
            ),
            throttle: smoothed(
                current: Float(currentControls.throttle),
                target: rawThrottle,
                blend: Tuning.throttleBlend
            )
        )
    }

    private func smoothed(
        current: Float,
        target: Float,
        blend: Float
    ) -> Float {
        current + (target - current) * blend.clamped(to: 0.0...1.0)
    }

    private func wrap(_ value: Float) -> Float {
        var angle = value
        let tau = Float.pi * 2.0
        while angle > Float.pi {
            angle -= tau
        }
        while angle < -Float.pi {
            angle += tau
        }
        return angle
    }

    private func shortestAngleRadians(_ value: Float) -> Float {
        wrap(value)
    }
}

private enum FixedWingGuidanceMode: String {
    case singlePointIntercept
    case inboundLegTrack
    case flyByTurnTransition
    case outboundLegTrack
    case terminalCapture
    case routeComplete

    var interceptState: FixedWingAssistInterceptState {
        switch self {
        case .singlePointIntercept:
            return .singlePointIntercept
        case .inboundLegTrack:
            return .inboundLegTrack
        case .flyByTurnTransition:
            return .flyByTurnTransition
        case .outboundLegTrack:
            return .outboundLegTrack
        case .terminalCapture:
            return .terminalCapture
        case .routeComplete:
            return .routeComplete
        }
    }
}

private extension Float {
    var radiansToDegrees: Float {
        self * 180.0 / .pi
    }

    var degreesToRadians: Float {
        self * .pi / 180.0
    }

    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
