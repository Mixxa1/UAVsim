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
        fixedWingParameters: FixedWingParameters? = nil,
        supportedLaunchModes: [LaunchMode] = LaunchMode.allCases
    ) -> MissionPlan {
        let previewRoute = previewBuilder.buildPreview(
            draft: draft,
            viewport: viewport,
            airframeClass: airframeClass,
            fixedWingParameters: fixedWingParameters
        )
        let launchPreview = previewBuilder.buildLaunchPreview(
            draft: draft,
            viewport: viewport,
            fixedWingParameters: fixedWingParameters,
            supportedLaunchModes: supportedLaunchModes
        )
        let validation = validator.validate(
            draft: draft,
            previewRoute: previewRoute,
            launchPreview: launchPreview,
            viewport: viewport,
            fixedWingParameters: fixedWingParameters,
            supportedLaunchModes: supportedLaunchModes
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
            launchAsset: resolvedLaunchAsset(
                from: draft.launchObject,
                fixedWingParameters: fixedWingParameters
            ),
            waypoints: planWaypoints,
            executionTargets: executionTargets,
            zones: draft.zones,
            constraints: draft.constraints,
            status: validation.status,
            explanations: validation.explanations
        )
    }

    private func resolvedLaunchAsset(
        from launchObject: MissionLaunchObject?,
        fixedWingParameters: FixedWingParameters?
    ) -> LaunchAsset? {
        guard var asset = launchObject?.launchAsset else {
            return nil
        }
        guard let fixedWingParameters else {
            return asset
        }
        switch asset {
        case .handLaunch(var hand):
            hand.releaseHeightMeters = fixedWingParameters.handReleaseHeightMeters
            asset = .handLaunch(hand)
        case .catapult(var catapult):
            catapult.rail.railLengthMeters = fixedWingParameters.catapultRailLengthMeters
            catapult.rail.usesRocketBooster = fixedWingParameters.catapultUsesRocketBooster
            asset = .catapult(catapult)
        case .canister:
            // The tube's geometry belongs to the launcher, not to the airframe's
            // catapult tuning. Which launcher it is, though, is the airframe's —
            // and this builder does not carry the profile, so the view model
            // resolves it in `activeLaunchAsset()`.
            break
        case .runway(var runway):
            // The strip has to be long enough for *this* airframe's roll, which
            // the drafted object cannot know: the same runway serves a 14 kg BWB
            // and a four-tonne turboprop.
            runway.usableLengthMeters = max(
                runway.usableLengthMeters,
                FixedWingRunwayGeometry.stripLength(for: fixedWingParameters)
            )
            asset = .runway(runway)
        }
        return asset
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
        case .fixedWing, .hybridVTOL:
            return fixedWingRouteBuilder.build(from: previewRoute)
        }
    }

    private func buildExecutionTargets(
        waypoints: [MissionWaypoint],
        previewRoute: MissionPreviewRoute?,
        airframeClass: AirframeClass
    ) -> [MissionTarget] {
        if airframeClass == .fixedWing || airframeClass == .hybridVTOL {
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
