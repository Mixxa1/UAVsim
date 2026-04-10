import Foundation
import simd

struct MissionPlannerOutputs {
    var route: MissionRoute
    var validationResult: MissionValidationResult
    var feasibility: MissionFeasibility
}

final class MissionPlannerService {
    private let validationService = MissionValidationService()
    private let routeBuilder = MissionRouteBuilder()
    private let routeValidator = MissionRouteValidator()

    func resolvePlanningState(
        _ planningState: inout MissionPlanningState,
        context: MissionPlanningContext
    ) {
        let outputs = buildOutputs(
            for: planningState,
            context: context
        )
        planningState.route = outputs.route
        planningState.validationResult = outputs.validationResult
        planningState.feasibility = outputs.feasibility
    }

    func materializePlan(
        from planningState: MissionPlanningState,
        context: MissionPlanningContext
    ) -> MissionPlan? {
        var resolved = planningState
        resolvePlanningState(&resolved, context: context)
        return materializePlan(fromResolvedState: resolved, context: context)
    }

    func materializePlan(
        fromResolvedState planningState: MissionPlanningState,
        context: MissionPlanningContext
    ) -> MissionPlan? {
        guard hasNavigableMission(planningState),
              let validatedRoute = planningState.route.validatedRoute else {
            return nil
        }

        let cruiseAltitudeMeters = validatedRoute.cruiseAltitudeMeters
        let missionWaypoints = effectiveWaypoints(for: planningState)
        let plan = MissionPlan(
            id: UUID(),
            uavProfileID: context.selectedDroneProfile.id,
            homePoint: context.homePoint,
            waypoints: missionWaypoints,
            zones: planningState.activeZones,
            missionType: planningState.missionType,
            constraints: planningState.constraints,
            payloadAssignment: planningState.payloadAssignment,
            returnMode: planningState.returnMode,
            altitudeLimitMeters: planningState.altitudeLimitMeters,
            speedLimitMps: planningState.speedLimitMps,
            isFeasible: planningState.feasibility.isStartAllowed,
            status: planningState.validationResult.planStatus,
            route: planningState.route,
            validatedRoute: validatedRoute,
            feasibility: planningState.feasibility,
            validationResult: planningState.validationResult,
            phase: .preflight,
            returnPoint: planningState.returnPoint,
            isReadyForExecution: planningState.validationResult.isLaunchAllowed,
            cruiseAltitudeMeters: cruiseAltitudeMeters,
            createdAt: Date()
        )

        let runtimeValidation = routeValidator.validate(route: validatedRoute, for: plan)
        guard runtimeValidation.isValid else {
            return nil
        }

        return plan
    }

    private func buildOutputs(
        for planningState: MissionPlanningState,
        context: MissionPlanningContext
    ) -> MissionPlannerOutputs {
        guard hasPlanningContent(planningState) else {
            return MissionPlannerOutputs(
                route: .empty,
                validationResult: .empty,
                feasibility: .unresolved
            )
        }

        let route = buildRoute(
            for: planningState,
            context: context
        )
        let validationResult = validationService.validatePlan(
            planningState: planningState,
            route: route,
            context: context
        )

        return MissionPlannerOutputs(
            route: route,
            validationResult: validationResult,
            feasibility: MissionFeasibility(validationResult: validationResult)
        )
    }

