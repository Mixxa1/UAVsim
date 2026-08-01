import Foundation
import simd

/// Identifier reserved for the synthetic "current aircraft position" first
/// waypoint that the ViewModel pushes onto the runtime route.
let fixedWingRuntimeRouteStartIdentifier = "fixed-wing-runtime-route-start"

// MARK: - Public surface (preserved for ViewModel/UI binding)

enum FixedWingAutopilotPhase: String, Equatable {
    case idle
    case launchClimb
    case trackingLeg
    case approachingWaypoint
    case completingMission
    case failed
}

enum FixedWingLaunchPhase: String, Equatable {
    case onRail
    case launchImpulse
    case railRelease
    case initialClimb
    case missionJoin
}

struct FixedWingRouteWaypoint: Equatable {
    var position: SIMD3<Float>
    var missionWaypointIndex: Int?
    var waypointIdentifier: String?
}

struct FixedWingRouteTrackingContext: Equatable {
    var routeIdentifier: String
    var waypoints: [FixedWingRouteWaypoint]
    var minimumWaypointIndex: Int?
    var preferredLoiterCenter: SIMD3<Float>?
    var preferredLoiterRadius: Float?
    /// Set only after route construction checked every intermediate turn using the full vehicle
    /// envelope and the live fixed-wing manoeuvre radius.
    var turnsValidated: Bool
    var validatedTurnRadiusMeters: Float?
    var validatedAirspeedMps: Float?
    /// Legacy preview geometry. Runtime guidance builds a full-radius fillet
    /// from the same validated waypoints and current bank authority so stale
    /// pre-baked radii cannot make a corner look flyable.
    var flyableRoute: FixedWingFlyableRoute?

    init(
        routeIdentifier: String,
        waypoints: [FixedWingRouteWaypoint],
        minimumWaypointIndex: Int? = nil,
        preferredLoiterCenter: SIMD3<Float>? = nil,
        preferredLoiterRadius: Float? = nil,
        turnsValidated: Bool = false,
        validatedTurnRadiusMeters: Float? = nil,
        validatedAirspeedMps: Float? = nil,
        flyableRoute: FixedWingFlyableRoute? = nil
    ) {
        self.routeIdentifier = routeIdentifier
        self.waypoints = waypoints
        self.minimumWaypointIndex = minimumWaypointIndex
        self.preferredLoiterCenter = preferredLoiterCenter
        self.preferredLoiterRadius = preferredLoiterRadius
        self.turnsValidated = turnsValidated
        self.validatedTurnRadiusMeters = validatedTurnRadiusMeters
        self.validatedAirspeedMps = validatedAirspeedMps
        self.flyableRoute = flyableRoute
    }
}

struct FixedWingGuidanceOutput: Equatable {
    var desiredThrottle: Float
    var desiredRoll: Float
    var desiredPitchBias: Float
    var desiredHeading: Float
    var desiredCourse: Float
    var headingError: Float
    var crossTrackError: Float
    var alongTrackProgress: Float
    var targetAirspeed: Float
    var targetAltitude: Float
}

struct FixedWingAutopilotDebugState: Equatable {
    enum MissionState: String, Equatable {
        case idle
        case aligningToLaunch
        case climbout
        case capturingLeg          // legacy: kept so safety/progress checks compile
        case trackingLeg
        case flyByTurn             // legacy: kept so safety/progress checks compile
        case loitering
        case completed
        case recoveringSpeed
        case failed
    }

    var routeIdentifier: String?
    var missionState: MissionState
    var activeSegmentIndex: Int
    var currentWaypointIndex: Int
    var legStart: SIMD3<Float>
    var legEnd: SIMD3<Float>
    var legDirection: SIMD2<Float>
    var waypointVector: SIMD2<Float>
    var crossTrackError: Float
    var alongTrackProgress: Float
    var remainingDistance: Float
    var headingDeg: Float
    var groundTrackDeg: Float
    var commandedRollDeg: Float
    var commandedPitchDeg: Float
    var commandedThrottle: Float
    var targetAirspeed: Float
    var targetAltitude: Float
    var desiredCourseDeg: Float
    var speedRecoveryActive: Bool

