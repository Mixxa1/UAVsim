import Foundation
import simd

/// Output of the assist controller. Roll/pitch/yaw are degrees, throttle is
/// 0–1. They are merged into the live control values by the ViewModel.
struct FixedWingAssistOutput {
    let state: FixedWingAssistState
    let rollDegrees: Float
    let pitchDegrees: Float
    let yawDegrees: Float
    let throttle: Float
    let transitionReason: String?
}

/// Diagnostic context passed in by the ViewModel. Kept for ABI compatibility
/// with the previous controller — most fields are now informational only.
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

/// Geometry assessment used by the UI for the "intercept feasibility" badge.
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

/// Drastically simplified assist controller.
///
/// The new design has three concrete behaviours, all built on the same
/// proportional+limit feedback shape:
/// - **headingHold** — keep `targetHeadingRadians` (set at engage time, or to
///   the current heading after a manual override decays).
/// - **altitudeHold** — keep `targetAltitudeMeters` via pitch + small
///   throttle assist.
/// - **waypointIntercept** — fly toward the active waypoint planar position
///   and capture it when within the acceptance radius.
///
/// All commands pass through a final clamp so we can never command an
/// unflyable bank or pitch.
final class FixedWingAssistController {
    private enum Tuning {
        static let headingBankGain: Float = 0.95
        static let maxBankDeg: Float = 28.0
        static let altitudePitchGain: Float = 0.85
        static let altitudeDampingGain: Float = 1.6
        static let altitudeThrottleAssist: Float = 0.014
        static let pitchUpClampDeg: Float = 9.0
        static let pitchDownClampDeg: Float = 7.0
        static let interceptCaptureMultiplier: Float = 1.1
        static let interceptOpeningMultiplier: Float = 1.6
        static let courseFilterTau: Float = 0.22
        static let bankFilterTau: Float = 0.30
        static let pitchFilterTau: Float = 0.45
        static let throttleFilterTau: Float = 0.60
    }

    private struct InterceptTracker {
        var waypointID: UUID
        var targetPosition: SIMD2<Float>
        var closestDistance: Float
        var lastDistance: Float
        var openingCounter: Int
    }

    private var filteredBankDeg: Float = 0.0
    private var filteredPitchDeg: Float = 0.0
    private var filteredThrottle: Float = 0.55
    private var filteredCourseRad: Float = 0.0
    private var hasCourseSeed = false
    private var tracker: InterceptTracker?