    private func buildRoute(
        for planningState: MissionPlanningState,
        context: MissionPlanningContext
    ) -> MissionRoute {
        let missionWaypoints = effectiveWaypoints(for: planningState)
        guard !missionWaypoints.isEmpty else {
            return .empty
        }

        let cruiseAltitudeMeters = resolvedTravelAltitude(
            for: planningState,
            context: context
        )
        let cruiseSpeed = resolvedCruiseSpeed(
            for: planningState,
            context: context
        )
        let outboundGoals = missionWaypoints.map {
            $0.worldPosition(altitude: cruiseAltitudeMeters)
        }
        let returnGoal = resolvedReturnGoal(
            for: planningState,
            homePoint: context.homePoint,
            cruiseAltitudeMeters: cruiseAltitudeMeters
        )

        var allLegGoals = outboundGoals
        if let returnGoal {
            allLegGoals.append(returnGoal)
        }

        var combinedPath: [SIMD3<Float>] = []
        var totalLength: Float = 0.0
        var totalSegments = 0
        var returnLegStartRoutePointIndex: Int?
        var legStart = context.homePoint

        for (legIndex, goal) in allLegGoals.enumerated() {
            if legIndex == outboundGoals.count, !combinedPath.isEmpty {
                returnLegStartRoutePointIndex = max(0, combinedPath.count - 1)
            }

            let planner = AutoPathPlannerService()
            planner.planIfNeeded(
                start: legStart,
                goal: goal,
                terrain: context.terrain,
                obstacles: context.obstacles,
                droneRadius: context.droneRadius,
                modeTag: legIndex >= outboundGoals.count ? "mission_return_leg_\(legIndex)" : "mission_leg_\(legIndex)",
                reason: "mission_plan_build",
                missionZones: planningState.plannerZones
            )

            let snapshot = planner.snapshot(currentPosition: legStart)
            guard snapshot.status == .valid, snapshot.waypoints.count >= 2 else {
                return blockedRoute(
                    missionWaypoints: missionWaypoints,
                    zoneCount: planningState.activeZones.count,
                    cruiseSpeed: cruiseSpeed,
                    context: context,
                    reason: snapshot.reason
                )
            }

            var legPath = snapshot.waypoints
            legPath[legPath.count - 1] = goal

            if combinedPath.isEmpty {
                combinedPath.append(contentsOf: legPath)
            } else {
                combinedPath.append(contentsOf: legPath.dropFirst())
            }

            totalLength += max(snapshot.pathLengthMeters, Self.pathLength(of: legPath))
            totalSegments += max(0, legPath.count - 1)
            legStart = goal
        }

        guard let validatedRoute = routeBuilder.build(
            rawPath: combinedPath,
            missionWaypoints: missionWaypoints,
            cruiseAltitudeMeters: cruiseAltitudeMeters,
            returnLegStartRoutePointIndex: returnLegStartRoutePointIndex
        ) else {
            return blockedRoute(
                missionWaypoints: missionWaypoints,
                zoneCount: planningState.activeZones.count,
                cruiseSpeed: cruiseSpeed,
                context: context,
                reason: "route_builder_failed"
            )
        }

        let riskZoneIntersections = Self.riskZoneIntersections(
            path: validatedRoute.polyline,
            zones: planningState.activeZones.filter { $0.type.isRiskZone }
        )
        let metrics = buildMetrics(
            totalLength: totalLength,
            totalSegments: validatedRoute.segments.count,
            riskZoneIntersections: riskZoneIntersections,
            waypointCount: missionWaypoints.count,
            zoneCount: planningState.activeZones.count,
            cruiseSpeed: cruiseSpeed,
            context: context
        )

        return MissionRoute(
            previewPath: validatedRoute.polyline,
            confirmedPath: validatedRoute.polyline,
            operationalWaypoints: outboundGoals,
            metrics: metrics,
            requiresReplan: false,
            plannerStatus: .valid,
            blockedReasonKey: nil,
            validatedRoute: validatedRoute
        )
    }

    private func blockedRoute(
        missionWaypoints: [TargetMarkerState],
        zoneCount: Int,
        cruiseSpeed: Float,
        context: MissionPlanningContext,
        reason: String
    ) -> MissionRoute {
        MissionRoute(
            previewPath: [],
            confirmedPath: [],
            operationalWaypoints: missionWaypoints.map {
                $0.worldPosition(altitude: context.homePoint.y)
            },
            metrics: buildMetrics(
                totalLength: 0.0,
                totalSegments: 0,
                riskZoneIntersections: 0,
                waypointCount: missionWaypoints.count,
                zoneCount: zoneCount,
                cruiseSpeed: cruiseSpeed,
                context: context
            ),
            requiresReplan: false,
            plannerStatus: .blocked,
            blockedReasonKey: Self.plannerBlockedReasonKey(for: reason),
            validatedRoute: nil
        )
    }

    private func effectiveWaypoints(for planningState: MissionPlanningState) -> [TargetMarkerState] {
        var result = planningState.waypoints
        if result.isEmpty, let dropZone = planningState.dropZone {
            result.append(TargetMarkerState(position: dropZone.center))
        } else if planningState.missionType == .delivery,
                  let dropZone = planningState.dropZone,
                  let last = result.last,
                  simd_distance(last.position, dropZone.center) > max(1.0, dropZone.radius * 0.25) {
            result.append(TargetMarkerState(position: dropZone.center))
        }
        return result
    }

