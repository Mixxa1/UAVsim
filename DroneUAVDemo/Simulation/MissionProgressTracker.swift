import Foundation
import simd

struct MissionProgressUpdate: Equatable {
    var distanceToActiveTarget: Float?
    var hasReachedActiveTarget: Bool
    var hasBoundTarget: Bool
}

final class MissionProgressTracker {
    private struct HybridVTOLProgressSample: Equatable {
        var targetID: UUID
        var targetIndex: Int
        var planarPosition: SIMD2<Float>
    }

    private var hybridVTOLProgressSample: HybridVTOLProgressSample?

    func evaluate(
        executionState: MissionExecutionState,
        planarPosition: SIMD2<Float>,
        currentMarker: TargetMarkerState?,
        autoNavigationStatus: AutoNavigationStatus,
        flightMode: DroneFlightMode,
        airframeClass: AirframeClass,
        fixedWingParameters: FixedWingParameters?,
        fixedWingDebugState: FixedWingAutopilotDebugState?,
        adapter: MissionAutopilotAdapter
    ) -> MissionProgressUpdate {
        guard let activeTarget = executionState.activeTarget else {
            resetHybridVTOLProgressSample()
            return MissionProgressUpdate(
                distanceToActiveTarget: nil,
                hasReachedActiveTarget: false,
                hasBoundTarget: false
            )
        }

        let distance = simd_distance(planarPosition, activeTarget.position)
        let fixedWingRouteCapable = airframeClass == .fixedWing || airframeClass == .hybridVTOL
        let isFixedWingRouteActive = fixedWingRouteCapable &&
            fixedWingRouteActive(debugState: fixedWingDebugState)
        let isHybridVTOLRouteGuidanceActive = airframeClass == .hybridVTOL &&
            (
                executionState.status == .running ||
                    flightMode == .autoPath ||
                    isFixedWingRouteActive
            )
        let arrivalRadius: Float = {
            switch airframeClass {
            case .multirotor:
                return 0.95
            case .fixedWing:
                return routeArrivalRadius(
                    for: airframeClass,
                    fixedWingParameters: fixedWingParameters
                )
            case .hybridVTOL:
                return isHybridVTOLRouteGuidanceActive
                    ? hybridVTOLArrivalRadius(
                        fixedWingParameters: fixedWingParameters,
                        activeTarget: activeTarget,
                        executionState: executionState
                    )
                    : hybridVTOLHoverArrivalRadius(for: fixedWingParameters)
            }
        }()
        let previousHybridVTOLPlanarPosition = previousHybridVTOLPlanarPosition(
            airframeClass: airframeClass,
            activeTarget: activeTarget,
            currentPosition: planarPosition
        )
        let hasBoundTarget: Bool = {
            if isFixedWingRouteActive {
                return true
            }
            let adapterHasBoundTarget = adapter.isBound(
                activeTarget: activeTarget,
                currentMarker: currentMarker
            )
            guard airframeClass == .hybridVTOL else {
                return adapterHasBoundTarget
            }

            // A running mission alone is not proof that hybrid guidance is
            // engaged. If the inner fixed-wing controller drops to manual or
            // hover between waypoints, reporting the target as bound prevents
            // DroneSimulationViewModel from rebinding it. Pause/resume then
            // appears to "fix" the route only because resume binds explicitly.
            // Takeoff is allowed while the bound target waits for the launch
            // handoff; normal route execution must actually be in autoPath.
            return adapterHasBoundTarget && (flightMode == .autoPath || flightMode == .takeoff)
        }()
        let autopilotSettled = !autoNavigationStatus.isActive ||
            autoNavigationStatus.phase == .hold ||
            (isFixedWingRouteActive && autoNavigationStatus.phase == .approach) ||
            flightMode != .autoPath
        let hasReachedActiveTarget: Bool = {
            guard hasBoundTarget else {
                return false
            }

            if airframeClass == .hybridVTOL {
                if distance <= arrivalRadius {
                    return true
                }
                guard let previousHybridVTOLPlanarPosition else {
                    return false
                }
                return motionSegmentIntersectsCircle(
                    from: previousHybridVTOLPlanarPosition,
                    to: planarPosition,
                    center: activeTarget.position,
                    radius: arrivalRadius
                )
            }

            if isFixedWingRouteActive,
               let fixedWingDebugState {
                if fixedWingDebugState.capturedMissionWaypointIndexAwaitingReplan
                    == activeTarget.index {
                    // This event comes only from the autopilot's swept physical capture. It is
                    // independent of the looser UI/progress arrival radius and lets the mission
                    // publish the next measured-pose route while the aircraft holds course.
                    return true
                }
                let controllerWaypointIndex = fixedWingDebugState.currentWaypointIndex
                let routeArrivalRadius = routeArrivalRadius(
                    for: airframeClass,
                    fixedWingParameters: fixedWingParameters
                )
                if controllerWaypointIndex > activeTarget.index {
                    return true
                }

                let finalStateReached = fixedWingDebugState.missionState == .loitering ||
                    fixedWingDebugState.missionState == .completed
                if controllerWaypointIndex >= activeTarget.index && finalStateReached {
                    return true
                }

                return controllerWaypointIndex >= activeTarget.index &&
                    distance <= routeArrivalRadius
            }

            return distance <= arrivalRadius && autopilotSettled
        }()

        return MissionProgressUpdate(
            distanceToActiveTarget: distance,
            hasReachedActiveTarget: hasReachedActiveTarget,
            hasBoundTarget: hasBoundTarget
        )
    }

