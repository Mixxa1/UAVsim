import Foundation
import simd

let fixedWingRuntimeRouteStartIdentifier = "fixed-wing-runtime-route-start"

enum FixedWingAutopilotPhase: String, Equatable {
    case idle
    case aligningToLeg
    case turnEntry
    case turningArc
    case interceptingLeg
    case trackingLeg
    case approachingWaypoint
    case completingMission
    case returnHome
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
    /// Optional explicit flyable route (line + arc primitives). When provided,
    /// the autopilot follows the primitives directly instead of reconstructing
    /// fly-by turns from raw polyline waypoints.
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
        case capturingLeg
        case trackingLeg
        case flyByTurn
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

final class FixedWingAutopilotController {
    private enum FixedWingCompletionMode: Equatable {
        case hold
        case loiter(center: SIMD3<Float>, radius: Float, clockwise: Bool)
    }

    private struct MissionReference {
        var routeIdentifier: String
        var completionMode: FixedWingCompletionMode
        var missionState: FixedWingAutopilotDebugState.MissionState
        var activeSegmentIndex: Int
        var activeWaypointIndex: Int
        var activeWaypointPosition: SIMD3<Float>
        var legStart: SIMD3<Float>
        var legEnd: SIMD3<Float>
        var nextLegEnd: SIMD3<Float>?
        var legDirectionXZ: SIMD2<Float>
        var legLength: Float
        var crossTrackError: Float
        var alongTrackDistance: Float
        var alongTrackProgress: Float
        var remainingDistance: Float
        var desiredAltitude: Float
        var currentCourse: Float
        var turnLeadDistance: Float
        var shouldBlendTurn: Bool
        var isFinalSegment: Bool
        var isCompleted: Bool
        /// Course (radians) precomputed by the primitive path follower. When
        /// non-nil, the lateral controller uses this directly instead of
        /// reconstructing a fly-by course from the leg geometry.
        var precomputedDesiredCourse: Float?
        /// Index of the current path primitive when primitive guidance is
        /// active. `nil` for legacy polyline-driven mission references.
        var primitivePathIndex: Int?
        var primitivePathType: FixedWingPrimitiveFollowProgress.PrimitiveType?
    }

    private struct LateralCommand {
        var desiredCourse: Float
        var headingError: Float
        var rollDemandDeg: Float
    }

    private struct EnergyCommand {
        var targetAirspeed: Float
        var targetAltitude: Float
        var pitchDemandDeg: Float
        var throttleDemand: Float
        var speedRecoveryActive: Bool
    }

    private final class FixedWingMissionFollower {
        private struct ActiveWaypointReference {
            var missionWaypointIndex: Int
            var position: SIMD3<Float>
        }

        private struct Projection {
            var alongTrackDistance: Float
            var alongTrackProgress: Float
            var crossTrackError: Float
            var distanceToEnd: Float
            var legLength: Float
        }

        private var routeIdentifier: String?
        private var activeSegmentIndex: Int = 0
        private var loiterElapsed: Float = 0.0
        private var loiterClockwise: Bool = true

        func reset() {
            routeIdentifier = nil
            activeSegmentIndex = 0
            loiterElapsed = 0.0
            loiterClockwise = true
        }

        func update(
            state: DroneState,
            routeTracking: FixedWingRouteTrackingContext,
            wing: FixedWingParameters,
            targetAltitude: Float,
            airspeed: Float,
            deltaTime: Float,
            launchProtected: Bool
        ) -> MissionReference? {
            let sanitizedWaypoints = sanitize(routeTracking.waypoints)
            guard sanitizedWaypoints.count >= 2 else {
                return nil
            }

            let minimumSegmentIndex = minimumActiveSegmentIndex(
                in: sanitizedWaypoints,
                minimumWaypointIndex: routeTracking.minimumWaypointIndex
            )

            if routeIdentifier != routeTracking.routeIdentifier {
                let previousRouteIdentifier = routeIdentifier
                routeIdentifier = routeTracking.routeIdentifier
                // Preserve loiter state and segment index across in-mission key
                // changes (e.g. waypoint advancement re-stamps the route key).
                // Resetting in that case wipes the segment we were already
                // tracking and produces a visible heading snap on the turn.
                let isInMissionRouteRefresh = sameMissionRoute(
                    previousRouteIdentifier,
                    routeTracking.routeIdentifier
                )
                if !isInMissionRouteRefresh {
                    loiterElapsed = 0.0
                    loiterClockwise = true
                }
                if routeTracking.routeIdentifier.hasPrefix("mission:") {
                    activeSegmentIndex = max(activeSegmentIndex, minimumSegmentIndex)
                    if !isInMissionRouteRefresh {
                        activeSegmentIndex = minimumSegmentIndex
                    }
                } else {
                    activeSegmentIndex = bestCaptureSegmentIndex(
                        for: state.position,
                        waypoints: sanitizedWaypoints,
                        minimumSegmentIndex: minimumSegmentIndex
                    )
                }
            } else if activeSegmentIndex < minimumSegmentIndex {
                activeSegmentIndex = minimumSegmentIndex
            }

            let finalSegmentIndex = sanitizedWaypoints.count - 2
            guard finalSegmentIndex >= 0 else {
                return nil
            }

            if launchProtected {
                activeSegmentIndex = min(activeSegmentIndex, finalSegmentIndex)
            } else {
                while activeSegmentIndex < finalSegmentIndex {
                    let projection = self.projection(
                        at: activeSegmentIndex,
                        position: state.position,
                        waypoints: sanitizedWaypoints
                    )
                    let turnLeadDistance = computeTurnLeadDistance(
                        segmentIndex: activeSegmentIndex,
                        waypoints: sanitizedWaypoints,
                        wing: wing,
                        airspeed: airspeed
                    )
                    if !shouldAdvance(
                        projection: projection,
                        segmentIndex: activeSegmentIndex,
                        finalSegmentIndex: finalSegmentIndex,
                        turnLeadDistance: turnLeadDistance,
                        airspeed: airspeed,
                        position: state.position,
                        waypoints: sanitizedWaypoints,
                        wing: wing
                    ) {
                        break
                    }
                    activeSegmentIndex += 1
                    loiterElapsed = 0.0
                }
            }

            let legStart = sanitizedWaypoints[activeSegmentIndex].position
            let legEnd = sanitizedWaypoints[activeSegmentIndex + 1].position
            let legDelta = SIMD2<Float>(legEnd.x - legStart.x, legEnd.z - legStart.z)
            let legLength = max(0.001, simd_length(legDelta))
            let legDirection = legDelta / legLength
            let activeWaypointReference = resolvedActiveWaypointReference(
                segmentIndex: activeSegmentIndex,
                waypoints: sanitizedWaypoints,
                minimumWaypointIndex: routeTracking.minimumWaypointIndex
            )
            let projection = self.projection(
                at: activeSegmentIndex,
                position: state.position,
                waypoints: sanitizedWaypoints
            )
            let usesSampledRouteGeometry = hasSampledRouteGeometry(sanitizedWaypoints)
            let isFinalSegment = activeSegmentIndex >= finalSegmentIndex
            let turnLeadDistance = computeTurnLeadDistance(
                segmentIndex: activeSegmentIndex,
                waypoints: sanitizedWaypoints,
                wing: wing,
                airspeed: airspeed
            )
            let flyByTurnActive = !usesSampledRouteGeometry && shouldBeginFlyByTurn(
                projection: projection,
                segmentIndex: activeSegmentIndex,
                finalSegmentIndex: finalSegmentIndex,
                turnLeadDistance: turnLeadDistance,
                airspeed: airspeed,
                position: state.position,
                waypoints: sanitizedWaypoints,
                wing: wing
            )

            let completionMode = resolvedCompletionMode(
                routeTracking: routeTracking,
                waypoints: sanitizedWaypoints,
                legDirection: legDirection
            )
            let currentCourse = courseRadians(from: legDirection)
            let nextLegEnd = activeSegmentIndex + 2 < sanitizedWaypoints.count
                ? sanitizedWaypoints[activeSegmentIndex + 2].position
                : nil

            let isCompleted: Bool
            let missionState: FixedWingAutopilotDebugState.MissionState
            if isFinalSegment,
               hasEnteredCompletion(
                projection: projection,
                legLength: legLength,
                position: state.position,
                legEnd: legEnd,
                wing: wing
               ) {
                loiterElapsed += deltaTime
                missionState = .loitering
                isCompleted = loiterElapsed >= 8.0
            } else {
                loiterElapsed = 0.0
                if launchProtected {
                    missionState = .climbout
                } else if flyByTurnActive {
                    missionState = .flyByTurn
                } else if abs(projection.crossTrackError) > max(wing.waypointAcceptanceRadiusMeters * 0.55, wing.minimumTurnRadius(airspeed: airspeed) * 0.14) {
                    missionState = .capturingLeg
                } else {
                    missionState = .trackingLeg
                }
                isCompleted = false
            }

            return MissionReference(
                routeIdentifier: routeTracking.routeIdentifier,
                completionMode: completionMode,
                missionState: missionState,
                activeSegmentIndex: activeSegmentIndex,
                activeWaypointIndex: activeWaypointReference.missionWaypointIndex,
                activeWaypointPosition: activeWaypointReference.position,
                legStart: legStart,
                legEnd: legEnd,
                nextLegEnd: nextLegEnd,
                legDirectionXZ: legDirection,
                legLength: legLength,
                crossTrackError: projection.crossTrackError,
                alongTrackDistance: projection.alongTrackDistance,
                alongTrackProgress: projection.alongTrackProgress,
                remainingDistance: remainingDistance(
                    from: state.position,
                    segmentIndex: activeSegmentIndex,
                    waypoints: sanitizedWaypoints
                ),
                desiredAltitude: targetAltitude,
                currentCourse: currentCourse,
                turnLeadDistance: turnLeadDistance,
                shouldBlendTurn: flyByTurnActive,
                isFinalSegment: isFinalSegment,
                isCompleted: isCompleted
            )
        }