    private func resolvedReturnGoal(
        for planningState: MissionPlanningState,
        homePoint: SIMD3<Float>,
        cruiseAltitudeMeters: Float
    ) -> SIMD3<Float>? {
        switch planningState.returnMode {
        case .holdPosition:
            return nil
        case .returnHome:
            return SIMD3<Float>(homePoint.x, cruiseAltitudeMeters, homePoint.z)
        case .landAtDesignatedZone:
            if let returnPoint = planningState.returnPoint {
                return returnPoint.worldPosition(altitude: cruiseAltitudeMeters)
            }
            return SIMD3<Float>(homePoint.x, cruiseAltitudeMeters, homePoint.z)
        }
    }

    private func hasPlanningContent(_ planningState: MissionPlanningState) -> Bool {
        !planningState.waypoints.isEmpty ||
            planningState.dropZone != nil ||
            !planningState.activeZones.isEmpty
    }

    private func hasNavigableMission(_ planningState: MissionPlanningState) -> Bool {
        !effectiveWaypoints(for: planningState).isEmpty &&
            planningState.route.validatedRoute != nil
    }

    private func resolvedTravelAltitude(
        for planningState: MissionPlanningState,
        context: MissionPlanningContext
    ) -> Float {
        let terrainCeiling = max(6.0, context.terrain.maxFlightAltitude - 2.0)
        let requestedAltitude = planningState.constraints.maxAltitudeMeters
            ?? planningState.altitudeLimitMeters
            ?? terrainCeiling
        let clampedMaxAltitude = min(terrainCeiling, requestedAltitude)
        let minimumAltitude = min(
            clampedMaxAltitude,
            max(2.5, planningState.constraints.minAltitudeMeters ?? 2.5)
        )
        return max(
            context.homePoint.y + 4.5,
            minimumAltitude
        )
    }

    private func resolvedCruiseSpeed(
        for planningState: MissionPlanningState,
        context: MissionPlanningContext
    ) -> Float {
        let profileCeiling = max(4.0, context.selectedDroneProfile.maxHorizontalSpeedMps * 0.62)
        let plannedSpeed = planningState.speedLimitMps ?? profileCeiling
        return max(3.5, min(plannedSpeed, context.selectedDroneProfile.maxHorizontalSpeedMps))
    }

    private func buildMetrics(
        totalLength: Float,
        totalSegments: Int,
        riskZoneIntersections: Int,
        waypointCount: Int,
        zoneCount: Int,
        cruiseSpeed: Float,
        context: MissionPlanningContext
    ) -> MissionRouteMetrics {
        let estimatedFlightTimeSec = cruiseSpeed > 0.1
            ? totalLength / cruiseSpeed + Float(totalSegments) * 2.2
            : 0.0
        let complexity = min(
            1.0,
            Float(totalSegments) / 18.0 +
                Float(riskZoneIntersections) * 0.16 +
                max(0.0, context.terrain.density - 0.35) * 0.45
        )
        let obstacleRiskScore = min(
            1.0,
            max(0.0, context.terrain.density * 0.42) +
                Float(context.obstacles.count).squareRoot() * 0.025 +
                Float(riskZoneIntersections) * 0.08
        )

        return MissionRouteMetrics(
            lengthMeters: totalLength,
            segmentCount: totalSegments,
            estimatedComplexity: complexity,
            riskZoneIntersections: riskZoneIntersections,
            waypointCount: waypointCount,
            zoneCount: zoneCount,
            estimatedFlightTimeSec: estimatedFlightTimeSec,
            obstacleRiskScore: obstacleRiskScore
        )
    }

    private static func pathLength(of points: [SIMD3<Float>]) -> Float {
        guard points.count > 1 else { return 0.0 }
        var total: Float = 0.0
        for index in 1..<points.count {
            total += simd_distance(points[index - 1], points[index])
        }
        return total
    }

    private static func riskZoneIntersections(
        path: [SIMD3<Float>],
        zones: [MissionZone]
    ) -> Int {
        guard path.count > 1, !zones.isEmpty else { return 0 }
        var intersections = 0
        for zone in zones {
            if path.contains(where: { zone.contains(SIMD2<Float>($0.x, $0.z)) }) {
                intersections += 1
            }
        }
        return intersections
    }

    private static func plannerBlockedReasonKey(for reason: String) -> String {
        switch reason {
        case "no_free_start_or_goal":
            return "mission.preview.blocked.no_free_start_or_goal"
        case "astar_blocked":
            return "mission.preview.blocked.astar"
        case "grid_build_failed", "missing_grid":
            return "mission.preview.blocked.grid"
        default:
            return "mission.preview.blocked.generic"
        }
    }
}