    static let idle = FixedWingAutopilotDebugState(
        routeIdentifier: nil,
        missionState: .idle,
        activeSegmentIndex: 0,
        currentWaypointIndex: 0,
        legStart: .zero,
        legEnd: .zero,
        legDirection: .zero,
        waypointVector: .zero,
        crossTrackError: 0.0,
        alongTrackProgress: 0.0,
        remainingDistance: 0.0,
        headingDeg: 0.0,
        groundTrackDeg: 0.0,
        commandedRollDeg: 0.0,
        commandedPitchDeg: 0.0,
        commandedThrottle: 0.0,
        targetAirspeed: 0.0,
        targetAltitude: 0.0,
        desiredCourseDeg: 0.0,
        speedRecoveryActive: false
    )
}

struct FixedWingAutopilotOutput: Equatable {
    var command: AutopilotControlCommand
    var guidance: FixedWingGuidanceOutput
    var phase: FixedWingAutopilotPhase
    var launchPhase: FixedWingLaunchPhase?
    var transitionReason: String?
    var debugState: FixedWingAutopilotDebugState
    var hasCompletedRoute: Bool
}

// MARK: - Controller

/// Adapter around `FixedWingAutopilot`. Owns the launch state machine and
/// translates between the legacy ViewModel-facing types
/// (`FixedWingRouteTrackingContext`, `AutopilotTrackingContext`) and the new
/// minimal autopilot inputs.
final class FixedWingAutopilotController {
    private(set) var phase: FixedWingAutopilotPhase = .idle
    private(set) var launchPhase: FixedWingLaunchPhase?
    private(set) var lastTransitionReason: String?
    private(set) var debugState: FixedWingAutopilotDebugState = .idle

    private let autopilot = FixedWingAutopilot()
    private var launchPhaseElapsed: Float = 0.0
    private var lastRouteIdentifier: String?

    func reset() {
        phase = .idle
        launchPhase = nil
        lastTransitionReason = nil
        debugState = .idle
        launchPhaseElapsed = 0.0
        lastRouteIdentifier = nil
        autopilot.reset()
    }

    func beginLaunch() {
        launchPhase = .onRail
        launchPhaseElapsed = 0.0
        setPhase(.launchClimb, reason: "launch_sequence_started")
    }