        private func sameMissionRoute(_ lhs: String?, _ rhs: String?) -> Bool {
            guard let lhs, let rhs,
                  lhs.hasPrefix("mission:"),
                  rhs.hasPrefix("mission:") else {
                return false
            }
            let lhsBase = lhs.split(separator: ":", maxSplits: 2).prefix(2).joined(separator: ":")
            let rhsBase = rhs.split(separator: ":", maxSplits: 2).prefix(2).joined(separator: ":")
            return lhsBase == rhsBase
        }

        private func sanitize(
            _ waypoints: [FixedWingRouteWaypoint]
        ) -> [FixedWingRouteWaypoint] {
            guard !waypoints.isEmpty else {
                return []
            }

            var output: [FixedWingRouteWaypoint] = []
            output.reserveCapacity(waypoints.count)

            for waypoint in waypoints {
                if let last = output.last,
                   simd_distance(last.position, waypoint.position) <= 0.05 {
                    if waypoint.missionWaypointIndex != nil || waypoint.waypointIdentifier != nil {
                        output[output.count - 1] = FixedWingRouteWaypoint(
                            position: last.position,
                            missionWaypointIndex: waypoint.missionWaypointIndex ?? last.missionWaypointIndex,
                            waypointIdentifier: waypoint.waypointIdentifier ?? last.waypointIdentifier
                        )
                    }
                    continue
                }
                output.append(waypoint)
            }

            return output
        }

        private func hasSampledRouteGeometry(
            _ waypoints: [FixedWingRouteWaypoint]
        ) -> Bool {
            guard waypoints.count > 3 else {
                return false
            }

            for index in 1..<(waypoints.count - 1) {
                if waypoints[index].missionWaypointIndex == nil &&
                    waypoints[index].waypointIdentifier == nil {
                    return true
                }
            }
            return false
        }

        private func minimumActiveSegmentIndex(
            in waypoints: [FixedWingRouteWaypoint],
            minimumWaypointIndex: Int?
        ) -> Int {
            guard let minimumWaypointIndex else {
                return 0
            }

            let finalSegmentIndex = waypoints.count - 2
            guard finalSegmentIndex >= 0 else {
                return 0
            }

            for segmentIndex in 0...finalSegmentIndex {
                let waypointReference = resolvedActiveWaypointReference(
                    segmentIndex: segmentIndex,
                    waypoints: waypoints,
                    minimumWaypointIndex: minimumWaypointIndex
                )
                if waypointReference.missionWaypointIndex >= minimumWaypointIndex {
                    return segmentIndex
                }
            }
            return 0
        }

        private func resolvedActiveWaypointReference(
            segmentIndex: Int,
            waypoints: [FixedWingRouteWaypoint],
            minimumWaypointIndex: Int?
        ) -> ActiveWaypointReference {
            guard !waypoints.isEmpty else {
                return ActiveWaypointReference(
                    missionWaypointIndex: minimumWaypointIndex ?? 0,
                    position: .zero
                )
            }

            let boundedSegmentIndex = max(0, min(segmentIndex, max(0, waypoints.count - 2)))
            let fallbackPosition = waypoints[min(boundedSegmentIndex + 1, waypoints.count - 1)].position

            if boundedSegmentIndex + 1 < waypoints.count {
                for index in (boundedSegmentIndex + 1)..<waypoints.count {
                    if let missionWaypointIndex = waypoints[index].missionWaypointIndex {
                        return ActiveWaypointReference(
                            missionWaypointIndex: missionWaypointIndex,
                            position: waypoints[index].position
                        )
                    }
                }
            }

            for index in stride(from: boundedSegmentIndex, through: 0, by: -1) {
                if let missionWaypointIndex = waypoints[index].missionWaypointIndex {
                    return ActiveWaypointReference(
                        missionWaypointIndex: missionWaypointIndex,
                        position: waypoints[index].position
                    )
                }
            }

            return ActiveWaypointReference(
                missionWaypointIndex: minimumWaypointIndex ?? 0,
                position: fallbackPosition
            )
        }

        private func bestCaptureSegmentIndex(
            for position: SIMD3<Float>,
            waypoints: [FixedWingRouteWaypoint],
            minimumSegmentIndex: Int
        ) -> Int {
            guard waypoints.count >= 2 else {
                return 0
            }

            var bestIndex = minimumSegmentIndex
            var bestScore = Float.greatestFiniteMagnitude
            let finalSegmentIndex = waypoints.count - 2

            for index in minimumSegmentIndex...finalSegmentIndex {
                let projection = self.projection(
                    at: index,
                    position: position,
                    waypoints: waypoints
                )
                let score = abs(projection.crossTrackError) + max(0.0, -projection.alongTrackDistance) * 0.35 + projection.distanceToEnd * 0.04
                if score < bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }

            return bestIndex
        }

        private func projection(
            at segmentIndex: Int,
            position: SIMD3<Float>,
            waypoints: [FixedWingRouteWaypoint]
        ) -> Projection {
            let start = waypoints[segmentIndex].position
            let end = waypoints[segmentIndex + 1].position
            return projection(
                from: start,
                to: end,
                position: position
            )
        }

        private func projection(
            from start: SIMD3<Float>,
            to end: SIMD3<Float>,
            position: SIMD3<Float>
        ) -> Projection {
            let legDelta = SIMD2<Float>(end.x - start.x, end.z - start.z)
            let legLength = max(0.001, simd_length(legDelta))
            let direction = legDelta / legLength
            let local = SIMD2<Float>(position.x - start.x, position.z - start.z)
            let alongTrack = simd_dot(local, direction)
            let normal = SIMD2<Float>(-direction.y, direction.x)
            let crossTrack = simd_dot(local, normal)

            return Projection(
                alongTrackDistance: alongTrack,
                alongTrackProgress: (alongTrack / legLength).fwClamped(to: -1.0...2.0),
                crossTrackError: crossTrack,
                distanceToEnd: simd_distance(
                    SIMD2<Float>(position.x, position.z),
                    SIMD2<Float>(end.x, end.z)
                ),
                legLength: legLength
            )
        }

