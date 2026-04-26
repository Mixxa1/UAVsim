import Foundation
import simd

/// Stable, "behaves-like-a-real-airplane" waypoint follower.
///
/// Design rationale (replaces the previous multi-controller fly-by stack):
/// - **Carrot pursuit** for lateral guidance: pick a virtual aim point a fixed
///   look-ahead distance ahead of the aircraft along the planned path. The
///   bank command is a proportional response to the heading error toward that
///   aim point, low-pass filtered and bank-limited. The aim point glides over
///   waypoint corners, which produces smooth, continuous turns regardless of
///   waypoint geometry.
/// - **Decoupled energy management**: pitch tracks altitude error (with
///   vertical-velocity damping); throttle tracks speed error. Stall protection
///   pitches the nose down whenever airspeed drops below a safe floor.
/// - **Robust waypoint advance**: a waypoint is "passed" when the aircraft
///   crosses its perpendicular acceptance plane (projection along the inbound
///   leg has exceeded the waypoint), or when planar distance falls inside
///   acceptance radius. Both criteria are evaluated each tick - whichever
///   triggers first advances the index. This prevents the autopilot from
///   getting stuck circling a waypoint it already overshot.
/// - **NaN-safe** throughout: any non-finite input produces a hold command.
struct FixedWingAutopilotInput {
    var aircraftPosition: SIMD3<Float>      // world (x, y, z)
    var aircraftVelocity: SIMD3<Float>
    var aircraftYawRadians: Float           // codebase convention (atan2(-dx, -dz))
    var aircraftPitchRadians: Float         // body pitch (positive = nose up in physics frame)
    var aircraftRollRadians: Float
    var aircraftAirspeed: Float
    var deltaTime: Float
}

struct FixedWingAutopilotPlan {
    /// Stable identifier so the controller can reset internal state when the
    /// plan changes underneath it.
    var routeIdentifier: String
    /// Planar (x, z) waypoints with per-waypoint altitude and acceptance hint.
    var waypoints: [FixedWingAutopilotWaypoint]
    /// Smallest waypoint index the controller is allowed to consider "current".
    /// This guarantees forward progress even if the route is rebuilt mid-flight.
    var minimumWaypointIndex: Int
    /// When true, the autopilot loops back to the first waypoint after the
    /// last one is captured. When false, it loiters at the last waypoint.
    var loopAfterFinalWaypoint: Bool
}

struct FixedWingAutopilotWaypoint: Equatable {
    var position: SIMD2<Float>
    var altitude: Float
    var acceptanceRadius: Float
}

struct FixedWingAutopilotResult: Equatable {
    var rollDegrees: Float
    var pitchDegrees: Float
    var yawDegrees: Float
    var throttle: Float
    var positionTarget: SIMD3<Float>
    var activeWaypointIndex: Int
    var distanceToActiveWaypointMeters: Float
    var crossTrackErrorMeters: Float
    var courseErrorDegrees: Float
    var desiredCourseDegrees: Float
    var headingDegrees: Float
    var commandedBankDegrees: Float
    var commandedPitchDegrees: Float
    var commandedThrottle: Float
    var targetAltitudeMeters: Float
    var targetAirspeedMpsActive: Float
    var aimPointWorld: SIMD3<Float>
    var legStartWorld: SIMD3<Float>
    var legEndWorld: SIMD3<Float>
    var alongTrackProgress: Float
    var remainingPathLengthMeters: Float
    var stallProtectionActive: Bool
    var hasCompletedRoute: Bool
}