    func trackingCommand(
        for context: AutopilotTrackingContext,
        parameters wing: FixedWingParameters,
        launchMode: LaunchMode,
        launchAsset: LaunchAsset?,
        routeTracking: FixedWingRouteTrackingContext? = nil,
        missionMinAirspeed: Float? = nil,
        missionMaxAirspeed: Float? = nil,
        useHybridVTOLCruiseStabilization: Bool = false
    ) -> FixedWingAutopilotOutput {
        let airspeed = max(
            context.state.forwardAirspeed,
            simd_length(SIMD2<Float>(context.state.velocity.x, context.state.velocity.z)),
            context.physicalState.isGroundRestState ? 0.0 : wing.minSafeAirspeed * 0.62
        )

        let tracking = routeTracking ?? syntheticRouteTracking(
            state: context.state,
            target: context.target,
            altitude: context.targetAltitude
        )

        updateLaunchPhase(
            context: context,
            wing: wing,
            launchMode: launchMode,
            airspeed: airspeed
        )

        if tracking.routeIdentifier != lastRouteIdentifier {
            lastRouteIdentifier = tracking.routeIdentifier
        }

        let plan = makePlan(from: tracking, defaultAltitude: context.targetAltitude, wing: wing)
        guard !plan.waypoints.isEmpty else {
            setPhase(.failed, reason: "empty_route")
            return failureOutput(for: context, wing: wing, tracking: tracking)
        }

        // During the initial seconds after launch, suppress aggressive
        // course commands so the airplane has time to climb out.
        let isLaunchProtected = isLaunchProtected(launchPhase)
        let cruiseOverride: Float? = isLaunchProtected ? wing.climbAirspeed : nil
        let altitudeFloor: Float? = isLaunchProtected
            ? max(context.targetAltitude, context.state.position.y + 4.0)
            : nil
        // Mission speed bounds don't apply during the protected climb-out —
        // that phase already has its own dedicated safe climb speed, which a
        // mission-configured cap shouldn't be able to override.
        let missionMinAirspeedActive: Float? = isLaunchProtected ? nil : missionMinAirspeed
        let missionMaxAirspeedActive: Float? = isLaunchProtected ? nil : missionMaxAirspeed

        let input = FixedWingAutopilotInput(
            aircraftPosition: context.state.position,
            aircraftVelocity: context.state.velocity,
            aircraftYawRadians: context.state.orientation.z,
            aircraftPitchRadians: context.state.orientation.y,
            aircraftRollRadians: context.state.orientation.x,
            aircraftAirspeed: airspeed,
            deltaTime: max(0.001, context.deltaTime)
        )

        guard let result = autopilot.update(
            plan: plan,
            wing: wing,
            cruiseAirspeedOverride: cruiseOverride,
            targetAltitudeOverride: altitudeFloor,
            missionMinAirspeed: missionMinAirspeedActive,
            missionMaxAirspeed: missionMaxAirspeedActive,
            useHybridVTOLCruiseStabilization: useHybridVTOLCruiseStabilization,
            input: input
        ) else {
            let reason = autopilot.lastFailureReason ?? "autopilot_returned_nil"
            setPhase(.failed, reason: reason)
            // `setPhase` intentionally suppresses duplicate phase transitions, but the reason can
            // change while already failed (for example timeout -> missed turn entry).
            lastTransitionReason = reason
            return failureOutput(for: context, wing: wing, tracking: tracking)
        }

        // Update phase from result.
        if result.hasCompletedRoute {
            setPhase(.completingMission, reason: "route_completed")
        } else if isLaunchProtected {
            setPhase(.launchClimb, reason: "launch_climbout_active")
        } else if result.flyByTransitionActive {
            setPhase(.approachingWaypoint, reason: "fly_by_turn")
        } else if result.distanceToActiveWaypointMeters < max(
            wing.waypointAcceptanceRadiusMeters * 1.6,
            simd_length(SIMD2<Float>(result.legEndWorld.x - result.legStartWorld.x,
                                     result.legEndWorld.z - result.legStartWorld.z)) * 0.18
        ) {
            setPhase(.approachingWaypoint, reason: "near_waypoint")
        } else {
            setPhase(.trackingLeg, reason: "tracking")
        }

        // Surface a genuine miss (set AFTER setPhase, which overwrites the
        // transition reason). The waypoint remains active and guidance turns
        // back to reacquire its sphere.
        if result.missedActiveWaypoint {
            lastTransitionReason = "waypoint_missed_reacquiring"
        }

        let command = AutopilotControlCommand(
            positionTarget: result.positionTarget,
            rollDegrees: result.rollDegrees,
            pitchDegrees: result.pitchDegrees,
            yawDegrees: result.yawDegrees,
            throttle: result.throttle
        )

        let guidance = FixedWingGuidanceOutput(
            desiredThrottle: result.commandedThrottle,
            desiredRoll: result.commandedBankDegrees.degreesToRadians,
            desiredPitchBias: result.commandedPitchDegrees.degreesToRadians,
            desiredHeading: result.desiredCourseDegrees.degreesToRadians,
            desiredCourse: result.desiredCourseDegrees.degreesToRadians,
            headingError: result.courseErrorDegrees.degreesToRadians,
            crossTrackError: result.crossTrackErrorMeters,
            alongTrackProgress: result.alongTrackProgress,
            targetAirspeed: result.targetAirspeedMpsActive,
            targetAltitude: result.targetAltitudeMeters
        )

        let missionWaypointIndex = trackingMissionWaypointIndex(
            tracking: tracking,
            autopilotIndex: result.activeWaypointIndex
        )

        let legDirection = SIMD2<Float>(
            result.legEndWorld.x - result.legStartWorld.x,
            result.legEndWorld.z - result.legStartWorld.z
        )
        let legLength = simd_length(legDirection)
        let legDirectionNormalized = legLength > 0.001 ? legDirection / legLength : SIMD2<Float>.zero

        let updatedDebug = FixedWingAutopilotDebugState(
            routeIdentifier: tracking.routeIdentifier,
            missionState: result.flyByTransitionActive
                ? .flyByTurn
                : missionState(forPhase: phase, hasCompleted: result.hasCompletedRoute),
            activeSegmentIndex: result.activeWaypointIndex,
            currentWaypointIndex: missionWaypointIndex,
            legStart: result.legStartWorld,
            legEnd: result.legEndWorld,
            legDirection: legDirectionNormalized,
            waypointVector: SIMD2<Float>(
                result.legEndWorld.x - context.state.position.x,
                result.legEndWorld.z - context.state.position.z
            ),
            crossTrackError: result.crossTrackErrorMeters,
            alongTrackProgress: result.alongTrackProgress,
            remainingDistance: result.remainingPathLengthMeters,
            headingDeg: result.headingDegrees,
            groundTrackDeg: result.headingDegrees,
            commandedRollDeg: result.commandedBankDegrees,
            commandedPitchDeg: result.commandedPitchDegrees,
            commandedThrottle: result.commandedThrottle,
            targetAirspeed: result.targetAirspeedMpsActive,
            targetAltitude: result.targetAltitudeMeters,
            desiredCourseDeg: result.desiredCourseDegrees,
            speedRecoveryActive: result.stallProtectionActive
        )
        debugState = updatedDebug

        return FixedWingAutopilotOutput(
            command: command,
            guidance: guidance,
            phase: phase,
            launchPhase: launchPhase,
            transitionReason: lastTransitionReason,
            debugState: updatedDebug,
            hasCompletedRoute: result.hasCompletedRoute
        )
    }