        private func computeTurnLeadDistance(
            segmentIndex: Int,
            waypoints: [FixedWingRouteWaypoint],
            wing: FixedWingParameters,
            airspeed: Float
        ) -> Float {
            guard segmentIndex + 2 < waypoints.count else {
                return max(wing.waypointAcceptanceRadiusMeters, wing.loiterRadiusMeters * 0.6)
            }

            let inbound = SIMD2<Float>(
                waypoints[segmentIndex + 1].position.x - waypoints[segmentIndex].position.x,
                waypoints[segmentIndex + 1].position.z - waypoints[segmentIndex].position.z
            )
            let outbound = SIMD2<Float>(
                waypoints[segmentIndex + 2].position.x - waypoints[segmentIndex + 1].position.x,
                waypoints[segmentIndex + 2].position.z - waypoints[segmentIndex + 1].position.z
            )
            let inboundLength = max(0.001, simd_length(inbound))
            let outboundLength = max(0.001, simd_length(outbound))
            let inboundCourse = courseRadians(from: inbound / inboundLength)
            let outboundCourse = courseRadians(from: outbound / outboundLength)
            let turnAngle = abs(shortestAngleRadians(outboundCourse - inboundCourse))
            guard turnAngle > 0.06 else {
                return wing.waypointAcceptanceRadiusMeters
            }

            let radius = guidanceTurnRadius(
                wing: wing,
                airspeed: airspeed
            )
            let geometricLead = radius * tan(min(.pi * 0.45, turnAngle * 0.5))
            let waypointLeadLimit = max(
                wing.waypointAcceptanceRadiusMeters * 2.05,
                min(inboundLength, outboundLength) * 0.22
            )
            let boundedLead = min(
                geometricLead,
                inboundLength * 0.36,
                outboundLength * 0.36,
                waypointLeadLimit
            )
            return max(wing.waypointAcceptanceRadiusMeters * 0.85, boundedLead)
        }

        private func shouldAdvance(
            projection: Projection,
            segmentIndex: Int,
            finalSegmentIndex: Int,
            turnLeadDistance: Float,
            airspeed: Float,
            position: SIMD3<Float>,
            waypoints: [FixedWingRouteWaypoint],
            wing: FixedWingParameters
        ) -> Bool {
            let legEnd = waypoints[segmentIndex + 1].position
            let legLength = segmentLength(at: segmentIndex, in: waypoints)
            let distanceToWaypoint = simd_distance(
                SIMD2<Float>(position.x, position.z),
                SIMD2<Float>(legEnd.x, legEnd.z)
            )

            if segmentIndex >= finalSegmentIndex {
                return false
            }

            let isRuntimeEntrySegment = waypoints[segmentIndex].waypointIdentifier == fixedWingRuntimeRouteStartIdentifier
            let switchCaptureRadius = waypointSwitchCaptureRadius(
                turnLeadDistance: turnLeadDistance,
                airspeed: airspeed,
                wing: wing
            )
            let handoffCrossTrackLimit = waypointHandoffCrossTrackLimit(
                turnLeadDistance: turnLeadDistance,
                airspeed: airspeed,
                wing: wing
            )
            if isRuntimeEntrySegment {
                let requiredCaptureRadius = max(
                    wing.waypointAcceptanceRadiusMeters * 0.82,
                    min(switchCaptureRadius, wing.waypointAcceptanceRadiusMeters * 1.05)
                )
                if distanceToWaypoint <= requiredCaptureRadius,
                   projection.alongTrackProgress >= 0.68 {
                    return true
                }
                if projection.alongTrackDistance >= legLength + switchCaptureRadius * 0.45,
                   distanceToWaypoint <= switchCaptureRadius * 1.12 {
                    return true
                }
                return false
            }

            if projection.alongTrackDistance >= legLength + max(
                wing.waypointAcceptanceRadiusMeters * 0.20,
                switchCaptureRadius * 0.25
            ) {
                return true
            }

            // Fly-by turning starts before waypoint ownership changes. The
            // segment should only hand over once the aircraft is actually
            // close to the waypoint or has cleanly crossed beyond it.
            if distanceToWaypoint <= switchCaptureRadius,
               projection.alongTrackProgress >= 0.82,
               abs(projection.crossTrackError) <= handoffCrossTrackLimit {
                return true
            }

            if segmentIndex + 2 < waypoints.count,
               hasEnteredNextLegGate(
                currentProjection: projection,
                segmentIndex: segmentIndex,
                position: position,
                waypoints: waypoints,
                turnLeadDistance: turnLeadDistance,
                airspeed: airspeed,
                wing: wing
               ) {
                return true
            }

            if distanceToWaypoint <= wing.waypointAcceptanceRadiusMeters,
               projection.alongTrackProgress >= 0.92 {
                return true
            }

            return false
        }

        private func hasEnteredNextLegGate(
            currentProjection: Projection,
            segmentIndex: Int,
            position: SIMD3<Float>,
            waypoints: [FixedWingRouteWaypoint],
            turnLeadDistance: Float,
            airspeed: Float,
            wing: FixedWingParameters
        ) -> Bool {
            guard segmentIndex + 2 < waypoints.count else {
                return false
            }

            let waypoint = waypoints[segmentIndex + 1].position
            let nextEnd = waypoints[segmentIndex + 2].position
            let nextProjection = projection(
                from: waypoint,
                to: nextEnd,
                position: position
            )
            let distanceToWaypoint = simd_distance(
                SIMD2<Float>(position.x, position.z),
                SIMD2<Float>(waypoint.x, waypoint.z)
            )
            let minimumTurnRadius = guidanceTurnRadius(wing: wing, airspeed: airspeed)
            let nextLegCorridor = max(
                wing.waypointAcceptanceRadiusMeters * 1.15,
                min(
                    minimumTurnRadius * 0.62,
                    max(turnLeadDistance * 0.92, wing.waypointAcceptanceRadiusMeters * 1.35)
                )
            )
            let turnGateDistance = max(
                0.0,
                currentProjection.legLength - max(turnLeadDistance, wing.waypointAcceptanceRadiusMeters * 0.9)
            )
            let nextLegProgressGate = max(
                wing.waypointAcceptanceRadiusMeters * 0.12,
                min(nextProjection.legLength * 0.16, max(turnLeadDistance * 0.22, 1.0))
            )
            let waypointWindow = max(
                turnLeadDistance * 1.35,
                nextLegCorridor * 1.1
            )

            return currentProjection.alongTrackDistance >= turnGateDistance &&
                distanceToWaypoint <= waypointWindow &&
                nextProjection.alongTrackDistance >= nextLegProgressGate &&
                abs(nextProjection.crossTrackError) <= nextLegCorridor
        }

        private func waypointSwitchCaptureRadius(
            turnLeadDistance: Float,
            airspeed: Float,
            wing: FixedWingParameters
        ) -> Float {
            let minimumTurnRadius = guidanceTurnRadius(wing: wing, airspeed: airspeed)
            return max(
                wing.waypointAcceptanceRadiusMeters,
                min(
                    turnLeadDistance * 0.38,
                    minimumTurnRadius * 0.58
                )
            )
        }

        private func waypointHandoffCrossTrackLimit(
            turnLeadDistance: Float,
            airspeed: Float,
            wing: FixedWingParameters
        ) -> Float {
            let minimumTurnRadius = guidanceTurnRadius(wing: wing, airspeed: airspeed)
            return max(
                wing.waypointAcceptanceRadiusMeters * 1.10,
                min(
                    max(turnLeadDistance * 0.46, wing.waypointAcceptanceRadiusMeters * 1.35),
                    minimumTurnRadius * 0.72
                )
            )
        }

        private func shouldBeginFlyByTurn(
            projection: Projection,
            segmentIndex: Int,
            finalSegmentIndex: Int,
            turnLeadDistance: Float,
            airspeed: Float,
            position: SIMD3<Float>,
            waypoints: [FixedWingRouteWaypoint],
            wing: FixedWingParameters
        ) -> Bool {
            guard segmentIndex < finalSegmentIndex else {
                return false
            }

            let legLength = segmentLength(at: segmentIndex, in: waypoints)
            let legEnd = waypoints[segmentIndex + 1].position
            let distanceToWaypoint = simd_distance(
                SIMD2<Float>(position.x, position.z),
                SIMD2<Float>(legEnd.x, legEnd.z)
            )
            let minimumTurnRadius = guidanceTurnRadius(wing: wing, airspeed: airspeed)
            let waypointWindow = max(
                turnLeadDistance * 1.18,
                max(
                    wing.waypointAcceptanceRadiusMeters * 1.55,
                    minimumTurnRadius * 0.82
                )
            )
            let captureCorridor = max(
                wing.waypointAcceptanceRadiusMeters * 1.08,
                min(
                    max(turnLeadDistance * 0.44, wing.waypointAcceptanceRadiusMeters * 1.30),
                    minimumTurnRadius * 0.68
                )
            )

            return projection.alongTrackDistance >= max(0.0, legLength - turnLeadDistance) &&
                distanceToWaypoint <= waypointWindow &&
                abs(projection.crossTrackError) <= captureCorridor
        }

