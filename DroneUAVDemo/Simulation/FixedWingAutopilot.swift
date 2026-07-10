import Foundation
import simd

/// Stable, "behaves-like-a-real-airplane" waypoint follower.
///
/// Design rationale (replaces the previous multi-controller fly-by stack):
/// - **Carrot pursuit** for lateral guidance: pick a virtual aim point ahead
///   on the active inbound leg. Before the active waypoint is captured, the
///   aim point stays on the inbound leg extended through the waypoint, so the
///   aircraft is guided through the capture sphere without switching to the
///   next segment early or turning back toward a fixed point.
/// - **Decoupled energy management**: pitch tracks altitude error (with
///   vertical-velocity damping); throttle tracks speed error. Stall protection
///   pitches the nose down whenever airspeed drops below a safe floor.
/// - **Robust waypoint advance**: a waypoint is "passed" only when the
///   aircraft enters the waypoint capture circle or the flown segment between
///   simulation ticks intersects that circle. The follower should shape the
///   trajectory through the circle instead of skipping a waypoint just because
///   it crossed an abstract finish plane.
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
    /// last one is captured. When false, it keeps flying outbound on the
    /// final leg course after route completion.
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
    /// True on the tick the aircraft crosses the waypoint's abeam plane
    /// without entering its capture sphere. The route does not advance: the
    /// controller keeps the waypoint active and turns back to reacquire it.
    var missedActiveWaypoint: Bool
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
        static let turnLiftCompensationGain: Float = 0.6   // rad pitch per unit (1/cos(bank) - 1)
        static let pitchFilterTau: Float = 0.45
        static let maxAltitudeBleedRateMps: Float = 4.5
        // The hybrid path enters this controller only after the VTOL has
        // become wingborne. Its rotor/wing handoff has more vertical lag than
        // a conventional airplane, so the conventional V/S gain repeatedly
        // drives the pitch command from one limit to the other.
        static let hybridVTOLAltitudePitchGain: Float = 0.026
        static let hybridVTOLVerticalDampingGain: Float = 0.045
        static let hybridVTOLPitchFilterTau: Float = 0.70
        static let hybridVTOLMaxPitchUpDeg: Float = 8.0
        static let hybridVTOLMaxPitchDownDeg: Float = 6.0
        // Throttle (speed)
        static let throttleSpeedGain: Float = 0.085        // throttle per (m/s) speed error
        static let throttleAltitudeAssistGain: Float = 0.018
        static let turnThrottleCompensationGain: Float = 0.3 // throttle per unit (1/cos(bank) - 1)
        static let throttleFilterTau: Float = 0.55
        static let throttleHoverSpan: ClosedRange<Float> = 0.32...0.95
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
        var missedActiveWaypoint: Bool = false
        var previousAircraftPlanar: SIMD2<Float> = .zero
        var hasPreviousAircraftPlanar: Bool = false
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
        missionMinAirspeed: Float? = nil,
        missionMaxAirspeed: Float? = nil,
        useHybridVTOLCruiseStabilization: Bool = false,
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
            state.hasPreviousAircraftPlanar = false
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
        if !state.hasPreviousAircraftPlanar {
            state.previousAircraftPlanar = aircraftPlanar
            state.hasPreviousAircraftPlanar = true
        }
        let cruiseAirspeed = max(
            wing.minSafeAirspeed * 1.05,
            cruiseAirspeedOverride ?? wing.cruiseAirspeed
        )
        let stallSafeSpeed = wing.minSafeAirspeed * Tuning.stallSpeedSafetyFactor
        let currentSpeed = max(0.0, input.aircraftAirspeed.isFinite ? input.aircraftAirspeed : 0.0)

        // Advance through any waypoints we have already crossed.
        //
        // `active.acceptanceRadius` is the same capture volume rendered on the
        // tactical map and in the 3D scene. Guidance lookahead is intentionally
        // larger, but it must not advance the route before this actual sphere
        // is crossed. The swept-segment test still catches a fast fly-through
        // that crosses the sphere between two ticks.
        state.missedActiveWaypoint = false
        var advanceGuard = 0
        while advanceGuard < plan.waypoints.count {
            let active = plan.waypoints[state.activeWaypointIndex]
            let captureRadius = max(active.acceptanceRadius, 4.0)
            let distanceToWaypoint = simd_length(aircraftPlanar - active.position)
            let crossedCaptureVolume = motionSegmentIntersectsCircle(
                from: state.previousAircraftPlanar,
                to: aircraftPlanar,
                center: active.position,
                radius: captureRadius
            )
            let insideAcceptance = distanceToWaypoint <= captureRadius

            // Detect crossing the waypoint's abeam plane without entering its
            // sphere. This is diagnostic only: a miss must never be counted as
            // a completed waypoint. Guidance below will cap its carrot at the
            // waypoint itself, causing a turn back and reacquisition.
            let inboundDirection: SIMD2<Float> = {
                if state.activeWaypointIndex > 0 {
                    let raw = active.position - plan.waypoints[state.activeWaypointIndex - 1].position
                    let length = simd_length(raw)
                    if length > 0.001 {
                        return raw / length
                    }
                }
                // First waypoint (no preceding waypoint to define a leg): fall
                // back to the aircraft's actual travel direction this tick, not
                // a bearing-to-waypoint, so the abeam test reflects real motion.
                let travel = aircraftPlanar - state.previousAircraftPlanar
                let travelLength = simd_length(travel)
                if travelLength > 0.0001 {
                    return travel / travelLength
                }
                return forwardDirection(yaw: input.aircraftYawRadians)
            }()
            let previousAlong = simd_dot(state.previousAircraftPlanar - active.position, inboundDirection)
            let currentAlong = simd_dot(aircraftPlanar - active.position, inboundDirection)
            let crossedAbeamPlane = previousAlong < 0.0 && currentAlong >= 0.0
            let overshotWithoutCapture = crossedAbeamPlane && !crossedCaptureVolume && !insideAcceptance

            if overshotWithoutCapture {
                state.missedActiveWaypoint = true
            }

            if crossedCaptureVolume || insideAcceptance {
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
        let crossTrack = simd_dot(SIMD2<Float>(-legDirection.y, legDirection.x), toAircraft)
        let alongTrackProgress = legLength > 0.01 ? max(0.0, min(1.0, alongTrack / legLength)) : 0.0

        // Carrot lookahead distance: large enough to behave smoothly, small
        // enough to capture turns. Floors prevent runaway look-ahead at low
        // airspeed (e.g. take-off).
        let speedForLookahead = max(currentSpeed, cruiseAirspeed * 0.6)
        let minimumTurnRadius = max(
            wing.waypointAcceptanceRadiusMeters * 1.4,
            wing.minimumTurnRadius(airspeed: speedForLookahead)
        )
        let lookaheadDistance = max(
            Tuning.lookaheadMinMeters,
            speedForLookahead * Tuning.lookaheadAirspeedFactor,
            minimumTurnRadius * Tuning.lookaheadTurnRadiusFactor
        )

        let holdsFinalCourse = state.hasCompletedRoute && !plan.loopAfterFinalWaypoint
        let aimPointPlanar: SIMD2<Float>
        if holdsFinalCourse {
            aimPointPlanar = aircraftPlanar + legDirection * max(
                lookaheadDistance,
                cruiseAirspeed * 4.0,
                activeWaypoint.acceptanceRadius * 3.0
            )
        } else {
            aimPointPlanar = computeCaptureAimPoint(
                activeWaypoint: activeWaypoint,
                legStart: legStartPlanar,
                legDirection: legDirection,
                alongTrack: alongTrack,
                legLength: legLength,
                lookaheadDistance: lookaheadDistance
            )
        }

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

        // Vertical target, resolved early so the bank limiter below can
        // reference it (the rest of vertical guidance recomputes the same
        // value further down — cheap, and keeps this section self-contained).
        let earlyTargetAltitude = targetAltitudeOverride ?? activeWaypoint.altitude

        // Low-altitude bank protection: pitch/throttle compensation alone
        // can't fully erase the lift a steep bank costs, so while still
        // climbing toward where the mission wants it to be, the aircraft
        // shouldn't attempt a turn sharp enough to outrun its margin before
        // getting there — the "banks while still low, sinks into the
        // ground" failure mode seen repeatedly in testing. Deliberately
        // measured against *this leg's own target altitude*, not a fixed
        // absolute height: a mission that intentionally cruises at 15m
        // should get full authority once it's actually at its own 15m
        // cruise, not be permanently capped because 15m is "low" in some
        // absolute sense — that previously made low-altitude missions
        // unable to complete turns at all. The restriction now only bites
        // while genuinely below profile (e.g. mid climb-out), and lifts as
        // soon as the aircraft reaches the altitude it's already trying to
        // hold.
        let altitudeDeficit = max(0.0, earlyTargetAltitude - input.aircraftPosition.y)
        let altitudeMarginFactor = (1.0 - altitudeDeficit / max(wing.initialClimbTargetAltitude, 1.0))
            .clamped(to: 0.35...1.0)
        let maxBankRad = max(0.05, wing.maxBankAngleDeg.degreesToRadians) * 0.95 * altitudeMarginFactor
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
        let targetAltitude = earlyTargetAltitude
        let altitudeError = targetAltitude - input.aircraftPosition.y
        let verticalVelocity = input.aircraftVelocity.y.isFinite ? input.aircraftVelocity.y : 0.0
        let bleed: Float = Tuning.maxAltitudeBleedRateMps
        let altitudePitchGain = useHybridVTOLCruiseStabilization
            ? Tuning.hybridVTOLAltitudePitchGain
            : Tuning.altitudePitchGain
        let verticalDampingGain = useHybridVTOLCruiseStabilization
            ? Tuning.hybridVTOLVerticalDampingGain
            : Tuning.verticalDampingGain
        let maxPitchUpDeg = useHybridVTOLCruiseStabilization
            ? min(wing.maxPitchUpDeg, Tuning.hybridVTOLMaxPitchUpDeg)
            : wing.maxPitchUpDeg
        let maxPitchDownDeg = useHybridVTOLCruiseStabilization
            ? min(wing.maxPitchDownDeg, Tuning.hybridVTOLMaxPitchDownDeg)
            : wing.maxPitchDownDeg
        let altitudePitchRaw = (altitudeError * altitudePitchGain
            - verticalVelocity * verticalDampingGain).clamped(to: -bleed...bleed)
        let maxPitchUpRad = max(0.05, maxPitchUpDeg.degreesToRadians)
        let maxPitchDownRad = max(0.05, maxPitchDownDeg.degreesToRadians)
        var rawPitchRad = altitudePitchRaw.clamped(to: -maxPitchDownRad...maxPitchUpRad)

        // Stall protection — if we are dangerously slow, force nose down.
        var stallProtectionActive = false
        if currentSpeed < stallSafeSpeed && input.aircraftPosition.y > 1.5 {
            let stallPitchDown = -Tuning.stallPitchDownDeg.degreesToRadians
            rawPitchRad = min(rawPitchRad, stallPitchDown)
            stallProtectionActive = true
        }

        let pitchFilterTau = useHybridVTOLCruiseStabilization
            ? Tuning.hybridVTOLPitchFilterTau
            : Tuning.pitchFilterTau
        let pitchAlpha = filterAlpha(tau: pitchFilterTau, dt: input.deltaTime)
        state.filteredPitchRad = state.filteredPitchRad + (rawPitchRad - state.filteredPitchRad) * pitchAlpha
        // Coordinated-turn lift compensation is applied *after* the pitch
        // filter, not blended into the filtered term — bank itself reaches
        // the lower-level PD loop after only the bank filter's lag (~0.32s);
        // routing the compensation through the pitch filter too (~0.45s)
        // would make it systematically trail the lift loss it's meant to
        // cancel. A bank trades vertical lift for centripetal force (lift's
        // vertical component falls by cos(bank)) — the old kinematic model
        // never charged for this, so without this term the aircraft sinks
        // every time it banks toward a waypoint.
        let bankLiftLossRad = (1.0 / max(cos(state.filteredBankRad), 0.5) - 1.0) * Tuning.turnLiftCompensationGain
        let commandedPitchRad: Float
        if useHybridVTOLCruiseStabilization {
            // This is a feed-forward correction, not an integral term. The
            // legacy fixed-wing path stores it for compatibility; hybrid VTOL
            // must keep it output-only or even a small sustained bank pumps
            // the saved pitch command to its upper limit in a few frames.
            commandedPitchRad = (state.filteredPitchRad + bankLiftLossRad)
                .clamped(to: -maxPitchDownRad...maxPitchUpRad)
        } else {
            state.filteredPitchRad = (state.filteredPitchRad + bankLiftLossRad)
                .clamped(to: -maxPitchDownRad...maxPitchUpRad)
            commandedPitchRad = state.filteredPitchRad
        }

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
        // Mission speed bounds narrow the airframe's own safe envelope, never
        // widen it — a mission can ask to cruise slower/faster within what's
        // physically flyable, not below stall or above the airframe's max.
        let missionSpeedFloor = max(stallSafeSpeed, missionMinAirspeed ?? stallSafeSpeed)
        let missionSpeedCeiling = max(missionSpeedFloor, min(wing.maxAirspeed, missionMaxAirspeed ?? wing.maxAirspeed))
        let targetSpeed = (cruiseAirspeed * approachScale).clamped(to: missionSpeedFloor...missionSpeedCeiling)
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
        // Coordinated-turn drag compensation, applied post-filter — same
        // reasoning as the pitch compensation above (throttle's own filter,
        // 0.55s, is even slower, so this matters even more here). A banked
        // turn needs more lift (1/cos(bank)), and induced drag grows with the
        // square of that, so without extra throttle airspeed bleeds through
        // the turn, costing even more lift on top of the bank's cosine loss.
        let turnDragBoost = (1.0 / max(cos(state.filteredBankRad), 0.5) - 1.0) * Tuning.turnThrottleCompensationGain
        let commandedThrottle: Float
        if useHybridVTOLCruiseStabilization {
            // Same feed-forward rule as pitch: do not integrate the bank drag
            // correction into persistent throttle state on every update.
            commandedThrottle = (state.filteredThrottle + turnDragBoost)
                .clamped(to: Tuning.throttleHoverSpan)
        } else {
            state.filteredThrottle = (state.filteredThrottle + turnDragBoost)
                .clamped(to: Tuning.throttleHoverSpan)
            commandedThrottle = state.filteredThrottle
        }

        let bankDeg = state.filteredBankRad.radiansToDegrees
        let pitchDeg = commandedPitchRad.radiansToDegrees
        let yawDeg = wrapAngle(desiredCourse).radiansToDegrees
        let aimWorld = SIMD3<Float>(aimPointPlanar.x, targetAltitude, aimPointPlanar.y)
        let positionTarget = holdsFinalCourse
            ? aimWorld
            : SIMD3<Float>(activeWaypoint.position.x, targetAltitude, activeWaypoint.position.y)

        let remainingDistance = holdsFinalCourse
            ? 0.0
            : remainingPathLength(
                plan: plan,
                startIndex: activeIndex,
                aircraft: aircraftPlanar
            )
        let legStartWorld = holdsFinalCourse
            ? SIMD3<Float>(aircraftPlanar.x, targetAltitude, aircraftPlanar.y)
            : SIMD3<Float>(legStartPlanar.x, targetAltitude, legStartPlanar.y)
        let legEndWorld = holdsFinalCourse
            ? aimWorld
            : SIMD3<Float>(legEndPlanar.x, targetAltitude, legEndPlanar.y)

        state.previousAircraftPlanar = aircraftPlanar
        state.hasPreviousAircraftPlanar = true

        return FixedWingAutopilotResult(
            rollDegrees: bankDeg,
            pitchDegrees: pitchDeg,
            yawDegrees: yawDeg,
            throttle: commandedThrottle,
            positionTarget: positionTarget,
            activeWaypointIndex: activeIndex,
            distanceToActiveWaypointMeters: simd_length(activeWaypoint.position - aircraftPlanar),
            crossTrackErrorMeters: crossTrack,
            courseErrorDegrees: courseError.radiansToDegrees,
            desiredCourseDegrees: yawDeg,
            headingDegrees: input.aircraftYawRadians.radiansToDegrees,
            commandedBankDegrees: bankDeg,
            commandedPitchDegrees: pitchDeg,
            commandedThrottle: commandedThrottle,
            targetAltitudeMeters: targetAltitude,
            targetAirspeedMpsActive: targetSpeed,
            aimPointWorld: aimWorld,
            legStartWorld: legStartWorld,
            legEndWorld: legEndWorld,
            alongTrackProgress: alongTrackProgress,
            remainingPathLengthMeters: remainingDistance,
            stallProtectionActive: stallProtectionActive,
            hasCompletedRoute: state.hasCompletedRoute,
            missedActiveWaypoint: state.missedActiveWaypoint
        )
    }

    var activeWaypointIndex: Int { state.activeWaypointIndex }
    var hasCompletedRoute: Bool { state.hasCompletedRoute }

    // MARK: - Internals

    private func computeCaptureAimPoint(
        activeWaypoint: FixedWingAutopilotWaypoint,
        legStart: SIMD2<Float>,
        legDirection: SIMD2<Float>,
        alongTrack: Float,
        legLength: Float,
        lookaheadDistance: Float
    ) -> SIMD2<Float> {
        guard legLength > 0.001 else {
            return activeWaypoint.position
        }

        let captureScale = max(
            activeWaypoint.acceptanceRadius,
            4.0
        )
        let boundedLookahead = min(
            lookaheadDistance,
            max(captureScale * 3.0, legLength)
        )
        // The carrot may move forward along the inbound leg, but it stops at
        // the waypoint center. Previously `max(...)` pushed it beyond the
        // waypoint and then kept moving it ahead of the aircraft forever. With
        // lateral error the aircraft followed a nearly parallel course and
        // crossed the abeam plane outside the sphere. Capping at `legLength`
        // progressively increases the intercept angle and, after an overshoot,
        // commands a genuine turn back toward the sphere.
        let desiredAlongTrack = min(
            legLength,
            max(0.0, alongTrack + boundedLookahead)
        )
        return legStart + legDirection * desiredAlongTrack
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
        let closestPoint = start + delta * t
        return simd_distance(closestPoint, center) <= radius
    }

    private func forwardDirection(yaw: Float) -> SIMD2<Float> {
        // Matches SimpleDronePhysicsEngine's yaw quaternion applied to body -Z.
        SIMD2<Float>(-sinf(yaw), -cosf(yaw))
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