    // MARK: - Internals

    private func setPhase(_ next: FixedWingAutopilotPhase, reason: String) {
        guard phase != next else {
            return
        }
        phase = next
        lastTransitionReason = reason
    }

    private func updateLaunchPhase(
        context: AutopilotTrackingContext,
        wing: FixedWingParameters,
        launchMode: LaunchMode,
        airspeed: Float
    ) {
        guard launchPhase != nil else {
            return
        }
        launchPhaseElapsed += max(0.0, context.deltaTime)
        let altitudeAboveStart = max(0.0, context.state.position.y)

        switch launchPhase {
        case .onRail:
            // Skip the catapult/rail wait for non-standard launches; for a
            // hand throw / runway start we simply move to launchImpulse so the
            // autopilot can start producing commands immediately.
            launchPhase = .launchImpulse
        case .launchImpulse:
            if airspeed >= wing.takeoffRotationSpeed * 0.6 {
                launchPhase = .railRelease
            }
        case .railRelease:
            if altitudeAboveStart >= 1.5 || airspeed >= wing.takeoffRotationSpeed {
                launchPhase = .initialClimb
            }
        case .initialClimb:
            let climbDone = altitudeAboveStart >= max(8.0, wing.initialClimbTargetAltitude * 0.6)
                || launchPhaseElapsed > 6.0
            if climbDone {
                launchPhase = .missionJoin
            }
        case .missionJoin:
            if altitudeAboveStart >= wing.initialClimbTargetAltitude || launchPhaseElapsed > 9.0 {
                launchPhase = nil
                launchPhaseElapsed = 0.0
            }
        case .none:
            break
        }
    }

    private func isLaunchProtected(_ phase: FixedWingLaunchPhase?) -> Bool {
        switch phase {
        case .onRail, .launchImpulse, .railRelease, .initialClimb:
            return true
        case .missionJoin, .none:
            return false
        }
    }

    private func makePlan(
        from tracking: FixedWingRouteTrackingContext,
        defaultAltitude: Float,
        wing: FixedWingParameters
    ) -> FixedWingAutopilotPlan {
        let routeWaypoints = tracking.waypoints
            .filter { isFinite($0.position) }
        let baseCaptureRadius = wing.waypointCaptureRadius(airspeed: wing.cruiseAirspeed)
        let waypoints: [FixedWingAutopilotWaypoint] = routeWaypoints
            .enumerated()
            .map { index, wp in
                FixedWingAutopilotWaypoint(
                    position: SIMD2<Float>(wp.position.x, wp.position.z),
                    altitude: wp.position.y.isFinite && wp.position.y > 0.05
                        ? wp.position.y
                        : max(defaultAltitude, 1.0),
                    acceptanceRadius: waypointAcceptanceRadius(
                        for: index,
                        routeWaypoints: routeWaypoints,
                        baseRadius: baseCaptureRadius,
                        wing: wing
                    ),
                    // Conventional fixed-wing mission points are fly-by anchors. The final point
                    // alone is a terminal capture; payload/mission progress is reported only after
                    // the validated arc has acquired its outbound leg.
                    capturePolicy: index == routeWaypoints.count - 1 ? .required : .flyBy
                )
            }
        let minimumIndex = max(0, tracking.minimumWaypointIndex ?? 0)
        return FixedWingAutopilotPlan(
            // The safety envelope is data, not route identity. Changing its radius must not reset
            // active waypoint progress to the latched runtime start; the follower separately
            // rejects a committed arc if the live envelope worsens.
            routeIdentifier: tracking.routeIdentifier,
            waypoints: waypoints,
            minimumWaypointIndex: min(max(0, minimumIndex - 1), max(0, waypoints.count - 1)),
            turnsValidated: tracking.turnsValidated,
            validatedTurnRadiusMeters: tracking.validatedTurnRadiusMeters,
            validatedAirspeedMps: tracking.validatedAirspeedMps,
            loopAfterFinalWaypoint: false
        )
    }

