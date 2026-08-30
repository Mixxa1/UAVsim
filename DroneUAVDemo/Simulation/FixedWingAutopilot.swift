import Foundation
import simd

/// Lateral-loop constants shared with the collision predictor. Route safety is invalid if the
/// proof assumes a slower/differently filtered turn than the controller that executes it.
enum FixedWingAutopilotLateralTuning {
    static let bankProportionalGain: Float = 1.45
    static let bankFilterTau: Float = 0.32
    static let courseFilterTau: Float = 0.18
    static let maximumBankScale: Float = 0.95
}

/// Stable, "behaves-like-a-real-airplane" waypoint follower.
///
/// Design rationale (replaces the previous multi-controller fly-by stack):
/// - **Carrot pursuit** for lateral guidance: pick a virtual aim point ahead
///   on the active path. Planner-generated intermediate corners are fly-by geometry: the follower
///   commits to a physically attainable constant-radius fillet before the corner, follows it
///   monotonically, and hands off only after acquiring the outbound leg. Operator mission points
///   require an actual swept capture and a measured-pose route handoff.
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
    /// Height above the surface below the aircraft. Drives low-altitude bank protection, which is
    /// about proximity to the ground and not about how far below its cruise level the route is.
    var heightAboveSurfaceMeters: Float = .greatestFiniteMagnitude
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
    /// The obstacle planner validated every non-terminal fillet at the same (or a more
    /// conservative) speed/bank envelope used below. Multi-point routes fail closed without it.
    var turnsValidated: Bool
    var validatedTurnRadiusMeters: Float?
    var validatedAirspeedMps: Float?
    /// When true, the autopilot loops back to the first waypoint after the
    /// last one is captured. When false, it keeps flying outbound on the
    /// final leg course after route completion.
    var loopAfterFinalWaypoint: Bool
}

struct FixedWingAutopilotWaypoint: Equatable {
    enum CapturePolicy: Equatable {
        /// Fixed-wing mission transit points are passed on a validated fly-by arc; mission
        /// progress advances after outbound acquisition, not by pretending the corner was hit.
        case flyBy
        /// Operator-authored mission points must intersect their swept acceptance circle. An
        /// intermediate capture holds course until a measured-pose route is published.
        case required
    }

    var position: SIMD2<Float>
    var altitude: Float
    var acceptanceRadius: Float
    var capturePolicy: CapturePolicy
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
    /// True while the lateral target is following a committed turn fillet.
    var flyByTransitionActive: Bool
    /// True on the tick the aircraft crosses the waypoint's abeam plane
    /// without entering its capture sphere. The route does not advance: the
    /// controller keeps the waypoint active and turns back to reacquire it.
    var missedActiveWaypoint: Bool
    /// Route-array index of an intermediate required point that was physically captured. It
    /// remains present during the measured-course hold so mission progress can acknowledge the
    /// exact event before publishing the next route.
    var capturedRequiredWaypointIndexAwaitingReplan: Int?
}

final class FixedWingAutopilot {
    private struct Tuning {
        // Carrot pursuit
        static let lookaheadAirspeedFactor: Float = 1.85   // L1 ≈ V * factor (seconds)
        static let lookaheadMinMeters: Float = 18.0
        static let lookaheadTurnRadiusFactor: Float = 1.35
        static let flyByRollInSeconds: Float = 0.90
        static let flyByBankLimitDeg: Float = 22.0
        static let flyByMaximumTurnDeg: Float = 150.0
        // Lateral
        static let bankProportionalGain = FixedWingAutopilotLateralTuning.bankProportionalGain
        static let bankFilterTau = FixedWingAutopilotLateralTuning.bankFilterTau
        static let courseFilterTau = FixedWingAutopilotLateralTuning.courseFilterTau
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

    private struct CommittedFlyBy: Equatable {
        var waypointIndex: Int
        var inboundDirection: SIMD2<Float>
        var outboundDirection: SIMD2<Float>
        var entry: SIMD2<Float>
        var exit: SIMD2<Float>
        var center: SIMD2<Float>
        var radius: Float
        var startAngle: Float
        var sweepAngle: Float
        var tangentDistance: Float
        var triggerDistance: Float