final class FixedWingAutopilot {
    private struct Tuning {
        // Carrot pursuit
        static let lookaheadAirspeedFactor: Float = 1.85   // L1 ≈ V * factor (seconds)
        static let lookaheadMinMeters: Float = 18.0
        static let lookaheadTurnRadiusFactor: Float = 1.35
        // Lateral
        static let bankProportionalGain: Float = 1.45      // rad bank per rad heading error
        static let bankFilterTau: Float = 0.32             // low-pass tau (seconds)
        static let courseFilterTau: Float = 0.18
        // Vertical (pitch from altitude)
        static let altitudePitchGain: Float = 0.075        // rad pitch per meter of altitude error
        static let verticalDampingGain: Float = 0.18       // rad pitch per (m/s) vertical velocity
        static let pitchFilterTau: Float = 0.45
        static let maxAltitudeBleedRateMps: Float = 4.5
        // Throttle (speed)
        static let throttleSpeedGain: Float = 0.085        // throttle per (m/s) speed error
        static let throttleAltitudeAssistGain: Float = 0.018
        static let throttleFilterTau: Float = 0.55
        static let throttleHoverSpan: ClosedRange<Float> = 0.32...0.95
        // Waypoint capture
        static let acceptancePlaneSlop: Float = 0.92       // require projection to pass 92% of segment
        static let crossTrackBleedFactor: Float = 0.8      // tighten radius if drone is far off track
        // Stall protection
        static let stallSpeedSafetyFactor: Float = 1.05
        static let stallPitchDownDeg: Float = 12.0
        // Speed scheduling
        static let approachSpeedScale: Float = 0.94        // gentle slow-down close to terminal point
    }

    private struct InternalState {
        var routeIdentifier: String?
        var activeWaypointIndex: Int = 0
        var filteredBankRad: Float = 0.0
        var filteredPitchRad: Float = 0.0
        var filteredThrottle: Float = 0.5
        var filteredCourseRad: Float = 0.0
        var hasCourseSeed: Bool = false
        var legAnchor: SIMD2<Float> = .zero
        var hasLegAnchor: Bool = false
        var hasCompletedRoute: Bool = false
    }

    private var state = InternalState()

    func reset() {
        state = InternalState()
    }

    /// Stops only the captured-state flag and waypoint pointer, but keeps the
    /// filtered command memory so a re-engage on the same route does not jolt
    /// the aircraft.
    func resetCaptureProgress() {
        state.activeWaypointIndex = 0
        state.hasCompletedRoute = false
        state.hasLegAnchor = false
    }