    private func waypointAcceptanceRadius(
        for index: Int,
        routeWaypoints: [FixedWingRouteWaypoint],
        baseRadius: Float,
        wing: FixedWingParameters
    ) -> Float {
        switch wing.family {
        case .surveyEVTOL:
            break
        case .tailsitterVTOL:
            return baseRadius
        default:
            return baseRadius
        }

        guard routeWaypoints.indices.contains(index) else {
            return baseRadius
        }

        let current = SIMD2<Float>(
            routeWaypoints[index].position.x,
            routeWaypoints[index].position.z
        )
        var nearestSpacing = Float.greatestFiniteMagnitude
        if index > 0 {
            let previous = SIMD2<Float>(
                routeWaypoints[index - 1].position.x,
                routeWaypoints[index - 1].position.z
            )
            nearestSpacing = min(nearestSpacing, simd_distance(current, previous))
        }
        if index + 1 < routeWaypoints.count {
            let next = SIMD2<Float>(
                routeWaypoints[index + 1].position.x,
                routeWaypoints[index + 1].position.z
            )
            nearestSpacing = min(nearestSpacing, simd_distance(current, next))
        }
        guard nearestSpacing.isFinite else {
            return baseRadius
        }

        let spacingCap = max(
            wing.waypointAcceptanceRadiusMeters * 0.72,
            nearestSpacing * 0.34
        )
        return min(baseRadius, max(5.0, spacingCap))
    }

    private func syntheticRouteTracking(
        state: DroneState,
        target: SIMD3<Float>,
        altitude: Float
    ) -> FixedWingRouteTrackingContext {
        let routeId = "fixed_wing_synthetic_\(Int(target.x * 10))_\(Int(target.z * 10))_\(Int(altitude * 10))"
        let safeAltitude = max(altitude, state.position.y, 1.0)
        let start = FixedWingRouteWaypoint(
            position: SIMD3<Float>(state.position.x, safeAltitude, state.position.z),
            missionWaypointIndex: nil,
            waypointIdentifier: fixedWingRuntimeRouteStartIdentifier
        )
        let end = FixedWingRouteWaypoint(
            position: SIMD3<Float>(target.x, safeAltitude, target.z),
            missionWaypointIndex: 0,
            waypointIdentifier: nil
        )
        return FixedWingRouteTrackingContext(
            routeIdentifier: routeId,
            waypoints: [start, end],
            minimumWaypointIndex: 1,
            preferredLoiterCenter: target,
            preferredLoiterRadius: nil,
            turnsValidated: true,
            flyableRoute: nil
        )
    }

    private func failureOutput(
        for context: AutopilotTrackingContext,
        wing: FixedWingParameters,
        tracking: FixedWingRouteTrackingContext
    ) -> FixedWingAutopilotOutput {
        let safeAltitude = max(
            context.targetAltitude,
            context.state.position.y + min(10.0, wing.initialClimbTargetAltitude * 0.35)
        )
        let positionTarget = SIMD3<Float>(
            context.state.position.x,
            safeAltitude,
            context.state.position.z
        )
        let safePitch = min(wing.maxPitchUpDeg, max(6.0, wing.initialClimbPitchDeg))
        let safeThrottle = max(
            context.flightBaseline.takeoffThrottleReference,
            context.flightBaseline.cruiseReferenceThrottle,
            wing.maxThrottle * 0.82
        ).clamped(to: wing.minThrottle...wing.maxThrottle)
        let command = AutopilotControlCommand(
            positionTarget: positionTarget,
            rollDegrees: 0.0,
            pitchDegrees: safePitch,
            yawDegrees: context.state.orientation.z.radiansToDegrees,
            throttle: safeThrottle
        )
        let guidance = FixedWingGuidanceOutput(
            desiredThrottle: safeThrottle,
            desiredRoll: 0.0,
            desiredPitchBias: safePitch.degreesToRadians,
            desiredHeading: context.state.orientation.z,
            desiredCourse: context.state.orientation.z,
            headingError: 0.0,
            crossTrackError: 0.0,
            alongTrackProgress: 0.0,
            targetAirspeed: wing.cruiseAirspeed,
            targetAltitude: safeAltitude
        )
        var fallbackDebug = FixedWingAutopilotDebugState.idle
        fallbackDebug.routeIdentifier = tracking.routeIdentifier
        fallbackDebug.missionState = .failed
        return FixedWingAutopilotOutput(
            command: command,
            guidance: guidance,
            phase: phase,
            launchPhase: launchPhase,
            transitionReason: lastTransitionReason ?? "fallback_no_route",
            debugState: fallbackDebug,
            hasCompletedRoute: false
        )
    }