        private func hasEnteredCompletion(
            projection: Projection,
            legLength: Float,
            position: SIMD3<Float>,
            legEnd: SIMD3<Float>,
            wing: FixedWingParameters
        ) -> Bool {
            let distanceToWaypoint = simd_distance(
                SIMD2<Float>(position.x, position.z),
                SIMD2<Float>(legEnd.x, legEnd.z)
            )
            let completionCaptureRadius = max(
                wing.waypointAcceptanceRadiusMeters * 1.15,
                min(wing.loiterRadiusMeters * 0.82, wing.waypointAcceptanceRadiusMeters * 1.8)
            )
            if distanceToWaypoint <= completionCaptureRadius {
                return true
            }

            return projection.alongTrackDistance >= legLength &&
                distanceToWaypoint <= max(completionCaptureRadius, wing.loiterRadiusMeters * 0.95)
        }

        private func resolvedCompletionMode(
            routeTracking: FixedWingRouteTrackingContext,
            waypoints: [FixedWingRouteWaypoint],
            legDirection: SIMD2<Float>
        ) -> FixedWingCompletionMode {
            let center = routeTracking.preferredLoiterCenter ?? waypoints.last?.position ?? .zero
            let radius = max(10.0, routeTracking.preferredLoiterRadius ?? 0.0)
            let clockwise = legDirection.x >= 0.0
            loiterClockwise = clockwise
            return .loiter(center: center, radius: radius, clockwise: clockwise)
        }

        private func remainingDistance(
            from position: SIMD3<Float>,
            segmentIndex: Int,
            waypoints: [FixedWingRouteWaypoint]
        ) -> Float {
            guard segmentIndex + 1 < waypoints.count else {
                return 0.0
            }

            var remaining = simd_distance(position, waypoints[segmentIndex + 1].position)
            if segmentIndex + 2 < waypoints.count {
                for index in (segmentIndex + 2)..<waypoints.count {
                    remaining += simd_distance(
                        waypoints[index - 1].position,
                        waypoints[index].position
                    )
                }
            }
            return remaining
        }

        private func segmentLength(
            at segmentIndex: Int,
            in waypoints: [FixedWingRouteWaypoint]
        ) -> Float {
            guard segmentIndex + 1 < waypoints.count else {
                return 0.0
            }
            return simd_distance(
                waypoints[segmentIndex].position,
                waypoints[segmentIndex + 1].position
            )
        }

        private func guidanceTurnRadius(
            wing: FixedWingParameters,
            airspeed: Float
        ) -> Float {
            let bankDegrees = min(
                wing.maxBankAngleDeg,
                max(8.0, wing.maxBankAngleDeg * 0.92)
            )
            let bankRadians = bankDegrees.degreesToRadians
            let speed = max(airspeed, wing.minSafeAirspeed)
            let bankLimitedRadius = speed * speed / max(0.1, 9.81 * tan(bankRadians))
            return max(
                wing.waypointAcceptanceRadiusMeters * 1.05,
                min(wing.minimumTurnRadius(airspeed: airspeed), bankLimitedRadius)
            )
        }
    }

    private final class FixedWingLateralGuidanceController {
        private struct FlyByTurnGeometry {
            var center: SIMD2<Float>
            var radius: Float
            var exitPoint: SIMD2<Float>
            var outboundDirection: SIMD2<Float>
            var outboundLength: Float
            var startAngle: Float
            var sweepAngle: Float

            var arcLength: Float {
                max(0.001, abs(sweepAngle) * radius)
            }
        }

        func command(
            state: DroneState,
            mission: MissionReference,
            wing: FixedWingParameters,
            airspeed: Float,
            launchPhase: FixedWingLaunchPhase?,
            launchHeading: Float?
        ) -> LateralCommand {
            let lookahead = max(wing.guidanceLookaheadDistance(airspeed: airspeed), wing.loiterRadiusMeters * 1.15)
            let currentCourse = measuredCourse(state: state, fallback: mission.currentCourse)

            let desiredCourse: Float
            // Primitive guidance overlay short-circuits the legacy fly-by
            // reconstruction: the lookahead course is already computed against
            // the explicit line/arc primitive of the flyable route.
            if let primitiveCourse = mission.precomputedDesiredCourse,
               primitiveCourse.isFinite,
               !(mission.missionState == .loitering || mission.isCompleted),
               launchHeading == nil {
                desiredCourse = primitiveCourse
            } else {
                switch mission.completionMode {
                case .hold:
                    desiredCourse = mission.currentCourse
                case .loiter(let center, let radius, let clockwise):
                    if mission.missionState == .loitering || mission.isCompleted {
                        desiredCourse = orbitCourse(
                            position: state.position,
                            center: center,
                            radius: radius,
                            clockwise: clockwise
                        )
                    } else if let launchHeading {
                        desiredCourse = launchHeading
                    } else {
                        desiredCourse = desiredTrackForLeg(
                            position: state.position,
                            mission: mission,
                            lookahead: lookahead,
                            wing: wing
                        )
                    }
                }
            }

            let courseTarget: Float
            if let launchHeading,
               launchPhase == .onRail || launchPhase == .launchImpulse || launchPhase == .railRelease {
                courseTarget = launchHeading
            } else {
                courseTarget = desiredCourse
            }

            let eta = shortestAngleRadians(courseTarget - currentCourse)
            let lateralAcceleration = 2.0 * airspeed * airspeed / max(lookahead, 1.0) * sin(eta)
            let bankRadians = atan2(lateralAcceleration, 9.81)
            let maxBankRadians = wing.maxBankAngleDeg.degreesToRadians
            let bankDemandDeg = bankRadians
                .fwClamped(to: -maxBankRadians...maxBankRadians)
                .radiansToDegrees

            return LateralCommand(
                desiredCourse: courseTarget,
                headingError: shortestAngleRadians(courseTarget - state.orientation.z),
                rollDemandDeg: bankDemandDeg
            )
        }

        private func desiredTrackForLeg(
            position: SIMD3<Float>,
            mission: MissionReference,
            lookahead: Float,
            wing: FixedWingParameters
        ) -> Float {
            let currentPosition = SIMD2<Float>(position.x, position.z)
            let legStart = SIMD2<Float>(mission.legStart.x, mission.legStart.z)
            let inboundAimDistance = (mission.alongTrackDistance + lookahead)
                .fwClamped(to: 0.0...mission.legLength)
            let inboundAimPoint = legStart + mission.legDirectionXZ * inboundAimDistance
            let inboundCourse = courseToPoint(
                from: currentPosition,
                to: inboundAimPoint,
                fallback: mission.currentCourse
            )
            if mission.shouldBlendTurn,
               let nextLegEnd = mission.nextLegEnd {
                let outboundEnd = SIMD2<Float>(nextLegEnd.x, nextLegEnd.z)
                if let flyByCourse = flyByTurnCourse(
                    position: currentPosition,
                    mission: mission,
                    outboundEnd: outboundEnd,
                    lookahead: lookahead,
                    wing: wing
                ) {
                    return flyByCourse
                }
            }

            return inboundCourse
        }

