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
/// - **waypointIntercept** — fly along the active inbound route line through
///   the waypoint and capture it only when the flown segment intersects the
///   acceptance circle or the aircraft is already inside that circle.
///
/// All commands pass through a final clamp so we can never command an
/// unflyable bank or pitch.
final class FixedWingAssistController {
    private enum Tuning {
        static let headingBankGain: Float = 0.95
        /// Rate term on yaw. Without it the heading loop cannot settle — see the bank computation.
        static let headingRateDampingGain: Float = 0.45
        static let maxBankDeg: Float = 28.0
        static let altitudePitchGain: Float = 0.85
        static let altitudeDampingGain: Float = 1.6
        static let turnLiftCompensationGainDeg: Float = 30.0 // extra deg pitch per unit (1/cos(bank) - 1)
        static let turnThrottleCompensationGain: Float = 0.3 // throttle per unit (1/cos(bank) - 1)
        static let altitudeThrottleAssist: Float = 0.014
        static let throttleSpeedGain: Float = 0.055
        static let pitchUpClampDeg: Float = 9.0
        static let pitchDownClampDeg: Float = 7.0
        static let courseFilterTau: Float = 0.22
        static let bankFilterTau: Float = 0.30
        static let pitchFilterTau: Float = 0.45
        static let throttleFilterTau: Float = 0.60
    }

    private struct InterceptTracker {
        var waypointID: UUID
        var targetPosition: SIMD2<Float>
        var legStartPosition: SIMD2<Float>
        var previousAircraftPlanar: SIMD2<Float>
        var hasPreviousAircraftPlanar: Bool
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
        let routeCompleted = assistState.mode == .waypointIntercept &&
            assistState.interceptCompleted &&
            assistState.interceptState == .routeComplete
        if routeCompleted {
            nextState.activeGuidanceTargetType = "routeComplete"
            nextState.activeGuidanceMode = "routeComplete"
        } else {
            nextState.activeGuidanceTargetType = assistState.mode.rawValue
            nextState.activeGuidanceMode = assistState.mode.rawValue
        }
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
                if assistState.interceptCompleted,
                   assistState.interceptState == .routeComplete {
                    return assistState.targetHeadingRadians ?? aircraftState.orientation.z
                }
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
        // Low-altitude bank protection — see FixedWingAutopilot.swift. Measured
        // against this leg's own target altitude (already resolved above),
        // not a fixed absolute height, so a mission that deliberately
        // cruises low still gets full bank authority once it's actually at
        // its own intended altitude.
        let altitudeDeficit = max(0.0, targetAltitudeMeters - aircraftState.position.y)
        let altitudeMarginFactor = (1.0 - altitudeDeficit / max(wing.initialClimbTargetAltitude, 1.0))
            .clamped(to: 0.35...1.0)
        let maxBankRad = min(Tuning.maxBankDeg, wing.maxBankAngleDeg).degreesToRadians * altitudeMarginFactor
        // Proportional plus rate, for the same reason the avoidance loop needed it.
        //
        // `courseError * gain` alone is a heading loop with no damping, and the low-pass below
        // adds phase lag on top, which costs margin rather than buying stability. Measured in one
        // flight: while the aircraft was in take-off — where the assist does not write roll and a
        // rate-damped avoidance loop owns it alone — the bank command stayed inside **±8°**; the
        // moment this branch took the axis it ran to **±30°** with the same obstacles outside.
        // The difference between the two loops was the rate term, so this one gets it too.
        var rawBankRad = (
            courseError * Tuning.headingBankGain
                - aircraftState.bodyAngularVelocity.z * Tuning.headingRateDampingGain
        ).clamped(to: -maxBankRad...maxBankRad)
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
        // Coordinated-turn lift compensation, applied post-filter — see
        // FixedWingAutopilot.swift for the full rationale (bank's own filter
        // is faster than this pitch filter, so routing compensation through
        // the pitch filter too would make it systematically trail the lift
        // loss it's meant to cancel).
        let bankLiftLossDeg = (1.0 / max(cos(filteredBankDeg.degreesToRadians), 0.5) - 1.0)
            * Tuning.turnLiftCompensationGainDeg
        // The clamp has to make room for the compensation, not eat it.
        //
        // Adding the compensation and then clamping to the same ceiling meant the two competed for
        // one budget, and in a turn the altitude loop had already spent it: the flight log shows
        // `pitchCmd` pinned at exactly 9.0 — `pitchUpClampDeg` — while the bank sat on its 28°
        // limit, so all 4.0° that (1/cos 28° − 1) × 30 asks for were discarded at the very moment
        // they were needed, and the altitude wandered 92 → 47 → 63 m. The ceiling now rises by
        // exactly the compensation: 9° stays the altitude loop's budget and the cost of the turn
        // is paid on top. Exactly the compensation and no more — the clamp also bounds angle of
        // attack, and a nose held higher than the turn requires trades the altitude problem for a
        // speed one.
        let compensatedPitchCeiling = Tuning.pitchUpClampDeg + max(0.0, bankLiftLossDeg)
        let commandedPitchDeg = (filteredPitchDeg + bankLiftLossDeg)
            .clamped(to: -Tuning.pitchDownClampDeg...compensatedPitchCeiling)