    private func missionState(
        forPhase phase: FixedWingAutopilotPhase,
        hasCompleted: Bool
    ) -> FixedWingAutopilotDebugState.MissionState {
        if hasCompleted { return .completed }
        switch phase {
        case .idle: return .idle
        case .launchClimb: return .climbout
        case .trackingLeg, .approachingWaypoint: return .trackingLeg
        case .completingMission: return .completed
        case .failed: return .failed
        }
    }

    private func trackingMissionWaypointIndex(
        tracking: FixedWingRouteTrackingContext,
        autopilotIndex: Int
    ) -> Int {
        guard tracking.waypoints.indices.contains(autopilotIndex) else {
            return autopilotIndex
        }
        if let missionIndex = tracking.waypoints[autopilotIndex].missionWaypointIndex {
            return missionIndex
        }
        if let previousMissionIndex = tracking.waypoints[...autopilotIndex].compactMap(\.missionWaypointIndex).last {
            return previousMissionIndex
        }
        if let nextMissionIndex = tracking.waypoints[autopilotIndex...].compactMap(\.missionWaypointIndex).first {
            return nextMissionIndex
        }
        return autopilotIndex
    }

    private func isFinite(_ v: SIMD3<Float>) -> Bool {
        v.x.isFinite && v.y.isFinite && v.z.isFinite
    }
}

private extension Float {
    var degreesToRadians: Float { self * .pi / 180.0 }
    var radiansToDegrees: Float { self * 180.0 / .pi }
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(range.upperBound, max(range.lowerBound, self))
    }
}

struct FixedWingLaunchRuntimeSnapshot: Equatable {
    let mode: LaunchMode
    let state: LaunchState
    let railProgress: Float
    let longitudinalAirspeedMps: Float
    let altitudeAboveLaunchMeters: Float
    let transitionReason: String?
    let dynamics: FixedWingLaunchDynamics?

    static let idle = FixedWingLaunchRuntimeSnapshot(
        mode: .standard,
        state: .idle,
        railProgress: 0.0,
        longitudinalAirspeedMps: 0.0,
        altitudeAboveLaunchMeters: 0.0,
        transitionReason: nil,
        dynamics: nil
    )

    var isReleased: Bool {
        switch state {
        case .rotation, .initialClimb, .transitionToFlight, .completed, .aborted:
            return true
        case .idle, .prelaunchCheck, .aligning, .launchCommit, .assistedAcceleration:
            return false
        }
    }
}

/// Authoritative launch state machine. It owns staging, rail/throw release,
/// AGL-relative climb transitions and abort timing. The route autopilot is
/// deliberately kept out of the held/rail phases and is only engaged after
/// physical release.
final class FixedWingLaunchController {
    private struct Configuration {
        let launchID: UUID
        let mode: LaunchMode
        let origin: SIMD3<Float>
        let direction: SIMD3<Float>
        let worldYawRadians: Float
        let pitchRadians: Float
        let travelLengthMeters: Float
        let releaseSpeedMps: Float
        let maximumAccelerationMps2: Float
        let nominalLaunchMassKg: Float
        let preSpoolSeconds: Float
        let minSafeAirspeedMps: Float
        let initialClimbAltitudeMeters: Float
    }

    private var configuration: Configuration?
    private var state: LaunchState = .idle
    private var phaseElapsed: Float = 0.0
    private var totalElapsed: Float = 0.0
    private var transitionReason: String?

    var isActive: Bool {
        configuration != nil && state != .idle && state != .completed && state != .aborted
    }

    func reset() {
        configuration = nil
        state = .idle
        phaseElapsed = 0.0
        totalElapsed = 0.0
        transitionReason = nil
    }