    func reset() {
        filteredBankDeg = 0.0
        filteredPitchDeg = 0.0
        filteredThrottle = 0.55
        filteredCourseRad = 0.0
        hasCourseSeed = false
        tracker = nil
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
        nextState.activeGuidanceMode = mode.rawValue
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
        nextState.activeGuidanceTargetType = assistState.mode.rawValue
        nextState.activeGuidanceMode = assistState.mode.rawValue
        nextState.usingObsoleteFixedWingMode = false
        // These transient diagnostic signals from the legacy fly-by stack are
        // no longer produced; clear them so the UI does not display stale data.
        nextState.flyByTransitionActive = false
        nextState.flyByTransitionFeasible = false
        nextState.lateralGuidanceSuppressedForPoorGeometry = false

        let aircraftPlanar = SIMD2<Float>(aircraftState.position.x, aircraftState.position.z)
        let dt: Float = 1.0 / 60.0  // assist runs in lockstep with the simulation tick

        // Resolve targets for this tick.
        let targetHeadingRad: Float = {
            switch assistState.mode {
            case .waypointIntercept:
                if let interceptTarget {
                    let direction = interceptTarget - aircraftPlanar
                    if simd_length(direction) > 0.5 {
                        return courseRadians(direction: direction)
                    }
                }
                return assistState.targetHeadingRadians ?? aircraftState.orientation.z
            case .headingHold, .altitudeHold:
                if turnOverrideActive {
                    // While the pilot is turning, follow them; resync after.
                    return aircraftState.orientation.z
                }
                return assistState.targetHeadingRadians ?? aircraftState.orientation.z
            case .manual:
                return aircraftState.orientation.z
            }
        }()

        let targetAltitudeMeters: Float = {
            if assistState.mode == .waypointIntercept,
               let interceptTarget,
               !interceptTarget.x.isNaN {
                _ = interceptTarget // altitude not associated with a single point — fall through
            }
            if altitudeOverrideActive {
                return max(0.0, aircraftState.position.y)
            }
            return assistState.targetAltitudeMeters ?? max(0.0, aircraftState.position.y)
        }()
        nextState.targetHeadingRadians = targetHeadingRad
        nextState.targetAltitudeMeters = targetAltitudeMeters

        // Smooth the desired course to suppress single-tick noise.
        if !hasCourseSeed {
            filteredCourseRad = targetHeadingRad
            hasCourseSeed = true
        } else {
            let alpha = filterAlpha(tau: Tuning.courseFilterTau, dt: dt)
            let delta = shortestAngle(targetHeadingRad - filteredCourseRad)
            filteredCourseRad = wrapAngle(filteredCourseRad + delta * alpha)
        }
        let courseError = shortestAngle(filteredCourseRad - aircraftState.orientation.z)
        let maxBankRad = min(Tuning.maxBankDeg, wing.maxBankAngleDeg).degreesToRadians
        var rawBankRad = (courseError * Tuning.headingBankGain).clamped(to: -maxBankRad...maxBankRad)
        if abs(courseError) < 0.04 {
            rawBankRad *= 0.4
        }
        let bankAlpha = filterAlpha(tau: Tuning.bankFilterTau, dt: dt)
        filteredBankDeg = filteredBankDeg + (rawBankRad.radiansToDegrees - filteredBankDeg) * bankAlpha

        // Altitude / pitch handling. Heading-hold also keeps altitude lightly.
        let altitudeError = targetAltitudeMeters - aircraftState.position.y
        let verticalVelocity = aircraftState.velocity.y.isFinite ? aircraftState.velocity.y : 0.0
        var rawPitchDeg = (altitudeError * Tuning.altitudePitchGain
            - verticalVelocity * Tuning.altitudeDampingGain)
            .clamped(to: -Tuning.pitchDownClampDeg...Tuning.pitchUpClampDeg)
        if altitudeOverrideActive {
            rawPitchDeg *= 0.2
        }
        let pitchAlpha = filterAlpha(tau: Tuning.pitchFilterTau, dt: dt)
        filteredPitchDeg = filteredPitchDeg + (rawPitchDeg - filteredPitchDeg) * pitchAlpha

        let baselineThrottle = max(0.32, baseline.cruiseReferenceThrottle)
        let throttleAssist = altitudeError * Tuning.altitudeThrottleAssist
        let rawThrottle = (baselineThrottle + throttleAssist).clamped(to: 0.32...0.95)
        let throttleAlpha = filterAlpha(tau: Tuning.throttleFilterTau, dt: dt)
        filteredThrottle = filteredThrottle + (rawThrottle - filteredThrottle) * throttleAlpha

        // Waypoint intercept — track capture progress for auto-advance.
        nextState.distanceToActiveWaypointMeters = nil
        nextState.headingErrorDegrees = courseError.radiansToDegrees
        nextState.rawHeadingErrorDegrees = courseError.radiansToDegrees
        nextState.commandedBankDegrees = filteredBankDeg
        nextState.filteredBankCommandDegrees = filteredBankDeg
        nextState.commandedTurnDirection = filteredBankDeg > 0.5 ? .right : (filteredBankDeg < -0.5 ? .left : .none)
        nextState.estimatedTurnRadiusMeters = max(
            wing.waypointAcceptanceRadiusMeters,
            wing.cruiseAirspeed / max(0.1, wing.nominalTurnRateRadPerSec)
        )

        if assistState.mode == .waypointIntercept,
           let target = captureTarget ?? interceptTarget,
           let waypointID = assistState.selectedWaypointID {
            let distance = simd_length(target - aircraftPlanar)
            let captureRadius = max(wing.waypointAcceptanceRadiusMeters, 5.0) * Tuning.interceptCaptureMultiplier
            let openingRadius = captureRadius * Tuning.interceptOpeningMultiplier

            nextState.distanceToActiveWaypointMeters = distance
            nextState.interceptFeasibilityState = .feasible

            if tracker?.waypointID != waypointID {
                tracker = InterceptTracker(
                    waypointID: waypointID,
                    targetPosition: target,
                    closestDistance: distance,
                    lastDistance: distance,
                    openingCounter: 0
                )
            }
            if var t = tracker {
                t.closestDistance = min(t.closestDistance, distance)
                if distance > t.lastDistance + 0.05 {
                    t.openingCounter += 1
                } else {
                    t.openingCounter = max(0, t.openingCounter - 1)
                }
                t.lastDistance = distance
                tracker = t
            }

            let entered = distance <= captureRadius
            let opening = (tracker?.openingCounter ?? 0) >= 4 && distance > openingRadius
            if entered || opening {
                nextState.interceptCompleted = true
                nextState.interceptState = .terminalCapture
                nextState.captureCompletedReason = entered ? "entered_capture_radius" : "opening_geometry"
                nextState.activeGuidanceTargetType = "terminalCapture"
                nextState.activeGuidanceMode = "terminalCapture"
                tracker = nil
            }
        }

        let transitionReason: String? = {
            if nextState.interceptCompleted {
                return nextState.captureCompletedReason
            }
            return nil
        }()

        return FixedWingAssistOutput(
            state: nextState,
            rollDegrees: filteredBankDeg.clamped(to: -Tuning.maxBankDeg...Tuning.maxBankDeg),
            pitchDegrees: filteredPitchDeg.clamped(to: -Tuning.pitchDownClampDeg...Tuning.pitchUpClampDeg),
            yawDegrees: wrapAngle(filteredCourseRad).radiansToDegrees,
            throttle: filteredThrottle,
            transitionReason: transitionReason
        )
    }