        private func flyByTurnCourse(
            position: SIMD2<Float>,
            mission: MissionReference,
            outboundEnd: SIMD2<Float>,
            lookahead: Float,
            wing: FixedWingParameters
        ) -> Float? {
            guard let geometry = flyByTurnGeometry(
                mission: mission,
                outboundEnd: outboundEnd,
                wing: wing
            ) else {
                return nil
            }

            let entryDistance = max(0.0, mission.legLength - mission.turnLeadDistance)
            let legTurnProgress = ((mission.alongTrackDistance - entryDistance) / max(mission.turnLeadDistance, 0.1))
                .fwClamped(to: 0.0...1.0)
            let angularProgress = arcProgress(
                position: position,
                center: geometry.center,
                startAngle: geometry.startAngle,
                sweepAngle: geometry.sweepAngle
            )
            let radialError = abs(simd_distance(position, geometry.center) - geometry.radius)
            let canUseAngularProgress = legTurnProgress > 0.05 &&
                radialError <= max(geometry.radius * 0.5, wing.waypointAcceptanceRadiusMeters * 1.5)
            let turnProgress = (
                canUseAngularProgress
                    ? max(smootherstep(legTurnProgress), angularProgress)
                    : smootherstep(legTurnProgress)
            ).fwClamped(to: 0.0...1.0)

            let turnLookahead = max(
                wing.waypointAcceptanceRadiusMeters * 0.85,
                min(lookahead * 0.72, geometry.arcLength * 0.62)
            )
            let progressAdvance = turnLookahead / geometry.arcLength
            let desiredProgress = turnProgress + progressAdvance

            let aimPoint: SIMD2<Float>
            let fallbackCourse: Float
            if desiredProgress <= 1.0 {
                let sampleAngle = geometry.startAngle + geometry.sweepAngle * desiredProgress
                aimPoint = SIMD2<Float>(
                    geometry.center.x + cos(sampleAngle) * geometry.radius,
                    geometry.center.y + sin(sampleAngle) * geometry.radius
                )
                fallbackCourse = courseRadians(
                    from: arcTangentDirection(
                        angle: sampleAngle,
                        sweepAngle: geometry.sweepAngle
                    )
                )
            } else {
                let overshootDistance = (desiredProgress - 1.0) * geometry.arcLength
                let outboundAimDistance = min(
                    max(overshootDistance, lookahead * 0.35),
                    max(0.0, geometry.outboundLength - mission.turnLeadDistance)
                )
                aimPoint = geometry.exitPoint + geometry.outboundDirection * outboundAimDistance
                fallbackCourse = courseRadians(from: geometry.outboundDirection)
            }

            return courseToPoint(
                from: position,
                to: aimPoint,
                fallback: fallbackCourse
            )
        }

        private func flyByTurnGeometry(
            mission: MissionReference,
            outboundEnd: SIMD2<Float>,
            wing: FixedWingParameters
        ) -> FlyByTurnGeometry? {
            let waypoint = SIMD2<Float>(mission.legEnd.x, mission.legEnd.z)
            let outboundDelta = outboundEnd - waypoint
            let outboundLength = simd_length(outboundDelta)
            guard outboundLength > 0.001 else {
                return nil
            }

            let inboundDirection = mission.legDirectionXZ
            let outboundDirection = outboundDelta / outboundLength
            let inboundCourse = courseRadians(from: inboundDirection)
            let outboundCourse = courseRadians(from: outboundDirection)
            let turnAngle = abs(shortestAngleRadians(outboundCourse - inboundCourse))
            let turnSign = inboundDirection.x * outboundDirection.y - inboundDirection.y * outboundDirection.x
            let tangentFactor = tan(min(.pi * 0.45, turnAngle * 0.5))
            guard turnAngle > 0.06,
                  abs(turnSign) > 0.001,
                  tangentFactor.isFinite,
                  tangentFactor > 0.05 else {
                return nil
            }

            let leadDistance = min(
                mission.turnLeadDistance,
                mission.legLength * 0.48,
                outboundLength * 0.48
            )
            guard leadDistance > max(wing.waypointAcceptanceRadiusMeters * 0.25, 0.5) else {
                return nil
            }

            let radius = leadDistance / tangentFactor
            guard radius.isFinite,
                  radius > max(0.5, wing.waypointAcceptanceRadiusMeters * 0.2) else {
                return nil
            }
            let entryPoint = waypoint - inboundDirection * leadDistance
            let exitPoint = waypoint + outboundDirection * leadDistance
            let rightNormal = SIMD2<Float>(-inboundDirection.y, inboundDirection.x)
            let center = turnSign > 0.0
                ? entryPoint + rightNormal * radius
                : entryPoint - rightNormal * radius
            let startAngle = atan2(entryPoint.y - center.y, entryPoint.x - center.x)
            let endAngle = atan2(exitPoint.y - center.y, exitPoint.x - center.x)
            let sweepAngle = arcSweep(
                startAngle: startAngle,
                endAngle: endAngle,
                turnSign: turnSign
            )

            guard abs(sweepAngle) > 0.04,
                  abs(sweepAngle) <= .pi * 1.6,
                  sweepAngle.isFinite else {
                return nil
            }

            return FlyByTurnGeometry(
                center: center,
                radius: radius,
                exitPoint: exitPoint,
                outboundDirection: outboundDirection,
                outboundLength: outboundLength,
                startAngle: startAngle,
                sweepAngle: sweepAngle
            )
        }

        private func arcProgress(
            position: SIMD2<Float>,
            center: SIMD2<Float>,
            startAngle: Float,
            sweepAngle: Float
        ) -> Float {
            let radial = position - center
            guard simd_length_squared(radial) > 0.0001 else {
                return 0.0
            }

            let currentAngle = atan2(radial.y, radial.x)
            var delta = currentAngle - startAngle
            if sweepAngle > 0.0 {
                while delta < 0.0 {
                    delta += .pi * 2.0
                }
                while delta > .pi * 2.0 {
                    delta -= .pi * 2.0
                }
            } else {
                while delta > 0.0 {
                    delta -= .pi * 2.0
                }
                while delta < -.pi * 2.0 {
                    delta += .pi * 2.0
                }
            }

            return (delta / sweepAngle).fwClamped(to: 0.0...1.0)
        }

        private func arcTangentDirection(
            angle: Float,
            sweepAngle: Float
        ) -> SIMD2<Float> {
            if sweepAngle >= 0.0 {
                return simd_normalize(SIMD2<Float>(-sin(angle), cos(angle)))
            }
            return simd_normalize(SIMD2<Float>(sin(angle), -cos(angle)))
        }

        private func arcSweep(
            startAngle: Float,
            endAngle: Float,
            turnSign: Float
        ) -> Float {
            var delta = shortestAngleRadians(endAngle - startAngle)
            if turnSign > 0.0, delta < 0.0 {
                delta += .pi * 2.0
            } else if turnSign < 0.0, delta > 0.0 {
                delta -= .pi * 2.0
            }
            return delta
        }

        private func measuredCourse(
            state: DroneState,
            fallback: Float
        ) -> Float {
            let planarVelocity = SIMD2<Float>(state.velocity.x, state.velocity.z)
            if simd_length(planarVelocity) > 0.2 {
                return courseRadians(from: simd_normalize(planarVelocity))
            }
            return fallback
        }

        private func orbitCourse(
            position: SIMD3<Float>,
            center: SIMD3<Float>,
            radius: Float,
            clockwise: Bool
        ) -> Float {
            let radial = SIMD2<Float>(position.x - center.x, position.z - center.z)
            let distance = max(0.1, simd_length(radial))
            let radialDirection = radial / distance
            let tangentDirection = clockwise
                ? SIMD2<Float>(radialDirection.y, -radialDirection.x)
                : SIMD2<Float>(-radialDirection.y, radialDirection.x)
            let radialError = (distance - radius) / max(radius, 0.1)
            let desiredDirection = simd_normalize(
                tangentDirection - radialDirection * radialError.fwClamped(to: -0.8...0.8)
            )
            return courseRadians(from: desiredDirection)
        }

        private func smootherstep(_ value: Float) -> Float {
            let t = value.fwClamped(to: 0.0...1.0)
            return t * t * (3.0 - 2.0 * t)
        }
    }

    private final class FixedWingEnergyController {
        private var filteredAltitudeTarget: Float?
        private var speedRecoveryLatched = false

        func reset() {
            filteredAltitudeTarget = nil
            speedRecoveryLatched = false
        }

