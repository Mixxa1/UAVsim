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
        static let interceptLeadLimitDeg: Float = 42.0
        static let headingBankFraction: Float = 0.72
        static let maxAssistBankDeg: Float = 30.0
        static let maxAltitudePitchDeg: Float = 10.0
        static let minAltitudePitchDeg: Float = -9.0
        static let interceptDebugInterval: TimeInterval = 0.25
        static let waypointRetargetToleranceMeters: Float = 0.05
        static let acceptancePlaneHysteresisMeters: Float = 0.10
        static let nearPassRadiusMultiplier: Float = 1.35
        static let nearPassOpeningDistanceMeters: Float = 0.15
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

        switch mode {
        case .manual:
            return FixedWingAssistState(
                mode: .manual,
                selectedWaypointID: selectedWaypointID ?? currentState.selectedWaypointID,
                targetHeadingRadians: nil,
                targetAltitudeMeters: nil,
                interceptCompleted: false
            )
        case .headingHold:
            return FixedWingAssistState(
                mode: .headingHold,
                selectedWaypointID: selectedWaypointID ?? currentState.selectedWaypointID,
                targetHeadingRadians: aircraftState.orientation.z,
                targetAltitudeMeters: max(0.0, aircraftState.position.y),
                interceptCompleted: false
            )
        case .altitudeHold:
            return FixedWingAssistState(
                mode: .altitudeHold,
                selectedWaypointID: selectedWaypointID ?? currentState.selectedWaypointID,
                targetHeadingRadians: aircraftState.orientation.z,
                targetAltitudeMeters: max(0.0, aircraftState.position.y),
                interceptCompleted: false
            )
        case .waypointIntercept:
            return FixedWingAssistState(
                mode: .waypointIntercept,
                selectedWaypointID: selectedWaypointID ?? currentState.selectedWaypointID,
                targetHeadingRadians: aircraftState.orientation.z,
                targetAltitudeMeters: max(0.0, aircraftState.position.y),
                interceptCompleted: false
            )
        }
    }

    func update(
        assistState: FixedWingAssistState,
        aircraftState: DroneState,
        wing: FixedWingParameters,
        baseline: ResolvedFlightBaseline,
        currentControls: DroneControlValues,
        interceptTarget: SIMD2<Float>?,
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
            yawTargetRadians = nextState.targetHeadingRadians ?? aircraftState.orientation.z
            rollTargetDegrees = headingRollTarget(
                currentHeading: aircraftState.orientation.z,
                targetHeading: yawTargetRadians,
                maxBankDegrees: min(Float(wing.maxBankAngleDeg) * Tuning.headingBankFraction, Tuning.maxAssistBankDeg)
            )
        case .altitudeHold:
            terminalCaptureTracker = nil
            nextState.targetHeadingRadians = aircraftState.orientation.z
            yawTargetRadians = aircraftState.orientation.z
            rollTargetDegrees = smoothed(
                current: Float(currentControls.roll),
                target: 0.0,
                blend: Tuning.neutralBlend
            )
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
                rollTargetDegrees = 0.0
                break
            }

            let currentHeading = aircraftState.orientation.z
            let targetBearing = bearingToTarget(
                from: planarPosition,
                to: interceptTarget,
                fallback: currentHeading
            )
            let headingError = shortestAngleRadians(targetBearing - currentHeading)
            let turnCommand = limitedTurnCommand(for: headingError)
            let limitedHeading = limitedInterceptHeading(
                currentHeading: currentHeading,
                targetBearing: targetBearing
            )
            let currentAirspeed = max(aircraftState.forwardAirspeed, wing.minSustainableSpeedMps)
            let captureRadius = max(
                wing.waypointAcceptanceRadiusMeters,
                wing.minimumTurnRadius(airspeed: currentAirspeed) * 0.35
            )
            let maxBankDegrees = min(Float(wing.maxBankAngleDeg) * 0.76, Tuning.maxAssistBankDeg)
            let bankCommand = bankCommandDegrees(
                forHeadingError: turnCommand,
                maxBankDegrees: maxBankDegrees
            )
            let captureAssessment = assessTerminalCapture(
                waypointID: nextState.selectedWaypointID,
                targetPosition: interceptTarget,
                currentPosition: planarPosition,
                currentHeading: currentHeading,
                captureRadius: captureRadius,
                wing: wing
            )

            emitInterceptDebugIfNeeded(
                currentWorldPosition: aircraftState.position,
                targetWorldPosition: SIMD3<Float>(
                    interceptTarget.x,
                    nextState.targetAltitudeMeters ?? aircraftState.position.y,
                    interceptTarget.y
                ),
                selectedWaypointID: interceptDebugContext.selectedWaypointID,
                guidanceTargetType: interceptDebugContext.guidanceTargetType,
                guidanceTargetPoint: interceptDebugContext.guidanceTargetPoint ?? interceptTarget,
                currentLegStart: interceptDebugContext.currentLegStart,
                currentLegEnd: interceptDebugContext.currentLegEnd,
                currentHeading: currentHeading,
                targetBearing: targetBearing,
                headingError: headingError,
                distanceToSelectedWaypoint: captureAssessment.distanceToWaypoint,
                captureRadius: captureAssessment.captureRadius,
                enteredCaptureRadius: captureAssessment.enteredCaptureRadius,
                crossedAcceptancePlane: captureAssessment.crossedAcceptancePlane,
                bearingToSelectedWaypoint: targetBearing,
                bearingUsedByGuidance: targetBearing,
                turnCommand: turnCommand,
                bankCommand: bankCommand,
                interceptCompletedReason: captureAssessment.interceptCompletedReason,
                activeTargetSource: interceptDebugContext.activeTargetSource,
                activeRouteIncludesHome: interceptDebugContext.activeRouteIncludesHome,
                segmentCountAfterValidation: interceptDebugContext.segmentCountAfterValidation
            )

            if let completedReason = captureAssessment.completedReason {
                terminalCaptureTracker = nil
                nextState = engage(
                    .headingHold,
                    from: aircraftState,
                    selectedWaypointID: nextState.selectedWaypointID,
                    currentState: nextState
                )
                nextState.interceptCompleted = true
                transitionReason = "fixed_wing_assist_intercept_complete_\(completedReason)"
                yawTargetRadians = nextState.targetHeadingRadians ?? aircraftState.orientation.z
                rollTargetDegrees = 0.0
                emitInterceptDebugIfNeeded(
                    currentWorldPosition: aircraftState.position,
                    targetWorldPosition: SIMD3<Float>(
                        interceptTarget.x,
                        nextState.targetAltitudeMeters ?? aircraftState.position.y,
                        interceptTarget.y
                    ),
                    selectedWaypointID: interceptDebugContext.selectedWaypointID,
                    guidanceTargetType: interceptDebugContext.guidanceTargetType,
                    guidanceTargetPoint: interceptDebugContext.guidanceTargetPoint ?? interceptTarget,
                    currentLegStart: interceptDebugContext.currentLegStart,
                    currentLegEnd: interceptDebugContext.currentLegEnd,
                    currentHeading: currentHeading,
                    targetBearing: targetBearing,
                    headingError: headingError,
                    distanceToSelectedWaypoint: captureAssessment.distanceToWaypoint,
                    captureRadius: captureAssessment.captureRadius,
                    enteredCaptureRadius: captureAssessment.enteredCaptureRadius,
                    crossedAcceptancePlane: captureAssessment.crossedAcceptancePlane,
                    bearingToSelectedWaypoint: targetBearing,
                    bearingUsedByGuidance: targetBearing,
                    turnCommand: turnCommand,
                    bankCommand: bankCommand,
                    interceptCompletedReason: completedReason,
                    activeTargetSource: interceptDebugContext.activeTargetSource,
                    activeRouteIncludesHome: interceptDebugContext.activeRouteIncludesHome,
                    segmentCountAfterValidation: interceptDebugContext.segmentCountAfterValidation,
                    force: true
                )
            } else {
                nextState.targetHeadingRadians = limitedHeading
                yawTargetRadians = limitedHeading
                rollTargetDegrees = bankCommand

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
                nextState.interceptCompleted = false
            }
        }

        return FixedWingAssistOutput(
            state: nextState,
            rollDegrees: rollTargetDegrees,
            pitchDegrees: pitchTargetDegrees,
            yawDegrees: yawTargetRadians.radiansToDegrees,
            throttle: throttleTarget.clamped(to: 0.0...1.0),
            transitionReason: transitionReason
        )
    }

    private func limitedInterceptHeading(
        currentHeading: Float,
        targetBearing: Float
    ) -> Float {
        let headingError = shortestAngleRadians(targetBearing - currentHeading)
        let limitedError = limitedTurnCommand(for: headingError)
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

    private func limitedTurnCommand(for headingError: Float) -> Float {
        headingError.clamped(
            to: -Tuning.interceptLeadLimitDeg.degreesToRadians...Tuning.interceptLeadLimitDeg.degreesToRadians
        )
    }

    private func bankCommandDegrees(
        forHeadingError headingError: Float,
        maxBankDegrees: Float
    ) -> Float {
        let targetRoll = headingError.radiansToDegrees * Tuning.headingBankGain
        return targetRoll.clamped(to: -maxBankDegrees...maxBankDegrees)
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

        // Fixed-wing yaw 0 points along world -Z and positive yaw produces a
        // right turn. The X term must therefore be negated to keep
        // targetBearing - currentHeading aligned with the roll/turn convention.
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
        currentWorldPosition: SIMD3<Float>,
        targetWorldPosition: SIMD3<Float>,
        selectedWaypointID: UUID?,
        guidanceTargetType: String,
        guidanceTargetPoint: SIMD2<Float>,
        currentLegStart: SIMD2<Float>?,
        currentLegEnd: SIMD2<Float>?,
        currentHeading: Float,
        targetBearing: Float,
        headingError: Float,
        distanceToSelectedWaypoint: Float,
        captureRadius: Float,
        enteredCaptureRadius: Bool,
        crossedAcceptancePlane: Bool,
        bearingToSelectedWaypoint: Float,
        bearingUsedByGuidance: Float,
        turnCommand: Float,
        bankCommand: Float,
        interceptCompletedReason: String,
        activeTargetSource: String,
        activeRouteIncludesHome: Bool,
        segmentCountAfterValidation: Int,
        force: Bool = false
    ) {
        let now = Date()
        guard force || now.timeIntervalSince(lastInterceptDebugTimestamp) >= Tuning.interceptDebugInterval else {
            return
        }

        lastInterceptDebugTimestamp = now
        print(
            String(
                format: "[FixedWingIntercept] selectedWaypointID=%@ guidanceTargetType=%@ guidanceTargetPoint=%@ currentLegStart=%@ currentLegEnd=%@ currentWorldPos=(%.2f, %.2f, %.2f) targetWorldPos=(%.2f, %.2f, %.2f) currentHeadingDeg=%.2f targetBearingDeg=%.2f bearingToSelectedWaypoint=%.2f bearingUsedByGuidance=%.2f headingErrorDeg=%.2f distanceToWaypoint=%.2f captureRadius=%.2f enteredCaptureRadius=%@ crossedAcceptancePlane=%@ turnCommand=%.2f bankCommand=%.2f interceptCompletedReason=%@ activeTargetSource=%@ activeRouteIncludesHome=%@ segmentCountAfterValidation=%d",
                formatWaypointIdentifier(selectedWaypointID),
                guidanceTargetType,
                formatPlanarPoint(guidanceTargetPoint),
                formatPlanarPoint(currentLegStart),
                formatPlanarPoint(currentLegEnd),
                currentWorldPosition.x,
                currentWorldPosition.y,
                currentWorldPosition.z,
                targetWorldPosition.x,
                targetWorldPosition.y,
                targetWorldPosition.z,
                bodyHeadingDegrees(fromYawRadians: currentHeading),
                bodyHeadingDegrees(fromYawRadians: targetBearing),
                bodyHeadingDegrees(fromYawRadians: bearingToSelectedWaypoint),
                bodyHeadingDegrees(fromYawRadians: bearingUsedByGuidance),
                headingError.radiansToDegrees,
                distanceToSelectedWaypoint,
                captureRadius,
                enteredCaptureRadius ? "true" : "false",
                crossedAcceptancePlane ? "true" : "false",
                turnCommand.radiansToDegrees,
                bankCommand,
                interceptCompletedReason,
                activeTargetSource,
                activeRouteIncludesHome ? "true" : "false",
                segmentCountAfterValidation
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