        var arcLength: Float { abs(sweepAngle) * radius }
    }

    private struct InternalState {
        /// Last commanded airspeed, m/s — the anchor for the acceleration corridor below.
        var previousTargetSpeed: Float = 0.0
        var hasTargetSpeed: Bool = false

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
        var committedFlyBy: CommittedFlyBy?
        /// A required intermediate mission point has been physically captured, but the route that
        /// approached it certified a pre-capture fillet rather than the late outbound turn. Hold
        /// the measured course until the owner publishes a newly planned route from this pose.
        var requiredCaptureHoldCourseRad: Float?
        var requiredCaptureWaypointIndex: Int?
    }

    private var state = InternalState()
    /// Populated only when returning `nil` for a recoverable guidance failure. The adapter uses
    /// this to distinguish a stale/missed turn entry (which needs a route re-anchor) from malformed
    /// input. It is cleared at the beginning of every update.
    private(set) var lastFailureReason: String?

    func reset() {
        state = InternalState()
        lastFailureReason = nil
    }

    /// Stops only the captured-state flag and waypoint pointer, but keeps the
    /// filtered command memory so a re-engage on the same route does not jolt
    /// the aircraft.
    func resetCaptureProgress() {
        state.activeWaypointIndex = 0
        state.hasCompletedRoute = false
        state.hasLegAnchor = false
        state.committedFlyBy = nil
        state.requiredCaptureHoldCourseRad = nil
        state.requiredCaptureWaypointIndex = nil
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
        lastFailureReason = nil
        guard !plan.waypoints.isEmpty else {
            return nil
        }
        guard plan.waypoints.count <= 2 || plan.turnsValidated else {
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
            state.committedFlyBy = nil
            state.requiredCaptureHoldCourseRad = nil
            state.requiredCaptureWaypointIndex = nil
        }

        // Honour minimum index from outside (forward-progress guarantee).
        if state.activeWaypointIndex < plan.minimumWaypointIndex {
            state.activeWaypointIndex = plan.minimumWaypointIndex
            state.hasLegAnchor = false
            state.committedFlyBy = nil
        }
        if state.activeWaypointIndex >= plan.waypoints.count {
            if plan.loopAfterFinalWaypoint {
                state.activeWaypointIndex = 0
                state.hasCompletedRoute = false
                state.hasLegAnchor = false
                state.committedFlyBy = nil
                state.requiredCaptureHoldCourseRad = nil
                state.requiredCaptureWaypointIndex = nil
            } else {
                state.activeWaypointIndex = plan.waypoints.count - 1
                state.hasCompletedRoute = true
                state.committedFlyBy = nil
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
        // --- The speed corridor, scheduled on altitude.
        //
        // Every speed in the catalogue is a number in metres per second, and the autopilot
        // used to treat all of them as if the air were sea-level air. Two things break when
        // it does.
        //
        // A stall speed is an *indicated* speed — it is a statement about dynamic pressure,
        // not about how fast the ground goes past. The true airspeed at which a wing stalls
        // grows as `sqrt(rho0/rho)`, so an aircraft at 13 km stalls at more than twice the
        // TAS it stalls at on the deck. An autopilot holding the sea-level figure as its
        // floor up there is holding a floor a thousand metres below the real one, and will
        // fly a high-altitude aircraft into a stall while its own logic reports margin.
        //
        // And the ceiling is not a speed at all up there, it is a Mach number: the same TAS
        // that is comfortably subsonic at sea level is past drag divergence in the cold thin
        // air of the tropopause, because the speed of sound has dropped by a sixth.
        //
        // Standard atmosphere rather than the weather's: this is the airframe's structural
        // and aerodynamic corridor, which does not move because a front came through.
        let scheduleAtmosphere = AtmosphereModel.standard.state(
            altitudeMeters: max(0.0, input.aircraftPosition.y)
        )
        let stallTrueAirspeedScale = sqrt(
            AtmosphereModel.seaLevelDensity / max(0.001, scheduleAtmosphere.airDensity)
        )
        let altitudeStallFloor = stallSafeSpeed * stallTrueAirspeedScale
        // Held a little under drag divergence. An autopilot that commands exactly the
        // divergence Mach is commanding the speed at which the drag rise begins, and will
        // sit in it.
        let machCeilingSpeed = FixedWingAerodynamics.dragDivergenceMach(for: wing.family)
            * scheduleAtmosphere.speedOfSoundMps * 0.97

        let currentSpeed = max(0.0, input.aircraftAirspeed.isFinite ? input.aircraftAirspeed : 0.0)

        // Commit the next real turn before capture processing. Otherwise an intermediate route
        // point can be crossed first and only then start commanding the outbound course — exactly
        // the late-turn failure that lets a wing enter a facade despite a point-safe A* path.
        if state.committedFlyBy?.waypointIndex != state.activeWaypointIndex {
            state.committedFlyBy = nil
        }
        if let committed = state.committedFlyBy {
            let turnWaypoint = plan.waypoints[committed.waypointIndex]
            let turnTargetAltitude = targetAltitudeOverride ?? turnWaypoint.altitude
            let effectiveBank = effectiveMaximumBankRadians(
                wing: wing,
                targetAltitude: turnTargetAltitude,
                currentAltitude: input.aircraftPosition.y,
                heightAboveSurface: input.heightAboveSurfaceMeters
            )
            let turnSpeed = max(
                currentSpeed,
                cruiseAirspeed * 1.12,
                wing.minSafeAirspeed,
                plan.validatedAirspeedMps ?? 0.0
            )
            let requiredRadius = requiredTurnRadius(
                wing: wing,
                airspeed: turnSpeed,
                effectiveMaxBankRadians: effectiveBank,
                validatedTurnRadius: plan.validatedTurnRadiusMeters
            )
            // Wind/speed and altitude authority can change after arc commitment. Never keep
            // steering along geometry that has become tighter than the aircraft's current
            // envelope; hand it back for a route re-anchor while AUTO + reactive avoidance remain
            // authoritative.
            if requiredRadius > committed.radius {
                lastFailureReason = "fly_by_envelope_changed_replan"
                return nil
            }
            if shouldCompleteFlyBy(
                committed,
                aircraftPosition: aircraftPlanar,
                aircraftYaw: input.aircraftYawRadians,
                acceptanceRadius: turnWaypoint.acceptanceRadius
            ) {
                state.activeWaypointIndex = min(
                    committed.waypointIndex + 1,
                    plan.waypoints.count - 1
                )
                state.hasLegAnchor = false
                state.committedFlyBy = nil
            }
        }
        if state.committedFlyBy == nil,
           state.requiredCaptureHoldCourseRad == nil,
           state.activeWaypointIndex > 0,
           state.activeWaypointIndex < plan.waypoints.count - 1 {
            let turnWaypoint = plan.waypoints[state.activeWaypointIndex]
            let turnTargetAltitude = targetAltitudeOverride ?? turnWaypoint.altitude
            let effectiveBank = effectiveMaximumBankRadians(
                wing: wing,
                targetAltitude: turnTargetAltitude,
                currentAltitude: input.aircraftPosition.y,
                heightAboveSurface: input.heightAboveSurfaceMeters
            )
            let turnSpeed = max(
                currentSpeed,
                cruiseAirspeed * 1.12,
                wing.minSafeAirspeed,
                plan.validatedAirspeedMps ?? 0.0
            )
            if let candidate = flyByGeometry(
                plan: plan,
                waypointIndex: state.activeWaypointIndex,
                wing: wing,
                airspeed: turnSpeed,
                effectiveMaxBankRadians: effectiveBank,
                validatedTurnRadius: plan.validatedTurnRadiusMeters
            ) {
                let remainingInbound = simd_dot(
                    turnWaypoint.position - aircraftPlanar,
                    candidate.inboundDirection
                )
                let inboundNormal = SIMD2<Float>(
                    -candidate.inboundDirection.y,
                    candidate.inboundDirection.x
                )
                let inboundCrossTrack = abs(simd_dot(
                    aircraftPlanar - turnWaypoint.position,
                    inboundNormal
                ))
                let commitCorridor = max(
                    turnWaypoint.acceptanceRadius * 2.0,
                    candidate.triggerDistance * 0.45
                )
                let previousRemainingInbound = simd_dot(
                    turnWaypoint.position - state.previousAircraftPlanar,
                    candidate.inboundDirection
                )
                let crossedRollInGate = previousRemainingInbound > candidate.triggerDistance
                    && remainingInbound <= candidate.triggerDistance
                // Commit only on the tick that crosses the early trigger with the complete roll-in
                // distance still available. A route that appears after the aircraft is already
                // inside that gate, or a cross-track miss at the gate, must be re-anchored; waiting
                // until the tangent point silently spends the 0.9 s reserve.
                if crossedRollInGate,
                   remainingInbound >= candidate.tangentDistance,
                   inboundCrossTrack <= commitCorridor {
                    state.committedFlyBy = candidate
                } else if remainingInbound <= candidate.triggerDistance {
                    lastFailureReason = "fly_by_entry_missed_replan"
                    return nil
                }
            } else if requiresPhysicalFlyBy(
                plan: plan,
                waypointIndex: state.activeWaypointIndex
            ) {
                // A validated multi-point plan is allowed to reach capture processing only when
                // its real turn fits the live speed/bank envelope. Otherwise the capture sphere
                // would advance to the outbound leg and command the exact late corner this path
                // follower is designed to prevent.
                lastFailureReason = "fly_by_geometry_invalid_replan"
                return nil
            }
        }

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
            guard state.requiredCaptureHoldCourseRad == nil else {
                break
            }
            let active = plan.waypoints[state.activeWaypointIndex]
            // A committed fly-by deliberately misses the mathematical corner. Do not let its
            // capture sphere tear down the checked arc halfway through roll-in; the monotonic arc
            // handoff above owns progress until the outbound leg is established.
            if state.committedFlyBy?.waypointIndex == state.activeWaypointIndex {
                break
            }
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
                        state.committedFlyBy = nil
                    } else {
                        state.hasCompletedRoute = true
                    }
                    break
                } else {
                    let requiresMeasuredPoseReplan = active.capturePolicy == .required
                    state.activeWaypointIndex += 1
                    state.hasLegAnchor = false
                    state.committedFlyBy = nil
                    if requiresMeasuredPoseReplan {
                        // Do not command the outbound leg from the stale inbound-route
                        // certificate. Mission progress observes this physical capture later in
                        // the same simulation tick; its next route identifier is built from the
                        // measured pose and clears this hold on the following update.
                        state.requiredCaptureHoldCourseRad = input.aircraftYawRadians
                        state.requiredCaptureWaypointIndex = state.activeWaypointIndex - 1
                        break
                    }
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
        let requiredCaptureHoldCourse = state.requiredCaptureHoldCourseRad
        let holdsRequiredCaptureCourse = requiredCaptureHoldCourse != nil
        let activeFlyBy = state.committedFlyBy.flatMap {
            $0.waypointIndex == activeIndex ? $0 : nil
        }
        let activeFlyByProgress = activeFlyBy.map {
            flyByProgress(aircraftPosition: aircraftPlanar, geometry: $0)
        }
        let aimPointPlanar: SIMD2<Float>
        if holdsRequiredCaptureCourse, let requiredCaptureHoldCourse {
            aimPointPlanar = aircraftPlanar + forwardDirection(
                yaw: requiredCaptureHoldCourse
            ) * max(
                lookaheadDistance,
                cruiseAirspeed * 4.0,
                activeWaypoint.acceptanceRadius * 3.0
            )
        } else if holdsFinalCourse {
            aimPointPlanar = aircraftPlanar + legDirection * max(
                lookaheadDistance,
                cruiseAirspeed * 4.0,
                activeWaypoint.acceptanceRadius * 3.0
            )
        } else if let activeFlyBy, let activeFlyByProgress {
            aimPointPlanar = flyByAimPoint(
                geometry: activeFlyBy,
                progress: activeFlyByProgress,
                lookaheadDistance: lookaheadDistance
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
        let maxBankRad = effectiveMaximumBankRadians(
            wing: wing,
            targetAltitude: earlyTargetAltitude,
            currentAltitude: input.aircraftPosition.y,
            heightAboveSurface: input.heightAboveSurfaceMeters
        )
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
        if currentSpeed < altitudeStallFloor && input.aircraftPosition.y > 1.5 {
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
        // Same room for the compensation as in FixedWingAssistController: added and then clamped
        // to the unchanged ceiling, the correction is discarded precisely in the turns that need
        // it, because the altitude loop has already spent the budget. Raised by exactly the
        // compensation — the clamp still bounds angle of attack. This is feed-forward for every
        // fixed-wing family; integrating it into `filteredPitchRad` winds the altitude loop up in a
        // sustained turn and leaves a climb/overspeed transient after rollout.
        let compensatedPitchUpRad = maxPitchUpRad + max(0.0, bankLiftLossRad)
        let commandedPitchRad = (state.filteredPitchRad + bankLiftLossRad)
            .clamped(to: -maxPitchDownRad...compensatedPitchUpRad)

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
        let missionSpeedFloor = max(altitudeStallFloor, missionMinAirspeed ?? stallSafeSpeed)
        // Floor wins if the two cross. That crossing is coffin corner — the altitude where
        // the stall speed has risen to meet the Mach limit — and when an aircraft is in it
        // the honest command is the one that keeps the wing flying, not the one that keeps
        // it subsonic. Note the aircraft is not *held* there: nothing here clamps the
        // achieved speed, only what is asked for.
        let missionSpeedCeiling = max(
            missionSpeedFloor,
            min(wing.maxAirspeed, machCeilingSpeed, missionMaxAirspeed ?? wing.maxAirspeed)
        )
        let desiredSpeed = (cruiseAirspeed * approachScale).clamped(to: missionSpeedFloor...missionSpeedCeiling)

        // --- The acceleration corridor.
        //
        // A commanded speed that steps is a commanded acceleration of infinity, and the
        // throttle loop answers a step by going to a stop. That was survivable while every
        // aircraft in the catalogue cruised within a few tens of m/s of every other; it is
        // not survivable for an aircraft whose corridor moves by hundreds of m/s as it
        // climbs, and it is exactly how a supersonic aircraft ends up being *told* to jump
        // the transonic rise rather than accelerate through it.
        //
        // 0.35 g in acceleration and 0.5 g in deceleration: an aircraft can always slow
        // down harder than it can speed up, because drag helps in one direction and fights
        // in the other. These bound the *command*, not the aircraft — an airframe with the
        // thrust to beat them still will, it just will not be asked to.
        let targetSpeed: Float = {
            guard state.hasTargetSpeed else { return desiredSpeed }
            let gravity = AtmosphereModel.gravityMps2
            let up = 0.35 * gravity * input.deltaTime
            let down = 0.50 * gravity * input.deltaTime
            let delta = desiredSpeed - state.previousTargetSpeed
            if delta > 0.0 { return state.previousTargetSpeed + min(delta, up) }
            return state.previousTargetSpeed + max(delta, -down)
        }()
        state.previousTargetSpeed = targetSpeed
        state.hasTargetSpeed = true
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
        // Feed-forward only. Keeping drag compensation in the filter memory pinned power at the
        // ceiling after a turn, invalidating the speed/radius envelope used by route planning.
        let commandedThrottle = (state.filteredThrottle + turnDragBoost)
            .clamped(to: Tuning.throttleHoverSpan)

        let bankDeg = state.filteredBankRad.radiansToDegrees
        let pitchDeg = commandedPitchRad.radiansToDegrees
        let yawDeg = wrapAngle(desiredCourse).radiansToDegrees
        let aimWorld = SIMD3<Float>(aimPointPlanar.x, targetAltitude, aimPointPlanar.y)
        let holdsMeasuredCourse = holdsFinalCourse || holdsRequiredCaptureCourse
        let positionTarget = holdsMeasuredCourse || activeFlyBy != nil
            ? aimWorld
            : SIMD3<Float>(activeWaypoint.position.x, targetAltitude, activeWaypoint.position.y)

        let remainingDistance = holdsFinalCourse
            ? 0.0
            : remainingPathLength(
                plan: plan,
                startIndex: activeIndex,
                aircraft: aircraftPlanar
            )
        let legStartWorld = holdsMeasuredCourse
            ? SIMD3<Float>(aircraftPlanar.x, targetAltitude, aircraftPlanar.y)
            : activeFlyBy.map { SIMD3<Float>($0.entry.x, targetAltitude, $0.entry.y) }
                ?? SIMD3<Float>(legStartPlanar.x, targetAltitude, legStartPlanar.y)
        let legEndWorld = holdsMeasuredCourse
            ? aimWorld
            : activeFlyBy.map { SIMD3<Float>($0.exit.x, targetAltitude, $0.exit.y) }
                ?? SIMD3<Float>(legEndPlanar.x, targetAltitude, legEndPlanar.y)

        let guidanceCrossTrack = holdsRequiredCaptureCourse ? 0.0 : activeFlyBy.map {
            simd_length(aircraftPlanar - $0.center) - $0.radius
        } ?? crossTrack
        let guidanceAlongTrackProgress = {
            if holdsRequiredCaptureCourse {
                return Float(0.0)
            }
            guard let activeFlyBy, let activeFlyByProgress,
                  activeFlyBy.arcLength > 0.01 else {
                return alongTrackProgress
            }
            return (activeFlyByProgress / activeFlyBy.arcLength).clamped(to: 0.0...1.0)
        }()

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
            crossTrackErrorMeters: guidanceCrossTrack,
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
            alongTrackProgress: guidanceAlongTrackProgress,
            remainingPathLengthMeters: remainingDistance,
            stallProtectionActive: stallProtectionActive,
            hasCompletedRoute: state.hasCompletedRoute,
            flyByTransitionActive: activeFlyBy != nil,
            missedActiveWaypoint: state.missedActiveWaypoint,
            capturedRequiredWaypointIndexAwaitingReplan:
                state.requiredCaptureWaypointIndex
        )
    }

    var activeWaypointIndex: Int { state.activeWaypointIndex }
    var hasCompletedRoute: Bool { state.hasCompletedRoute }

    // MARK: - Internals

    /// Keyed on height above the surface — see the note in DroneSimulationViewModel.
    private func effectiveMaximumBankRadians(
        wing: FixedWingParameters,
        targetAltitude: Float,
        currentAltitude: Float,
        heightAboveSurface: Float
    ) -> Float {
        _ = (targetAltitude, currentAltitude)
        let altitudeMarginFactor = (
            max(0.0, heightAboveSurface) / max(wing.initialClimbTargetAltitude, 1.0)
        ).clamped(to: 0.35...1.0)
        return max(0.05, wing.maxBankAngleDeg.degreesToRadians)
            * FixedWingAutopilotLateralTuning.maximumBankScale
            * altitudeMarginFactor
    }

    /// Returns a full-radius fillet or `nil`; the radius is never reduced to make a short leg
    /// appear feasible. Route construction is responsible for replanning a corner that cannot fit.
    private func flyByGeometry(
        plan: FixedWingAutopilotPlan,
        waypointIndex: Int,
        wing: FixedWingParameters,
        airspeed: Float,
        effectiveMaxBankRadians: Float,
        validatedTurnRadius: Float?
    ) -> CommittedFlyBy? {
        guard waypointIndex > 0,
              waypointIndex < plan.waypoints.count - 1,
              plan.waypoints[waypointIndex].capturePolicy == .flyBy else {
            return nil
        }

        let previous = plan.waypoints[waypointIndex - 1].position
        let current = plan.waypoints[waypointIndex].position
        let next = plan.waypoints[waypointIndex + 1].position
        let inbound = current - previous
        let outbound = next - current
        let inboundLength = simd_length(inbound)
        let outboundLength = simd_length(outbound)
        guard inboundLength > 0.05, outboundLength > 0.05 else { return nil }

        let inboundDirection = inbound / inboundLength
        let outboundDirection = outbound / outboundLength
        let dot = simd_dot(inboundDirection, outboundDirection).clamped(to: -1.0...1.0)
        let turnAngle = acos(dot)
        guard turnAngle > Float(4.0).degreesToRadians,
              turnAngle < Tuning.flyByMaximumTurnDeg.degreesToRadians else {
            return nil
        }

        let turnSign = inboundDirection.x * outboundDirection.y
            - inboundDirection.y * outboundDirection.x
        guard abs(turnSign) > 0.001 else { return nil }

        let speed = max(airspeed, wing.minSafeAirspeed)
        let radius = requiredTurnRadius(
            wing: wing,
            airspeed: speed,
            effectiveMaxBankRadians: effectiveMaxBankRadians,
            validatedTurnRadius: validatedTurnRadius
        )
        let tangentDistance = radius * tan(turnAngle * 0.5)
        let triggerDistance = tangentDistance + speed * Tuning.flyByRollInSeconds
        let geometryMargin = max(1.0, plan.waypoints[waypointIndex].acceptanceRadius * 0.25)
        guard tangentDistance.isFinite,
              triggerDistance + geometryMargin <= inboundLength,
              tangentDistance + geometryMargin <= outboundLength else {
            return nil
        }

        let entry = current - inboundDirection * tangentDistance
        let exit = current + outboundDirection * tangentDistance
        let leftNormal = SIMD2<Float>(-inboundDirection.y, inboundDirection.x)
        let center = turnSign > 0.0
            ? entry + leftNormal * radius
            : entry - leftNormal * radius
        let startAngle = atan2(entry.y - center.y, entry.x - center.x)
        let endAngle = atan2(exit.y - center.y, exit.x - center.x)
        var sweepAngle = endAngle - startAngle
        if turnSign > 0.0 {
            while sweepAngle < 0.0 { sweepAngle += .pi * 2.0 }
            while sweepAngle > .pi * 2.0 { sweepAngle -= .pi * 2.0 }
        } else {
            while sweepAngle > 0.0 { sweepAngle -= .pi * 2.0 }
            while sweepAngle < -.pi * 2.0 { sweepAngle += .pi * 2.0 }
        }

        guard entry.x.isFinite, entry.y.isFinite,
              exit.x.isFinite, exit.y.isFinite,
              center.x.isFinite, center.y.isFinite,
              startAngle.isFinite, sweepAngle.isFinite,
              abs(sweepAngle) > 0.01 else {
            return nil
        }

        return CommittedFlyBy(
            waypointIndex: waypointIndex,
            inboundDirection: inboundDirection,
            outboundDirection: outboundDirection,
            entry: entry,
            exit: exit,
            center: center,
            radius: radius,
            startAngle: startAngle,
            sweepAngle: sweepAngle,
            tangentDistance: tangentDistance,
            triggerDistance: triggerDistance
        )
    }

    private func requiredTurnRadius(
        wing: FixedWingParameters,
        airspeed: Float,
        effectiveMaxBankRadians: Float,
        validatedTurnRadius: Float?
    ) -> Float {
        let permittedBank = min(
            max(Float(5.0).degreesToRadians, effectiveMaxBankRadians),
            Tuning.flyByBankLimitDeg.degreesToRadians
        )
        let speed = max(airspeed, wing.minSafeAirspeed)
        let bankLimitedRadius = speed * speed / max(0.1, 9.81 * tan(permittedBank))
        return max(
            wing.waypointAcceptanceRadiusMeters * 1.05,
            wing.minimumTurnRadius(airspeed: speed),
            bankLimitedRadius,
            validatedTurnRadius ?? 0.0
        )
    }

    private func requiresPhysicalFlyBy(
        plan: FixedWingAutopilotPlan,
        waypointIndex: Int
    ) -> Bool {
        guard waypointIndex > 0,
              waypointIndex < plan.waypoints.count - 1,
              plan.waypoints[waypointIndex].capturePolicy == .flyBy else {
            return false
        }
        let inbound = plan.waypoints[waypointIndex].position
            - plan.waypoints[waypointIndex - 1].position
        let outbound = plan.waypoints[waypointIndex + 1].position
            - plan.waypoints[waypointIndex].position
        let inboundLength = simd_length(inbound)
        let outboundLength = simd_length(outbound)
        guard inboundLength > 0.05, outboundLength > 0.05 else {
            return true
        }
        let dot = simd_dot(
            inbound / inboundLength,
            outbound / outboundLength
        ).clamped(to: -1.0...1.0)
        return acos(dot) > Float(4.0).degreesToRadians
    }

    private func flyByProgress(
        aircraftPosition: SIMD2<Float>,
        geometry: CommittedFlyBy
    ) -> Float {
        if simd_dot(aircraftPosition - geometry.entry, geometry.inboundDirection) < 0.0 {
            return 0.0
        }
        if simd_dot(aircraftPosition - geometry.exit, geometry.outboundDirection) > 0.0 {
            return geometry.arcLength
        }

        let currentAngle = atan2(
            aircraftPosition.y - geometry.center.y,
            aircraftPosition.x - geometry.center.x
        )
        var angularProgress = currentAngle - geometry.startAngle
        if geometry.sweepAngle > 0.0 {
            while angularProgress < 0.0 { angularProgress += .pi * 2.0 }
            while angularProgress > .pi * 2.0 { angularProgress -= .pi * 2.0 }
            angularProgress = min(angularProgress, geometry.sweepAngle)
        } else {
            while angularProgress > 0.0 { angularProgress -= .pi * 2.0 }
            while angularProgress < -.pi * 2.0 { angularProgress += .pi * 2.0 }
            angularProgress = max(angularProgress, geometry.sweepAngle)
        }
        return abs(angularProgress) * geometry.radius
    }

    private func flyByAimPoint(
        geometry: CommittedFlyBy,
        progress: Float,
        lookaheadDistance: Float
    ) -> SIMD2<Float> {
        let desiredDistance = max(0.0, progress) + max(1.0, lookaheadDistance)
        if desiredDistance <= geometry.arcLength {
            let fraction = (desiredDistance / max(0.001, geometry.arcLength))
                .clamped(to: 0.0...1.0)
            let angle = geometry.startAngle + geometry.sweepAngle * fraction
            return SIMD2<Float>(
                geometry.center.x + cos(angle) * geometry.radius,
                geometry.center.y + sin(angle) * geometry.radius
            )
        }
        return geometry.exit
            + geometry.outboundDirection * (desiredDistance - geometry.arcLength)
    }

    private func shouldCompleteFlyBy(
        _ geometry: CommittedFlyBy,
        aircraftPosition: SIMD2<Float>,
        aircraftYaw: Float,
        acceptanceRadius: Float
    ) -> Bool {
        let progress = flyByProgress(
            aircraftPosition: aircraftPosition,
            geometry: geometry
        )
        let outboundLocal = aircraftPosition - geometry.exit
        let outboundAlong = simd_dot(outboundLocal, geometry.outboundDirection)
        let outboundNormal = SIMD2<Float>(
            -geometry.outboundDirection.y,
            geometry.outboundDirection.x
        )
        let outboundCrossTrack = abs(simd_dot(outboundLocal, outboundNormal))
        let outboundCourse = courseRadians(direction: geometry.outboundDirection)
        let headingError = abs(shortestAngle(outboundCourse - aircraftYaw))
        let handoffCorridor = max(
            max(4.0, acceptanceRadius) * 1.6,
            geometry.radius * 0.22
        )
        let arcNearlyComplete = progress >= geometry.arcLength * 0.82
        let outboundAcquired = outboundAlong >= -max(4.0, acceptanceRadius)
            && outboundCrossTrack <= handoffCorridor
            && headingError <= Float(18.0).degreesToRadians
        return arcNearlyComplete && outboundAcquired
    }

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