        func command(
            state: DroneState,
            targetAltitude: Float,
            wing: FixedWingParameters,
            flightBaseline: ResolvedFlightBaseline,
            launchPhase: FixedWingLaunchPhase?,
            missionState: FixedWingAutopilotDebugState.MissionState,
            deltaTime: Float
        ) -> EnergyCommand {
            let currentAirspeed = max(
                state.forwardAirspeed,
                simd_length(SIMD2<Float>(state.velocity.x, state.velocity.z))
            )
            let climbProtected = launchPhase == .onRail ||
                launchPhase == .launchImpulse ||
                launchPhase == .railRelease ||
                launchPhase == .initialClimb

            let targetAirspeedBase: Float = {
                if climbProtected {
                    return max(wing.climbAirspeed, wing.minSafeAirspeed + 1.0)
                }
                return wing.cruiseAirspeed
            }()

            let filteredTargetAltitude = rateLimitedAltitudeTarget(
                currentAltitude: state.position.y,
                targetAltitude: targetAltitude,
                wing: wing,
                deltaTime: deltaTime
            )
            let altitudeError = filteredTargetAltitude - state.position.y
            let desiredVerticalSpeed = altitudeError >= 0.0
                ? min(wing.nominalClimbRateMps, altitudeError * 0.34)
                : max(-wing.nominalSinkRateMps, altitudeError * 0.28)

            if currentAirspeed <= wing.minSafeAirspeed + 0.8 {
                speedRecoveryLatched = true
            } else if currentAirspeed >= targetAirspeedBase + 1.5 {
                speedRecoveryLatched = false
            }

            var targetAirspeed = targetAirspeedBase
            if speedRecoveryLatched {
                targetAirspeed = min(wing.maxAirspeed, max(targetAirspeedBase, wing.minSafeAirspeed + 2.4))
            }

            let airspeedError = targetAirspeed - currentAirspeed
            let flightPathAngle = asin(
                (desiredVerticalSpeed / max(targetAirspeed, wing.minSafeAirspeed)).fwClamped(to: -0.36...0.36)
            )

            var pitchDemandDeg = flightPathAngle.radiansToDegrees +
                altitudeError * 0.08 -
                state.velocity.y * 1.45 -
                airspeedError * 1.35

            if speedRecoveryLatched {
                pitchDemandDeg = min(pitchDemandDeg, wing.speedRecoveryPitchCeilingDeg)
            }

            if climbProtected {
                pitchDemandDeg = max(pitchDemandDeg, wing.initialClimbPitchDeg)
            }

            if missionState == .loitering {
                pitchDemandDeg = min(pitchDemandDeg, 6.0)
            }

            pitchDemandDeg = pitchDemandDeg.fwClamped(
                to: (-wing.maxPitchDownDeg)...wing.maxPitchUpDeg
            )

            let baselineThrottle = flightBaseline.cruiseReferenceThrottle
                .fwClamped(to: wing.minThrottle...wing.maxThrottle)
            var throttleDemand = baselineThrottle +
                airspeedError * 0.065 +
                desiredVerticalSpeed * 0.045 +
                altitudeError * 0.006 -
                state.velocity.y * 0.018

            if climbProtected {
                throttleDemand = max(throttleDemand, flightBaseline.takeoffThrottleReference)
            }

            if speedRecoveryLatched {
                throttleDemand = max(throttleDemand, max(wing.minThrottle, 0.84))
            }

            throttleDemand = throttleDemand.fwClamped(to: wing.minThrottle...wing.maxThrottle)

            return EnergyCommand(
                targetAirspeed: targetAirspeed,
                targetAltitude: filteredTargetAltitude,
                pitchDemandDeg: pitchDemandDeg,
                throttleDemand: throttleDemand,
                speedRecoveryActive: speedRecoveryLatched
            )
        }

        private func rateLimitedAltitudeTarget(
            currentAltitude: Float,
            targetAltitude: Float,
            wing: FixedWingParameters,
            deltaTime: Float
        ) -> Float {
            let seed = filteredAltitudeTarget ?? currentAltitude
            let delta = targetAltitude - seed
            let upwardStep = wing.nominalClimbRateMps * deltaTime
            let downwardStep = wing.nominalSinkRateMps * deltaTime
            let limited = seed + delta.fwClamped(to: -downwardStep...upwardStep)
            filteredAltitudeTarget = limited
            return limited
        }
    }

    private let missionFollower = FixedWingMissionFollower()
    private let primitiveFollower = FixedWingPrimitivePathFollower()
    private let lateralGuidanceController = FixedWingLateralGuidanceController()
    private let energyController = FixedWingEnergyController()

    private(set) var phase: FixedWingAutopilotPhase = .idle
    private(set) var launchPhase: FixedWingLaunchPhase?
    private(set) var lastTransitionReason: String?
    private(set) var debugState: FixedWingAutopilotDebugState = .idle

    private var launchPhaseElapsed: Float = 0.0
    private var commandedRollDeg: Float = 0.0
    private var commandedPitchDeg: Float = 0.0
    private var commandedThrottle: Float = 0.0
    private var commandedCourseRadians: Float?

    func reset() {
        phase = .idle
        launchPhase = nil
        lastTransitionReason = nil
        debugState = .idle
        launchPhaseElapsed = 0.0
        commandedRollDeg = 0.0
        commandedPitchDeg = 0.0
        commandedThrottle = 0.0
        commandedCourseRadians = nil
        missionFollower.reset()
        primitiveFollower.reset()
        energyController.reset()
    }

    func beginLaunch() {
        launchPhase = .onRail
        launchPhaseElapsed = 0.0
        setPhase(.aligningToLeg, reason: "launch_sequence_started")
    }