    func update(
        plan: FixedWingAutopilotPlan,
        wing: FixedWingParameters,
        cruiseAirspeedOverride: Float?,
        targetAltitudeOverride: Float?,
        input: FixedWingAutopilotInput
    ) -> FixedWingAutopilotResult? {
        guard !plan.waypoints.isEmpty else {
            return nil
        }
        guard isFiniteVector(input.aircraftPosition),
              isFiniteVector(input.aircraftVelocity),
              input.aircraftYawRadians.isFinite,
              input.deltaTime.isFinite, input.deltaTime > 0.0 else {
            return nil
        }

        // (Re)seed when the plan changes.
        if state.routeIdentifier != plan.routeIdentifier {
            state.routeIdentifier = plan.routeIdentifier
            state.activeWaypointIndex = max(0, plan.minimumWaypointIndex)
            state.hasCompletedRoute = false
            state.hasLegAnchor = false
            state.hasCourseSeed = false
        }

        // Honour minimum index from outside (forward-progress guarantee).
        if state.activeWaypointIndex < plan.minimumWaypointIndex {
            state.activeWaypointIndex = plan.minimumWaypointIndex
            state.hasLegAnchor = false
        }
        if state.activeWaypointIndex >= plan.waypoints.count {
            if plan.loopAfterFinalWaypoint {
                state.activeWaypointIndex = 0
                state.hasCompletedRoute = false
                state.hasLegAnchor = false
            } else {
                state.activeWaypointIndex = plan.waypoints.count - 1
                state.hasCompletedRoute = true
            }
        }

        let aircraftPlanar = SIMD2<Float>(input.aircraftPosition.x, input.aircraftPosition.z)
        let cruiseAirspeed = max(
            wing.minSafeAirspeed * 1.05,
            cruiseAirspeedOverride ?? wing.cruiseAirspeed
        )
        let stallSafeSpeed = wing.minSafeAirspeed * Tuning.stallSpeedSafetyFactor
        let currentSpeed = max(0.0, input.aircraftAirspeed.isFinite ? input.aircraftAirspeed : 0.0)

        // Advance through any waypoints we have already crossed.
        var advanceGuard = 0
        while advanceGuard < plan.waypoints.count {
            let active = plan.waypoints[state.activeWaypointIndex]
            let segmentStart = legStart(for: state.activeWaypointIndex, plan: plan, fallback: aircraftPlanar)
            let segment = active.position - segmentStart
            let segmentLength = simd_length(segment)
            let toAircraft = aircraftPlanar - segmentStart
            let projection: Float
            if segmentLength > 0.001 {
                projection = simd_dot(toAircraft, segment) / segmentLength
            } else {
                projection = 0.0
            }
            let acceptance = max(active.acceptanceRadius, wing.waypointAcceptanceRadiusMeters)
            let distanceToWaypoint = simd_length(aircraftPlanar - active.position)

            let crossedPlane = segmentLength > 0.5 && projection >= segmentLength * Tuning.acceptancePlaneSlop
            let insideAcceptance = distanceToWaypoint <= acceptance

            if crossedPlane || insideAcceptance {
                let isLast = state.activeWaypointIndex >= plan.waypoints.count - 1
                if isLast {
                    if plan.loopAfterFinalWaypoint {
                        state.activeWaypointIndex = 0
                        state.hasLegAnchor = false
                        state.hasCompletedRoute = false
                    } else {
                        state.hasCompletedRoute = true
                    }
                    break
                } else {
                    state.activeWaypointIndex += 1
                    state.hasLegAnchor = false
                }
                advanceGuard += 1
                continue
            }
            break
        }

        let activeIndex = min(state.activeWaypointIndex, plan.waypoints.count - 1)
        let activeWaypoint = plan.waypoints[activeIndex]

        // Anchor the inbound leg when we begin tracking it. This keeps the
        // segment-projection geometry stable even if the aircraft drifts off
        // the original line — it always treats "where we joined the leg" as
        // the start.
        if !state.hasLegAnchor {
            if activeIndex > 0 {
                state.legAnchor = plan.waypoints[activeIndex - 1].position
            } else {
                state.legAnchor = aircraftPlanar
            }
            state.hasLegAnchor = true
        }
        let legStartPlanar = state.legAnchor
        let legEndPlanar = activeWaypoint.position
        let legVector = legEndPlanar - legStartPlanar
        let legLength = simd_length(legVector)
        let legDirection: SIMD2<Float>
        if legLength > 0.001 {
            legDirection = legVector / legLength
        } else {
            legDirection = forwardDirection(yaw: input.aircraftYawRadians)
        }

        let toAircraft = aircraftPlanar - legStartPlanar
        let alongTrack = simd_dot(toAircraft, legDirection)
        let projectedOnLeg = legStartPlanar + legDirection * alongTrack
        let crossTrack = simd_dot(SIMD2<Float>(-legDirection.y, legDirection.x), toAircraft)
        let alongTrackProgress = legLength > 0.01 ? max(0.0, min(1.0, alongTrack / legLength)) : 0.0

        // Carrot lookahead distance: large enough to behave smoothly, small
        // enough to capture turns. Floors prevent runaway look-ahead at low
        // airspeed (e.g. take-off).
        let speedForLookahead = max(currentSpeed, cruiseAirspeed * 0.6)
        let minimumTurnRadius = max(
            wing.waypointAcceptanceRadiusMeters * 1.4,
            speedForLookahead / max(0.1, wing.nominalTurnRateRadPerSec)
        )
        let lookaheadDistance = max(
            Tuning.lookaheadMinMeters,
            speedForLookahead * Tuning.lookaheadAirspeedFactor,
            minimumTurnRadius * Tuning.lookaheadTurnRadiusFactor
        )

        let aimPointPlanar = computeAimPoint(
            plan: plan,
            startIndex: activeIndex,
            legStart: legStartPlanar,
            projectedOnLeg: projectedOnLeg,
            legDirection: legDirection,
            alongTrack: alongTrack,
            legLength: legLength,
            lookaheadDistance: lookaheadDistance
        )

        // Lateral guidance — bank from heading error to the carrot.
        let aimVector = aimPointPlanar - aircraftPlanar
        let aimDistance = simd_length(aimVector)
        let desiredCourseRaw: Float
        if aimDistance > 0.05 {
            desiredCourseRaw = courseRadians(direction: aimVector / aimDistance)
        } else {
            desiredCourseRaw = courseRadians(direction: legDirection)
        }
        // Smooth the course command to suppress 1-tick noise (tight aim point
        // near a waypoint, projection wrap, etc.).
        if !state.hasCourseSeed {
            state.filteredCourseRad = desiredCourseRaw
            state.hasCourseSeed = true
        } else {
            let alpha = filterAlpha(tau: Tuning.courseFilterTau, dt: input.deltaTime)
            let delta = shortestAngle(desiredCourseRaw - state.filteredCourseRad)
            state.filteredCourseRad = wrapAngle(state.filteredCourseRad + delta * alpha)
        }
        let desiredCourse = state.filteredCourseRad
        let courseError = shortestAngle(desiredCourse - input.aircraftYawRadians)

        let maxBankRad = max(0.05, wing.maxBankAngleDeg.degreesToRadians) * 0.95
        var rawBankRad = (courseError * Tuning.bankProportionalGain).clamped(to: -maxBankRad...maxBankRad)
        // Anti-windup: bleed the bank command toward zero when the heading
        // error is small. This prevents endless small corrections that look
        // like a "wagging tail".
        if abs(courseError) < 0.035 {
            rawBankRad *= 0.4
        }
        let bankAlpha = filterAlpha(tau: Tuning.bankFilterTau, dt: input.deltaTime)
        state.filteredBankRad = state.filteredBankRad + (rawBankRad - state.filteredBankRad) * bankAlpha

        // Vertical guidance — pitch + throttle.
        let targetAltitude = targetAltitudeOverride ?? activeWaypoint.altitude
        let altitudeError = targetAltitude - input.aircraftPosition.y
        let verticalVelocity = input.aircraftVelocity.y.isFinite ? input.aircraftVelocity.y : 0.0
        let bleed: Float = Tuning.maxAltitudeBleedRateMps
        let altitudePitchRaw = (altitudeError * Tuning.altitudePitchGain
            - verticalVelocity * Tuning.verticalDampingGain).clamped(to: -bleed...bleed)
        let maxPitchUpRad = max(0.05, wing.maxPitchUpDeg.degreesToRadians)
        let maxPitchDownRad = max(0.05, wing.maxPitchDownDeg.degreesToRadians)
        var rawPitchRad = altitudePitchRaw.clamped(to: -maxPitchDownRad...maxPitchUpRad)

        // Stall protection — if we are dangerously slow, force nose down.
        var stallProtectionActive = false
        if currentSpeed < stallSafeSpeed && input.aircraftPosition.y > 1.5 {
            let stallPitchDown = -Tuning.stallPitchDownDeg.degreesToRadians
            rawPitchRad = min(rawPitchRad, stallPitchDown)
            stallProtectionActive = true
        }

        let pitchAlpha = filterAlpha(tau: Tuning.pitchFilterTau, dt: input.deltaTime)
        state.filteredPitchRad = state.filteredPitchRad + (rawPitchRad - state.filteredPitchRad) * pitchAlpha

        // Throttle: cruise + speed error + altitude assist when climbing.
        let approachScale: Float = {
            // Slow down a touch only when within reach of the final waypoint
            // (avoids overshoot of a terminal hold).
            guard !plan.loopAfterFinalWaypoint,
                  state.activeWaypointIndex >= plan.waypoints.count - 1 else {
                return 1.0
            }
            let distance = simd_length(activeWaypoint.position - aircraftPlanar)
            let slow = max(activeWaypoint.acceptanceRadius * 4.0, cruiseAirspeed * 2.0)
            let blend = (distance / slow).clamped(to: 0.0...1.0)
            return Tuning.approachSpeedScale + (1.0 - Tuning.approachSpeedScale) * blend
        }()
        let targetSpeed = (cruiseAirspeed * approachScale).clamped(to: stallSafeSpeed...wing.maxAirspeed)
        let speedError = targetSpeed - currentSpeed
        let cruiseHover: Float = 0.55
        let altitudeBoost = max(0.0, altitudeError) * Tuning.throttleAltitudeAssistGain
        let stallBoost: Float = stallProtectionActive ? 0.18 : 0.0
        var rawThrottle = (cruiseHover
            + speedError * Tuning.throttleSpeedGain
            + altitudeBoost
            + stallBoost
            - max(0.0, -altitudeError) * 0.012) // gentle pull back during high-altitude descent
        rawThrottle = rawThrottle.clamped(to: Tuning.throttleHoverSpan)
        let throttleAlpha = filterAlpha(tau: Tuning.throttleFilterTau, dt: input.deltaTime)
        state.filteredThrottle = state.filteredThrottle + (rawThrottle - state.filteredThrottle) * throttleAlpha
        state.filteredThrottle = state.filteredThrottle.clamped(to: Tuning.throttleHoverSpan)

        let bankDeg = state.filteredBankRad.radiansToDegrees
        let pitchDeg = state.filteredPitchRad.radiansToDegrees
        let yawDeg = wrapAngle(desiredCourse).radiansToDegrees
        let aimWorld = SIMD3<Float>(aimPointPlanar.x, targetAltitude, aimPointPlanar.y)
        let positionTarget = SIMD3<Float>(activeWaypoint.position.x, targetAltitude, activeWaypoint.position.y)

        let remainingDistance = remainingPathLength(
            plan: plan,
            startIndex: activeIndex,
            aircraft: aircraftPlanar
        )

        return FixedWingAutopilotResult(
            rollDegrees: bankDeg,
            pitchDegrees: pitchDeg,
            yawDegrees: yawDeg,
            throttle: state.filteredThrottle,
            positionTarget: positionTarget,
            activeWaypointIndex: activeIndex,
            distanceToActiveWaypointMeters: simd_length(activeWaypoint.position - aircraftPlanar),
            crossTrackErrorMeters: crossTrack,
            courseErrorDegrees: courseError.radiansToDegrees,
            desiredCourseDegrees: yawDeg,
            headingDegrees: input.aircraftYawRadians.radiansToDegrees,
            commandedBankDegrees: bankDeg,
            commandedPitchDegrees: pitchDeg,
            commandedThrottle: state.filteredThrottle,
            targetAltitudeMeters: targetAltitude,
            targetAirspeedMpsActive: targetSpeed,
            aimPointWorld: aimWorld,
            legStartWorld: SIMD3<Float>(legStartPlanar.x, targetAltitude, legStartPlanar.y),
            legEndWorld: SIMD3<Float>(legEndPlanar.x, targetAltitude, legEndPlanar.y),
            alongTrackProgress: alongTrackProgress,
            remainingPathLengthMeters: remainingDistance,
            stallProtectionActive: stallProtectionActive,
            hasCompletedRoute: state.hasCompletedRoute
        )
    }