    @discardableResult
    func begin(
        mode: LaunchMode,
        asset: LaunchAsset,
        origin: SIMD3<Float>,
        wing: FixedWingParameters,
        nominalLaunchMassKg: Float
    ) -> Bool {
        let direction: SIMD3<Float>
        let yaw: Float
        let pitch: Float
        let travelLength: Float
        let releaseSpeed: Float
        let launchID: UUID

        switch (mode, asset) {
        case (.handLaunch, .handLaunch(let hand)):
            direction = hand.direction3D
            yaw = hand.worldYawRadians
            pitch = hand.launchAngleDegrees.degreesToRadians
            travelLength = 0.0
            releaseSpeed = wing.handThrowSpeed
            launchID = hand.id
        case (.catapult, .catapult(let catapult)):
            direction = catapult.rail.direction3D
            yaw = catapult.rail.worldYawRadians
            pitch = catapult.rail.railAngleDegrees.degreesToRadians
            travelLength = max(0.5, catapult.rail.railLengthMeters)
            releaseSpeed = wing.catapultExitSpeed
            launchID = catapult.id
        default:
            reset()
            state = .aborted
            transitionReason = "launch_asset_mode_mismatch"
            return false
        }

        guard origin.x.isFinite, origin.y.isFinite, origin.z.isFinite,
              simd_length(direction).isFinite, simd_length(direction) > 0.5,
              releaseSpeed.isFinite, releaseSpeed > 0.5 else {
            reset()
            state = .aborted
            transitionReason = "launch_geometry_invalid"
            return false
        }

        configuration = Configuration(
            launchID: launchID,
            mode: mode,
            origin: origin,
            direction: simd_normalize(direction),
            worldYawRadians: yaw,
            pitchRadians: pitch,
            travelLengthMeters: travelLength,
            releaseSpeedMps: releaseSpeed,
            maximumAccelerationMps2: wing.maxCatapultAccelerationG * 9.81,
            nominalLaunchMassKg: max(0.2, nominalLaunchMassKg),
            preSpoolSeconds: wing.launchPreSpoolSeconds,
            minSafeAirspeedMps: wing.minSafeAirspeed,
            initialClimbAltitudeMeters: wing.initialClimbTargetAltitude
        )
        state = .prelaunchCheck
        phaseElapsed = 0.0
        totalElapsed = 0.0
        transitionReason = "launch_preflight_started"
        return true
    }

    func update(
        aircraftState: DroneState,
        windVector: SIMD3<Float>,
        isArmed: Bool,
        batteryAvailable: Bool,
        deltaTime: Float
    ) -> FixedWingLaunchRuntimeSnapshot {
        guard let configuration else {
            return state == .aborted
                ? FixedWingLaunchRuntimeSnapshot(
                    mode: .standard,
                    state: .aborted,
                    railProgress: 0.0,
                    longitudinalAirspeedMps: 0.0,
                    altitudeAboveLaunchMeters: 0.0,
                    transitionReason: transitionReason,
                    dynamics: nil
                )
                : .idle
        }

        let dt = max(0.0, min(deltaTime, 0.1))
        if state != .completed && state != .aborted {
            phaseElapsed += dt
            totalElapsed += dt
        }

        let relativeAirVelocity = aircraftState.velocity - windVector
        let longitudinalAirspeed = max(0.0, simd_dot(relativeAirVelocity, configuration.direction))
        let altitudeAboveLaunch = max(0.0, aircraftState.position.y - configuration.origin.y)
        let railProgress: Float = configuration.travelLengthMeters > 0.05
            ? (simd_dot(aircraftState.position - configuration.origin, configuration.direction) /
                configuration.travelLengthMeters).clamped(to: 0.0...1.0)
            : (isReleasedState(state) ? 1.0 : 0.0)

        if !isArmed || !batteryAvailable || aircraftState.physicalState == .crashed {
            transition(to: .aborted, reason: "launch_preflight_runtime_failure")
        } else {
            advance(
                railProgress: railProgress,
                longitudinalAirspeed: longitudinalAirspeed,
                altitudeAboveLaunch: altitudeAboveLaunch,
                configuration: configuration
            )
        }

        return FixedWingLaunchRuntimeSnapshot(
            mode: configuration.mode,
            state: state,
            railProgress: state == .assistedAcceleration && configuration.mode == .handLaunch
                ? min(1.0, phaseElapsed / 0.035)
                : railProgress,
            longitudinalAirspeedMps: longitudinalAirspeed,
            altitudeAboveLaunchMeters: altitudeAboveLaunch,
            transitionReason: transitionReason,
            dynamics: dynamics(for: configuration)
        )
    }