    func trackingCommand(
        for context: AutopilotTrackingContext,
        parameters wing: FixedWingParameters,
        launchMode: LaunchMode,
        launchAsset: LaunchAsset?,
        routeTracking: FixedWingRouteTrackingContext? = nil
    ) -> FixedWingAutopilotOutput {
        let airspeed = max(
            context.state.forwardAirspeed,
            simd_length(SIMD2<Float>(context.state.velocity.x, context.state.velocity.z)),
            context.physicalState.isGroundRestState ? 0.0 : wing.minSafeAirspeed * 0.62
        )

        let tracking = routeTracking ?? fallbackRouteTracking(
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

        guard var mission = missionFollower.update(
            state: context.state,
            routeTracking: tracking,
            wing: wing,
            targetAltitude: context.targetAltitude,
            airspeed: max(airspeed, wing.minSafeAirspeed),
            deltaTime: context.deltaTime,
            launchProtected: isLaunchProtected(launchPhase)
        ) else {
            setPhase(.failed, reason: "missing_route")
            return fallbackOutput(for: context, wing: wing)
        }

        // Primitive guidance overlay: when the route tracking context carries
        // an explicit flyable route (line + arc primitives), the airplane is
        // steered along those primitives via lookahead. The legacy mission
        // reference (legStart/legEnd, etc.) is preserved for energy control,
        // debug state and authority handshake.
        if !isLaunchProtected(launchPhase),
           let flyableRoute = tracking.flyableRoute {
            let planarPos = SIMD2<Float>(context.state.position.x, context.state.position.z)
            if let progress = primitiveFollower.update(
                position: planarPos,
                route: flyableRoute,
                wing: wing,
                airspeed: max(airspeed, wing.minSafeAirspeed),
                minimumWaypointIndex: tracking.minimumWaypointIndex
            ) {
                mission = applyPrimitiveOverlay(
                    base: mission,
                    progress: progress,
                    targetAltitude: mission.desiredAltitude,
                    wing: wing
                )
            }
        }

        let launchHeading = resolvedLaunchHeading(launchAsset: launchAsset, launchPhase: launchPhase)
        let lateral = lateralGuidanceController.command(
            state: context.state,
            mission: mission,
            wing: wing,
            airspeed: max(airspeed, wing.minSafeAirspeed),
            launchPhase: launchPhase,
            launchHeading: launchHeading
        )
        let energy = energyController.command(
            state: context.state,
            targetAltitude: mission.desiredAltitude,
            wing: wing,
            flightBaseline: context.flightBaseline,
            launchPhase: launchPhase,
            missionState: mission.missionState,
            deltaTime: context.deltaTime
        )

        let filteredRollDeg = rateLimit(
            current: commandedRollDeg,
            target: lateral.rollDemandDeg,
            rate: max(18.0, wing.maxBankAngleDeg * (1.35 + wing.bankResponseGain)),
            deltaTime: context.deltaTime
        )
        let filteredPitchDeg = rateLimit(
            current: commandedPitchDeg,
            target: energy.pitchDemandDeg,
            rate: max(10.0, wing.maxPitchUpDeg * (1.05 + wing.climbResponseGain)),
            deltaTime: context.deltaTime
        )
        let filteredThrottle = rateLimit(
            current: commandedThrottle,
            target: energy.throttleDemand,
            rate: 0.85,
            deltaTime: context.deltaTime
        ).fwClamped(to: wing.minThrottle...wing.maxThrottle)

        commandedRollDeg = filteredRollDeg
        commandedPitchDeg = filteredPitchDeg
        commandedThrottle = filteredThrottle
        let blendedCourse = blendAngle(
            current: commandedCourseRadians ?? context.state.orientation.z,
            target: lateral.desiredCourse,
            blend: (context.deltaTime * 1.8).fwClamped(to: 0.08...0.28)
        )
        // Absolute step limit on the commanded course tied to a generous
        // multiple of the wing's nominal turn rate. This prevents the
        // autopilot from issuing a catastrophic heading snap when a route
        // refresh produces a large desiredCourse delta — the airplane will
        // still bank decisively, but won't spin its nose at impossible rates.
        let nominalTurnRateRad = max(0.05, wing.nominalTurnRateDegPerSec * .pi / 180.0)
        let courseStepLimit = nominalTurnRateRad * max(0.0, context.deltaTime) * 2.4
        commandedCourseRadians = limitedCourseStep(
            from: commandedCourseRadians ?? context.state.orientation.z,
            to: blendedCourse,
            maxStep: courseStepLimit
        )

        let resolvedPhase = resolveAutopilotPhase(
            missionState: mission.missionState,
            speedRecoveryActive: energy.speedRecoveryActive,
            yawAlignToHome: context.yawAlignToHome
        )
        setPhase(resolvedPhase, reason: phaseReason(for: resolvedPhase, speedRecoveryActive: energy.speedRecoveryActive))

        let guidance = FixedWingGuidanceOutput(
            desiredThrottle: filteredThrottle,
            desiredRoll: filteredRollDeg,
            desiredPitchBias: filteredPitchDeg,
            desiredHeading: commandedCourseRadians ?? lateral.desiredCourse,
            desiredCourse: lateral.desiredCourse,
            headingError: lateral.headingError,
            crossTrackError: mission.crossTrackError,
            alongTrackProgress: mission.alongTrackProgress,
            targetAirspeed: energy.targetAirspeed,
            targetAltitude: energy.targetAltitude
        )

        let positionTarget = missionReferencePositionTarget(
            mission: mission,
            desiredAltitude: energy.targetAltitude
        )

        let command = AutopilotControlCommand(
            positionTarget: positionTarget,
            rollDegrees: filteredRollDeg,
            pitchDegrees: filteredPitchDeg,
            yawDegrees: (commandedCourseRadians ?? lateral.desiredCourse).radiansToDegrees,
            throttle: filteredThrottle
        )

        let debug = FixedWingAutopilotDebugState(
            routeIdentifier: mission.routeIdentifier,
            missionState: energy.speedRecoveryActive ? .recoveringSpeed : mission.missionState,
            activeSegmentIndex: mission.activeSegmentIndex,
            currentWaypointIndex: mission.activeWaypointIndex,
            legStart: mission.legStart,
            legEnd: mission.legEnd,
            legDirection: mission.legDirectionXZ,
            waypointVector: SIMD2<Float>(
                mission.activeWaypointPosition.x - context.state.position.x,
                mission.activeWaypointPosition.z - context.state.position.z
            ),
            crossTrackError: mission.crossTrackError,
            alongTrackProgress: mission.alongTrackProgress,
            remainingDistance: mission.remainingDistance,
            headingDeg: context.state.orientation.z.radiansToDegrees,
            groundTrackDeg: measuredGroundTrackDegrees(
                state: context.state,
                fallback: mission.currentCourse.radiansToDegrees
            ),
            commandedRollDeg: filteredRollDeg,
            commandedPitchDeg: filteredPitchDeg,
            commandedThrottle: filteredThrottle,
            targetAirspeed: energy.targetAirspeed,
            targetAltitude: energy.targetAltitude,
            desiredCourseDeg: lateral.desiredCourse.radiansToDegrees,
            speedRecoveryActive: energy.speedRecoveryActive
        )
        debugState = debug

        if mission.isCompleted {
            setPhase(.completingMission, reason: "route_completed")
        }

        return FixedWingAutopilotOutput(
            command: command,
            guidance: guidance,
            phase: phase,
            launchPhase: launchPhase,
            transitionReason: lastTransitionReason,
            debugState: debug,
            hasCompletedRoute: mission.isCompleted
        )
    }

    private func fallbackOutput(
        for context: AutopilotTrackingContext,
        wing: FixedWingParameters
    ) -> FixedWingAutopilotOutput {
        let fallbackThrottle = context.flightBaseline.cruiseReferenceThrottle.fwClamped(
            to: wing.minThrottle...wing.maxThrottle
        )
        let command = AutopilotControlCommand(
            positionTarget: context.state.position,
            rollDegrees: 0.0,
            pitchDegrees: 0.0,
            yawDegrees: context.state.orientation.z.radiansToDegrees,
            throttle: fallbackThrottle
        )
        let guidance = FixedWingGuidanceOutput(
            desiredThrottle: fallbackThrottle,
            desiredRoll: 0.0,
            desiredPitchBias: 0.0,
            desiredHeading: context.state.orientation.z,
            desiredCourse: context.state.orientation.z,
            headingError: 0.0,
            crossTrackError: 0.0,
            alongTrackProgress: 0.0,
            targetAirspeed: wing.cruiseAirspeed,
            targetAltitude: context.state.position.y
        )
        debugState = .idle
        return FixedWingAutopilotOutput(
            command: command,
            guidance: guidance,
            phase: phase,
            launchPhase: launchPhase,
            transitionReason: lastTransitionReason,
            debugState: debugState,
            hasCompletedRoute: false
        )
    }

    private func fallbackRouteTracking(
        state: DroneState,
        target: SIMD3<Float>,
        altitude: Float
    ) -> FixedWingRouteTrackingContext {
        FixedWingRouteTrackingContext(
            routeIdentifier: "fallback",
            waypoints: [
                FixedWingRouteWaypoint(
                    position: SIMD3<Float>(state.position.x, altitude, state.position.z),
                    missionWaypointIndex: nil,
                    waypointIdentifier: nil
                ),
                FixedWingRouteWaypoint(
                    position: target,
                    missionWaypointIndex: 0,
                    waypointIdentifier: nil
                )
            ],
            minimumWaypointIndex: 0,
            preferredLoiterCenter: target,
            preferredLoiterRadius: nil
        )
    }

    private func updateLaunchPhase(
        context: AutopilotTrackingContext,
        wing: FixedWingParameters,
        launchMode: LaunchMode,
        airspeed: Float
    ) {
        guard launchMode != .standard || launchPhase != nil else {
            launchPhase = nil
            launchPhaseElapsed = 0.0
            return
        }

        launchPhaseElapsed += context.deltaTime

        if launchPhase == nil {
            beginLaunch()
        }

        guard let launchPhase else {
            return
        }

        switch launchPhase {
        case .onRail:
            if airspeed >= max(wing.handThrowSpeed * 0.75, 3.5) || launchPhaseElapsed > 0.9 {
                self.launchPhase = .launchImpulse
                launchPhaseElapsed = 0.0
            }
        case .launchImpulse:
            if airspeed >= max(wing.takeoffRotationSpeed, wing.handThrowSpeed) || launchPhaseElapsed > 0.8 {
                self.launchPhase = .railRelease
                launchPhaseElapsed = 0.0
            }
        case .railRelease:
            if launchPhaseElapsed > 0.35 {
                self.launchPhase = .initialClimb
                launchPhaseElapsed = 0.0
            }
        case .initialClimb:
            if context.state.position.y >= wing.initialClimbTargetAltitude * 0.72 ||
                airspeed >= wing.climbAirspeed * 0.95 {
                self.launchPhase = .missionJoin
                launchPhaseElapsed = 0.0
            }
        case .missionJoin:
            if context.state.position.y >= wing.initialClimbTargetAltitude ||
                launchPhaseElapsed > 3.5 {
                self.launchPhase = nil
                launchPhaseElapsed = 0.0
            }
        }
    }

    private func applyPrimitiveOverlay(
        base: MissionReference,
        progress: FixedWingPrimitiveFollowProgress,
        targetAltitude: Float,
        wing: FixedWingParameters
    ) -> MissionReference {
        var overlay = base
        overlay.precomputedDesiredCourse = progress.desiredCourse
        overlay.primitivePathIndex = progress.primitiveIndex
        overlay.primitivePathType = progress.primitiveType
        overlay.crossTrackError = progress.crossTrackError
        overlay.alongTrackDistance = progress.alongPrimitiveDistance
        overlay.alongTrackProgress = progress.primitiveLength > 0.001
            ? (progress.alongPrimitiveDistance / progress.primitiveLength).fwClamped(to: 0.0...1.0)
            : 0.0
        overlay.remainingDistance = progress.totalRemainingDistance
        overlay.shouldBlendTurn = progress.primitiveType == .arc
        overlay.legLength = max(0.001, progress.primitiveLength)
        // The "leg" used by the legacy energy/debug path becomes the local
        // tangent at the airplane's projected position on the primitive.
        // Keeping legStart at the current planar position and legEnd in the
        // direction of the primitive's local course gives the energy
        // controller a stable hand-off without affecting altitude tracking.
        let courseDir = SIMD2<Float>(
            -sin(progress.primitiveCourseAtPosition),
            -cos(progress.primitiveCourseAtPosition)
        )
        let basePos = SIMD3<Float>(
            base.legStart.x,
            targetAltitude,
            base.legStart.z
        )
        let pseudoEnd = SIMD3<Float>(
            basePos.x + courseDir.x * max(1.0, progress.primitiveLength),
            targetAltitude,
            basePos.z + courseDir.y * max(1.0, progress.primitiveLength)
        )
        overlay.legDirectionXZ = courseDir
        overlay.legEnd = pseudoEnd
        overlay.currentCourse = progress.primitiveCourseAtPosition
        // Active waypoint accounting for mission auto-advance.
        overlay.activeWaypointIndex = progress.activeAnchorMissionIndex ?? base.activeWaypointIndex
        overlay.activeWaypointPosition = SIMD3<Float>(
            progress.activeAnchorPosition.x,
            targetAltitude,
            progress.activeAnchorPosition.y
        )
        overlay.isFinalSegment = progress.isOnFinalPrimitive
        // Approximate turn-lead distance from the wing parameters; the
        // primitive follower already anticipates turns geometrically so this
        // value is used purely for downstream debug telemetry.
        overlay.turnLeadDistance = max(
            wing.waypointAcceptanceRadiusMeters,
            wing.minimumTurnRadius() * 0.5
        )
        return overlay
    }

    private func resolvedLaunchHeading(
        launchAsset: LaunchAsset?,
        launchPhase: FixedWingLaunchPhase?
    ) -> Float? {
        switch launchAsset {
        case .catapult(let catapult):
            switch launchPhase {
            case .onRail, .launchImpulse, .railRelease:
                return catapult.rail.headingRadians
            case .initialClimb, .missionJoin, .none:
                return catapult.rail.launchDirectionRadians
            }
        case .none:
            return nil
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

    private func measuredGroundTrackDegrees(
        state: DroneState,
        fallback: Float
    ) -> Float {
        let planarVelocity = SIMD2<Float>(state.velocity.x, state.velocity.z)
        guard simd_length(planarVelocity) > 0.2 else {
            return fallback
        }
        return courseRadians(from: simd_normalize(planarVelocity)).radiansToDegrees
    }

    private func resolveAutopilotPhase(
        missionState: FixedWingAutopilotDebugState.MissionState,
        speedRecoveryActive: Bool,
        yawAlignToHome: Bool
    ) -> FixedWingAutopilotPhase {
        if yawAlignToHome {
            return .returnHome
        }

        if speedRecoveryActive {
            return .interceptingLeg
        }

        switch missionState {
        case .idle:
            return .idle
        case .aligningToLaunch:
            return .aligningToLeg
        case .climbout:
            return .turnEntry
        case .capturingLeg:
            return .interceptingLeg
        case .trackingLeg:
            return .trackingLeg
        case .flyByTurn:
            return .turningArc
        case .loitering, .completed:
            return .completingMission
        case .recoveringSpeed:
            return .interceptingLeg
        case .failed:
            return .failed
        }
    }

    private func phaseReason(
        for phase: FixedWingAutopilotPhase,
        speedRecoveryActive: Bool
    ) -> String {
        if speedRecoveryActive {
            return "airspeed_recovery"
        }

        switch phase {
        case .idle:
            return "idle"
        case .aligningToLeg:
            return "launch_align"
        case .turnEntry:
            return "launch_climb"
        case .turningArc:
            return "flyby_turn"
        case .interceptingLeg:
            return "leg_capture"
        case .trackingLeg:
            return "track_capture"
        case .approachingWaypoint:
            return "approaching_waypoint"
        case .completingMission:
            return "final_loiter"
        case .returnHome:
            return "return_home_tracking"
        case .failed:
            return "guidance_failed"
        }
    }

    private func missionReferencePositionTarget(
        mission: MissionReference,
        desiredAltitude: Float
    ) -> SIMD3<Float> {
        if case .loiter(let center, let radius, let clockwise) = mission.completionMode,
           mission.missionState == .loitering || mission.isCompleted {
            let direction = clockwise ? 1.0 as Float : -1.0 as Float
            let offset = SIMD2<Float>(
                mission.legDirectionXZ.y * radius * direction,
                -mission.legDirectionXZ.x * radius * direction
            )
            return SIMD3<Float>(
                center.x + offset.x,
                desiredAltitude,
                center.z + offset.y
            )
        }

        return SIMD3<Float>(
            mission.legEnd.x,
            desiredAltitude,
            mission.legEnd.z
        )
    }

    private func setPhase(
        _ next: FixedWingAutopilotPhase,
        reason: String
    ) {
        lastTransitionReason = reason
        phase = next
    }

    private func rateLimit(
        current: Float,
        target: Float,
        rate: Float,
        deltaTime: Float
    ) -> Float {
        let maxStep = max(0.001, rate) * deltaTime
        return current + (target - current).fwClamped(to: -maxStep...maxStep)
    }

    private func blendAngle(
        current: Float,
        target: Float,
        blend: Float
    ) -> Float {
        current + shortestAngleRadians(target - current) * blend.fwClamped(to: 0.0...1.0)
    }

    private func limitedCourseStep(
        from current: Float,
        to target: Float,
        maxStep: Float
    ) -> Float {
        guard current.isFinite, target.isFinite else {
            return target.isFinite ? target : current
        }
        let delta = shortestAngleRadians(target - current)
        if !maxStep.isFinite || maxStep <= 0.0 {
            return current + delta
        }
        let limited = delta.fwClamped(to: -maxStep...maxStep)
        return current + limited
    }
}

private func courseRadians(from direction: SIMD2<Float>) -> Float {
    atan2(-direction.x, -direction.y)
}

private func courseToPoint(
    from currentPosition: SIMD2<Float>,
    to targetPosition: SIMD2<Float>,
    fallback: Float
) -> Float {
    let delta = targetPosition - currentPosition
    guard simd_length_squared(delta) > 0.0001 else {
        return fallback
    }
    return courseRadians(from: simd_normalize(delta))
}

private func shortestAngleRadians(_ angle: Float) -> Float {
    var normalized = angle
    while normalized > .pi {
        normalized -= (.pi * 2.0)
    }
    while normalized < -.pi {
        normalized += (.pi * 2.0)
    }
    return normalized
}

private extension Float {
    var radiansToDegrees: Float {
        self * 180.0 / .pi
    }

    var degreesToRadians: Float {
        self * .pi / 180.0
    }

    func fwClamped(to range: ClosedRange<Float>) -> Float {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