    var activeWaypointIndex: Int { state.activeWaypointIndex }
    var hasCompletedRoute: Bool { state.hasCompletedRoute }

    // MARK: - Internals

    private func legStart(
        for index: Int,
        plan: FixedWingAutopilotPlan,
        fallback: SIMD2<Float>
    ) -> SIMD2<Float> {
        if index <= 0 {
            return fallback
        }
        return plan.waypoints[index - 1].position
    }

    private func computeAimPoint(
        plan: FixedWingAutopilotPlan,
        startIndex: Int,
        legStart: SIMD2<Float>,
        projectedOnLeg: SIMD2<Float>,
        legDirection: SIMD2<Float>,
        alongTrack: Float,
        legLength: Float,
        lookaheadDistance: Float
    ) -> SIMD2<Float> {
        // Walk the path from the projected point until we accumulate
        // `lookaheadDistance` meters. The aim point glides over corners
        // because we never stop at a waypoint — we always continue into the
        // next segment.
        var remaining = lookaheadDistance
        var cursor = projectedOnLeg
        var cursorAlong = max(0.0, alongTrack)
        var currentEnd = plan.waypoints[startIndex].position
        var currentDirection = legDirection
        var currentLengthRemaining = max(0.0, legLength - cursorAlong)

        var index = startIndex
        var iterationGuard = 0
        while remaining > 0.0 && iterationGuard < plan.waypoints.count + 2 {
            iterationGuard += 1
            if currentLengthRemaining >= remaining {
                return cursor + currentDirection * remaining
            }
            // Step to end of this segment, then advance to the next leg.
            cursor = currentEnd
            remaining -= currentLengthRemaining

            let nextIndex = index + 1
            if nextIndex >= plan.waypoints.count {
                if plan.loopAfterFinalWaypoint, !plan.waypoints.isEmpty {
                    let wrappedStart = plan.waypoints[plan.waypoints.count - 1].position
                    let wrappedEnd = plan.waypoints[0].position
                    let wrappedVector = wrappedEnd - wrappedStart
                    let wrappedLength = simd_length(wrappedVector)
                    if wrappedLength < 0.001 {
                        return cursor + currentDirection * remaining
                    }
                    currentDirection = wrappedVector / wrappedLength
                    currentEnd = wrappedEnd
                    currentLengthRemaining = wrappedLength
                    index = 0
                    cursorAlong = 0.0
                    continue
                }
                // Final waypoint — extrapolate along the inbound direction so
                // the carrot still leads, even past the last point.
                return cursor + currentDirection * remaining
            }

            let segStart = currentEnd
            let segEnd = plan.waypoints[nextIndex].position
            let segVector = segEnd - segStart
            let segLength = simd_length(segVector)
            if segLength < 0.001 {
                index = nextIndex
                continue
            }
            currentDirection = segVector / segLength
            currentEnd = segEnd
            currentLengthRemaining = segLength
            cursor = segStart
            cursorAlong = 0.0
            index = nextIndex
        }

        return cursor + currentDirection * max(0.0, remaining)
    }

