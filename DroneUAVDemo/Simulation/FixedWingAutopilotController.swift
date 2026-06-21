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
    /// Legacy field — the new autopilot does not require pre-baked geometry,
    /// it derives smooth turns from raw waypoints via carrot pursuit. The
    /// field is retained so existing call sites compile unchanged.
    var flyableRoute: FixedWingFlyableRoute?

    init(
        routeIdentifier: String,
        waypoints: [FixedWingRouteWaypoint],
        minimumWaypointIndex: Int? = nil,
        preferredLoiterCenter: SIMD3<Float>? = nil,
        preferredLoiterRadius: Float? = nil,
        flyableRoute: FixedWingFlyableRoute? = nil
    ) {
        self.routeIdentifier = routeIdentifier
        self.waypoints = waypoints
        self.minimumWaypointIndex = minimumWaypointIndex
        self.preferredLoiterCenter = preferredLoiterCenter
        self.preferredLoiterRadius = preferredLoiterRadius
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
        missionMaxAirspeed: Float? = nil
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
            input: input
        ) else {
            setPhase(.failed, reason: "autopilot_returned_nil")
            return failureOutput(for: context, wing: wing, tracking: tracking)
        }

        // Update phase from result.
        if result.hasCompletedRoute {
            setPhase(.completingMission, reason: "route_completed")
        } else if isLaunchProtected {
            setPhase(.launchClimb, reason: "launch_climbout_active")
        } else if result.distanceToActiveWaypointMeters < max(
            wing.waypointAcceptanceRadiusMeters * 1.6,
            simd_length(SIMD2<Float>(result.legEndWorld.x - result.legStartWorld.x,
                                     result.legEndWorld.z - result.legStartWorld.z)) * 0.18
        ) {
            setPhase(.approachingWaypoint, reason: "near_waypoint")
        } else {
            setPhase(.trackingLeg, reason: "tracking")
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
            missionState: missionState(forPhase: phase, hasCompleted: result.hasCompletedRoute),
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
        let baseAcceptanceRadius = max(wing.waypointAcceptanceRadiusMeters, 4.0)
        let turnAwareAcceptanceRadius = max(
            baseAcceptanceRadius * 1.45,
            min(
                wing.minimumTurnRadius(airspeed: wing.cruiseAirspeed) * 0.85,
                baseAcceptanceRadius * 8.0
            )
        )
        let waypoints: [FixedWingAutopilotWaypoint] = tracking.waypoints
            .filter { isFinite($0.position) }
            .map { wp in
                FixedWingAutopilotWaypoint(
                    position: SIMD2<Float>(wp.position.x, wp.position.z),
                    altitude: wp.position.y.isFinite && wp.position.y > 0.05
                        ? wp.position.y
                        : max(defaultAltitude, 1.0),
                    acceptanceRadius: turnAwareAcceptanceRadius
                )
            }
        let minimumIndex = max(0, tracking.minimumWaypointIndex ?? 0)
        return FixedWingAutopilotPlan(
            routeIdentifier: tracking.routeIdentifier,
            waypoints: waypoints,
            minimumWaypointIndex: min(max(0, minimumIndex - 1), max(0, waypoints.count - 1)),
            loopAfterFinalWaypoint: false
        )
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
            flyableRoute: nil
        )
    }

    private func failureOutput(
        for context: AutopilotTrackingContext,
        wing: FixedWingParameters,
        tracking: FixedWingRouteTrackingContext
    ) -> FixedWingAutopilotOutput {
        let positionTarget = SIMD3<Float>(
            context.state.position.x,
            max(context.targetAltitude, context.state.position.y),
            context.state.position.z
        )
        let command = AutopilotControlCommand(
            positionTarget: positionTarget,
            rollDegrees: 0.0,
            pitchDegrees: 0.0,
            yawDegrees: context.state.orientation.z.radiansToDegrees,
            throttle: 0.5
        )
        let guidance = FixedWingGuidanceOutput(
            desiredThrottle: 0.5,
            desiredRoll: 0.0,
            desiredPitchBias: 0.0,
            desiredHeading: context.state.orientation.z,
            desiredCourse: context.state.orientation.z,
            headingError: 0.0,
            crossTrackError: 0.0,
            alongTrackProgress: 0.0,
            targetAirspeed: wing.cruiseAirspeed,
            targetAltitude: context.targetAltitude
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
        if let nextMissionIndex = tracking.waypoints[autopilotIndex...].compactMap(\.missionWaypointIndex).first {
            return nextMissionIndex
        }
        if let previousMissionIndex = tracking.waypoints[...autopilotIndex].compactMap(\.missionWaypointIndex).last {
            return previousMissionIndex
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
}
