import Foundation

final class MissionPlanBuilder {
    private let previewBuilder: MissionPreviewBuilder
    private let validator: MissionPlanValidator
    private let multicopterRouteBuilder: MulticopterRouteBuilder
    private let fixedWingRouteBuilder: FixedWingRouteBuilder

    init(
        previewBuilder: MissionPreviewBuilder = MissionPreviewBuilder(),
        validator: MissionPlanValidator = MissionPlanValidator(),
        multicopterRouteBuilder: MulticopterRouteBuilder = MulticopterRouteBuilder(),
        fixedWingRouteBuilder: FixedWingRouteBuilder = FixedWingRouteBuilder()
    ) {
        self.previewBuilder = previewBuilder
        self.validator = validator
        self.multicopterRouteBuilder = multicopterRouteBuilder
        self.fixedWingRouteBuilder = fixedWingRouteBuilder
    }

    func buildPlan(
        from draft: MissionDraft,
        viewport: MapViewportState,
        airframeClass: AirframeClass = .multirotor,
        fixedWingParameters: FixedWingParameters? = nil
    ) -> MissionPlan {
        let previewRoute = previewBuilder.buildPreview(
            draft: draft,
            viewport: viewport,
            airframeClass: airframeClass,
            fixedWingParameters: fixedWingParameters
        )
        let validation = validator.validate(
            draft: draft,
            previewRoute: previewRoute,
            viewport: viewport
        )
        let routeBuild = buildRoute(
            from: previewRoute,
            airframeClass: airframeClass
        )
        let planWaypoints = draft.waypoints.map(MissionTarget.init)
        let executionTargets = buildExecutionTargets(
            waypoints: draft.waypoints,
            previewRoute: previewRoute,
            airframeClass: airframeClass
        )

        return MissionPlan(
            id: UUID(),
            builtAt: Date(),
            airframeKind: UAVAirframeKind(airframeClass),
            startPoint: routeBuild?.routePoints.first ?? previewRoute?.points.first ?? viewport.dockPosition,
            routePoints: routeBuild?.routePoints ?? previewRoute?.points ?? [],
            missionPoints: routeBuild?.missionPoints ?? previewRoute?.missionPlanPoints ?? [],
            routeKind: routeBuild?.routeKind ?? (airframeClass == .fixedWing ? .fixedWingFlyable : .multicopterPolyline),
            legs: routeBuild?.legs ?? [],
            launchMode: draft.selectedLaunchMode,
            launchObject: draft.launchObject,
            launchAsset: draft.launchObject?.launchAsset,
            waypoints: planWaypoints,
            executionTargets: executionTargets,
            zones: draft.zones,
            constraints: draft.constraints,
            status: validation.status,
            explanations: validation.explanations
        )
    }

    private func buildRoute(
        from previewRoute: MissionPreviewRoute?,
        airframeClass: AirframeClass
    ) -> MissionPlanRouteBuildResult? {
        guard let previewRoute else {
            return nil
        }

        switch airframeClass {
        case .multirotor:
            return multicopterRouteBuilder.build(from: previewRoute)
        case .fixedWing:
            return fixedWingRouteBuilder.build(from: previewRoute)
        }
    }

    private func buildExecutionTargets(
        waypoints: [MissionWaypoint],
        previewRoute: MissionPreviewRoute?,
        airframeClass: AirframeClass
    ) -> [MissionTarget] {
        if airframeClass == .fixedWing {
            return waypoints.map(MissionTarget.init)
        }

        guard let previewRoute,
              previewRoute.points.count >= 2,
              previewRoute.waypointExecutionPointIndices.count == waypoints.count else {
            return []
        }

        let waypointIndexByExecutionPoint = Dictionary(
            uniqueKeysWithValues: previewRoute.waypointExecutionPointIndices.enumerated().map { executionIndex, routePointIndex in
                (routePointIndex, executionIndex)
            }
        )

        return previewRoute.points.enumerated().compactMap { routePointIndex, point in
            guard routePointIndex > 0 else {
                return nil
            }
            guard let associatedWaypointIndex = previewRoute.waypointExecutionPointIndices.firstIndex(where: { $0 >= routePointIndex }),
                  associatedWaypointIndex < waypoints.count else {
                return nil
            }

            let waypoint = waypoints[associatedWaypointIndex]
            let countsTowardMissionProgress = waypointIndexByExecutionPoint[routePointIndex] != nil
            return MissionTarget(
                id: countsTowardMissionProgress ? waypoint.id : UUID(),
                waypointID: waypoint.id,
                index: routePointIndex - 1,
                label: waypoint.label,
                position: point,
                countsTowardMissionProgress: countsTowardMissionProgress
            )
        }
    }
}
