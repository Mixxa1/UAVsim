import Foundation

final class MissionPlanBuilder {
    private let previewBuilder: MissionPreviewBuilder
    private let validator: MissionPlanValidator

    init(
        previewBuilder: MissionPreviewBuilder = MissionPreviewBuilder(),
        validator: MissionPlanValidator = MissionPlanValidator()
    ) {
        self.previewBuilder = previewBuilder
        self.validator = validator
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
        let planWaypoints = draft.waypoints.map(MissionTarget.init)
        let executionTargets = buildExecutionTargets(
            waypoints: draft.waypoints,
            previewRoute: previewRoute
        )

        return MissionPlan(
            id: UUID(),
            builtAt: Date(),
            startPoint: previewRoute?.missionPlanPoints.first ?? viewport.dockPosition,
            routePoints: previewRoute?.points ?? [],
            launchMode: draft.selectedLaunchMode,
            launchObject: draft.launchObject,
            waypoints: planWaypoints,
            executionTargets: executionTargets,
            zones: draft.zones,
            constraints: draft.constraints,
            status: validation.status,
            explanations: validation.explanations
        )
    }

    private func buildExecutionTargets(
        waypoints: [MissionWaypoint],
        previewRoute: MissionPreviewRoute?
    ) -> [MissionTarget] {
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