    private func remainingPathLength(
        plan: FixedWingAutopilotPlan,
        startIndex: Int,
        aircraft: SIMD2<Float>
    ) -> Float {
        guard startIndex < plan.waypoints.count else {
            return 0.0
        }
        var total = simd_length(plan.waypoints[startIndex].position - aircraft)
        if startIndex + 1 < plan.waypoints.count {
            for i in (startIndex + 1)..<plan.waypoints.count {
                total += simd_length(plan.waypoints[i].position - plan.waypoints[i - 1].position)
            }
        }
        return total
    }

    private func filterAlpha(tau: Float, dt: Float) -> Float {
        guard tau > 0.0001 else {
            return 1.0
        }
        // Standard exponential smoothing: alpha = 1 - exp(-dt/tau). Approximated
        // with a stable explicit formula and clamped for short / long ticks.
        let raw = 1.0 - expf(-max(0.0, dt) / tau)
        return raw.clamped(to: 0.02...1.0)
    }

    private func forwardDirection(yaw: Float) -> SIMD2<Float> {
        // Matches the SimpleDronePhysicsEngine planar-direction fallback.
        SIMD2<Float>(sinf(yaw), -cosf(yaw))
    }

    /// Compass-style course (radians) that matches MulticopterAutopilotController
    /// and SimpleDronePhysicsEngine: `atan2(-direction.x, -direction.y)`.
    private func courseRadians(direction: SIMD2<Float>) -> Float {
        let yaw = atan2f(-direction.x, -direction.y)
        return yaw.isFinite ? yaw : 0.0
    }

    private func shortestAngle(_ angle: Float) -> Float {
        var normalized = angle
        while normalized > .pi { normalized -= 2.0 * .pi }
        while normalized < -.pi { normalized += 2.0 * .pi }
        return normalized
    }

    private func wrapAngle(_ angle: Float) -> Float {
        var wrapped = angle.truncatingRemainder(dividingBy: 2.0 * .pi)
        if wrapped > .pi { wrapped -= 2.0 * .pi }
        if wrapped < -.pi { wrapped += 2.0 * .pi }
        return wrapped
    }

    private func isFiniteVector(_ v: SIMD3<Float>) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite
    }
}

private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
    var degreesToRadians: Float { self * .pi / 180.0 }
    var radiansToDegrees: Float { self * 180.0 / .pi }
}