    func evaluateInterceptGeometry(
        aircraftState: DroneState,
        wing: FixedWingParameters,
        target: SIMD2<Float>
    ) -> FixedWingAssistGeometryAssessment? {
        let aircraftPlanar = SIMD2<Float>(aircraftState.position.x, aircraftState.position.z)
        let direction = target - aircraftPlanar
        let distance = simd_length(direction)
        guard distance > 0.05, distance.isFinite else {
            return nil
        }
        let bearing = courseRadians(direction: direction / distance)
        let headingError = shortestAngle(bearing - aircraftState.orientation.z)
        let estimatedRadius = max(
            wing.waypointAcceptanceRadiusMeters,
            wing.cruiseAirspeed / max(0.1, wing.nominalTurnRateRadPerSec)
        )
        let availableTurnIn = max(0.0, distance - estimatedRadius)
        let feasibility: FixedWingAssistInterceptFeasibilityState = {
            let absErr = abs(headingError)
            if absErr < 0.6 { return .feasible }
            if absErr < 1.0 { return .tightTurn }
            return .poorGeometry
        }()
        let bankCommandRad = headingError.clamped(
            to: -wing.maxBankAngleDeg.degreesToRadians...wing.maxBankAngleDeg.degreesToRadians
        )
        return FixedWingAssistGeometryAssessment(
            feasibilityState: feasibility,
            distanceToWaypoint: distance,
            headingErrorRadians: headingError,
            availableTurnInDistance: availableTurnIn,
            estimatedTurnRadius: estimatedRadius,
            targetBearing: bearing,
            limitedHeading: bearing,
            turnCommand: bankCommandRad,
            commandedBankDegrees: bankCommandRad.radiansToDegrees,
            commandedTurnDirection: bankCommandRad > 0.05
                ? .right
                : (bankCommandRad < -0.05 ? .left : .none)
        )
    }

    // MARK: - Helpers

    private func filterAlpha(tau: Float, dt: Float) -> Float {
        guard tau > 0.0001 else { return 1.0 }
        return (1.0 - expf(-max(0.0, dt) / tau)).clamped(to: 0.02...1.0)
    }

    private func courseRadians(direction: SIMD2<Float>) -> Float {
        let yaw = atan2f(-direction.x, -direction.y)
        return yaw.isFinite ? yaw : 0.0
    }

    private func shortestAngle(_ angle: Float) -> Float {
        var a = angle
        while a > .pi { a -= 2.0 * .pi }
        while a < -.pi { a += 2.0 * .pi }
        return a
    }

    private func wrapAngle(_ angle: Float) -> Float {
        var a = angle.truncatingRemainder(dividingBy: 2.0 * .pi)
        if a > .pi { a -= 2.0 * .pi }
        if a < -.pi { a += 2.0 * .pi }
        return a
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
    var degreesToRadians: Float { self * .pi / 180.0 }
    var radiansToDegrees: Float { self * 180.0 / .pi }
}