    private func advance(
        railProgress: Float,
        longitudinalAirspeed: Float,
        altitudeAboveLaunch: Float,
        configuration: Configuration
    ) {
        switch state {
        case .idle, .completed, .aborted:
            return
        case .prelaunchCheck:
            if phaseElapsed >= max(0.12, configuration.preSpoolSeconds * 0.45) {
                transition(to: .aligning, reason: "launch_alignment_started")
            }
        case .aligning:
            if phaseElapsed >= max(0.10, configuration.preSpoolSeconds * 0.55) {
                transition(to: .launchCommit, reason: "launch_alignment_complete")
            }
        case .launchCommit:
            if phaseElapsed >= 0.10 {
                transition(to: .assistedAcceleration, reason: configuration.mode == .catapult
                    ? "catapult_carriage_released"
                    : "hand_throw_released")
            }
        case .assistedAcceleration:
            if configuration.mode == .catapult {
                if railProgress >= 0.995 {
                    transition(to: .rotation, reason: "catapult_rail_end_reached")
                } else if phaseElapsed > 3.5 {
                    transition(to: .aborted, reason: "catapult_acceleration_timeout")
                }
            } else if phaseElapsed >= 0.035 {
                transition(to: .rotation, reason: "hand_throw_impulse_complete")
            }
        case .rotation:
            let energyReady = longitudinalAirspeed >= configuration.minSafeAirspeedMps * 0.82
            if energyReady || altitudeAboveLaunch >= 0.65 || phaseElapsed > 2.0 {
                transition(to: .initialClimb, reason: energyReady
                    ? "launch_energy_recovered"
                    : "launch_climb_control_engaged")
            }
        case .initialClimb:
            let altitudeReady = altitudeAboveLaunch >= configuration.initialClimbAltitudeMeters * 0.60
            let speedReady = longitudinalAirspeed >= configuration.minSafeAirspeedMps * 0.90
            if altitudeReady && speedReady {
                transition(to: .transitionToFlight, reason: "protected_climb_complete")
            } else if phaseElapsed > 7.0 {
                transition(to: .transitionToFlight, reason: "protected_climb_timeout_handoff")
            }
        case .transitionToFlight:
            let altitudeReady = altitudeAboveLaunch >= configuration.initialClimbAltitudeMeters * 0.90
            let speedReady = longitudinalAirspeed >= configuration.minSafeAirspeedMps * 0.92
            // The elapsed-time handoff needs a floor under it.
            //
            // This is the transition that actually ends a launch — the view model's own
            // completion check never runs, because by then the mode is no longer `.takeoff`.
            // Unqualified, the four-second branch handed the aircraft over at **1.8 m** on a hand
            // launch and **3.6 m** off the catapult, both times still descending, and both times
            // the wing was in the field a second later. Timing out is a reasonable way to stop
            // waiting; it is not a reason to declare an aircraft flying. Height above the launch
            // point is the cheapest honest test available here, and the global 16 s backstop
            // below still resolves a launch that never gets there.
            let safeHandoffAltitude = max(6.0, configuration.initialClimbAltitudeMeters * 0.35)
            if altitudeReady && speedReady {
                transition(to: .completed, reason: "launch_sequence_completed")
            } else if phaseElapsed > 4.0, altitudeAboveLaunch >= safeHandoffAltitude {
                transition(to: .completed, reason: "launch_sequence_handoff_timeout")
            }
        }

        if totalElapsed > 16.0,
           state != .completed,
           state != .aborted {
            if isReleasedState(state) {
                transition(to: .completed, reason: "launch_global_handoff_timeout")
            } else {
                transition(to: .aborted, reason: "launch_global_timeout")
            }
        }
    }

    private func dynamics(
        for configuration: Configuration
    ) -> FixedWingLaunchDynamics? {
        let phase: FixedWingLaunchDynamicsPhase
        switch state {
        case .prelaunchCheck, .aligning, .launchCommit:
            phase = .held
        case .assistedAcceleration:
            phase = configuration.mode == .catapult ? .catapultRail : .handRelease
        case .idle, .rotation, .initialClimb, .transitionToFlight, .completed, .aborted:
            return nil
        }

        return FixedWingLaunchDynamics(
            launchID: configuration.launchID,
            mode: configuration.mode,
            phase: phase,
            origin: configuration.origin,
            direction: configuration.direction,
            worldYawRadians: configuration.worldYawRadians,
            pitchRadians: configuration.pitchRadians,
            travelLengthMeters: configuration.travelLengthMeters,
            targetReleaseSpeedMps: configuration.releaseSpeedMps,
            maximumAccelerationMps2: configuration.maximumAccelerationMps2,
            nominalLaunchMassKg: configuration.nominalLaunchMassKg
        )
    }

    private func transition(to next: LaunchState, reason: String) {
        guard state != next else {
            return
        }
        state = next
        phaseElapsed = 0.0
        transitionReason = reason
    }

    private func isReleasedState(_ state: LaunchState) -> Bool {
        switch state {
        case .rotation, .initialClimb, .transitionToFlight, .completed, .aborted:
            return true
        case .idle, .prelaunchCheck, .aligning, .launchCommit, .assistedAcceleration:
            return false
        }
    }
}