        let baselineThrottle = max(0.32, baseline.cruiseReferenceThrottle)
        let throttleAssist = altitudeError * Tuning.altitudeThrottleAssist
        let airspeed = max(0.0, aircraftState.forwardAirspeed)
        let speedError = wing.cruiseAirspeed - airspeed
        let stallBoost: Float = airspeed < wing.minSafeAirspeed ? 0.16 : 0.0
        let rawThrottle = (
            baselineThrottle
                + throttleAssist
                + speedError * Tuning.throttleSpeedGain
                + stallBoost
        ).clamped(to: 0.25...0.95)
        let throttleAlpha = filterAlpha(tau: Tuning.throttleFilterTau, dt: dt)
        filteredThrottle = filteredThrottle + (rawThrottle - filteredThrottle) * throttleAlpha
        // Coordinated-turn drag compensation, applied post-filter — see FixedWingAutopilot.swift.
        let turnDragBoost = (1.0 / max(cos(filteredBankDeg.degreesToRadians), 0.5) - 1.0)
            * Tuning.turnThrottleCompensationGain
        // Same correction for power: the log had throttle sitting on 0.95 throughout the turn,
        // so the drag compensation was being clipped off exactly as the pitch was.
        let compensatedThrottleCeiling = min(1.0, 0.95 + max(0.0, turnDragBoost))
        let commandedThrottle = (filteredThrottle + turnDragBoost)
            .clamped(to: 0.25...compensatedThrottleCeiling)

        // Waypoint intercept — track capture progress for auto-advance.
        nextState.distanceToActiveWaypointMeters = nil
        nextState.headingErrorDegrees = courseError.radiansToDegrees
        nextState.rawHeadingErrorDegrees = courseError.radiansToDegrees
        nextState.commandedBankDegrees = filteredBankDeg
        nextState.filteredBankCommandDegrees = filteredBankDeg
        nextState.commandedTurnDirection = filteredBankDeg > 0.5 ? .right : (filteredBankDeg < -0.5 ? .left : .none)
        nextState.estimatedTurnRadiusMeters = max(
            wing.waypointAcceptanceRadiusMeters,
            wing.minimumTurnRadius(airspeed: wing.cruiseAirspeed)
        )

        if assistState.mode == .waypointIntercept,
           !assistState.interceptCompleted,
           let target = captureTarget ?? interceptTarget,
           let waypointID = assistState.selectedWaypointID {
            let distance = simd_length(target - aircraftPlanar)
            // Use the exact same radius as the tactical-map/3D sphere and the
            // main fixed-wing autopilot. Assist guidance must not silently
            // capture a larger invisible circle.
            let captureRadius = wing.waypointCaptureRadius(airspeed: wing.cruiseAirspeed)
            let legStart = interceptDebugContext.currentLegStart ?? tracker?.legStartPosition ?? aircraftPlanar

            nextState.distanceToActiveWaypointMeters = distance
            nextState.interceptFeasibilityState = .feasible

            if tracker?.waypointID != waypointID ||
                simd_distance(tracker?.targetPosition ?? target, target) > 0.05 {
                tracker = InterceptTracker(
                    waypointID: waypointID,
                    targetPosition: target,
                    legStartPosition: legStart,
                    previousAircraftPlanar: aircraftPlanar,
                    hasPreviousAircraftPlanar: false
                )
            }
            let previousAircraftPlanar = tracker?.previousAircraftPlanar ?? aircraftPlanar
            let hadPreviousAircraftPlanar = tracker?.hasPreviousAircraftPlanar ?? false
            let crossedCaptureCircle = hadPreviousAircraftPlanar && motionSegmentIntersectsCircle(
                from: previousAircraftPlanar,
                to: aircraftPlanar,
                center: target,
                radius: captureRadius
            )
            if var t = tracker {
                t.previousAircraftPlanar = aircraftPlanar
                t.hasPreviousAircraftPlanar = true
                tracker = t
            }

            let entered = distance <= captureRadius
            if entered || crossedCaptureCircle {
                nextState.interceptCompleted = true
                nextState.interceptState = .terminalCapture
                nextState.captureCompletedReason = entered ? "entered_capture_circle" : "crossed_capture_circle"
                nextState.activeGuidanceTargetType = "terminalCapture"
                nextState.activeGuidanceMode = "terminalCapture"
                nextState.targetHeadingRadians = aircraftState.orientation.z
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
            pitchDegrees: commandedPitchDeg.clamped(to: -wing.maxPitchDownDeg...wing.maxPitchUpDeg),
            yawDegrees: wrapAngle(filteredCourseRad).radiansToDegrees,
            throttle: commandedThrottle,
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
            wing.minimumTurnRadius(airspeed: wing.cruiseAirspeed)
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

    private func motionSegmentIntersectsCircle(
        from start: SIMD2<Float>,
        to end: SIMD2<Float>,
        center: SIMD2<Float>,
        radius: Float
    ) -> Bool {
        guard start.x.isFinite, start.y.isFinite,
              end.x.isFinite, end.y.isFinite,
              center.x.isFinite, center.y.isFinite,
              radius.isFinite, radius > 0.0 else {
            return false
        }

        let delta = end - start
        let lengthSquared = simd_length_squared(delta)
        guard lengthSquared > 0.000001 else {
            return simd_distance(end, center) <= radius
        }

        let t = (simd_dot(center - start, delta) / lengthSquared).clamped(to: 0.0...1.0)
        let closest = start + delta * t
        return simd_distance(closest, center) <= radius
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
    var degreesToRadians: Float { self * .pi / 180.0 }
    var radiansToDegrees: Float { self * 180.0 / .pi }
}