    private func fixedWingRouteActive(
        debugState: FixedWingAutopilotDebugState?
    ) -> Bool {
        guard let debugState else {
            return false
        }
        switch debugState.missionState {
        case .idle, .failed:
            return false
        case .aligningToLaunch,
             .climbout,
             .capturingLeg,
             .trackingLeg,
             .flyByTurn,
             .loitering,
             .completed,
             .recoveringSpeed:
            return true
        }
    }

    private func fixedWingArrivalRadius(
        for fixedWingParameters: FixedWingParameters?
    ) -> Float {
        let wing = resolvedFixedWingParameters(fixedWingParameters)
        return max(wing.waypointAcceptanceRadiusMeters * 1.15, 10.0)
    }

    private func hybridVTOLArrivalRadius(
        for fixedWingParameters: FixedWingParameters?
    ) -> Float {
        let wing = resolvedFixedWingParameters(fixedWingParameters)
        if wing.family == .surveyEVTOL {
            return max(
                wing.waypointCaptureRadius(airspeed: wing.cruiseAirspeed),
                wing.waypointAcceptanceRadiusMeters * 1.05,
                8.0
            )
        }
        return max(
            wing.waypointCaptureRadius(airspeed: wing.cruiseAirspeed),
            wing.waypointAcceptanceRadiusMeters * 1.15,
            10.0
        )
    }

    private func hybridVTOLArrivalRadius(
        fixedWingParameters: FixedWingParameters?,
        activeTarget: MissionTarget,
        executionState: MissionExecutionState
    ) -> Float {
        let wing = resolvedFixedWingParameters(fixedWingParameters)
        let baseRadius = hybridVTOLArrivalRadius(for: fixedWingParameters)
        guard wing.family == .surveyEVTOL else {
            return baseRadius
        }

        var nearestSpacing = Float.greatestFiniteMagnitude
        for progress in executionState.waypointProgress {
            let target = progress.target
            if target.id == activeTarget.id &&
                target.index == activeTarget.index {
                continue
            }
            let spacing = simd_distance(target.position, activeTarget.position)
            if spacing > 0.001 {
                nearestSpacing = min(nearestSpacing, spacing)
            }
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

    private func hybridVTOLHoverArrivalRadius(
        for fixedWingParameters: FixedWingParameters?
    ) -> Float {
        let wing = resolvedFixedWingParameters(fixedWingParameters)
        switch wing.family {
        case .surveyEVTOL:
            return max(3.5, min(6.0, wing.waypointAcceptanceRadiusMeters * 0.45))
        case .tailsitterVTOL:
            return max(3.5, min(7.0, wing.waypointAcceptanceRadiusMeters * 0.50))
        default:
            return max(3.5, min(6.0, wing.waypointAcceptanceRadiusMeters * 0.45))
        }
    }

    private func routeArrivalRadius(
        for airframeClass: AirframeClass,
        fixedWingParameters: FixedWingParameters?
    ) -> Float {
        if airframeClass == .hybridVTOL {
            return hybridVTOLArrivalRadius(for: fixedWingParameters)
        }
        return fixedWingArrivalRadius(for: fixedWingParameters)
    }

    private func resolvedFixedWingParameters(
        _ fixedWingParameters: FixedWingParameters?
    ) -> FixedWingParameters {
        let wing = fixedWingParameters ?? FixedWingParameters(
            family: .conventionalSurvey,
            minSustainableSpeedMps: 10.0,
            cruiseSpeedMps: 17.0,
            climbSpeedMps: 13.0,
            stallWarningSpeedMps: 9.0,
            waypointAcceptanceRadiusMeters: 9.0,
            nominalTurnRateDegPerSec: 9.0,
            bankResponseGain: 0.72,
            climbResponseGain: 0.64,
            descentResponseGain: 0.54,
            dragFactor: 1.0,
            throttleResponseGain: 0.64,
            turnAuthority: 0.64,
            maxBankAngleDeg: 38.0
        )
        return wing
    }

    private func previousHybridVTOLPlanarPosition(
        airframeClass: AirframeClass,
        activeTarget: MissionTarget,
        currentPosition: SIMD2<Float>
    ) -> SIMD2<Float>? {
        guard airframeClass == .hybridVTOL else {
            resetHybridVTOLProgressSample()
            return nil
        }

        let previousPosition: SIMD2<Float>? = {
            guard let sample = hybridVTOLProgressSample,
                  sample.targetID == activeTarget.id,
                  sample.targetIndex == activeTarget.index else {
                return nil
            }
            return sample.planarPosition
        }()
        hybridVTOLProgressSample = HybridVTOLProgressSample(
            targetID: activeTarget.id,
            targetIndex: activeTarget.index,
            planarPosition: currentPosition
        )
        return previousPosition
    }

    private func resetHybridVTOLProgressSample() {
        hybridVTOLProgressSample = nil
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

        let rawT = simd_dot(center - start, delta) / lengthSquared
        let t = min(max(rawT, 0.0), 1.0)
        let closestPoint = start + delta * t
        return simd_distance(closestPoint, center) <= radius
    }
}
